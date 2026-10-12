let
  mkDataDisk = device: {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions.zfs = {
        size = "100%";
        content = {
          type = "zfs";
          pool = "tank";
        };
      };
    };
  };
in
{
  disko.devices = {
    # By id, never /dev/sdX: those names move between boots (the root SSD has
    # been both sda and sdb). All four disks hang off the add-on SATA card
    # (PCI 02:00.0); the port is the ata-N in /dev/disk/by-path. Each mirror
    # pairs a 2.5" with a 3.5" disk.
    disk = {
      hdd1 = mkDataDisk "/dev/disk/by-id/ata-ST1000LM024_HN-M101MBB_S2RUJ9DD125574"; # 2.5" Samsung M8, mirror-0, ata-6
      hdd2 = mkDataDisk "/dev/disk/by-id/ata-TOSHIBA_MQ01ABD100_24JTS1W1S"; # 2.5" Toshiba, mirror-1, ata-5
      hdd3 = mkDataDisk "/dev/disk/by-id/ata-ST1000DM010-2EP102_ZN1CC0FG"; # 3.5" Seagate, mirror-0, ata-4
      hdd4 = mkDataDisk "/dev/disk/by-id/ata-ST1000DM010-2EP102_ZN1C964P"; # 3.5" Seagate, mirror-1, ata-3
    };

    zpool.tank = {
      type = "zpool";
      mode = {
        topology = {
          type = "topology";
          vdev = [
            {
              mode = "mirror";
              members = [
                "hdd1"
                "hdd3"
              ];
            }
            {
              mode = "mirror";
              members = [
                "hdd2"
                "hdd4"
              ];
            }
          ];
        };
      };

      options = {
        ashift = "12";
        autotrim = "off";
      };

      rootFsOptions = {
        compression = "lz4";
        atime = "off";
        xattr = "sa";
        acltype = "posixacl";
        dnodesize = "auto";
        mountpoint = "none";
        canmount = "off";
        "com.sun:auto-snapshot" = "false";
      };

      datasets = {
        k8s = {
          type = "zfs_fs";
          mountpoint = "/tank/k8s";
          options = {
            recordsize = "64K";
            "com.sun:auto-snapshot" = "true";
            mountpoint = "legacy";
          };
        };

        media = {
          type = "zfs_fs";
          mountpoint = "/tank/media";
          options = {
            recordsize = "1M";
            mountpoint = "legacy";
          };
        };

        backups = {
          type = "zfs_fs";
          mountpoint = "/tank/backups";
          options = {
            recordsize = "1M";
            mountpoint = "legacy";
            compression = "zstd";
            "com.sun:auto-snapshot" = "true";
          };
        };

        reserved = {
          type = "zfs_fs";
          options = {
            mountpoint = "none";
            canmount = "off";
            refreservation = "100G";
          };
        };
      };
    };
  };
}
