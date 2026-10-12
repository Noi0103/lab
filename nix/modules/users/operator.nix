{ lib, ... }:
let
  keysDir = ../../keys/operator;
  keyFiles = lib.filesystem.listFilesRecursive keysDir;
  pubKeys = builtins.filter (f: lib.hasSuffix ".pub" (toString f)) keyFiles;
in
{
  users.users.operator = {
    openssh.authorizedKeys.keyFiles = pubKeys;
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };
  # Lets rebuild.sh copy closures built on another host (unsigned paths).
  nix.settings.trusted-users = [ "operator" ];
}
