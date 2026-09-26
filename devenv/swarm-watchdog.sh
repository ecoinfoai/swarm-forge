#!/usr/bin/env bash
# Keeps the swarm from stalling on a missed wake-up. The handoff daemon wakes a
# role exactly once; if that wake is lost, the role idles with mail in its
# inbox forever. Every SWARM_WATCHDOG_INTERVAL seconds this re-wakes roles that
# were stalled at two consecutive checks (so it never races the daemon's own
# wake), gives up on a role after SWARM_WATCHDOG_MAX_WAKES unanswered wakes,
# and exits when the swarm's tmux server stops. swarm-up starts it.
set -euo pipefail

root="${DEVENV_ROOT:?swarm-watchdog must run inside the project devenv shell}"
state="$root/.swarmforge"
status="${SWARM_STATUS:-swarm-status}"
interval="${SWARM_WATCHDOG_INTERVAL:-120}"
max_wakes="${SWARM_WATCHDOG_MAX_WAKES:-3}"
pidfile="$state/watchdog.pid"
logfile="$state/watchdog.log"

[[ -r "$state/tmux-socket" ]] || { echo "swarm-watchdog: no running swarm in $root" >&2; exit 1; }
sock="$(<"$state/tmux-socket")"

if [[ -r "$pidfile" ]] && kill -0 "$(<"$pidfile")" 2>/dev/null; then
  echo "swarm-watchdog: already running (pid $(<"$pidfile"))"
  exit 0
fi
echo $$ > "$pidfile"
trap 'rm -f "$pidfile"' EXIT

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$logfile"; }
alive() { tmux -S "$sock" has-session 2>/dev/null; }
stalled_now() { DEVENV_ROOT="$root" "$status" --list-stalled 2>/dev/null || true; }
wake() { DEVENV_ROOT="$root" "$status" --wake "$@" >/dev/null; }

log "started (every ${interval}s, at most ${max_wakes} wakes per stall)"
declare -A previous=() wakes=()
while alive; do
  sleep "$interval"
  alive || break
  declare -A current=()
  while IFS= read -r role; do
    [[ -n "$role" ]] && current[$role]=1
  done < <(stalled_now)

  for role in "${!wakes[@]}"; do
    [[ -n "${current[$role]:-}" ]] || unset "wakes[$role]"
  done

  due=()
  for role in "${!current[@]}"; do
    [[ -n "${previous[$role]:-}" ]] || continue
    n="${wakes[$role]:-0}"
    if (( n < max_wakes )); then
      due+=("$role")
      wakes[$role]=$((n + 1))
    elif (( n == max_wakes )); then
      log "$role still stalled after $max_wakes wakes; needs the operator"
      wakes[$role]=$((n + 1))
    fi
  done
  if (( ${#due[@]} )); then
    log "woke ${due[*]}"
    wake "${due[@]}"
  fi

  previous=()
  for role in "${!current[@]}"; do previous[$role]=1; done
  unset current
done
log "swarm stopped; exiting"
