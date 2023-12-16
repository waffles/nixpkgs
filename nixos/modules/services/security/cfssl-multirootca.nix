{ config, options, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.cfssl-multirootca;
in {
  options.services.cfssl-multirootca = {
    enable = mkEnableOption (lib.mdDoc "the multirootca api server included with CFSSL");

    address = mkOption {
      default = "127.0.0.1";
      type = types.str;
      description = lib.mdDoc "Address to bind.";
    };

    port = mkOption {
      default = 8888;
      type = types.port;
      description = lib.mdDoc "Port to bind.";
    };

    defaultLabel = mkOption {
      default = null;
      type = types.nullOr types.str;
      description = lib.mdDoc "Specify a default label that handles requests without a label.";
    };

    logLevel = mkOption {
      default = 1;
      type = types.enum [ 0 1 2 3 4 5 ];
      description = lib.mdDoc "Log level (0 = DEBUG, 5 = FATAL).";
    };

    rootsFile = mkOption {
      default = "roots.conf";
      type = types.str;
      description = lib.mdDoc ''
        An absolute path to a configuration file specifying the roots and their keys.
        See: https://github.com/cloudflare/cfssl

        Do not put this in nix-store as it might contain secrets.
        '';
    };

    workingDir = mkOption {
      default = "/var/lib/cfssl-multirootca";
      type = types.path;
      description = lib.mdDoc ''
        The working directory for multirootca. Paths in the roots configuration
        will be relitive to this directory.

        ::: {.note}
        If left as the default value this directory will automatically be
        created before the multirootca server starts, otherwise you are
        responsible for ensuring the directory exists with appropriate
        ownership and permissions.
        :::
      '';
    };

    tlsCert = mkOption {
      default = null;
      type = types.nullOr types.path;
      description = lib.mdDoc "Server certificate.";
    };

    tlsKey = mkOption {
      default = null;
      type = types.nullOr types.str;
      description = lib.mdDoc "Server private key.";
    };
  };

  config = mkIf cfg.enable {
    users.groups.cfssl = {
      gid = config.ids.gids.cfssl;
    };

    users.users.cfssl-multirootca = {
      description = "cfssl-multirootca user";
      group = "cfssl";
      uid = config.ids.uids.cfssl-multirootca;
    };

    systemd.services.cfssl-multirootca = {
      description = "CFSSL Multi-Root CA API server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = lib.mkMerge [
        {
          WorkingDirectory =  cfg.workingDir;
          Restart = "always";
          User = "cfssl-multirootca";
          Group = "cfssl";

          ExecStart = with cfg; let
            opt = n: v: optionalString (v != null) ''-${n}="${v}"'';
          in
            lib.concatStringsSep " \\\n" [
              "${pkgs.cfssl}/bin/multirootca"
              (opt "a" "${address}:${(toString port)}")
              (opt "l" defaultLabel)
              (opt "loglevel" (toString logLevel))
              (opt "roots" rootsFile)
              (opt "tls-cert" tlsCert)
              (opt "tls-key" tlsKey)
            ];
        }
        (mkIf (cfg.workingDir == options.services.cfssl-multirootca.workingDir.default) {
          StateDirectory = baseNameOf cfg.workingDir;
          StateDirectoryMode = 700;
        })
      ];
    };
  };
}
