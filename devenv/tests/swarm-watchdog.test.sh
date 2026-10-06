#!/usr/bin/env bash
# Behavior tests for devenv/swarm-watchdog.sh with a one-second check interval
# against a real, throwaway tmux server. Reuses the swarm fixture builder.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
watchdog="$here/../swarm-watchdog.sh"
export SWARM_STATUS="$here/../swarm-status.sh"
subject="$SWARM_STATUS"
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
eval "$(sed -n '/^busy_screen=/,/^status() /p' "$here/swarm-status.test.sh")"

# The fixture pane echoes typed input twice (terminal echo plus cat), so wakes
# are counted from the watchdog log; on_screen only proves the message arrives.
on_screen() { tmux -S "$sock" capture-pane -p -S -200 -t "swarmforge-$1" | grep -q 'new handoff mail'; }
wakes_in() { grep -cE "woke .*\\b$1\\b" "$root/.swarmforge/watchdog.log" 2>/dev/null || true; }
start_watchdog() {
  DEVENV_ROOT="$root" SWARM_WATCHDOG_INTERVAL=1 SWARM_WATCHDOG_MAX_WAKES=3 bash "$watchdog" &
  wd=$!
}
wait_for() { local i; for ((i = 0; i < 40; i++)); do eval "$1" && return 0; sleep 0.25; done; return 1; }

# 3-4: persistent stall is woken and logged; busy and mail-less roles are not
make_swarm "coder:idle_screen:1:0" "refactorer:busy_screen:0:1" "architect:idle_screen:0:0"
start_watchdog
wait_for 'on_screen coder' || fail "a role stalled across two checks is woken"
grep -q 'woke coder' "$root/.swarmforge/watchdog.log" || fail "the wake is logged"
(( $(wakes_in refactorer) == 0 )) || fail "a busy role is never woken"
(( $(wakes_in architect) == 0 )) || fail "an idle role without mail is never woken"

# 5: gives up after three unanswered wakes, then starts over once the role recovers
wait_for 'grep -q "coder still stalled after 3 wakes" "$root/.swarmforge/watchdog.log"' \
  || fail "it reports a role that ignores three wakes"
sleep 3
(( $(wakes_in coder) == 3 )) || fail "it stops at three wakes (got $(wakes_in coder))"
rm "$root/wt-coder/.swarmforge/handoffs/inbox/new/m0.handoff"
sleep 2.5
: > "$root/wt-coder/.swarmforge/handoffs/inbox/new/m1.handoff"
wait_for '(( $(wakes_in coder) >= 4 ))' || fail "a role that recovered and stalled again is woken again"

# 7: a second watchdog refuses to start
out="$(DEVENV_ROOT="$root" SWARM_WATCHDOG_INTERVAL=1 bash "$watchdog" 2>&1)"
grep -q 'already running' <<<"$out" || fail "a second watchdog refuses to start"
grep -q "Watchdog: running" <<<"$(status)" || fail "status reports the running watchdog"

# 6: exits when the swarm is gone
tmux -S "$sock" kill-server
wait_for '! kill -0 "$wd" 2>/dev/null' || fail "the watchdog exits when the swarm stops"
[[ ! -e "$root/.swarmforge/watchdog.pid" ]] || fail "the pid file is removed on exit"
kill "$wd" 2>/dev/null; rm -rf "$root"

# 8: an orphaned card is woken only after SWARM_WATCHDOG_ORPHAN_CHECKS consecutive checks
orphan_woken() { grep -qE 'woke architect \(idle card\)' "$root/.swarmforge/watchdog.log" 2>/dev/null; }
make_swarm "coder:idle_screen:0:0" "architect:idle_screen:0:0"
printf 'task-4-search\tarchitect\n' > "$root/.swarmforge/board/tasks.tsv"
DEVENV_ROOT="$root" SWARM_WATCHDOG_INTERVAL=1 SWARM_WATCHDOG_ORPHAN_CHECKS=3 bash "$watchdog" &
wd=$!
sleep 2.2
orphan_woken && fail "an orphan is not woken before its check threshold"
wait_for 'orphan_woken' || fail "an orphaned card's lane owner is woken after the threshold"
continue_on_screen() { tmux -S "$sock" capture-pane -p -S -200 -t swarmforge-architect | grep -q 'task-4-search is still in your lane'; }
wait_for 'continue_on_screen' || fail "the orphan receives the continue message"
(( $(wakes_in coder) == 0 )) || fail "roles that do not own the lane are not woken"
kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null; cleanup

if ((failures)); then echo "$failures failure(s)"; exit 1; fi
echo "all swarm-watchdog tests passed"
