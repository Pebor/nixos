# Quiet boot with plymouth splash (t490s).
{
  flake.modules.nixos.plymouth = { pkgs, ... }: {
    boot.plymouth = {
      enable = true;
      theme = "connect";
      themePackages = with pkgs; [
        (adi1090x-plymouth-themes.override {
          selected_themes = [ "connect" ];
        })
      ];
    };

    boot.loader.timeout = 0;
    boot.kernelParams = [
      "quiet"
      "splash"
      "boot.shell_on_fail"
    ];
  };
}
