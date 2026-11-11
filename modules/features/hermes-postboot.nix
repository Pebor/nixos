{ pkgs, ... }:
# Post-boot verification: after every boot, prove the machine came back.
#
# It waits for hermes-native, counts containers, probes the public hostnames and
# sends ONE Telegram line straight from the host (curl + the bot token in
# /var/lib/hermes/.env) — so the signal arrives even when the agent itself is
# the thing that failed. Full detail lands in /home/server/.postboot.log.
#
# Why a unit and not a "detached script": a transient unit or a background
# docker container does not survive a reboot; this does.
{
  flake.modules.nixos.hermes-postboot = { pkgs, ... }: {
    systemd.services.hermes-postboot-verify = {
      description = "Post-boot health verification (one-line Telegram report)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "hermes-native.service" "docker.service" "network-online.target" ];
      path = with pkgs; [ bash coreutils curl docker systemd gawk gnugrep gnused ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.bash}/bin/bash ${./scripts/postboot-verify.sh}";
      };
    };
  };
}
