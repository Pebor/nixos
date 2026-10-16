# fish shell + plugins. Aliases point at the new dendritic layout:
# host files live in modules/hosts/<hostname>.nix, shared HM modules in
# modules/home/. No more --impure anywhere.
{
  flake.modules.homeManager.fish = { pkgs, ... }: {
    programs.fish = {
      enable = true;

      shellAliases = let
        globalNixosPath = "~/nixos";
        hostPath = "${globalNixosPath}/modules/hosts/$hostname.nix";
        homePath = "${globalNixosPath}/modules/home";
        featPath = "${globalNixosPath}/modules/features";
        modPath = "${globalNixosPath}/modules";

      in {
        nxswitch = "nh os switch ${globalNixosPath}";
        nxedit = "hx ${hostPath}";
        nxeswitch = "hx ${hostPath} && nh os switch ${globalNixosPath}";

        hmswitch = "nh home switch ${globalNixosPath}";
        hmedit = "hx ${homePath}";
        hmeswitch = "hx ${homePath} && nh home switch ${globalNixosPath}";

        featedit = "hx ${featPath}";
        modedit = "hx ${modPath}";

        # independent update cadence for system vs home manager
        nxupdate = "nix flake update nixpkgs --flake ${globalNixosPath}";
        hmupdate = "nix flake update nixpkgs-hm --flake ${globalNixosPath}";

        j = "z";
        zel = "zellij";

        ls = "eza --git";
        la = "eza --git --all";
        ll = "eza --git -al";
      };

      shellAbbrs = {
        nxshell = "nix shell nixpkgs#";
        gtc = "git commit";
        gta = "git add .";
        gtp = "git push";
      };

      interactiveShellInit = ''
        if type -q devenv
          devenv hook fish | source
        end
      '';
    };

    home.packages = with pkgs; [
      fishPlugins.fzf-fish
      fishPlugins.puffer
      fishPlugins.grc
      fishPlugins.done
      fishPlugins.fish-you-should-use
      fishPlugins.z

      fd
      fzf
      grc
    ];
  };
}
