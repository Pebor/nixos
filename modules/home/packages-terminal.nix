# Terminal programs (superset of the old per-host copies).
{ inputs, ... }:
{
  flake.modules.homeManager.packages-terminal = { pkgs, ... }:
    let
      # TEMPORARY package patch — delete once nixpkgs ships a complete tree.
      #
      # nixpkgs' pi-coding-agent 1.5.0 installs the monorepo workspaces by
      # whitelist and then deletes every remaining @earendil-works/* symlink.
      # The whitelist predates pi 1.5.0's new packages/schema workspace
      # (@earendil-works/pi-schema), which pi-ai 1.5.0 declares as a dependency,
      # so the validator never reaches the store and every *subagent* dies at
      # startup with ERR_MODULE_NOT_FOUND. The TUI survives because it never
      # statically imports pi-ai.
      #
      # This is the same one line upstream needs — add pi-schema to the
      # postInstall loop in pkgs/by-name/pi/pi-coding-agent/package.nix.
      # Everything is built from the source tree; nothing is fetched.
      piAgent = pkgs.pi-coding-agent.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          cp -r packages/schema \
            "$out/lib/node_modules/pi-monorepo/node_modules/@earendil-works/pi-schema"
        '';
      });
    in
    {
      home.packages = with pkgs; [
        # Terminals
        foot
        ratty

        git
        jujutsu

        inputs.helix.packages.${pkgs.stdenv.hostPlatform.system}.default

        nh
        comma
        nix-index

        antigravity-cli

        btop
        bottom

        bat
        eza
        dust
        ripgrep
        jq
        tldr

        ffmpeg
        imagemagick

        nushell
        brush

        fastfetch
        powertop
        bluetui
        spotify-player
        systemctl-tui
        lazygit

        zellij
        yazi

        # opencode from the temporary nixpkgs-opencode pin (2.2.1): 2.2.5 in
        # unstable cannot build (NixOS/nixpkgs#582673). Revert to plain `opencode`
        # and drop the input once unstable ships a buildable 2.2.5.
        inputs.nixpkgs-opencode.legacyPackages.${pkgs.stdenv.hostPlatform.system}.opencode

        # pi (minimal harness): 4 tools, ~4x leaner requests than opencode,
        # uses the same OpenCode Go subscription. Kept side by side on purpose.
        # Patched above: see piAgent for why it is not plain `pi-coding-agent`.
        piAgent
        nodejs_22 # `pi install` / `pi update` shell out to npm
      ];
    };
}
