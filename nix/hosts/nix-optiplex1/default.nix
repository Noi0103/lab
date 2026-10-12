{ ... }:
{
  imports = [
    ../../modules/base.nix
    ../../modules/boot-systemd.nix
    ../../modules/firewall.nix
    ../../modules/headless.nix
    ../../modules/ssh.nix
    ../../modules/k3s-server.nix
    ../../modules/users/operator.nix
    ../../modules/zfs.nix
    ../../disko/tank.nix
    ../../modules/nfs-server.nix
    ../../modules/tank-health.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "nix-optiplex1";
  networking.hostId = "B353293D";

  # Uncapped, the ARC grows to RAM minus 1 GiB and left 1-2 GiB free for days,
  # mostly holding media streamed once; the hot set is under 2 GiB.
  # Applied when the zfs module loads, i.e. on the next boot.
  boot.extraModprobeConfig = "options zfs zfs_arc_max=${toString (4 * 1024 * 1024 * 1024)}";
}
