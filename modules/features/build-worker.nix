# Server side of distributed builds (t490s-server).
#
# Clients push builds over SSH as the locked-down `nixbuild` user. The
# private keys live on the clients (readable by root, since the nix daemon
# makes the SSH connection); the public halves are listed here.
#
# Adding another build client:
#   1. On the client: sudo ssh-keygen -t ed25519 -N "" -C "nixbuild@<host>" \
#        -f /root/.ssh/nixbuild_ed25519
#   2. Append the .pub line below (keep the `restrict` prefix).
#   3. Rebuild this host; the change can be applied remotely over SSH.
{
  flake.modules.nixos.build-worker = { pkgs, ... }: {
    users.groups.nixbuild = { };
    users.users.nixbuild = {
      isSystemUser = true;
      group = "nixbuild";
      # A real shell is required: the client's nix daemon executes nix-store /
      # nix-daemon commands over SSH. Key-only auth + `restrict` (no pty, no
      # forwarding) keep it locked down regardless.
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = [
        # nixbuild@t14 (/root/.ssh/nixbuild_ed25519 on t14)
        "restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEMy51UJMugO8JxyPxiIrFVApQJCB4akco87KLT0Z9GC nixbuild@t14"
        # nixbuild@desktop — TODO: add when desktop's keypair is generated
      ];
    };

    # Lets nixbuild pass substituter/options through the build connection.
    nix.settings.trusted-users = [ "nixbuild" ];

    # Conservative GC for a cache host: cached build results stay useful for
    # a month; GC-rooted paths (cache-warm out-links, system profiles) are
    # never touched regardless.
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
      randomizedDelaySec = "45min";
    };
  };
}
