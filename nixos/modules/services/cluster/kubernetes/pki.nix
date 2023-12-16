{ config, lib, pkgs, ... }:

with lib;

let
  top = config.services.kubernetes;
  cfg = top.pki;

  k8sCaCsr = pkgs.writeText "kube-pki-k8s-ca-csr.json" (builtins.toJSON {
    key = {
        algo = "rsa";
        size = 2048;
    };
    names = singleton cfg.k8sCaSpec;
  });
  
  etcdCaCsr = pkgs.writeText "kube-pki-etcd-ca-csr.json" (builtins.toJSON {
    key = {
        algo = "rsa";
        size = 2048;
    };
    names = singleton cfg.etcdCaSpec;
  });

  frontProxyCaCsr = pkgs.writeText "kube-pki-front-proxy-ca-csr.json" (builtins.toJSON {
    key = {
        algo = "rsa";
        size = 2048;
    };
    names = singleton cfg.frontProxyCaSpec;
  });

  csrCfssl = pkgs.writeText "kube-pki-cfssl-csr.json" (builtins.toJSON {
    key = {
        algo = "rsa";
        size = 2048;
    };
    CN = top.masterAddress;
    hosts = [top.masterAddress] ++ cfg.cfsslAPIExtraSANs;
  });

  rootToIm = pkgs.writeText "root-to-im.json" (builtins.toJSON {    
    signing = {
        default = {
            expiry = "43800h";
            ca_constraint = {
                is_ca = true;
                max_path_len = 0;
                max_path_len_zero = true;
            };
            usages = [
                "digital signature"
                "cert sign"
                "crl sign"
                "signing"
            ];
        };    
    };
  });

  k8sCaApiTokenBaseName = "k8sCa.secret";
  etcdCaApiTokenBaseName = "etcdCa.secret";
  frontProxyCaApiTokenBaseName = "frontProxyCa.secret";

  apiTokenPaths = {
    multirootca = with config.services; {
      k8sCa = "${cfssl-multirootca.workingDir}/${k8sCaApiTokenBaseName}";
      etcdCa = "${cfssl-multirootca.workingDir}/${etcdCaApiTokenBaseName}";
      frontProxyCa = "${cfssl-multirootca.workingDir}/${frontProxyCaApiTokenBaseName}";
    };
    certmgr = {
      k8sCa = "${top.secretsPath}/${k8sCaApiTokenBaseName}";
      etcdCa = "${top.secretsPath}/${etcdCaApiTokenBaseName}";
      frontProxyCa = "${top.secretsPath}/${frontProxyCaApiTokenBaseName}";
    };
  };
 
  apiTokenLength = 32;

  clusterAdminKubeconfig = with cfg.certs.clusterAdmin;
    top.lib.mkKubeConfig "cluster-admin" {
        server = top.apiserverAddress;
        certFile = cert;
        keyFile = key;
    };

  remote = with config.services; "https://${kubernetes.masterAddress}:${toString cfssl-multirootca.port}";
in
{
  ###### interface
  options.services.kubernetes.pki = with lib.types; {

    enable = mkEnableOption (lib.mdDoc "easyCert issuer service");

    certs = mkOption {
      description = lib.mdDoc "List of certificate specs to feed to cert generator.";
      default = {};
      type = attrs;
    };

    genCfsslCACert = mkOption {
      description = lib.mdDoc ''
        Whether to automatically generate cfssl CA certificate and key,
        if they don't exist.
      '';
      default = true;
      type = bool;
    };

    genCfsslAPICerts = mkOption {
      description = lib.mdDoc ''
        Whether to automatically generate cfssl API webserver TLS cert and key,
        if they don't exist.
      '';
      default = true;
      type = bool;
    };

    cfsslAPIExtraSANs = mkOption {
      description = lib.mdDoc ''
        Extra x509 Subject Alternative Names to be added to the cfssl API webserver TLS cert.
      '';
      default = [];
      example = [ "subdomain.example.com" ];
      type = listOf str;
    };

    genCfsslAPIToken = mkOption {
      description = lib.mdDoc ''
        Whether to automatically generate cfssl API-token secret,
        if they doesn't exist.
      '';
      default = true;
      type = bool;
    };

    pkiTrustOnBootstrap = mkOption {
      description = lib.mdDoc "Whether to always trust remote cfssl server upon initial PKI bootstrap.";
      default = true;
      type = bool;
    };

    k8sCaSpec = mkOption {
      description = lib.mdDoc "Certificate specification for the auto-generated Kubernetes general CA.";
      default = {
        CN = "kubernetes-ca";
        O = "NixOS";
        OU = "services.kubernetes.pki.caSpec";
        L = "auto-generated";
      };
      type = attrs;
    };

    etcdCaSpec = mkOption {
      description = lib.mdDoc "Certificate specification for the auto-generated Kubernetes general CA.";
      default = {
        CN = "etcd-ca";
        O = "NixOS";
        OU = "services.kubernetes.pki.caSpec";
        L = "auto-generated";
      };
      type = attrs;
    };

   frontProxyCaSpec = mkOption {
      description = lib.mdDoc "Certificate specification for the auto-generated Kubernetes general CA.";
      default = {
        CN = "kubernetes-front-proxy-ca";
        O = "NixOS";
        OU = "services.kubernetes.pki.caSpec";
        L = "auto-generated";
      };
      type = attrs;
    };

    etcClusterAdminKubeconfig = mkOption {
      description = lib.mdDoc ''
        Symlink a kubeconfig with cluster-admin privileges to environment path
        (/etc/\<path\>).
      '';
      default = null;
      type = nullOr str;
    };

  };

  ###### implementation
  config = mkIf cfg.enable
  (let
    cfsslCertPathPrefix = "${config.services.cfssl-multirootca.workingDir}/cfssl";
    cfsslCert = "${cfsslCertPathPrefix}.pem";
    cfsslKey = "${cfsslCertPathPrefix}-key.pem";
  in
  {

    services.cfssl-multirootca = mkIf (top.apiserver.enable) {
      enable = true;
      address = "0.0.0.0";
      tlsCert = cfsslCert;
      tlsKey = cfsslKey;
    };

    systemd.services.cfssl-multirootca.preStart = with pkgs; with config.services.cfssl-multirootca; mkIf (top.apiserver.enable)
    (concatStringsSep "\n" [
      "set -e"
      "if [ ! -f ${workingDir}/${rootsFile} ]; then"
      (concatStringsSep "\n" (mapAttrsToList (key: value:
      ''
        echo '${(builtins.toJSON {
            signing = {
              profiles = {
                default = {
                  usages = [
                    "digital signature"
                  ];
                  auth_key = "default";
                  expiry = "8760h";
                };
              };
            };
            auth_keys = {
              default = {
                type = "standard";
                key = "file:${value}";
              };
            };
          })}' > "${workingDir}/${key}-config.json"        
          echo '
          [ ${key} ]
          private = file://${key}-key.pem
          certificate = ${key}.pem
          config = ${key}-config.json' \
            >> ${workingDir}/${rootsFile};      
      ${(optionalString cfg.genCfsslAPIToken 
      ''
        if [ ! -f "${value}" ]; then
          head -c ${toString (apiTokenLength / 2)} /dev/urandom | od -An -t x | tr -d ' ' >"${value}"
        fi
        chown cfssl-multirootca "${value}" && chmod 400 "${value}"
      '')}
      ''
      ) apiTokenPaths.multirootca))
      
      "fi"
      (optionalString cfg.genCfsslCACert ''
        if [ ! -f "${workingDir}/k8sCa.pem" ]; then
          ${cfssl}/bin/cfssl genkey -initca ${k8sCaCsr} | \
            ${cfssl}/bin/cfssljson -bare ${workingDir}/k8sCa
        fi
        if [ ! -f "${workingDir}/etcdCa.pem" ]; then
          ${cfssl}/bin/cfssl gencert \
            -ca ${workingDir}/k8sCa.pem \
            -ca-key ${workingDir}/k8sCa-key.pem \
            -config ${rootToIm} \
            ${etcdCaCsr} | \
            ${cfssl}/bin/cfssljson -bare etcdCa
        fi
         if [ ! -f "${workingDir}/frontProxyCa.pem" ]; then
          ${cfssl}/bin/cfssl gencert \
            -ca ${workingDir}/k8sCa.pem \
            -ca-key ${workingDir}/k8sCa-key.pem \
            -config ${rootToIm} \
            ${frontProxyCaCsr} | \
            ${cfssl}/bin/cfssljson -bare frontProxyCa
        fi
      '')

      (optionalString cfg.genCfsslAPICerts ''
        if [ ! -f "${workingDir}/cfssl.pem" ]; then
          ${cfssl}/bin/cfssl gencert \
          -ca ${workingDir}/k8sCa.pem \
          -ca-key ${workingDir}/k8sCa-key.pem \
          ${csrCfssl} | \
            ${cfssl}/bin/cfssljson -bare ${cfsslCertPathPrefix}
        fi
      '')
      ]);

    systemd.services.kube-certmgr-bootstrap = {
      description = "Kubernetes certmgr bootstrapper";
      wantedBy = [ "certmgr.service" ];
      after = [ "cfssl.target" ];
      script = concatStringsSep "\n" [''
        set -e

        # If there's a cfssl (cert issuer) running locally, then don't rely on user to
        # manually paste it in place. Just symlink.
        # otherwise, create the target file, ready for users to insert the token

        mkdir -p '${dirOf apiTokenPaths.certmgr.k8sCa}'

        if [ -f "${apiTokenPaths.multirootca.k8sCa}" ]; then
          ln -fs "${apiTokenPaths.multirootca.k8sCa}" "${apiTokenPaths.certmgr.k8sCa}"
        else
          touch "${apiTokenPaths.certmgr.k8sCa}" && chmod 600 "${apiTokenPaths.certmgr.k8sCa}"
        fi
        if [ -f "${apiTokenPaths.multirootca.etcdCa}" ]; then
          ln -fs "${apiTokenPaths.multirootca.etcdCa}" "${apiTokenPaths.certmgr.etcdCa}"
        else
          touch "${apiTokenPaths.certmgr.etcdCa}" && chmod 600 "${apiTokenPaths.certmgr.etcdCa}"
        fi
        if [ -f "${apiTokenPaths.multirootca.frontProxyCa}" ]; then
          ln -fs "${apiTokenPaths.multirootca.frontProxyCa}" "${apiTokenPaths.certmgr.frontProxyCa}"
        else
          touch "${apiTokenPaths.certmgr.frontProxyCa}" && chmod 600 "${apiTokenPaths.certmgr.frontProxyCa}"
        fi
      ''
      (optionalString (cfg.pkiTrustOnBootstrap) ''
        if [ ! -f "${top.caFile}" ] || [ $(cat "${top.caFile}" | wc -c) -lt 1 ]; then
          ${pkgs.curl}/bin/curl --fail-early -f -kd '{ "label": "k8sCa" }' ${remote}/api/v1/cfssl/info | \
            ${pkgs.cfssl}/bin/cfssljson -stdout >${top.caFile}
        fi
        if [ ! -f "${top.lib.secret "etcdCa"}" ] || [ $(cat "${top.lib.secret "etcdCa"}" | wc -c) -lt 1 ]; then
          ${pkgs.curl}/bin/curl --fail-early -f -kd '{ "label": "etcdCa" }' ${remote}/api/v1/cfssl/info | \
            ${pkgs.cfssl}/bin/cfssljson -stdout >${top.lib.secret "etcdCa"}
        fi
        if [ ! -f "${top.lib.secret "frontProxyCa"}" ] || [ $(cat "${top.lib.secret "frontProxyCa"}" | wc -c) -lt 1 ]; then
          ${pkgs.curl}/bin/curl --fail-early -f -kd '{ "label": "frontProxyCa" }' ${remote}/api/v1/cfssl/info | \
            ${pkgs.cfssl}/bin/cfssljson -stdout >${top.lib.secret "frontProxyCa"}
        fi
      '')
      ];
      serviceConfig = {
        RestartSec = "10s";
        Restart = "on-failure";
      };
    };

    security.pki.certificateFiles = [top.caFile];

    services.certmgr = {
      enable = true;
      package = pkgs.certmgr-selfsigned;
      svcManager = "command";
      specs =
        let
          mkSpec = _: cert: {
            inherit (cert) action;
            authority = {
              inherit remote;
              # file.path = cert.caCert;
              root_ca = cfsslCert;
              profile = "default";
              label = cert.label;
              auth_key_file = apiTokenPaths.certmgr."${toString cert.label}";
            };
            certificate = {
              path = cert.cert;
            };
            private_key = cert.privateKeyOptions;
            request = {
              hosts = [cert.CN] ++ cert.hosts;
              inherit (cert) CN;
              key = {
                algo = "rsa";
                size = 2048;
              };
              names = [ cert.fields ];
            };
          };
        in
          mapAttrs mkSpec cfg.certs;
      };

      #TODO: Get rid of kube-addon-manager in the future for the following reasons
      # - it is basically just a shell script wrapped around kubectl
      # - it assumes that it is clusterAdmin or can gain clusterAdmin rights through serviceAccount
      # - it is designed to be used with k8s system components only
      # - it would be better with a more Nix-oriented way of managing addons
      systemd.services.kube-addon-manager = mkIf top.addonManager.enable (mkMerge [{
        environment.KUBECONFIG = with cfg.certs.addonManager;
          top.lib.mkKubeConfig "addon-manager" {
            server = top.apiserverAddress;
            certFile = cert;
            keyFile = key;
          };
        }

        (optionalAttrs (top.addonManager.bootstrapAddons != {}) {
          serviceConfig.PermissionsStartOnly = true;
          preStart = with pkgs;
          let
            files = mapAttrsToList (n: v: writeText "${n}.json" (builtins.toJSON v))
              top.addonManager.bootstrapAddons;
          in
          ''
            export KUBECONFIG=${clusterAdminKubeconfig}
            ${top.package}/bin/kubectl apply -f ${concatStringsSep " \\\n -f " files}
          '';
        })]);

      environment.etc.${cfg.etcClusterAdminKubeconfig}.source = mkIf (cfg.etcClusterAdminKubeconfig != null)
        clusterAdminKubeconfig;

      environment.systemPackages = mkIf (top.kubelet.enable || top.proxy.enable) [
      (pkgs.writeScriptBin "nixos-kubernetes-node-join" ''
        set -e
        exec 1>&2

        if [ $# -gt 0 ]; then
          echo "Usage: $(basename $0)"
          echo ""
          echo "No args. Apitoken must be provided on stdin."
          echo "To get the apitoken, execute: 'sudo cat ${apiTokenPaths.certmgr.k8sCa}' on the master node."
          exit 1
        fi

        if [ $(id -u) != 0 ]; then
          echo "Run as root please."
          exit 1
        fi

        read -r token
        if [ ''${#token} != ${toString apiTokenLength} ]; then
          echo "Token must be of length ${toString apiTokenLength}."
          exit 1
        fi

        echo $token > ${apiTokenPaths.certmgr.k8sCa}
        chmod 600 ${apiTokenPaths.certmgr.k8sCa}

        echo "Restarting certmgr..." >&1
        systemctl restart certmgr

        echo "Waiting for certs to appear..." >&1

        ${optionalString top.kubelet.enable ''
          while [ ! -f ${cfg.certs.kubelet.cert} ]; do sleep 1; done
          echo "Restarting kubelet..." >&1
          systemctl restart kubelet
        ''}

        ${optionalString top.proxy.enable ''
          while [ ! -f ${cfg.certs.kubeProxyClient.cert} ]; do sleep 1; done
          echo "Restarting kube-proxy..." >&1
          systemctl restart kube-proxy
        ''}

        ${optionalString top.flannel.enable ''
          while [ ! -f ${cfg.certs.flannelClient.cert} ]; do sleep 1; done
          echo "Restarting flannel..." >&1
          systemctl restart flannel
        ''}

        echo "Node joined successfully"
      '')];

      # isolate etcd on loopback at the master node
      # easyCerts doesn't support multimaster clusters anyway atm.
      services.etcd = with cfg.certs.etcd; {
        listenClientUrls = ["https://127.0.0.1:2379"];
        listenPeerUrls = ["https://127.0.0.1:2380"];
        advertiseClientUrls = ["https://etcd.local:2379"];
        initialCluster = ["${top.masterAddress}=https://etcd.local:2380"];
        initialAdvertisePeerUrls = ["https://etcd.local:2380"];
        certFile = mkDefault cert;
        keyFile = mkDefault key;
        trustedCaFile = mkDefault caCert;
      };
      networking.extraHosts = mkIf (config.services.etcd.enable) ''
        127.0.0.1 etcd.${top.addons.dns.clusterDomain} etcd.local
      '';

      services.flannel = with cfg.certs.flannelClient; {
        kubeconfig = top.lib.mkKubeConfig "flannel" {
          server = top.apiserverAddress;
          certFile = cert;
          keyFile = key;
        };
      };

      services.kubernetes = {

        apiserver = mkIf top.apiserver.enable (with cfg.certs.apiServer; {
          etcd = with cfg.certs.apiserverEtcdClient; {
            servers = ["https://etcd.local:2379"];
            certFile = mkDefault cert;
            keyFile = mkDefault key;
            caFile = mkDefault caCert;
          };
          clientCaFile = mkDefault caCert;
          tlsCertFile = mkDefault cert;
          tlsKeyFile = mkDefault key;
          serviceAccountKeyFile = mkDefault cfg.certs.serviceAccount.cert;
          serviceAccountSigningKeyFile = mkDefault cfg.certs.serviceAccount.key;
          kubeletClientCaFile = mkDefault caCert;
          kubeletClientCertFile = mkDefault cfg.certs.apiserverKubeletClient.cert;
          kubeletClientKeyFile = mkDefault cfg.certs.apiserverKubeletClient.key;
          proxyClientCertFile = mkDefault cfg.certs.apiserverProxyClient.cert;
          proxyClientKeyFile = mkDefault cfg.certs.apiserverProxyClient.key;
        });
        controllerManager = mkIf top.controllerManager.enable {
          serviceAccountKeyFile = mkDefault cfg.certs.serviceAccount.key;
          rootCaFile = cfg.certs.controllerManagerClient.caCert;
          kubeconfig = with cfg.certs.controllerManagerClient; {
            certFile = mkDefault cert;
            keyFile = mkDefault key;
          };
        };
        scheduler = mkIf top.scheduler.enable {
          kubeconfig = with cfg.certs.schedulerClient; {
            certFile = mkDefault cert;
            keyFile = mkDefault key;
          };
        };
        kubelet = mkIf top.kubelet.enable {
          clientCaFile = mkDefault cfg.certs.kubelet.caCert;
          tlsCertFile = mkDefault cfg.certs.kubelet.cert;
          tlsKeyFile = mkDefault cfg.certs.kubelet.key;
          kubeconfig = with cfg.certs.kubeletClient; {
            certFile = mkDefault cert;
            keyFile = mkDefault key;
          };
        };
        proxy = mkIf top.proxy.enable {
          kubeconfig = with cfg.certs.kubeProxyClient; {
            certFile = mkDefault cert;
            keyFile = mkDefault key;
          };
        };
      };
    });

  meta.buildDocsInSandbox = false;
}
