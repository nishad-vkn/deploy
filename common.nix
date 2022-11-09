{ lib, ... }:

{
  imports = import ./modules/module-list.nix;
  networking.firewall.enable = false;

  services.journald.extraConfig = ''
    MaxRetentionSec=3month
  '';

  opencloud.services.acme = {
    key.type = "rsa";
    key.size = 4096;
  };w

  nixpkgs.overlays = lib.singleton (self: lib.const {
    inherit (import ./pkgs { pkgs = self; }) opencloud;
  });
}
