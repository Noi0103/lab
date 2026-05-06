{ ... }:

{
  # TODO: split up
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [
    22
  ];
  # networking.firewall.allowedUDPPorts = [ ];
}
