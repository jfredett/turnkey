{ pkgs, lib, rootTokenPath, tokenPath, ...  }: with lib; let
in {
  mkTimers = tokenName: {
    "turnkey-${tokenName}-timer" = {
      enable = true;
      wantedBy = [ "turnkey.target" ];
      partOf = [ "${tokenName}-token.service" ];
      after = [ "turnkey.service" ];
      description = "Emerald City Turnkey Token: Renew Minder for ${tokenName}";
      timerConfig.OnCalendar = "*:0/1"; # renew every minute
      timerConfig.RandomizedDelaySec = "10s";
    };
  };

  mkServices = cfgIn: tokenName: let cfg = cfgIn.${tokenName}; in {
    "turnkey-${tokenName}-token" = {
      description = "Emerald City Turnkey Token: ${tokenName}";
      after = [ "turnkey.target" ];
      wantedBy = [ "turnkey.target" ];
      serviceConfig = {
        Type = "simple";
        RemainAfterExit = "yes";
        # NOTE: Maybe these shouldn't be oneshots, but rather end in a loop which kills the
        # service if the managed token goes blank. it can wake up every few seconds, get a read
        # lock, verify it's nonempty, then repeat. If it ever gets a readlock and it's empty it
        # shuts itself down, and then restart policy can trigger to re-acquire?
        ExecStart = with pkgs; pkgs.writeShellScript "turnkey-${tokenName}-token.sh" ''
          tokenPath = "${tokenPath tokenName}";
          flock -s ${rootTokenPath} -c "{
            vault login token=$(cat ${rootTokenPath})

            vault token create -field=token -policy=${concatStringsSep " -policy=" cfg.policies} -ttl=${cfg.ttl} > $tokenPath 

            chown ${cfg.user}:${cfg.group} $tokenPath
            chmod 600 $tokenPath
          }" &>/dev/null

          echo "Token acquired, entering monitoring loop."
          while true ; do
            flock -s $tokenPath -c "{
              # If the token has been removed, we need to exit
              [ -e $tokenPath ] && exit 1
              # If the token has gone empty, we need to fail.
              [ -z $(cat $tokenPath) ] && exit 2
            }" &>/dev/null
            echo "Token still fresh"
            sleep 15;
          done 
        '';
        ExecStop = with pkgs; pkgs.writeShellScript "${tokenName}-cleanup.sh" ''
          flock -x $tokenPath -c "rm -f $tokenPath"
        '';
      };
    };
    "turnkey-${tokenName}-renew" = {
      enable = true; 
      description = "Emerald City Turnkey Token: Renew ${tokenName}";
      partOf = [ "turnkey-${tokenName}-token.service" ];

      path = [ pkgs.vault-bin pkgs.util-linux pkgs.jq ];
      environment.VAULT_ADDR = "https://vault.emerald.city:8200";

      serviceConfig = {
        User = "root";
        Group = "root";
        Type = "oneshot";
        ExecStart = with pkgs; pkgs.writeShellScript "turnkey-${tokenName}-renew.sh" ''
          flock -x ${rootTokenPath} -c "{
            vault login token=$(cat ${rootTokenPath})
            vault token renew $(cat ${tokenPath tokenName})
          }" &>/dev/null
          echo "Token expires at:"
          vault token lookup -format=json | jq .data.expire_time
        '';
      };
    };
    /*
    # TODO: Implement a rotation script to run less often
    "turnkey-${tokenName}-refresh" = {
    };
    # */
  };
}
