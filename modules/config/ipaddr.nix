{ options, config, lib, ... }:

{
  options.opencloud.mainIPv4 = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      The main IPv4 address of this host.

      This is mainly useful for deployment-wide usage on other nodes, like for
      example for DNS records.

      This in turn also sets <option>deployment.hetzner.mainIPv4</option>.
    '';
  };

  options.opencloud.mainIPv6 = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      The main IPv6 address of this host.

      This is mainly useful for deployment-wide usage on other nodes, like for
      example for DNS records.
    '';
  };

  options.opencloud.mainDevice = lib.mkOption {
    type = lib.types.str;
    default = "eth0";
    description = ''
      The network device where the <option>opencloud.mainIPv4</option> and
      the <option>opencloud.mainIPv6</option> address reside.
    '';
  };

  config = let
    maybeConfig = lib.optionalAttrs (options ? deployment) {
      deployment.hetzner.mainIPv4 = config.opencloud.mainIPv4;
    };
  in lib.mkIf (config.opencloud.mainIPv4 != null) maybeConfig;
}
