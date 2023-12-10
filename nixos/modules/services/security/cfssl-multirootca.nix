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

    roots = mkOption {
      type = types.str;
      description = lib.mdDoc ''
        An absolute path to a configuration file specifying the roots and their keys.
        See: https://github.com/cloudflare/cfssl

        :::{.note}
        The directory containing the roots file will be used as the working 
        directory of the multirootca service so paths in the roots file will
        be relative to that path.

        Please ensure the directory is readable and executable, and that the roots 
        file as well as all certs referecned in it are readable by the 
        cfssl-multirootca user in the cfssl group.

        Do not put this in nix-store as it might contain secrets.
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
          WorkingDirectory = dirOf cfg.roots;
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
              (opt "roots" roots)
              (opt "tls-cert" tlsCert)
              (opt "tls-key" tlsKey)
            ];
        }
      ];
    };
  };
}
