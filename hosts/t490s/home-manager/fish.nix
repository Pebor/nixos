{ pkgs, ... } : {
  
  programs.fish = {
    enable = true;

    shellAliases = let
      globalNixosPath = "~/nixos";
      nixosPath = "${globalNixosPath}/hosts/$hostname";
      homePath = "${nixosPath}/home-manager";
    in {
      nxswitch = "nh os switch ${globalNixosPath}";
      nxedit = "hx ${nixosPath}";
      nxeswitch = "hx ${nixosPath} && nh os switch ${globalNixosPath}";

      hmswitch = "nh home switch ${homePath}";
      hmedit = "hx ${homePath}";
      hmeswitch = "hx ${homePath} && nh home switch ${homePath}";

      j = "z";
      zel = "zellij";

      ls = "eza --git";
      la = "eza --git --all";
      ll = "eza --git -al";

      ai = "aichat";
      aif = "aichat -f";
      aic = "aichat -c";
      aie = "aichat -e";
    };
  
    shellAbbrs = {
      nxshell = "nix shell nixpkgs#";
    };
    
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

}
