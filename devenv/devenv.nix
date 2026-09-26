{ pkgs, inputs, ... }:
let
  # Backlog.md is not in nixpkgs; every other tool comes from the project's
  # nixpkgs pin so it is served from the binary cache instead of built locally.
  backlog-md = inputs.backlog-md.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  packages = [
    pkgs.git
    pkgs.tmux
    pkgs.babashka
    pkgs.quarto
    pkgs.just
    pkgs.claude-code
    pkgs.pi-coding-agent
    backlog-md
  ];

  # Agent panes inherit the tmux server's environment, and the role worktrees
  # never trigger direnv, so the swarm must be started from inside this shell.
  scripts.swarm-up.exec = ''exec "$DEVENV_ROOT/swarm" "$@"'';
  scripts.swarm-watch.exec = ''exec bash ${./swarm-watch.sh} "$@"'';
  scripts.swarm-status.exec = ''exec bash ${./swarm-status.sh} "$@"'';
  # The launcher only knows macOS `open`, so the dashboard never opens on Linux.
  scripts.dash.exec = ''exec xdg-open "$(cat "$DEVENV_ROOT/.swarmforge/dashboard-url")"'';
  scripts.board.exec = ''exec backlog browser "$@"'';
  scripts.docs-preview.exec = ''exec quarto preview "$DEVENV_ROOT/docs" "$@"'';
  scripts.docs-render.exec = ''exec quarto render "$DEVENV_ROOT/docs" "$@"'';
}
