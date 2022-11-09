let
  mkMachine = attrs: {
    imports = [ ./common-machines.nix ]
           ++ attrs.imports or [];
  } // removeAttrs attrs [ "imports" ];
in {
  network.description = "opencloud Services";
  network.enableRollback = true;

  resources.sshKeyPairs."hydra-build" = {};

  ultron = { pkgs, lib, config, ... }: mkMachine {
    imports = [ ./machines/ultron ];
    opencloud.mainIPv4 = "5.9.105.142";
    opencloud.mainIPv6 = "2a01:4f8:162:4187::";

    deployment.encryptedLinksTo = [ "dugee" "gussh" ];

    deployment.hetzner.partitions = ''
      clearpart --all --initlabel --drives=sda,sdb

      part swap1 --recommended --label=swap1 --fstype=swap --ondisk=sda
      part swap2 --recommended --label=swap2 --fstype=swap --ondisk=sdb

      part btrfs.1 --grow --ondisk=sda
      part btrfs.2 --grow --ondisk=sdb

      btrfs / --data=1 --metadata=1 --label=root btrfs.1 btrfs.2
    '';

    services.openssh.extraConfig = lib.mkAfter ''
      ListenAddress ${config.deployment.hetzner.mainIPv4}
      ListenAddress [2a01:4f8:162:4187::]
    '';
  };

  taalo = { pkgs, lib, nodes, config, ... }: let
    inherit (config.networking.p2pTunnels.ssh) ultron;
  in mkMachine {
    imports = [ ./hydra.nix ];
    opencloud.mainIPv4 = "216.239.38.106";
    opencloud.mainIPv6 = "2001:4860:4802:34::6a";

    fileSystems."/".options = [
      "autodefrag" "space_cache" "compress=lzo" "noatime"
    ];

    boot.kernelPackages = pkgs.linuxPackages_latest;

    deployment.hetzner.partitions = ''
      clearpart --all --initlabel --drives=sda,sdb

      part swap1 --size=10000 --label=swap1 --fstype=swap --ondisk=sda
      part swap2 --size=10000 --label=swap2 --fstype=swap --ondisk=sdb

      part btrfs.1 --grow --ondisk=sda
      part btrfs.2 --grow --ondisk=sdb

      btrfs / --data=1 --metadata=1 --label=root btrfs.1 btrfs.2
    '';
    deployment.encryptedLinksTo = [ "ultron" ];

    services.hydra-dev = {
      listenHost = lib.mkForce ultron.localIPv4;
      dbi = "dbi:Pg:dbname=hydra;user=hydra;host=${ultron.remoteIPv4}";
    };

    opencloud.conditions.hydra-init.custom.command = ''
      ${pkgs.postgresql}/bin/psql -h ${ultron.remoteIPv4} hydra hydra -c ""
    '';
  };

  benteflork = mkMachine {
    imports = [ ./hydra-slave.nix ];
    opencloud.mainIPv4 = "144.76.202.147";
    opencloud.mainIPv6 = "2a01:4f8:200:8392::";
  };

  dugee = { nodes, config, lib, ... }: mkMachine {
    imports = [ ./dns-server.nix ];
    opencloud.services.acme.dnsHandler = let
      myself = config.networking.hostName;
      tunnel = nodes.ultron.config.networking.p2pTunnels.ssh.${myself};
    in {
      enable = true;
      fqdn = "ns1.opencloud.software";
      listen = lib.singleton {
        host = tunnel.remoteIPv4;
        device = "tun${toString tunnel.remoteTunnel}";
      };
    };
    opencloud.mainIPv4 = "78.46.182.124";
    opencloud.mainIPv6 = "2a01:4f8:d13:3009::2";
    networking.localCommands = lib.mkAfter ''
      ip -6 addr add 2a01:4f8:d13:3009::2 dev ${config.opencloud.mainDevice}
    '';
  };

  gussh = { config, lib, ... }: mkMachine {
    imports = [ ./dns-server.nix ];
    opencloud.mainIPv4 = "78.47.142.38";
    opencloud.mainIPv6 = "2a01:4f8:d13:5308::2";
    networking.localCommands = lib.mkAfter ''
      ip -6 addr add 2a01:4f8:d13:5308::2 dev ${config.opencloud.mainDevice}
    '';
  };

  unzervalt = { nodes, lib, ... }: mkMachine {
    deployment.targetEnv = "container";
    deployment.container.host = nodes.ultron.config;
    imports = [ ./common.nix ]
           ++ lib.optional (lib.pathExists ./private/default.nix) ./private;
    opencloud.services.webspace.enable = true;
    users.mutableUsers = false;
  };
}
