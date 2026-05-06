{ config, cluster, ... }:

let
  serverHost = cluster.serverHost;
in
{
  sops.secrets."k3s.agent.token" = { };

  services.k3s = {
    enable = true;
    role = "agent";
    tokenFile = config.sops.secrets."k3s.agent.token".path;
    serverAddr = "https://${serverHost}:6443";
  };

  networking.firewall.allowedTCPPorts = [
    10250 # k3s Kubelet metrics and API    6443 # k3s server kubernetes api
  ];

  networking.firewall.allowedUDPPorts = [ 8472 ]; # Flannel VXLAN
}
