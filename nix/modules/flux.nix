{ pkgs, ... }:
let
  fluxVersion = "2.8.6";
  fluxInstallManifest = pkgs.fetchurl {
    url = "https://github.com/fluxcd/flux2/releases/download/v${fluxVersion}/install.yaml";
    sha256 = "sha256:cb6dadb9f2525dd6665c1cd3f206ef0078e912499e923278844cc8a47906e93c";
  };
in
{
  services.k3s.manifests = {
    "01-namespace.yaml".source = ../config/manifests/flux-namespace.yaml;
    "02-install.yaml".source = fluxInstallManifest;
    "03-sync.yaml".source = ../config/manifests/flux-sync.yaml;
  };
}
