# Hardened OpenSSH server (t420-server).
{
  flake.modules.nixos.ssh-server = {
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };
}
