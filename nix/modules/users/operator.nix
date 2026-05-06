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
}
