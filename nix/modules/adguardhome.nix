{
  lib,
  config,
  pkgs,
  cluster,
  ...
}:
let
  inherit (cluster)
    hosts
    hostDomain
    ingressIP
    externalDomain
    internalDomain
    ;
  self = config.networking.hostName;
  selfIP = hosts.${self};

  hostRecords = lib.mapAttrs' (name: ip: lib.nameValuePair "${name}.${hostDomain}" ip) hosts;

  records = hostRecords // {
    "${externalDomain}" = ingressIP;
    "*.${externalDomain}" = ingressIP;
    "adguard.${internalDomain}" = selfIP;
  };
in
{
  assertions = [
    {
      assertion = hosts ? ${self};
      message = "adguard: host '${self}' is missing from cluster.hosts";
    }
  ];

  networking.firewall.allowedUDPPorts = [ 53 ];
  networking.firewall.allowedTCPPorts = [
    53
    3000
  ];

  services.adguardhome.enable = true;
  services.adguardhome = {
    mutableSettings = false;
    settings = {
      http.address = "0.0.0.0:3000";
      users = [
        {
          name = "admin";
          password = "@ADMIN_HASH@"; # replaced in preStart
        }
      ];

      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        upstream_dns = [
          "https://dns.quad9.net/dns-query"
          "https://cloudflare-dns.com/dns-query"
          "[/fritz.box/]192.168.178.1"
        ];
        bootstrap_dns = [
          "9.9.9.9"
          "1.1.1.1"
        ];
        fallback_dns = [ ];
      };

      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
        rewrites = lib.mapAttrsToList (domain: answer: {
          inherit domain answer;
          enabled = true;
        }) records;
      };
    };
  };

  sops.secrets."adguard/adminpw" = {
    restartUnits = [ "adguardhome.service" ];
  };

  systemd.services.adguardhome = {
    serviceConfig.LoadCredential = [
      "adminpw:${config.sops.secrets."adguard/adminpw".path}"
    ];

    preStart = lib.mkAfter ''
      pw=$(<"$CREDENTIALS_DIRECTORY/adminpw")
      HASH=$(printf '%s' "$pw" | ${pkgs.mkpasswd}/bin/mkpasswd -m bcrypt --stdin)
      # No in-place edit (sed -i, yq -i): those fchown the new file, and the
      # module's SystemCallFilter (~@privileged) kills that with SIGSYS.
      # bcrypt hashes never contain '|' or '&'.
      cfg="$STATE_DIRECTORY/AdGuardHome.yaml"
      sed "s|@ADMIN_HASH@|$HASH|" "$cfg" > "$cfg.tmp"
      mv "$cfg.tmp" "$cfg"
    '';
  };
}
