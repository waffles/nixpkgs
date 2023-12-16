import ./make-test-python.nix (
  let
    caName = "ca";
  in
  { pkgs, ... } : {
  name = "cfssl-multirootca";

  nodes.machine = { config, lib, pkgs, ... }:
  {
    networking.firewall.allowedTCPPorts = [ config.services.cfssl-multirootca.port ];
    
    services.cfssl-multirootca = {
      enable = true;
    };

    systemd.services.cfssl-multirootca.after = [ "cfssl-multirootca-init.service" ];

    systemd.services.cfssl-multirootca-init = {
      description = "Initialize the cfssl multirootca";
      wantedBy    = [ "multi-user.target" ];
      serviceConfig = {
        User             = "cfssl-multirootca";
        Type             = "oneshot";           
        StateDirectory = baseNameOf config.services.cfssl-multirootca.workingDir;
        StateDirectoryMode = 700;
        WorkingDirectory = config.services.cfssl-multirootca.workingDir;
      };

      script = with pkgs; ''
        ${cfssl}/bin/cfssl genkey -initca ${pkgs.writeText "ca.json" (builtins.toJSON {
          hosts = [ "ca.example.com" ];
          key = {
            algo = "rsa"; size = 4096; };
            names = [
              {
                C = "US";
                L = "San Francisco";
                O = "Internet Widgets, LLC";
                OU = "Certificate Authority";
                ST = "California";
              }
            ];
        })} | ${cfssl}/bin/cfssljson -bare ca

        echo '${(builtins.toJSON {
          signing = {
            profiles = {
              default = {
                usages = [
                  "digital signature"
                ];
                auth_key = "default";
                expiry = "720h";
              };
            };
          };
          auth_keys = {
            default = {
              type = "standard";
              key = "012345678012345678";
            };
          };
        })}' > "cfssl-config.json"
        pwd
        echo '
        [ ${caName} ]
        private = file://ca-key.pem
        certificate = ca.pem
        config = cfssl-config.json' \
          > ${config.services.cfssl-multirootca.workingDir}/${config.services.cfssl-multirootca.rootsFile};
      '';
    };
  };

  testScript =
  let     
     cfsslrequest = with pkgs; writeScript "cfsslrequest" ''
      curl -f -X POST -H "Content-Type: application/json" -d '{"label":"${caName}"}'\
       http://localhost:8888/api/v1/cfssl/info | ${cfssl}/bin/cfssljson /tmp/certificate
    '';
  in
    ''
      machine.wait_for_unit("cfssl-multirootca.service")
      machine.wait_until_succeeds("${cfsslrequest}")
      machine.succeed("ls /tmp/certificate.pem")
    '';
})
