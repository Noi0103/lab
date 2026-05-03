{ config, ... }:
{
  networking.networkmanager = {
    enable = true; # configs go /run/NetworkManager instead of /etc/NetworkManager
    # provided file has to be in .env format
    ensureProfiles.environmentFiles = [ config.sops.secrets."network.env".path ];
  };
  sops.secrets."network.env" = { };

  networking.networkmanager.ensureProfiles.profiles = {
    "lab" = {
      connection = {
        id = "$name"; # display name
        type = "wifi";
        interface-name = "wlp3s0";
      };
      ipv4 = {
        method = "auto";
      };
      ipv6 = {
        addr-gen-mode = "default";
        method = "auto";
      };
      wifi = {
        mode = "infrastructure";
        ssid = "$name";
      };
      wifi-security = {
        auth-alg = "open";
        key-mgmt = "wpa-psk";
        psk = "$psk";
      };
    };
  };
}
