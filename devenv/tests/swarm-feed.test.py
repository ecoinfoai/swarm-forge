#!/usr/bin/env python3
"""Tests for devenv/swarm-feed. Run with: python3 devenv/tests/swarm-feed.test.py

The unit tests cover the decision rule. The integration tests start the real
SwarmForge dashboard server on a temporary project root (no agents) and are
skipped when babashka is not installed.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "swarm-feed"
PROJECT = HERE.parent.parent


def load_feed():
    loader = importlib.machinery.SourceFileLoader("swarm_feed", str(SCRIPT))
    spec = importlib.util.spec_from_loader("swarm_feed", loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules["swarm_feed"] = module
    loader.exec_module(module)
    return module


feed = load_feed()


def task(n: int, status: str = "To Do") -> "feed.Task":
    return feed.Task(id=f"TASK-{n}", title=f"Card number {n}", status=status)


def snapshot(**overrides) -> "feed.Snapshot":
    base = dict(
        live_cards=[],
        board_names=set(),
        approvals=[],
        clarifications=0,
        queued_handoffs=0,
        tasks=[task(1), task(2)],
    )
    base.update(overrides)
    return feed.Snapshot(**base)


def decide(snap, **kwargs):
    options = dict(auto_approve=False, until=None, quiet_polls=2, settle=2)
    options.update(kwargs)
    return feed.decide(snap, **options)


class CardNameTest(unittest.TestCase):
    def test_name_joins_task_number_and_title_slug(self):
        self.assertEqual(
            feed.card_name("TASK-1", "Ingest pilot regulations from reg-ledger and list them"),
            "task-1-ingest-pilot-regulations",
        )

    def test_name_keeps_three_words_and_drops_punctuation(self):
        self.assertEqual(feed.card_name("TASK-2", "Show a regulation's table of contents"),
                         "task-2-show-a-regulation")


class DecideTest(unittest.TestCase):
    def test_idle_swarm_feeds_first_open_task(self):
        action = decide(snapshot())
        self.assertEqual((action.kind, action.task_id), ("feed", "TASK-1"))
        self.assertEqual(action.card, "task-1-card-number-1")

    def test_active_card_waits(self):
        action = decide(snapshot(live_cards=["task-1-card-number-1"]))
        self.assertEqual(action.kind, "wait")

    def test_queued_handoffs_wait(self):
        self.assertEqual(decide(snapshot(queued_handoffs=1)).kind, "wait")

    def test_idle_must_hold_for_settle_polls(self):
        self.assertEqual(decide(snapshot(), quiet_polls=1).kind, "wait")

    def test_pending_approval_waits_without_auto_approve(self):
        action = decide(snapshot(approvals=["a1"]))
        self.assertEqual((action.kind, action.needs_operator), ("wait", True))

    def test_pending_approval_is_approved_with_auto_approve(self):
        action = decide(snapshot(approvals=["a1", "a2"]), auto_approve=True)
        self.assertEqual((action.kind, action.approvals), ("approve", ["a1", "a2"]))

    def test_pending_clarification_waits_even_with_auto_approve(self):
        action = decide(snapshot(clarifications=1), auto_approve=True)
        self.assertEqual((action.kind, action.needs_operator), ("wait", True))

    def test_next_task_is_fed_after_previous_is_done(self):
        action = decide(snapshot(tasks=[task(1, "Done"), task(2)],
                                 board_names={"task-1-card-number-1"}))
        self.assertEqual((action.kind, action.task_id), ("feed", "TASK-2"))

    def test_all_done_finishes(self):
        action = decide(snapshot(tasks=[task(1, "Done"), task(2, "Done")]))
        self.assertEqual(action.kind, "finished")

    def test_unfinished_task_without_card_stops(self):
        action = decide(snapshot(tasks=[task(1, "In Progress"), task(2)]))
        self.assertEqual(action.kind, "stop")

    def test_card_already_on_board_for_open_task_stops(self):
        action = decide(snapshot(board_names={"task-1-card-number-1"}))
        self.assertEqual(action.kind, "stop")

    def test_until_stops_feeding_after_named_task(self):
        action = decide(snapshot(tasks=[task(1, "Done"), task(2)]), until="TASK-1")
        self.assertEqual(action.kind, "finished")

    def test_until_still_feeds_named_task(self):
        action = decide(snapshot(), until="TASK-1")
        self.assertEqual((action.kind, action.task_id), ("feed", "TASK-1"))


ROLES = ["specifier", "coder", "refactorer", "architect"]


@unittest.skipUnless(shutil.which("bb"), "babashka (bb) is required for the dashboard server")
class DashboardIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="feed-"))
        self.root = self.tmp / "root"
        shutil.copytree(PROJECT / "swarmforge", self.root / "swarmforge")
        state = self.root / ".swarmforge"
        state.mkdir()
        rows = []
        for role in ROLES:
            worktree = self.root if role == "specifier" else self.root / ".worktrees" / role
            (worktree / ".swarmforge" / "handoffs" / "inbox" / "new").mkdir(parents=True, exist_ok=True)
            name = "master" if role == "specifier" else role
            rows.append("\t".join([role, name, str(worktree), f"sf-{role}", role, "claude", "task", "forward-only"]))
        (state / "roles.tsv").write_text("\n".join(rows) + "\n")

        self.tasks_file = self.tmp / "tasks.json"
        self.set_tasks([("TASK-1", "First card", "To Do"), ("TASK-2", "Second card", "To Do")])
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "backlog"
        stub.write_text(f"#!/bin/sh\ncat '{self.tasks_file}'\n")
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
        self.env = dict(os.environ, DEVENV_ROOT=str(self.root),
                        PATH=f"{bin_dir}:{os.environ['PATH']}", SWARM_FEED_NOTIFY="0")

        self.log = open(self.tmp / "dashboard.log", "w")
        self.server = subprocess.Popen(
            [str(self.root / "swarmforge" / "scripts" / "pack_web.sh"), "--serve", str(self.root)],
            stdout=self.log, stderr=subprocess.STDOUT)
        url_file = state / "dashboard-url"
        deadline = time.time() + 20
        while not url_file.exists() and time.time() < deadline:
            time.sleep(0.1)
        self.url = url_file.read_text().strip()

    def tearDown(self):
        self.server.terminate()
        self.server.wait(timeout=10)
        self.log.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def set_tasks(self, rows):
        tasks = [{"id": i, "title": t, "status": s, "ordinal": 1000 * n, "labels": ["demo"]}
                 for n, (i, t, s) in enumerate(rows, start=1)]
        self.tasks_file.write_text(json.dumps({"schemaVersion": 1, "kind": "tasks", "tasks": tasks}))

    def run_feed(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), "--once", "--settle", "1", *args],
                              env=self.env, capture_output=True, text=True, timeout=60)

    def board(self):
        with urllib.request.urlopen(self.url + "/api/state", timeout=10) as response:
            return {t["name"]: t["lane"] for t in json.load(response)["tasks"]}

    def deliver_queued_notes(self):
        for note in (self.root / ".swarmforge" / "handoffs" / "outbox").glob("*.handoff"):
            note.unlink()

    def finish_card(self, name):
        subprocess.run([str(self.root / "swarmforge" / "scripts" / "pack_board.sh"), "done",
                        "--root", str(self.root), "--name", name], check=True, capture_output=True)

    def test_feeds_one_card_then_waits_then_feeds_the_next(self):
        first = self.run_feed()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(self.board(), {"task-1-first-card": "specifier"})

        waiting = self.run_feed()
        self.assertEqual(self.board(), {"task-1-first-card": "specifier"}, waiting.stdout)

        self.deliver_queued_notes()
        self.finish_card("task-1-first-card")
        self.set_tasks([("TASK-1", "First card", "Done"), ("TASK-2", "Second card", "To Do")])
        self.run_feed()
        self.assertEqual(self.board().get("task-2-second-card"), "specifier")

    def test_done_card_with_open_task_stops_with_exit_1(self):
        self.run_feed()
        self.deliver_queued_notes()
        self.finish_card("task-1-first-card")
        result = self.run_feed()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertNotIn("task-2-second-card", self.board())

    def test_dry_run_creates_nothing(self):
        result = self.run_feed("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.board(), {})

    def test_until_finishes_without_feeding_later_tasks(self):
        self.set_tasks([("TASK-1", "First card", "Done"), ("TASK-2", "Second card", "To Do")])
        result = self.run_feed("--until", "TASK-1")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.board(), {})

    def pending_approval(self):
        pending = self.root / ".swarmforge" / "handoffs" / "pending_approval"
        pending.mkdir(parents=True, exist_ok=True)
        file = pending / "40_spec_from_specifier_to_coder.handoff"
        file.write_text("id: spec1\nfrom: specifier\nto: coder\ntype: git_handoff\n"
                        "task: task-1-first-card\n\nspec ready\n")
        return file

    def test_auto_approve_releases_a_pending_specification(self):
        file = self.pending_approval()
        result = self.run_feed("--auto-approve")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(file.exists())
        released = self.root / ".swarmforge" / "handoffs" / "outbox" / file.name
        self.assertIn("approved: true", released.read_text())

    def test_pending_specification_is_left_alone_without_auto_approve(self):
        file = self.pending_approval()
        self.run_feed()
        self.assertTrue(file.exists())
        self.assertEqual(self.board(), {})

    def test_unknown_until_task_is_a_usage_error(self):
        self.assertEqual(self.run_feed("--until", "TASK-99").returncode, 2)

    def test_missing_swarm_exits_1(self):
        (self.root / ".swarmforge" / "dashboard-url").unlink()
        self.assertEqual(self.run_feed().returncode, 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
