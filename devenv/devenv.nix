{ pkgs, inputs, ... }:
let
  # Backlog.md is not in nixpkgs; every other tool comes from the project's
  # nixpkgs pin so it is served from the binary cache instead of built locally.
  backlog-md = inputs.backlog-md.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # nixpkgs pairs quarto 1.10 with pandoc 3.7, which rejects the
  # syntax-highlighting option quarto sends, so rendering writes nothing.
  # quarto 1.10 is built against pandoc 3.10; nixpkgs' newest pandoc (3.9)
  # is not in the binary cache, so use pandoc's static release build.
  quarto-pandoc = pkgs.stdenvNoCC.mkDerivation {
    pname = "pandoc-static";
    version = "3.10";
    src = pkgs.fetchurl {
      url = "https://github.com/jgm/pandoc/releases/download/3.10/pandoc-3.10-linux-amd64.tar.gz";
      hash = "sha256-4PivYtDyZ9IrqlvO/m1d2joJfMxg3nlLdZ/gMVmSMkQ=";
    };
    installPhase = "install -Dm755 bin/pandoc $out/bin/pandoc";
  };
in
{
  packages = [
    pkgs.git
    pkgs.tmux
    pkgs.babashka
    pkgs.quarto
    pkgs.just
    pkgs.claude-code
    backlog-md
  ];

  env.QUARTO_PANDOC = "${quarto-pandoc}/bin/pandoc";

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
