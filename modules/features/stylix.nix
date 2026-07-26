# Stylix theming — one scheme definition driving both layers.
# The NixOS aspect themes the system, the homeManager aspect themes the user.
{ inputs, ... }:
let
  scheme = pkgs: "${pkgs.base16-schemes}/share/themes/onedark-dark.yaml";
in
{
  flake.modules.nixos.stylix = { pkgs, ... }: {
    imports = [ inputs.stylix.nixosModules.default ];

    stylix = {
      enable = true;
      base16Scheme = scheme pkgs;
      targets.plymouth.enable = false;
    };
  };

  flake.modules.homeManager.stylix = { pkgs, ... }: {
    imports = [ inputs.stylix.homeModules.stylix ];

    stylix = {
      enable = true;
      base16Scheme = scheme pkgs;

      icons = {
        enable = true;
        package = pkgs.tela-icon-theme;
        dark = "Tela-dark";
        light = "Tela";
      };

      fonts = {
        sansSerif = {
          package = pkgs.inter;
          name = "Inter";
        };
        serif = {
          package = pkgs.noto-fonts;
          name = "Noto Serif";
        };
        monospace = {
          package = pkgs.fira-code;
          name = "Fira Code";
        };
        emoji = {
          package = pkgs.noto-fonts-color-emoji;
          name = "Noto Color Emoji";
        };
      };

      # hyprland family is themed by hand in modules/features/hyprland.nix
      targets = {
        hyprland.enable = false;
        hyprlock.enable = false;
        hyprpaper.enable = false;
      };
    };

    # base16-schemes was a system package before; HM aspect owns it now.
    home.packages = [ pkgs.base16-schemes ];
  };
}
