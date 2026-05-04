{ ... }:

{
  # TODO: split up
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [
    22
    6443 # k3s server kubernetes api
    10250 # k3s Kubelet metrics and API
  ];
  networking.firewall.allowedUDPPorts = [
    8472 # k3s Required only for Flannel VXLAN
  ];
}
