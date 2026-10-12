{
  config,
  pkgs,
  cluster,
  ...
}:

{
  boot.supportedFilesystems = [ "nfs" ];

  sops.secrets."k3s.agent.token" = { };

  services.k3s = {
    enable = true;
    package = pkgs.k3s_1_35;
    role = "agent";
    tokenFile = config.sops.secrets."k3s.agent.token".path;
    serverAddr = "https://${cluster.serverHost}:6443";
  };
  networking.firewall.allowedTCPPorts = [
    9100 # prometheus node exporter
    10250 # k3s Kubelet metrics and API
    7946 # MetalLB L2
  ];

  networking.firewall.allowedUDPPorts = [
    8472 # Flannel VXLAN
    7946 # MetalLB L2
  ];
}
