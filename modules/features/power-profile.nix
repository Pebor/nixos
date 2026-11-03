# power-profile — full power by day, quiet overnight.
#
# Kotlin builds are CPU-bound and this laptop is capped at 10 W PL1 with turbo off by the old
# quiet-build setup, which made every build several times slower than the hardware allows.
# A 15-minute timer keeps the machine in the right mode without anyone remembering to switch:
#
#   full  : performance profile, turbo on,  PL1 25 W / PL2 44 W  (08:00–00:00)
#   quiet : low-power profile,  turbo off, PL1 10 W / PL2 15 W  (00:00–08:00)
#
# Move the window with quietStart / quietEnd (hours, 24 h clock).
{ ... }:
{
  flake.modules.nixos.power-profile = { pkgs, ... }:
    let
      rapl = "/sys/class/powercap/intel-rapl/intel-rapl:0";
      quietStart = 0;
      quietEnd = 8;

      applyPower = pkgs.writeShellScript "power-profile" ''
        set -u
        hour=$(${pkgs.coreutils}/bin/date +%H)
        hour=$((10#$hour))

        if [ "$hour" -ge ${toString quietStart} ] && [ "$hour" -lt ${toString quietEnd} ]; then
          mode=quiet
        else
          mode=full
        fi

        # Timer runs every 15 min; skip the writes when the profile already matches.
        current=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo unknown)
        if [ "$mode" = quiet ] && [ "$current" = low-power ]; then exit 0; fi
        if [ "$mode" = full ] && [ "$current" = performance ]; then exit 0; fi

        if [ "$mode" = quiet ]; then
          echo low-power > /sys/firmware/acpi/platform_profile 2>/dev/null || true
          echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
          echo 10000000 > ${rapl}/constraint_0_power_limit_uw 2>/dev/null || true
          echo 15000000 > ${rapl}/constraint_1_power_limit_uw 2>/dev/null || true
          for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo powersave > "$c" 2>/dev/null || true
          done
        else
          echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null || true
          echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
          echo 25000000 > ${rapl}/constraint_0_power_limit_uw 2>/dev/null || true
          echo 44000000 > ${rapl}/constraint_1_power_limit_uw 2>/dev/null || true
          for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo performance > "$c" 2>/dev/null || true
          done
        fi
        echo "power profile: $mode"
      '';
    in
    {
      systemd.services.power-profile = {
        description = "Full power by day, quiet overnight";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = applyPower;
        };
      };

      systemd.timers.power-profile = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "15min";
        };
      };
    };
}
