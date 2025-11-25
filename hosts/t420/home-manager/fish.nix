{ pkgs, ... } : {
  
  programs.fish = {
    enable = true;

    shellAliases = let
      homePath = "~/nixos/home-manager";
    in {
      nxswitch = "nh os switch ~/nixos/";
      nxedit = "hx ~/nixos";
      nxeswitch = "hx ~/nixos/ && nh os switch ~/nixos/";

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
