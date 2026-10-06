#!/usr/bin/env bash
# Reports whether the running swarm is working, waiting on the operator, or
# stalled. A role is stalled when its agent is idle while handoff mail sits in
# its inbox: the daemon wakes a role once, and a missed wake leaves it idle.
# A card can also be orphaned: it sits in a role's lane while every role is idle
# and nothing is queued, waiting on the operator, or in flight. That happens when
# an agent ends its turn with work still open, and no mail exists to wake it.
#   swarm-status                  table of cards, attention, and roles
#   swarm-status --list-stalled   stalled role names, one per line
#   swarm-status --list-orphaned  lane owners of orphaned cards, one per line
#   swarm-status --wake [role…]   wake stalled roles and orphaned lane owners
#                                 (all of them, or only those named)
set -euo pipefail

wake_message="You have new handoff mail. If idle, run ready_for_next.sh."
orphan_message() { echo "Card $1 is still in your lane and you are idle. If your work on it is not finished, continue it; if it is finished, complete your handoff."; }

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
  --list-orphaned) mode=orphans ;;
  --wake) mode=wake; wanted=("${@:2}") ;;
  *) echo "usage: swarm-status [--list-stalled | --list-orphaned | --wake [role...]]" >&2; exit 2 ;;
esac

# Queue directories appear lazily; a missing one is an empty queue.
count() { [[ -d "$1" ]] || { echo 0; return; }; find "$1" -maxdepth 1 -type f -name "${2:-*.handoff}" | wc -l; }
plural() { (( $1 == 1 )) && echo "$1 $2" || echo "$1 ${2}s"; }

# Claude Code shows "<verb>… (<elapsed>" while a turn is running.
busy() { tmux -S "$sock" capture-pane -p -t "$1" | grep -qE '…[[:space:]]*\([0-9]+[hms]|esc to interrupt'; }

approvals="$(count "$state/handoffs/pending_approval")"
clarifications="$(count "$state/dashboard/clarifications/pending" '*')"

rows=()
stalled_roles=()
declare -A session_of=() any_session=()
busy_roles=0
queued=0
while IFS=$'\t' read -r role _ worktree session _; do
  [[ -z "$role" ]] && continue
  inbox="$worktree/.swarmforge/handoffs/inbox"
  new="$(count "$inbox/new")"
  inproc="$(count "$inbox/in_process")"
  queued=$(( queued + new + inproc + $(count "$worktree/.swarmforge/handoffs/outbox") ))
  any_session[$role]="$session"
  if busy "$session"; then
    status=busy
    busy_roles=$(( busy_roles + 1 ))
  elif (( new + inproc > 0 )); then
    status=STALLED
    stalled_roles+=("$role")
    session_of[$role]="$session"
  else
    status=idle
  fi
  rows+=("$(printf '%-12s %-8s %4s %11s' "$role" "$status" "$new" "$inproc")")
done < "$state/roles.tsv"

# Roles are the only lanes an agent can be woken in; "done" and unknown lanes
# are not an agent's to finish.
orphan_cards=()
declare -A orphan_of=()
if (( busy_roles + queued + approvals + clarifications == 0 )) && [[ -r "$state/board/tasks.tsv" ]]; then
  while IFS=$'\t' read -r name lane _; do
    [[ -n "$name" && -n "${any_session[$lane]:-}" ]] || continue
    orphan_of[$lane]="$name"
    orphan_cards+=("$name")
  done < "$state/board/tasks.tsv"
fi

case "$mode" in
  orphans)
    (( ${#orphan_of[@]} )) && printf '%s\n' "${!orphan_of[@]}"
    exit 0 ;;
  list)
    (( ${#stalled_roles[@]} )) && printf '%s\n' "${stalled_roles[@]}"
    exit 0 ;;
  wake)
    (( ${#wanted[@]} )) || wanted=("${stalled_roles[@]}" "${!orphan_of[@]}")
    for role in "${wanted[@]}"; do
      if [[ -n "${session_of[$role]:-}" ]]; then
        session="${session_of[$role]}"; message="$wake_message"
      elif [[ -n "${orphan_of[$role]:-}" ]]; then
        session="${any_session[$role]}"; message="$(orphan_message "${orphan_of[$role]}")"
      else
        continue
      fi
      tmux -S "$sock" send-keys -t "$session" -l "$message"
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

for lane in "${!orphan_of[@]}"; do
  printf '\nOrphaned: %s waits in lane %s but every role is idle\n' "${orphan_of[$lane]}" "$lane"
  echo "  -> run 'swarm-status --wake' to tell $lane to continue"
done

(( ${#stalled_roles[@]} == 0 )) && exit 0
printf '\nStalled: %s\n' "${stalled_roles[*]}"
echo "  -> run 'swarm-status --wake' to resend the wake message"
