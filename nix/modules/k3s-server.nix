{
  config,
  lib,
  pkgs,
  cluster,
  ...
}:

let
  cfg = config.lab.k3s;
in
{
  options.lab.k3s.clusterInit = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Bootstrap a new embedded-etcd cluster on this node.
      Exactly one server (cluster.serverHost) sets this; every other
      server joins it via serverAddr.
    '';
  };

  config = {
    boot.supportedFilesystems = [ "nfs" ];

    sops.secrets."k3s.agent.token" = { };
    sops.secrets."k3s.server.token" = { };

    services.k3s = {
      enable = true;
      package = pkgs.k3s_1_35;
      role = "server";
      clusterInit = cfg.clusterInit;
      serverAddr = lib.mkIf (!cfg.clusterInit) "https://${cluster.serverHost}:6443";
      tokenFile = config.sops.secrets."k3s.server.token".path;
      agentTokenFile = config.sops.secrets."k3s.agent.token".path;
      extraFlags = [
        "--disable=servicelb"
        "--node-ip=${cluster.hosts.${config.networking.hostName}}"
        "--tls-san=${config.networking.hostName}.${cluster.hostDomain}"
      ];
    };

    networking.firewall.allowedTCPPorts = [
      6443 # k3s server kubernetes api
      2379 # etcd client
      2380 # etcd peer
      9100 # prometheus node exporter
      10250 # k3s Kubelet metrics and API
      7946 # MetalLB L2
    ];

    networking.firewall.allowedUDPPorts = [
      8472 # Flannel VXLAN
      7946 # MetalLB L2
    ];
  };
}
