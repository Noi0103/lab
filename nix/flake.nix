{
  description = "Homelab cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
    pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      sops-nix,
      pre-commit-hooks,
      disko,
    }:
    let
      cluster = import ./cluster.nix;

      forAllSystems =
        fn:
        nixpkgs.lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ] (system: fn nixpkgs.legacyPackages.${system});

      mkHost =
        hostname:
        nixpkgs.lib.nixosSystem {
          specialArgs = { inherit cluster; };
          modules = [
            ./hosts/${hostname}
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
          ];
        };
    in
    {
      nixosConfigurations = {
        nix-thinkpad = mkHost "nix-thinkpad";
        nix-letsnote1 = mkHost "nix-letsnote1";
        nix-letsnote2 = mkHost "nix-letsnote2";
        nix-optiplex1 = mkHost "nix-optiplex1";
        nix-optiplex2 = mkHost "nix-optiplex2";
        nix-netcup-chiller = mkHost "nix-netcup-chiller";
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inherit (self.checks.${pkgs.stdenv.hostPlatform.system}.pre-commit-check) shellHook;
          buildInputs = self.checks.${pkgs.stdenv.hostPlatform.system}.pre-commit-check.enabledPackages;
          packages = with pkgs; [
            nixfmt
            nil
            nixd
          ];
        };

        # Tools for local/cluster.sh (docs/LOCAL.md), which re-execs itself in
        # this shell so versions come from flake.lock and not from the host.
        local = pkgs.mkShell {
          LAB_LOCAL_SHELL = "1";
          packages = with pkgs; [
            curl
            fluxcd
            jq
            k9s
            kubeconform
            kubectl
            kustomize
            lima
            rsync
            sops
            wireguard-tools
          ];
        };
      });

      checks = forAllSystems (pkgs: {
        pre-commit-check = pre-commit-hooks.lib.${pkgs.stdenv.hostPlatform.system}.run {
          src = ./.;
          hooks.nixfmt.enable = true;
          hooks.deadnix.enable = true;
          hooks.gitleaks = {
            enable = true;
            name = "gitleaks";
            entry = "${pkgs.gitleaks}/bin/gitleaks protect --verbose --redact --staged";
            package = pkgs.gitleaks;
            pass_filenames = false;
          };
        };
      });
    };
}
