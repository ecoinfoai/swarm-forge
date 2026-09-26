#!/usr/bin/env bash
# Shows every agent of the running swarm as a read-only tiled pane in one
# terminal. Leave with the normal tmux detach (prefix, then d).
set -euo pipefail

root="${DEVENV_ROOT:?swarm-watch must run inside the project devenv shell}"
state="$root/.swarmforge"
[[ -r "$state/tmux-socket" && -r "$state/roles.tsv" ]] || {
  echo "swarm-watch: no running swarm in $root (start it with swarm-up)" >&2; exit 1; }
sock="$(<"$state/tmux-socket")"
tmux -S "$sock" has-session 2>/dev/null || {
  echo "swarm-watch: swarm tmux server is not running (start it with swarm-up)" >&2; exit 1; }

mapfile -t roles < <(cut -f1 "$state/roles.tsv")
mapfile -t sessions < <(cut -f4 "$state/roles.tsv")
view="swarm-view-$(basename "$root")"
viewer() { printf 'TMUX= tmux -S %q attach -r -t %q' "$sock" "$1"; }

tmux kill-session -t "$view" 2>/dev/null || true
tmux new-session -d -s "$view" -x 240 -y 60 "$(viewer "${sessions[0]}")"
tmux select-pane -t "$view" -T "${roles[0]}"
for i in "${!sessions[@]}"; do
  (( i == 0 )) && continue
  tmux split-window -t "$view" "$(viewer "${sessions[i]}")"
  tmux select-pane -t "$view" -T "${roles[i]}"
  tmux select-layout -t "$view" tiled >/dev/null
done
tmux set-option -t "$view" pane-border-status top >/dev/null
tmux set-option -t "$view" pane-border-format ' #{pane_title} ' >/dev/null

if [[ -n "${TMUX:-}" ]]; then
  exec tmux switch-client -t "$view"
fi
exec tmux attach -t "$view"
