{ config, pkgs, ... }:

{
  networking.firewall.allowedTCPPorts = [
    8099 # zigbee2mqtt
    1883 # mosquitto
  ];

  sops.secrets = {
    "zigbee2mqtt-secret.yaml" = {
      owner = config.users.users.zigbee2mqtt.name;
      group = config.users.users.zigbee2mqtt.group;
      sopsFile = ../secrets/zigbee2mqtt.yaml;
      path = "${config.services.zigbee2mqtt.dataDir}/secret.yaml";
    };

    "zigbee2mqtt-devices.yaml" = {
      owner = config.users.users.zigbee2mqtt.name;
      group = config.users.users.zigbee2mqtt.group;
      sopsFile = ../secrets/z2m-devices.enc;
      format = "binary";
    };

    "mosquitto-zigbee2mqtt-password" = {
      sopsFile = ../secrets/mosquitto.yaml;
      owner = "mosquitto";
      group = "mosquitto";
    };

    "mosquitto-homeassistant-password" = {
      sopsFile = ../secrets/mosquitto.yaml;
      owner = "mosquitto";
      group = "mosquitto";
    };
  };

  # A list, so it is appended to the upstream module's ExecStartPre (which
  # copies configuration.yaml since NixOS 26.05) instead of conflicting with it.
  systemd.services.zigbee2mqtt.serviceConfig.ExecStartPre =
    let
      setupDevices = pkgs.writeShellScript "z2m-setup-devices" ''
        if [ ! -f ${config.services.zigbee2mqtt.dataDir}/devices.yaml ]; then
          cp ${config.sops.secrets."zigbee2mqtt-devices.yaml".path} \
             ${config.services.zigbee2mqtt.dataDir}/devices.yaml
          chown zigbee2mqtt:zigbee2mqtt ${config.services.zigbee2mqtt.dataDir}/devices.yaml
          chmod 600 ${config.services.zigbee2mqtt.dataDir}/devices.yaml
        fi
      '';
    in
    [ "+${setupDevices}" ];

  services.zigbee2mqtt.enable = true;
  services.zigbee2mqtt = {
    dataDir = "/var/lib/zigbee2mqtt";

    settings = {
      serial = {
        port = "/dev/ttyUSB0";
        adapter = "ember";
        baudrate = 115200;
        rtscts = false;
      };

      mqtt = {
        base_topic = "zigbee2mqtt";
        server = "!secret mqtt_server";
        user = "!secret mqtt_user";
        password = "!secret mqtt_password";
      };

      advanced = {
        log_level = "info";
        channel = 11;
        network_key = "!secret network_key";
        pan_id = 52343;
        ext_pan_id = [
          75
          80
          193
          40
          147
          11
          28
          1
        ];
      };

      frontend = {
        enabled = true;
        port = 8099;
      };

      homeassistant.enabled = true;

      devices = "devices.yaml";
    };

  };

  services.mosquitto.enable = true;
  services.mosquitto = {
    listeners = [
      {
        address = "0.0.0.0";
        port = 1883;

        users = {
          z2m = {
            passwordFile = config.sops.secrets."mosquitto-zigbee2mqtt-password".path;
            acl = [
              "readwrite zigbee2mqtt/#"
              "readwrite homeassistant/#"
            ];
          };

          hass = {
            passwordFile = config.sops.secrets."mosquitto-homeassistant-password".path;
            acl = [ "readwrite #" ];
          };
        };
      }
    ];
  };
}
