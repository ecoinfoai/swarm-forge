#!/usr/bin/env bash
# Reports whether the running swarm is working, waiting on the operator, or
# stalled. A role is stalled when its agent is idle while handoff mail sits in
# its inbox: the daemon wakes a role once, and a missed wake leaves it idle.
# With --wake, resends the daemon's wake message to every stalled role.
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

wake=false
case "${1:-}" in
  "") ;;
  --wake) wake=true ;;
  *) echo "usage: swarm-status [--wake]" >&2; exit 2 ;;
esac

count() { find "$1" -maxdepth 1 -type f -name '*.handoff' 2>/dev/null | wc -l; }
plural() { (( $1 == 1 )) && echo "$1 $2" || echo "$1 ${2}s"; }

# Claude Code shows "<verb>… (<elapsed>" while a turn is running.
busy() { tmux -S "$sock" capture-pane -p -t "$1" | grep -qE '…[[:space:]]*\([0-9]+[hms]|esc to interrupt'; }

if [[ -r "$state/board/tasks.tsv" ]]; then
  while IFS=$'\t' read -r name lane _; do
    [[ -n "$name" ]] && printf 'Card: %s (lane: %s)\n' "$name" "$lane"
  done < "$state/board/tasks.tsv"
fi

approvals="$(count "$state/handoffs/pending_approval")"
clarifications="$(find "$state/dashboard/clarifications/pending" -maxdepth 1 -type f 2>/dev/null | wc -l)"
printf 'Attention: %s, %s\n' "$(plural "$approvals" approval)" "$(plural "$clarifications" clarification)"
(( approvals + clarifications > 0 )) && echo "  -> waiting on you: answer in the dashboard (dash)"

if tmux -S "$sock" list-clients -F '#{client_flags}' 2>/dev/null | grep -q 'read-only'; then
  echo "WARNING: a read-only client is attached; the daemon cannot wake roles until it detaches"
fi

printf '\n%-12s %-8s %4s %11s\n' ROLE STATE NEW IN-PROCESS
stalled=()
while IFS=$'\t' read -r role _ worktree session _; do
  [[ -z "$role" ]] && continue
  inbox="$worktree/.swarmforge/handoffs/inbox"
  new="$(count "$inbox/new")"
  inproc="$(count "$inbox/in_process")"
  if busy "$session"; then
    status=busy
  elif (( new + inproc > 0 )); then
    status=STALLED
    stalled+=("$role:$session")
  else
    status=idle
  fi
  printf '%-12s %-8s %4s %11s\n' "$role" "$status" "$new" "$inproc"
done < "$state/roles.tsv"

(( ${#stalled[@]} == 0 )) && exit 0
printf '\nStalled: %s\n' "$(printf '%s ' "${stalled[@]%%:*}")"
if ! $wake; then
  echo "  -> run 'swarm-status --wake' to resend the wake message"
  exit 0
fi
for entry in "${stalled[@]}"; do
  session="${entry#*:}"
  tmux -S "$sock" send-keys -t "$session" -l "$wake_message"
  sleep 0.15
  tmux -S "$sock" send-keys -t "$session" C-m
  echo "  woke ${entry%%:*}"
done
