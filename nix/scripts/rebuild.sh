#!/bin/bash
# Usage: rebuild.sh <host> [build-host]   (build-host defaults to <host>)
set -euo pipefail

host=$1
build=${2:-$1}

nix run nixpkgs#nixos-rebuild -- switch --flake ".#$host" \
  --target-host "operator@$host.lab" --build-host "operator@$build.lab" --sudo -L
