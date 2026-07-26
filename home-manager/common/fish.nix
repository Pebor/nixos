{ pkgs, ... } : {
  
  programs.fish = {
    enable = true;

    shellAliases = let
      globalNixosPath = "~/nixos";
      nixosPath = "${globalNixosPath}/hosts/$hostname";
      globalHomePath = "${globalNixosPath}/home-manager";
      homePath = "${nixosPath}/home-manager";
    in {
      nxswitch = "nh os switch ${globalNixosPath}";
      nxedit = "hx ${nixosPath}";
      nxeswitch = "hx ${nixosPath} && nh os switch ${globalNixosPath}";

      hmswitch = "nh home switch ${globalHomePath}";
      hmedit = "hx ${homePath}";
      hmeswitch = "hx ${homePath} && nh home switch ${globalHomePath}";

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

}
