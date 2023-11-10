{ config, pkgs, lib, ... }: with lib; let 
in {
  mkServices = tokenName: secretName: let
    cfg = config.turnkey.tokens.${tokenName}.secrets.${secretName};
    mount = if cfg ? mount then cfg.mount else tokenName;
    user = if cfg ? user then cfg.user else tokenName;
    group = if cfg ? group then cfg.group else tokenName;

    tokenPath = "/run/keys/${tokenName}.token";
    mountPath = "/run/keys/${mount}";
    secretPath = "${mountPath}/${secretName}.secret";
    vaultSecretPath = "${mount}/${secretName}";
    token = "$(cat ${tokenPath})";

    mkActualSecret = field: linkPath: ''
      vault kv get -field=${field} ${mount}/${field} > /run/keys/${mount}/${field}.secret
      ln -s /run/keys/${mount}/${field}.secret ${linkPath}
      chown ${user}:${group} /run/keys/${mount}/${field}.secret
      chmod 0600 /run/keys/${mount}/${field}.secret
    '';
    getSecretFields = concatLines (attrValues (mapAttrs mkActualSecret cfg.fields));
  in {
    "turnkey-${tokenName}-${secretName}-secret" = {
      enable = true;
      description = "Emerald City Turnkey Secret: ${secretName}";
      after = [ "turnkey.target" ];
      wantedBy = [ "turnkey.target" ];
      requires = [ "turnkey.target" ];
      path = [ pkgs.vault-bin pkgs.util-linux pkgs.jq ];
      environment.VAULT_ADDR = "https://vault.emerald.city:8200";
      serviceConfig = {
        User = "root";
        Group = "root";
        Type = "simple";
        RemainAfterExit = "yes";
        ExecStart = pkgs.writeShellScript "${secretName}-acquire.sh" ''
          flock -s ${tokenPath} -c "{
            vault login token=${token}

            mkdir -p ${mountPath}

            ${getSecretFields}
          }" 

          echo "Secret acquired, entering monitoring loop."
          while true ; do
            flock -s ${secretPath} -c "{
              # If the secret has been removed, we need to exit
              [ -e ${secretPath} ] && exit 1
              # If the secret has gone empty, we need to fail.
              [ -z $(cat ${secretPath}) ] && exit 2
            }"
            echo "Token still fresh"
            sleep 15;
          done 
        '';
      };
    };

    /*
    "${secretName}-renew" = {
    };
    "${secretName}-refresh" = {
    };
    */
  };

  mkTimers = secretCfg: tokenName: { }: {
  };
}
