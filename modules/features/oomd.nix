# systemd-oomd out-of-memory killer acting on user sessions (t490s).
{
  flake.modules.nixos.oomd = {
    systemd.oomd = {
      enable = true;
      enableUserSlices = true; # Act on user sessions
    };
  };
}
