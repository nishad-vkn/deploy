import ../make-test.nix ({ lib, system, ... }:

let
  testClient = pkgs: pkgs.opencloud.buildErlang rec {
    name = "testclient";
    version = "1.0";

    erlangDeps = with pkgs.opencloud.erlangPackages; [
      escalus
    ];

    src = pkgs.stdenv.mkDerivation {
      name = "test-client-src";

      buildCommand = ''
        mkdir -p "$out/src"

        cat > "$out/src/testclient.app.src" <<EOF
        {application, testclient, [
          {description, "Test client for hot code reloading"},
          {vsn, "${version}"},
          {modules, []},
          {registered, [testclient]},
          {applications, [kernel, stdlib]}
        ]}.
        EOF

        cat > "$out/rebar.config" <<EOF
        {deps, [{escalus, ".*", none}]}.
        EOF

        cat "${./testclient.erl}" > "$out/src/testclient.erl"
      '';
    };
  };

  argsFile = pkgs: let
    client = testClient pkgs;
    deps = [ client ] ++ client.recursiveErlangDeps;
  in pkgs.writeText "testclient.args" ''
    ${lib.concatMapStringsSep "\n" (dep: "-pa ${dep.appDir}/ebin") deps}
    -sname test@client
    -setcookie testclient
    -noinput
    -s testclient start
  '';

  nodes = {
    server = {
      networking.extraHosts = "127.0.0.1 server";
      opencloud.services.mongooseim = {
        enable = true;
        settings = {
          hosts = [ "server" ];
          modules.register.options.ip_access = [];
          acl.rules.access.c2s = [ { allow = true; } ];
          acl.rules.access.local = [ { allow = true; } ];
          acl.rules.access.register = [ { allow = true; } ];
          registrationTimeout = null;
        };
      };
    };

    client = { pkgs, ... }: {
      networking.extraHosts = "127.0.0.1 client";
      environment.systemPackages = [ pkgs.erlang ];
      systemd.services.testclient = {
        description = "Test Client";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "fs.target" "keys.target" ];

        environment.HOME = testClient pkgs;
        serviceConfig.ExecStart = "@${pkgs.erlang}/bin/erl testclient"
                                + " -args_file ${argsFile pkgs}";
      };
    };
  };

  newServerConfig = {
    opencloud.services.mongooseim.settings = {
      acl.rules.access.c2s = lib.mkForce [ { allow = false; } ];
    };
  };

  newServerCode = { pkgs, ... }: {
    opencloud.services.mongooseim.package = let
      patched = pkgs.opencloud.mongooseim.overrideDerivation (drv: {
        postPatch = (drv.postPatch or "") + ''
          sed -i -e 's!<<"Pong">>!<<"Pang">>!' \
            apps/ejabberd/src/mod_adhoc.erl
        '';
      });
    in patched;
  };

  buildNewServer = configurations: let
    inherit (import <nixpkgs/nixos/lib/build-vms.nix> {
      inherit system;
    }) buildVirtualNetwork;

    newNodes = nodes // {
      server = {
        # XXX: Shouldn't need to include common.nix again!
        imports = [ ../../common.nix nodes.server ] ++ configurations;
      };
    };
  in (buildVirtualNetwork newNodes).server.config.system.build.toplevel;

  newServerConfigBuild = buildNewServer [ newServerConfig ];
  revertedServerConfigBuild = buildNewServer [];
  newServerCodeBuild = buildNewServer [ newServerCode ];

in {
  name = "code-reload";

  inherit nodes;

  testScript = let
    switchToServer = build: ''
      $server->succeed("${build}/bin/switch-to-configuration test");
    '';

  in ''
    sub sendTestClientCommand {
      return $client->succeed(
        'erl_call -sname test@client -c testclient '.
        '-a "gen_server call [testclient, '.$_[0].', 60000]"'
      );
    }

    sub assertTestClient {
      my ($command, $expect) = @_;
      my $result = sendTestClientCommand($command);
      die "Expected $expect but got $result instead" if $result ne $expect;
    }

    sub assertUptime {
      my ($old, $new) = @_;
      die "old server uptime is $old seconds, ".
          "but new uptime is just $new seconds, ".
          "so the server has restarted in-between!"
          if $old > $new;
    }

    startAll;
    $server->waitForUnit("mongooseim.service");
    $client->waitForUnit("testclient.service");

    my ($old_uptime,
        $new_conf_uptime,
        $reverted_config_uptime,
        $new_code_uptime);

    subtest "initial version", sub {
      assertTestClient("ping", "pong");
      assertTestClient("register", "register_done");
      assertTestClient("login", "logged_in");
      assertTestClient("adhoc_ping", "pong");
      assertTestClient("communicate", "great_communication");

      $server->sleep(10); # Let the server gather uptime
      $old_uptime = sendTestClientCommand("get_uptime");
    };

    subtest "change configuration", sub {
      ${switchToServer newServerConfigBuild}

      assertTestClient("check_connections", "still_connected");

      $new_conf_uptime = sendTestClientCommand("get_uptime");

      assertTestClient("login", "login_failure");

      assertUptime($old_uptime, $new_conf_uptime);
    };

    subtest "revert configuration", sub {
      ${switchToServer revertedServerConfigBuild}

      assertTestClient("login", "logged_in");
      assertTestClient("adhoc_ping", "pong");

      $reverted_config_uptime = sendTestClientCommand("get_uptime");
      assertUptime($new_conf_uptime, $reverted_config_uptime);
    };

    subtest "change code", sub {
      ${switchToServer newServerCodeBuild}

      # XXX: Change this to "still_connected" after MongooseIM 2.1.0:
      assertTestClient("check_connections", "not_connected_anymore");
      # XXX: Remove this line after MongooseIM 2.1.0:
      assertTestClient("login", "logged_in");
      assertTestClient("adhoc_ping", "pang");

      $new_code_uptime = sendTestClientCommand("get_uptime");

      # XXX: Make sure to use the following after MongooseIM 2.1.0:
      # assertUptime($reverted_config_uptime, $new_code_uptime);
      # ... and remove the following:
      die "old server uptime is $reverted_config_uptime seconds, ".
          "but new uptime is $new_code_uptime seconds, which indicates ".
          "that the server has not restarted!"
          if $reverted_config_uptime < $new_code_uptime;
    };

    subtest "stop server", sub {
      $server->succeed("systemctl stop mongooseim");
      assertTestClient("check_connections", "not_connected_anymore");
    };
  '';
})
