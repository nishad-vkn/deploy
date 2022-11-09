vhost:

{ pkgs, lib, ... }: let

  testLibs = let
    pkg = pkgs.opencloud.mongooseimTests;
    deps = lib.singleton pkg ++ pkg.recursiveErlangDeps;
  in map (d: "${d.appDir}/ebin") deps;

  users = {
    outsider.password = "truly secure, no?";
    outsider.shouldExist = false;

    admin.server = "cloudvkn.com";
    admin.password = "big admin";

    wallop.server = "cloudvkn.com";
    wallop.password = "small wallop";

    toradmin.server = "opencloud.business";
    toradmin.password = "torservers dedicated admin";

    alice.password = "D0nt3v3ntry";
    bob.password = "D0nt3v3ntry";
  };

  mkTestConfig = hclib: fqdn: realHost: let
    mkSpecVal = val: if lib.isString val then { binary = val; } else val;
    mkUser = name: spec: {
      username.binary = name;
      server.binary = spec.server or fqdn;
      host.binary = spec.host or realHost;
      starttls.atom = "required";
      auth_method.binary = "SCRAM-SHA-1";
    } // lib.mapAttrs (lib.const mkSpecVal) spec;
  in pkgs.writeText "test.config" ''
    {escalus_xmpp_server, escalus_mongooseim}.
    {escalus_host, ${hclib.erlBinary realHost}}.

    {escalus_users, ${hclib.erlPropList (lib.mapAttrs mkUser users)}}.
  '';

  registerUser = fqdn: name: spec: let
    user = spec.username or name;
    host = spec.host or fqdn;
    inherit (spec) password;
    shouldExist = spec.shouldExist or true;
    cmd = [ "mongooseimctl" "register" name host password ];
    shellCmd = lib.concatMapStringsSep " " lib.escapeShellArg cmd;
    perlCmd = "$ultron->succeed('${lib.escape ["'"] shellCmd}');";
  in lib.optionalString shouldExist perlCmd;

  testRunner = fqdn: [
    "${pkgs.erlang}/bin/ct_run"
    "-noinput" "-noshell"
    "-config" "/etc/opencloud/test.config"
    "-ct_hooks" "ct_tty_hook" "[]"
    "-env" "FQDN" fqdn
    "-logdir" "ct_report"
    "-dir" "test"
    "-erl_args"
    "-pa"
  ] ++ testLibs;

  sourceTree = pkgs.runCommand "test-source-tree" {} ''
    mkdir -p "$out/test"
    cp "${./opencloud_SUITE.erl}" "$out/test/opencloud_SUITE.erl"
  '';

in {
  name = "vhost-${vhost}-escalus";

  nodes.client = { nodes, hclib, ... }: let
    inherit (nodes.ultron.config.opencloud.vhosts.${vhost}) fqdn;
    realHost = if fqdn == "torservers.net" then "jabber.${fqdn}" else fqdn;
  in {
    virtualisation.memorySize = 1024;
    environment.etc."opencloud/test.config" = {
      source = mkTestConfig hclib fqdn realHost;
    };
  };

  excludeNodes = [ "taalo" "benteflork" "unzervalt" ];

  testScript = { nodes, ... }: let
    inherit (nodes.ultron.config.opencloud.vhosts.${vhost}) fqdn;
  in ''
    ${lib.concatStrings (lib.mapAttrsToList (registerUser fqdn) users)}

    $client->succeed('cp -Lr ${sourceTree}/* .');

    ${(import ../../../mongooseim/lib.nix {
      inherit pkgs lib;
    }).runCommonTests (testRunner fqdn)}
  '';
}
