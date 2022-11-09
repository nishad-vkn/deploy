{ config, pkgs, lib, hclib, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf mkMerge mkDefault types;
  cfg = config.opencloud.services.dyndns;

  daemon = pkgs.opencloud.compileHaskell {
    name = "dyndns";
    source = ./dyndns.hs;

    ghcflags = [ "-O2" "-Wall" ];
    buildDepends = [
      "acid-state" "cereal-text" "stm" "wai" "warp" "yaml"
      pkgs.opencloud.nexus
    ];
  };

  credentialOptions = { name, ... }: {
    options.username = mkOption {
      type = types.str;
      description = ''
        The user name that clients use to update their dynamic DNS records.
      '';
    };

    options.password = mkOption {
      type = types.str;
      description = ''
        The password that clients use to update their dynamic DNS records.
      '';
    };

    options.domains = mkOption {
      type = types.listOf types.str;
      description = ''
        The fully qualified domain names that this user is allowed to update.
      '';
    };

    config.username = mkDefault name;
  };

  userGroupOptions = mode: {
    user = mkOption {
      type = types.str;
      default = "dyndns";
      description = ''
        User name to use for running the ${mode} daemon.
      '';
    };

    group = mkOption {
      type = types.nullOr types.str;
      default = "dyndns";
      description = ''
        Group name to use for running the ${mode} daemon.
      '';
    };
  };

  mkService = mode: cfgContents: let
    cfgFile = pkgs.writeText "dyndns-${mode}.yaml" cfgContents;
    modeUCFirst = lib.toUpper (lib.substring 0 1 mode)
                + lib.substring 1 (-1) mode;
    userGroupSC = lib.optionalAttrs (cfg.${mode}.user != "dyndns") {
      User = cfg.slave.user;
    } // lib.optionalAttrs (cfg.${mode}.group != "dyndns") {
      Group = cfg.slave.group;
    };
    commonSC = {
      ExecStart = "@${daemon} dyndns-${mode} --${mode} ${cfgFile}";
      RestartSec = 10;
    };
    specificSC = {
      Restart = "on-failure";
      User = "dyndns";
      Group = "dyndns";
    } // lib.optionalAttrs (lib.any (s: s.device != null) cfg.master.slaves) {
      AmbientCapabilities = [ "CAP_NET_RAW" ];
    };
  in {
    after = [ "network.target" ];
    description = "Dynamic DNS ${modeUCFirst} Server";
    restartTriggers = [ cfgFile ];
    serviceConfig = commonSC // specificSC // userGroupSC;
  };

  yamlStr = val: "'${lib.replaceStrings ["'"] ["''"] val}'";
  yamlList = items: "[${lib.concatMapStringsSep ", " yamlStr items}]";

  credentials = let
    mkCredUser = username: attrs: [
      "  ${yamlStr username}:"
      "    password: ${yamlStr attrs.password}"
      "    domains: ${yamlList attrs.domains}"
    ];
    users = lib.flatten (lib.mapAttrsToList mkCredUser cfg.master.credentials);
    result = lib.concatStringsSep "\n" (lib.singleton "credentials:" ++ users);
  in lib.optionalString (users != []) result;

  nameservers = let
    mkNS = ns: "  - ${yamlStr ns}";
    nsHosts = map mkNS cfg.master.nameservers;
  in lib.concatStringsSep "\n" (lib.singleton "nameservers:" ++ nsHosts);

  mkYamlSlave = scfg: let
    attrs = [
      "host: ${yamlStr scfg.host}"
      "port: ${toString scfg.port}"
    ] ++ lib.optional (scfg.device != null) "device: ${yamlStr scfg.device}";
  in "- " + lib.concatStringsSep "\n    " attrs;

  masterConfig = mkIf cfg.master.enable {
    systemd.services.dyndns-master = mkService "master" ''
      ${if cfg.master.credentialFile != null then ''
      credentials: !include ${yamlStr cfg.master.credentialFile}
      '' else credentials}
      ${nameservers}
      email: ${yamlStr cfg.master.emailAddress}
      stateDir: ${yamlStr cfg.master.stateDir}
      slaves:
        ${lib.concatMapStringsSep "\n  " mkYamlSlave cfg.master.slaves}
    '';

    systemd.sockets = hclib.mkSocketConfig {
      namePrefix = "dyndns-master-http";
      description = "Dyndns HTTP Socket For Master";
      service = "dyndns-master";
      fdName = "http";
      config = cfg.master.http;
    };

    users.users.dyndns = mkIf (cfg.master.user == "dyndns") {
      uid = 2022;
      group = cfg.master.group;
      description = "Dynamic DNS Master User";
      home = cfg.master.stateDir;
      createHome = true;
    };

    users.groups.dyndns = mkIf (cfg.master.group == "dyndns") {
      gid = 2022;
    };

    assertions = let
      mkOpt = opt: "`opencloud.services.dyndns.master.${opt}'";
    in [
      { assertion = lib.length cfg.master.nameservers >= 1;
        message = "You have to specify at least one nameserver in"
                + " ${mkOpt "nameservers"}.";
      }
      { assertion = cfg.master.credentialFile != null
                 -> cfg.master.credentials == {};
        message = "You can either specify ${mkOpt "credentials"} or"
                + " ${mkOpt "credentialFile"}, not both.";
      }
    ];
  };

  slaveBaseConfig = mkIf cfg.slave.enable {
    systemd.services.dyndns-slave = mkService "slave" ''
      writeZoneCommand: ${yamlStr cfg.slave.zoneCommand}
    '';

    systemd.sockets = hclib.mkSocketConfig {
      namePrefix = "dyndns-slave";
      description = "Dyndns Socket For Master Connections";
      service = "dyndns-slave";
      fdName = "master";
      config = cfg.slave.master;
    };

    users.users.dyndns = mkIf (cfg.slave.user == "dyndns") {
      description = "Dynamic DNS Slave User";
      uid = 2022;
      group = cfg.slave.group;
    };

    users.groups.dyndns = mkIf (cfg.slave.group == "dyndns") {
      gid = 2022;
    };
  };

  slaveNSDConfig = mkIf cfg.slave.useNSD {
    systemd.services.dyndns-slave.after = [ "nsd.service" ];
    opencloud.nsd-zone-writer.enable = lib.mkOverride 900 true;
    opencloud.nsd-zone-writer.beforeUnits = [ "dyndns-slave.service" ];
    opencloud.nsd-zone-writer.allowedUsers = lib.singleton cfg.slave.user;

    opencloud.services.dyndns.slave = {
      zoneCommand = let
        zoneWriter = config.opencloud.nsd-zone-writer.command;
      in lib.mkOverride 900 zoneWriter;
    };
  };

  slaveConfig = mkMerge [ slaveBaseConfig slaveNSDConfig ];

in {

  options.opencloud.services.dyndns.master = {
    enable = mkEnableOption "Opencloud dynamic DNS master service";
    http = hclib.mkListenerOption "incoming HTTP connections" "::" 3000;

    slaves = mkOption {
      type = types.listOf (types.submodule {
        options.host = mkOption {
          type = types.str;
          description = ''
            The hostname or IP address of the slave listener to connect and push
            zone updates to.
          '';
        };

        options.port = mkOption {
          type = types.int;
          default = 6000;
          description = ''
            The port of the slave listener to connect and push zone updates to.
          '';
        };

        options.device = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Device to use for connectiong to the slave.
          '';
        };
      });
      default = [];
      description = ''
        A list of slaves to connect to and send DNS zone updates.
      '';
    };

    credentials = mkOption {
      type = types.attrsOf (types.submodule credentialOptions);
      default = {};
      example.alice.password = "ilikebob";
      example.alice.domains = [ "alice.example.net" ];
      example.bob.password = "ilikealice";
      example.bob.domains = [ "bob.example.com" "bob.example.org" ];
      description = ''
        Credentials consisting of usernames, passwords and allowed hosts that
        the master server allows.
      '';
    };

    credentialFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Use this file for credentials instead of putting them directly into the
        main configuration file.
      '';
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/dyndns";
      description = ''
        Directory where the master process keeps its internal state (which for
        example consists of zonefile serial numbers).
      '';
    };

    emailAddress = mkOption {
      type = types.str;
      description = ''
        The email address to use in the SOA record.
      '';
    };

    nameservers = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        The DNS servers that are authoriative for all of the zones that are
        generated by the slaves.
      '';
    };
  } // userGroupOptions "master";

  options.opencloud.services.dyndns.slave = {
    enable = mkEnableOption "Opencloud dynamic DNS slave service";
    master = hclib.mkListenerOption "incoming master connections" "::" 6000;

    useNSD = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to update zones of a locally running NSD (see
        <option>services.nsd</option>).
      '';
    };

    zoneCommand = mkOption {
      type = types.str;
      description = ''
        Command to update the zone file.

        The FQDN of the zone is passed as the first argument and the zone file
        contents are piped to that command via <literal>stdin</literal>.
      '';
    };
  } // userGroupOptions "slave";

  config = mkMerge [ slaveConfig masterConfig ];
}
