{ pkgs, rootTokenPath, mkDescription, roleIDPath, secretIDPath, ... }: let 
in {
  mkService = {
    turnkey-root = {
      after = [ "turnkey.target" ];
      path = [ pkgs.vault-bin pkgs.util-linux ];
      environment.VAULT_ADDR = "https://vault.emerald.city:8200";
      serviceConfig = {
        User = "root";
        Group = "root";
        Type = "oneshot";
        RemainAfterExit = "no";
        ExecStart = with pkgs; pkgs.writeShellScript "turnkey-renew.sh" ''
          flock -s ${rootTokenPath} -c "{
            vault login token=$(cat ${rootTokenPath})
            vault token renew
          }" &> /dev/null
        '';
      };
    };
  };
  mkTimer = {
    turnkey-root-renew = {
      enable = true;
      wantedBy = [ "turnkey.target" ];
      after = [ "turnkey-unlock.service" ];
      description = mkDescription "Root Token Renewal Timer";
      timerConfig.OnCalendar = "*:0/1"; #Every minute
      timerConfig.RandomizedDelaySec = "10s";
    };
  };
  mkUnlockOneshot = {
      # Responsible for turning the role/secret -> root token and starting
      # all the other services by isolating to the target
      turnkey = {
        after = [ "multi-user.target" ];
        path = [ pkgs.vault-bin pkgs.util-linux ];
        environment.VAULT_ADDR = "https://vault.emerald.city:8200";
        description = mkDescription "Root Token Unlock Script";
        bindsTo = [ "turnkey.target" ];
        serviceConfig = { 
          User = "root";
          Group = "root";
          RemainAfterExit = "yes";
          ExecStart = with pkgs; pkgs.writeShellScript "turnkey-unlock.sh" ''
            if [ -e "${rootTokenPath}" ] && [ ! -z "$(cat ${rootTokenPath})" ] ; then 
              echo "Already have a root token, skipping."
              exit 0
            fi

            if vault write -field=token auth/approle/login \
                     role_id=$(cat ${roleIDPath}) \
                     secret_id=$(cat ${secretIDPath}) > ${rootTokenPath} ; then
              echo "Keys installed, activating turnkey target"
            else
              echo "ERROR: Could not authorize with provided keys."
              exit 1
            fi

            vault token capabilities $(cat ${rootTokenPath})

            vault login token="$(cat ${rootTokenPath})"

            systemctl isolate turnkey.target
            '';
          ExecStartPost = with pkgs; pkgs.writeShellScript "turnkey-start-post.sh" ''
            rm -f ${secretIDPath}
            rm -f ${roleIDPath}
          '';
          ExecStopPost = with pkgs; pkgs.writeShellScript "turnkey-stop-post.sh" ''
            rm -f ${secretIDPath}
            rm -f ${roleIDPath}
          '';
          ExecStop = with pkgs; pkgs.writeShellScript "turnkey-stop.sh" ''
            # FIXME: this should actually 'hibernate' the system, generating
            # a longterm token in rootTokenPath (like, 15m or some
            # max-build-time).
            #
            # The issue right now is that when I run the build against this
            # machine, it tries to start this script, but hangs because it's
            # already started.
            # 
            # A workaround for now is to comment `rm` part of the script,
            # this is less safe, but it allows the build to complete without
            # dying because it can't find a secret/role pair.

            # flock -x ${rootTokenPath} -c "rm -f ${rootTokenPath}"
            systemctl stop turnkey.target
          '';
          };
        };
  };
}
