# Health of the tank pool (disko/tank.nix): SMART self-tests, SMART metrics for
# Prometheus (cluster/infra/configs/monitoring/) and ZFS event notifications.
{ config, lib, ... }:
let
  # smartd -s schedules (T/MM/DD/d/HH): a short test weekly and a long test
  # monthly, each disk on its own days so mirror partners never test together,
  # all clear of the monthly scrub on the 1st.
  selfTests = {
    hdd1 = "(S/../../1/01|L/../08/./02)";
    hdd2 = "(S/../../2/01|L/../12/./02)";
    hdd3 = "(S/../../3/01|L/../16/./02)";
    hdd4 = "(S/../../4/01|L/../20/./02)";
  };
in
{
  services.smartd = {
    enable = true;
    autodetect = false;
    devices = lib.mapAttrsToList (disk: schedule: {
      device = config.disko.devices.disk.${disk}.device;
      options = "-s ${schedule}";
    }) selfTests;
  };

  # Scans every disk, the root SSD included.
  services.prometheus.exporters.smartctl = {
    enable = true;
    openFirewall = true;
  };

  # zed posts pool events (faults, data errors, finished scrubs and resilvers)
  # to ntfy.sh. The topic is the only credential, so it stays out of
  # services.zfs.zed.settings (Nix store): zed.rc is rendered by sops from the
  # module's settings plus the topic.
  services.zfs.zed.settings.ZED_NOTIFY_VERBOSE = true;
  sops.secrets."zed/ntfy-topic".sopsFile = ../secrets/zed.yaml;
  sops.templates."zed.rc".content = config.environment.etc."zfs/zed.d/zed.rc".text + ''
    ZED_NTFY_TOPIC="${config.sops.placeholder."zed/ntfy-topic"}"
  '';
  environment.etc."zfs/zed.d/zed.rc".source = lib.mkForce config.sops.templates."zed.rc".path;
}
