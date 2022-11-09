{ pkgs, lib, hclib, config, nodes, ... }:

with lib;

let
  unzervaltIPv4 = nodes.unzervalt.config.networking.privateIPv4;
  parsifalIPv4 = config.opencloud.imperativeContainers.parsifal.localAddress;
  hydraIPv4 = nodes.taalo.config.networking.p2pTunnels.ssh.ultron.localIPv4;

  genIPv46VHosts = vhost: scfg: let
    getSocketPort = s: last (splitString ":" s);
    processNode = addr: node: node // {
      socket = "${addr}:${getSocketPort (node.socket or "80")}";
    };
  in optionals (vhost.ipv4 != null) (map (processNode vhost.ipv4) scfg) ++
     optionals (vhost.ipv6 != null) (map (processNode "[${vhost.ipv6}]") scfg);

  genSSLVHosts = vhost: configuration: genIPv46VHosts vhost [
    {
      type = "static";
      on = vhost.fqdn;
      socket = ":443";

      socketConfig = ''
        ssl.engine  = "enable"
        ssl.use-sslv2 = "disable"
        ssl.use-sslv3 = "disable"
        ssl.pemfile = "${vhost.ssl.allInOne}"
        ssl.ca-file = "${vhost.ssl.fullChain}"
      '';

      inherit configuration;
    }
    {
      socket = ":80";
      socketConfig = ''
        url.redirect = ( "^/(.*)" => "https://opencloud.software/$1" )
      '';
    }
  ];

  taaloTunnel = nodes.taalo.config.networking.p2pTunnels.ssh.ultron;

in {
  imports = [ ../../domains.nix ../../xmpp.nix ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  fileSystems."/".options = [
    "autodefrag" "space_cache" "compress=lzo" "noatime"
  ];

  networking.nat = {
    enable = true;
    externalInterface = config.opencloud.mainDevice;
  };

  # XXX: Factor out!
  networking.extraHosts = "127.0.0.1 ${config.networking.hostName}";

  opencloud.imperativeContainers.parsifal = {
    index = 1;
    forwardSSH = [
      "${config.opencloud.vhosts.opencloud.ipv4}:2222"
      "[${config.opencloud.vhosts.opencloud.ipv6}]:2222"
    ];
    authorizedKeys = [
      (concatStrings [
        "ssh-rsa "
        "AAAAB3NzaC1yc2EAAAADAQABAAABAQC+rrVQrAofce2eJLXVmYejyaed0ZrGoX+gl4zTE"
        "30fsVMdlkC4vltvbGxSZ4sTi3x4FfXIh8d0+O4XdaDePQwv+feCz3Ky+ZGNj0zbKA082M"
        "G91V9p/1FlOUpMkCRXnIxNhAOpwQxyhPUOJlDWgDDpdBPe4DMOzSf0krpMEX7CbJx/S5T"
        "9Wy/nlF/e0Lbxb+FRL0kVdnM7JnWQcB9NvHt/NYPoPLQCFiWxKI5jW9YthF55T11+xgKO"
        "/QBm9nuZU8ij5gMDR65EymtRgYjqtBy+CrqpX9pkwnAWFeYItZfshUj3pDfn6pMjfQ7MR"
        "Z4ol5E9RXIjnLR5XDfoI/7NzzA1"
      ])
      (concatStrings [
        "ssh-rsa "
        "AAAAB3NzaC1yc2EAAAADAQABAAABAQDFnhcVRaz6SKxlbVp2DtxZztOkiwiAvgATi2ehx"
        "9aAyyaEf0HWM5tHQnVVj99zxL5EY6g/pQ9hZZMFu9s/VORTk8ULpyLTMDMktvokUnBJOj"
        "7HIB0U+Yyh1AoR3k1y0j6xCkH6Bcl0uZOn1XX/zorcjtuuA5LmfI3zj2whD/8cGzW/6Wq"
        "YOnSDI9RQ0dUPhHiZEH5U7vbKjgz7Ry9I7VkjB8Ztfax+BNwV1Um0FmiITPz3PgriU/AD"
        "vn1m1hIu5Vc38YQvaoXIAypeOXgGWGTLTOq/gtCOKGmg3VFERUstPXKgsij0Ves6DxT+0"
        "CiIN9EClp2uuMtfH1pLCAI3ttvf"
      ])
    ];
  };

  opencloud.services.acme = let
    inherit (config.networking.p2pTunnels.ssh) dugee;
  in {
    enable = true;
    email = "ssladmin@opencloud.software";
    handlerAddress = dugee.remoteIPv4;
    handlerDevice = "tun${toString dugee.localTunnel}";
  };

  opencloud.services.dyndns.master = {
    enable = true;
    emailAddress = "postmaster@opencloud.software";
    nameservers = [ "ns1.opencloud.software" "ns2.opencloud.software" ];
    http = mkForce (singleton { host = "127.0.0.1"; device = "lo"; });
    slaves = let
      mkSlaveConnector = m: with config.networking.p2pTunnels.ssh.${m}; {
        host = remoteIPv4;
        device = "tun${toString localTunnel}";
      };
    in mkForce (unique (map mkSlaveConnector [ "dugee" "gussh" ]));
    credentials = hclib.getcred "dyndns-users" {};
  };

  services.postgresql = {
    enable = true;
    extraConfig = ''
      listen_addresses = '${taaloTunnel.remoteIPv4}, 127.0.0.1, ::1'
      max_connections = 400
    '';
    authentication = mkAfter ''
      host hydra all ${taaloTunnel.localIPv4}/32 trust
    '';
    initialScript = pkgs.writeText "postgresql-init.sql" ''
      CREATE ROLE hydra LOGIN;
      CREATE DATABASE hydra OWNER hydra;
    '';
  };

  opencloud.postgresql.databases.hydra.users.hydra.isOwner = true;

  opencloud.conditions.postgresql.bindable.address = taaloTunnel.remoteIPv4;

  opencloud.services.lighttpd = {
    enable = true;
    defaultPort = null;

    configuration = ''
      mimetype.assign = (
        ".html" => "text/html",
        ".js" => "text/javascript"
      )
    '';

    modules.proxy.enable = true;
    modules.magnet.enable = true;
    modules.setenv.enable = true;
    modules.redirect.enable = true;

    virtualHosts = with config.opencloud.vhosts; genSSLVHosts opencloud ''
      $HTTP["url"] =~ "^/hydra(?:$|/)" {
        magnet.attract-physical-path-to = ( "${pkgs.writeText "rewrite.lua" ''
        if string.sub(lighty.env["request.uri"], 1, 6) == "/hydra" then
          lighty.env["request.uri"] = string.sub(lighty.env["request.uri"], 7)
        end
        ''}" )
        setenv.add-request-header = (
          "X-Request-Base" => "https://opencloud.software/hydra/"
        )
        proxy.balance = "hash"
        proxy.server = ("/hydra" => ((
          "host" => "${hydraIPv4}",
          "port" => 3000
        )))
      # Mapping to Dynamic DNS Master
      } else $HTTP["url"] =~ "^/dyndns(?:$|/)" {
        proxy.balance = "hash"
        proxy.server = ("/dyndns" => ((
          "host" => "127.0.0.1",
          "port" => 3000
        )))
      # Mapping to parsifal container
      } else $HTTP["url"] =~ "^/foss-herablads(?:$|/)" {
        setenv.add-request-header = (
          "X-Request-Base" => "https://opencloud.software/foss-herablads/"
        )
        proxy.balance = "hash"
        proxy.server = ("/foss-herablads" => ((
          "host" => "${parsifalIPv4}",
          "port" => 80
        )))
      # http://redmine.lighttpd.net/issues/1268
      } else $HTTP["url"] =~ "" {
        server.document-root = "${pkgs.opencloud.site}"
      }
    '' ++ optionals (hasAttr "unzervalt" nodes) (genIPv46VHosts misc ([{
      socketConfig = ''
        proxy.balance = "hash"
        proxy.server = ("" => ((
          "host" => "${unzervaltIPv4}",
          "port" => 80
        )))
      '';
    }]));
  };

  systemd.sockets."unzervalt-ssh" = mkIf (hasAttr "unzervalt" nodes) {
    description = "SSH proxy socket to Unzervalt";
    wantedBy = [ "sockets.target" ];
    socketConfig.ListenStream = [
      "${config.opencloud.vhosts.misc.ipv4}:22"
      "[${config.opencloud.vhosts.misc.ipv6}]:22"
    ];
  };

  systemd.services."unzervalt-ssh" = mkIf (hasAttr "unzervalt" nodes) {
    description = "SSH proxy to Unzervalt";
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd"
                + " ${unzervaltIPv4}:2222";
      PrivateTmp = true;
    };
  };
}
