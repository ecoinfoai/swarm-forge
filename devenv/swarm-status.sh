#!/usr/bin/env bash
# Reports whether the running swarm is working, waiting on the operator, or
# stalled. A role is stalled when its agent is idle while handoff mail sits in
# its inbox: the daemon wakes a role once, and a missed wake leaves it idle.
#   swarm-status                  table of cards, attention, and roles
#   swarm-status --list-stalled   stalled role names, one per line
#   swarm-status --wake [role…]   resend the wake message to stalled roles
#                                 (all of them, or only those named)
set -euo pipefail

wake_message="You have new handoff mail. If idle, run ready_for_next.sh."

root="${DEVENV_ROOT:?swarm-status must run inside the project devenv shell}"
state="$root/.swarmforge"
if [[ ! -r "$state/tmux-socket" || ! -r "$state/roles.tsv" ]]; then
  echo "swarm-status: no running swarm in $root (start it with swarm-up)" >&2
  exit 1
fi
sock="$(<"$state/tmux-socket")"
if ! tmux -S "$sock" has-session 2>/dev/null; then
  echo "swarm-status: no running swarm in $root (its tmux server is gone)" >&2
  exit 1
fi

mode=table
wanted=()
case "${1:-}" in
  "") ;;
  --list-stalled) mode=list ;;
  --wake) mode=wake; wanted=("${@:2}") ;;
  *) echo "usage: swarm-status [--list-stalled | --wake [role...]]" >&2; exit 2 ;;
esac

# Queue directories appear lazily; a missing one is an empty queue.
count() { [[ -d "$1" ]] || { echo 0; return; }; find "$1" -maxdepth 1 -type f -name "${2:-*.handoff}" | wc -l; }
plural() { (( $1 == 1 )) && echo "$1 $2" || echo "$1 ${2}s"; }

# Claude Code shows "<verb>… (<elapsed>" while a turn is running.
busy() { tmux -S "$sock" capture-pane -p -t "$1" | grep -qE '…[[:space:]]*\([0-9]+[hms]|esc to interrupt'; }

rows=()
stalled_roles=()
declare -A session_of=()
while IFS=$'\t' read -r role _ worktree session _; do
  [[ -z "$role" ]] && continue
  inbox="$worktree/.swarmforge/handoffs/inbox"
  new="$(count "$inbox/new")"
  inproc="$(count "$inbox/in_process")"
  if busy "$session"; then
    status=busy
  elif (( new + inproc > 0 )); then
    status=STALLED
    stalled_roles+=("$role")
    session_of[$role]="$session"
  else
    status=idle
  fi
  rows+=("$(printf '%-12s %-8s %4s %11s' "$role" "$status" "$new" "$inproc")")
done < "$state/roles.tsv"

case "$mode" in
  list)
    (( ${#stalled_roles[@]} )) && printf '%s\n' "${stalled_roles[@]}"
    exit 0 ;;
  wake)
    (( ${#wanted[@]} )) || wanted=("${stalled_roles[@]}")
    for role in "${wanted[@]}"; do
      session="${session_of[$role]:-}"
      [[ -z "$session" ]] && continue
      tmux -S "$sock" send-keys -t "$session" -l "$wake_message"
      sleep 0.15
      tmux -S "$sock" send-keys -t "$session" C-m
      echo "woke $role"
    done
    exit 0 ;;
esac

if [[ -r "$state/board/tasks.tsv" ]]; then
  while IFS=$'\t' read -r name lane _; do
    [[ -n "$name" ]] && printf 'Card: %s (lane: %s)\n' "$name" "$lane"
  done < "$state/board/tasks.tsv"
fi

approvals="$(count "$state/handoffs/pending_approval")"
clarifications="$(count "$state/dashboard/clarifications/pending" '*')"
printf 'Attention: %s, %s\n' "$(plural "$approvals" approval)" "$(plural "$clarifications" clarification)"
(( approvals + clarifications > 0 )) && echo "  -> waiting on you: answer in the dashboard (dash)"

pid="$(cat "$state/watchdog.pid" 2>/dev/null || true)"
if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
  echo "Watchdog: running (pid $pid), log in .swarmforge/watchdog.log"
else
  echo "Watchdog: not running (swarm-up starts it)"
fi

if tmux -S "$sock" list-clients -F '#{client_flags}' 2>/dev/null | grep -q 'read-only'; then
  echo "WARNING: a read-only client is attached; the daemon cannot wake roles until it detaches"
fi

printf '\n%-12s %-8s %4s %11s\n' ROLE STATE NEW IN-PROCESS
printf '%s\n' "${rows[@]}"

(( ${#stalled_roles[@]} == 0 )) && exit 0
printf '\nStalled: %s\n' "${stalled_roles[*]}"
echo "  -> run 'swarm-status --wake' to resend the wake message"
