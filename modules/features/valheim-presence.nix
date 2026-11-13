# valheim-presence — kdo je ve Valheimu, pro monitorovací tab v tasks-app.
#
# Proč: monitorovací obrazovka appky má ukázat, jestli si Llyfr (bratr) zrovna hraje.
# Valheim nemá admin API, jeho query port neodpovídá na A2S dotaz a RCON by vyžadoval
# heslo — jediný bezplatný signál je log dedicated serveru, který streamuje
# `valheim-presence.sh` přes ssh z VPS. Skript zapisuje stav do
# /home/server/tasks-api/data/valheim-presence.json a tasks-api ho servíruje appce
# na /api/v1/status. Žádná tajemství, žádné hlasování v intervalu.
#
# Stav: systemctl status valheim-presence
#        cat ~/tasks-api/data/valheim-presence.json
{ ... }:
{
  flake.modules.nixos.valheim-presence = { pkgs, ... }: {
    systemd.services.valheim-presence = {
      description = "Valheim: kdo je ve hře → tasks-app monitoring";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = with pkgs; [
        bash
        openssh
        coreutils
        gnused
        gnugrep
      ];
      serviceConfig = {
        ExecStart = "${pkgs.bash}/bin/bash ${./valheim-presence.sh}";
        Restart = "always";
        RestartSec = "15s";
        # Stejný uživatel jako tasks-api: soubor leží v jeho datovém adresáři.
        User = "server";
        Group = "users";
      };
    };
  };
}
