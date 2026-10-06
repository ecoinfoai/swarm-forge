#!/usr/bin/env bash
# Behavior tests for devenv/swarm-status.sh against a real, throwaway tmux
# server whose panes print fixture agent screens.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
subject="$here/../swarm-status.sh"
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
expect_match() { grep -qE -- "$2" <<<"$1" || fail "$3 (no match for /$2/ in:\n$1)"; }
expect_no_match() { grep -qE -- "$2" <<<"$1" && fail "$3 (unexpected /$2/)"; return 0; }

busy_screen='✽ Percolating… (14s · ↓ 904 tokens · thinking with high effort)'
idle_screen='✻ Churned for 3m 8s · done'

# Builds a project with one role per argument "role:screen:new:in_process".
make_swarm() {
  root="$(mktemp -d)"
  sock="$root/tmux.sock"
  mkdir -p "$root/.swarmforge/handoffs/pending_approval" \
           "$root/.swarmforge/dashboard/clarifications/pending" \
           "$root/.swarmforge/board"
  echo "$sock" > "$root/.swarmforge/tmux-socket"
  : > "$root/.swarmforge/roles.tsv"
  local spec role screen new inproc wt
  for spec in "$@"; do
    IFS=: read -r role screen new inproc <<<"$spec"
    wt="$root/wt-$role"
    mkdir -p "$wt/.swarmforge/handoffs/inbox/new" "$wt/.swarmforge/handoffs/inbox/in_process"
    for ((i = 0; i < new; i++)); do : > "$wt/.swarmforge/handoffs/inbox/new/m$i.handoff"; done
    for ((i = 0; i < inproc; i++)); do : > "$wt/.swarmforge/handoffs/inbox/in_process/p$i.handoff"; done
    printf '%s\t%s\t%s\tswarmforge-%s\t%s\tclaude\ttask\tforward-only\n' \
      "$role" "$role" "$wt" "$role" "$role" >> "$root/.swarmforge/roles.tsv"
    printf '%s\n' "${!screen}" > "$root/$role.screen"
    tmux -S "$sock" new-session -d -s "swarmforge-$role" -x 120 -y 20 \
      "cat '$root/$role.screen'; exec cat"
  done
  sleep 0.3
}
cleanup() { tmux -S "$sock" kill-server 2>/dev/null; rm -rf "$root"; }
status() { DEVENV_ROOT="$root" bash "$subject" "$@" 2>&1; }

# 1-3: role states
make_swarm "coder:idle_screen:1:0" "refactorer:busy_screen:0:1" "architect:idle_screen:0:0"
out="$(status)"
expect_match "$out" '^coder +STALLED +1 +0' "idle role with mail is stalled"
expect_match "$out" '^refactorer +busy +0 +1' "working role is busy"
expect_match "$out" '^architect +idle +0 +0' "idle role without mail is idle"
expect_match "$out" 'Stalled: coder' "stalled roles are summarized"
cleanup

# 4: attention items
make_swarm "specifier:idle_screen:0:0"
: > "$root/.swarmforge/handoffs/pending_approval/50_x_from_specifier_to_coder.handoff"
: > "$root/.swarmforge/dashboard/clarifications/pending/clar-1.request"
out="$(status)"
expect_match "$out" 'Attention: 1 approval, 1 clarification' "attention counts are shown"
cleanup

# 5: read-only viewer warning
make_swarm "coder:idle_screen:0:0"
script -qc "tmux -S '$sock' attach -r -t swarmforge-coder" /dev/null >/dev/null 2>&1 &
viewer=$!
sleep 0.5
out="$(status)"
expect_match "$out" 'read-only' "an attached read-only client is reported"
kill "$viewer" 2>/dev/null
cleanup

# 6: no swarm
root="$(mktemp -d)"; sock="$root/none.sock"
out="$(status)"; code=$?
[[ $code -eq 1 ]] || fail "missing swarm exits 1 (got $code)"
expect_match "$out" 'no running swarm' "missing swarm is explained"
rm -rf "$root"

# 7: --wake reaches stalled roles only
make_swarm "coder:idle_screen:1:0" "architect:idle_screen:0:0"
status --wake >/dev/null
sleep 0.5
expect_match "$(tmux -S "$sock" capture-pane -p -t swarmforge-coder)" 'new handoff mail' "stalled role is woken"
expect_no_match "$(tmux -S "$sock" capture-pane -p -t swarmforge-architect)" 'new handoff mail' "idle role without mail is left alone"
cleanup

# 8: stalled roles as a plain list
make_swarm "coder:idle_screen:1:0" "refactorer:busy_screen:0:1" "architect:idle_screen:0:0"
expect_match "$(status --list-stalled)" '^coder$' "list-stalled prints the stalled role"
[[ "$(status --list-stalled | wc -l)" -eq 1 ]] || fail "list-stalled prints only stalled roles"
cleanup

# 9: --wake with names wakes only those still stalled
make_swarm "coder:idle_screen:1:0" "architect:idle_screen:1:0" "refactorer:idle_screen:0:0"
status --wake architect refactorer >/dev/null
sleep 0.5
expect_match "$(tmux -S "$sock" capture-pane -p -t swarmforge-architect)" 'new handoff mail' "named stalled role is woken"
expect_no_match "$(tmux -S "$sock" capture-pane -p -t swarmforge-coder)" 'new handoff mail' "unnamed stalled role is left alone"
expect_no_match "$(tmux -S "$sock" capture-pane -p -t swarmforge-refactorer)" 'new handoff mail' "named role that is not stalled is left alone"
cleanup

# 10: status reports the watchdog
make_swarm "coder:idle_screen:0:0"
expect_match "$(status)" 'Watchdog: not running' "a missing watchdog is reported"
cleanup

# 11: a fresh swarm has not created every queue directory yet
make_swarm "coder:idle_screen:1:0"
rm -rf "$root/wt-coder/.swarmforge/handoffs/inbox/in_process" \
       "$root/.swarmforge/handoffs/pending_approval" "$root/.swarmforge/dashboard" "$root/.swarmforge/board"
out="$(status)"; code=$?
[[ $code -eq 0 ]] || fail "missing queue directories do not fail the report (exit $code)"
expect_match "$out" '^coder +STALLED +1 +0' "missing directories count as empty"
expect_match "$(status --list-stalled)" '^coder$' "list-stalled survives missing directories"
cleanup

# 12: a live card whose every role is idle is orphaned; the lane owner is named
card() { printf '%s\t%s\n' "$1" "$2" > "$root/.swarmforge/board/tasks.tsv"; }
make_swarm "coder:idle_screen:0:0" "architect:idle_screen:0:0"
card task-4-search architect
expect_match "$(status --list-orphaned)" '^architect$' "list-orphaned names the lane owner"
out="$(status)"
expect_match "$out" 'Orphaned: task-4-search .*architect' "the table reports the orphaned card"
expect_no_match "$out" 'Stalled:' "an orphaned card is not a mail stall"
cleanup

# 13: anything that explains the silence means the card is not orphaned
orphans() { status --list-orphaned | wc -l; }
make_swarm "coder:idle_screen:0:0" "architect:busy_screen:0:0"
card task-4-search coder
[[ "$(orphans)" -eq 0 ]] || fail "a working role means the card is not orphaned"
cleanup
make_swarm "coder:idle_screen:1:0" "architect:idle_screen:0:0"
card task-4-search architect
[[ "$(orphans)" -eq 0 ]] || fail "mail in an inbox is a stall, not an orphan"
cleanup
make_swarm "coder:idle_screen:0:0" "architect:idle_screen:0:0"
card task-4-search architect
mkdir -p "$root/wt-coder/.swarmforge/handoffs/outbox"; : > "$root/wt-coder/.swarmforge/handoffs/outbox/o.handoff"
[[ "$(orphans)" -eq 0 ]] || fail "a handoff still in an outbox is in flight"
cleanup
make_swarm "coder:idle_screen:0:0" "architect:idle_screen:0:0"
card task-4-search architect
: > "$root/.swarmforge/handoffs/pending_approval/50_x.handoff"
[[ "$(orphans)" -eq 0 ]] || fail "a pending approval means the card waits for the operator"
cleanup
make_swarm "coder:idle_screen:0:0" "architect:idle_screen:0:0"
card task-4-search architect
: > "$root/.swarmforge/dashboard/clarifications/pending/clar-1.request"
[[ "$(orphans)" -eq 0 ]] || fail "a pending clarification means the card waits for the operator"
cleanup
make_swarm "coder:idle_screen:0:0" "architect:idle_screen:0:0"
card task-4-search done
[[ "$(orphans)" -eq 0 ]] || fail "a done card is not orphaned"
cleanup
make_swarm "coder:idle_screen:0:0" "architect:idle_screen:0:0"
card task-4-search nowhere
[[ "$(orphans)" -eq 0 ]] || fail "a lane no role owns is never woken"
cleanup

# 14: --wake nudges the orphaned lane owner with a continue message, not the mail one
make_swarm "coder:idle_screen:0:0" "architect:idle_screen:0:0"
card task-4-search architect
status --wake >/dev/null
sleep 0.5
expect_match "$(tmux -S "$sock" capture-pane -p -t swarmforge-architect)" 'task-4-search is still in your lane' "the lane owner is told to continue"
expect_no_match "$(tmux -S "$sock" capture-pane -p -t swarmforge-architect)" 'new handoff mail' "an orphan is not told about mail it does not have"
expect_no_match "$(tmux -S "$sock" capture-pane -p -t swarmforge-coder)" 'still in your lane' "other roles are left alone"
cleanup

if ((failures)); then echo "$failures failure(s)"; exit 1; fi
echo "all swarm-status tests passed"
