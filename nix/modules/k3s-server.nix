{ config, ... }:

{
  sops.secrets."k3s.agent.token" = { };
  sops.secrets."k3s.server.token" = { };

  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = true;
    tokenFile = config.sops.secrets."k3s.server.token".path;
    agentTokenFile = config.sops.secrets."k3s.agent.token".path;
  };

  networking.firewall.allowedTCPPorts = [
    6443 # k3s server kubernetes api
    10250 # k3s Kubelet metrics and API    6443 # k3s server kubernetes api
  ];

  networking.firewall.allowedUDPPorts = [ 8472 ]; # Flannel VXLAN
}
