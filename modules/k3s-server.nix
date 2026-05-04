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
}
