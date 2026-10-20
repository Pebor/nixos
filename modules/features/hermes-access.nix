# SSH access for the Hermes agent (Docker container on t490s). Opt-in per
# host: importing this module lets the agent log in as `pebor` over SSH
# with its ed25519 key (the private key never leaves t490s). Pair it with
# the `ssh-server` feature - the agent needs an sshd to talk to.
#
# Also grants pebor passwordless `nixos-rebuild` and `nh` (arg globs, so
# every subcommand works) so remote maintenance does not stall on a sudo
# password. Everything else still needs the password.
#
# Policy (agreed 2026-10-20): read-only work on the host is free with an
# announcement; anything state-changing is announced and done after OK.
{
  flake.modules.nixos.hermes-access = {
    users.users.pebor.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOKfo9OXLvKFwAZ6SvyoOl0NPIdUUMLw4POqKkehATCh hermes@t490s"
    ];

    security.sudo.extraRules = [{
      users = [ "pebor" ];
      commands = [
        { command = "/run/current-system/sw/bin/nixos-rebuild *"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/nh *"; options = [ "NOPASSWD" ]; }
      ];
    }];
  };
}
