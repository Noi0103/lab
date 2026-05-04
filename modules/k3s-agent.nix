{ config, ... }:

{
  sops.secrets."k3s.agent.token" = { };

  # TODO: Not functional. Find a way to add the server address without knowing which host is currently configured as role = server.
  services.k3s = {
    enable = true;
    role = "agent";
    tokenFile = config.sops.secrets."k3s.agent.token".path;
  };
}
