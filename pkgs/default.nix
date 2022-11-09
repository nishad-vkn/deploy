{ pkgs ? import <nixpkgs> {} }:

let
  callPackage = pkgs.lib.callPackageWith (pkgs // opencloud);

  opencloud = rec {
    compileC = callPackage ./build-support/compile-c.nix {};
    compileHaskell = callPackage ./build-support/compile-haskell.nix {};
    buildErlang = callPackage ./build-support/build-erlang {};
    writeEscript = callPackage ./build-support/write-escript.nix {};

    nexus = pkgs.haskellPackages.callPackage ./nexus {};

    mongooseim = callPackage ./mongooseim {};
    mongooseimTests = callPackage ./mongooseim/tests {};
    spectrum2 = callPackage ./spectrum2 {};

    acmetool = callPackage ./acmetool {};

    site = callPackage ./site {};

    erlangPackages = callPackage ./erlang-packages.nix {
      inherit pkgs buildErlang writeEscript;
    };

    # dependencies for spectrum2
    libcommuni = callPackage ./spectrum2/libcommuni.nix {};
    libpqxx = callPackage ./spectrum2/libpqxx.nix {};
    swiften = callPackage ./spectrum2/swiften.nix {};

    xmppoke = callPackage ./xmppoke {
      lua = pkgs.lua5_1;
      luaPackages = pkgs.lua51Packages;
    };
    xmppokeReport = callPackage ./xmppoke/genreport.nix {};
  };
in pkgs // {
  inherit opencloud;
}
