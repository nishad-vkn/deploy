{ config, pkgs, lib, hclib, ... }:

let
  cfg = config.opencloud.erlang-inet;

  # In cfg.hosts we have { host = ip; }, but for the Erlang inetrc we need to
  # have it the other way around: { ip = [ host1 host2 ... ]; }
  reversedHosts = let
    accumHosts = host: acc: [host] ++ lib.remove host acc;
    reverse = name: value: { ${value} = name; };
  in lib.foldAttrs accumHosts [] (lib.mapAttrsToList reverse cfg.hosts);

in {
  options.opencloud.erlang-inet = {
    hosts = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = {};
      example.foo = "192.168.0.11";
      example.bar = "192.168.0.12";
      description = ''
        A map of host names to IP addresses that is used for looking up short
        names in Erlang distributed nodes.
      '';
    };

    inetConfigFile = lib.mkOption {
      type = lib.types.path;
      internal = true;
      description = ''
        The generated Erlang inet configuration (ERL_INETRC).
      '';
    };
  };

  config = lib.mkIf (cfg.hosts != {}) {
    opencloud.erlang-inet.inetConfigFile = pkgs.writeText "erl_inetrc" ''
      {hosts_file, ""}.
      ${lib.concatStrings (lib.mapAttrsToList (ip: hosts: ''
        {host, ${hclib.parseErlIpAddr ip}, ${hclib.erlList hosts}}.
      '') reversedHosts)}
      {lookup, [file, native]}.
    '';
  };
}
