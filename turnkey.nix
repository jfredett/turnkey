{ config, pkgs, lib, ... }: with lib;
let 
  configtree = (import ./config-tree.nix);
  roleIDPath = "/run/keys/role-id";
  secretIDPath = "/run/keys/secret-id";
  rootTokenPath = "/run/keys/root.token";
  childrenName = "tokens";
  parentName = "turnkey";
  mkDescription = component: "Emerald City Turnkey Service: ${component}";
  parentDescription = mkDescription "Machine Token Minder";
  parentOptions = with types; {
    enable = mkEnableOption "Enable ${parentDescription}";
    appRole = mkOption {
      description = "The name of the approle to use, usually the hostname of the machine";
      type = str;
    };
    period = mkOption {
      description = "The renewal period to apply to the root token";
      default = "3m";
      type = str;
    };
  };
  childOptions = with types; {
    user = mkOption { description = "user who will own the token, defaults to name of token"; type = nullOr str; };
    group = mkOption { description = "group who will own the token defaults to name of token"; type = nullOr str; };
    ttl = mkOption { description = ""; type = str; };
    policies = mkOption { description = "list of policies for the token"; type = listOf str; };
    secrets = mkOption { 
      type = attrsOf (
        submodule {
          options = {
            targetPath = mkOption { type = str; };
            mount = mkOption { type = nullOr str; default = null;  };
            user = mkOption { type = str; };
            group = mkOption { type = str; };
            mode = mkOption { type = str; default = "0600"; };
            fields = mkOption { type = attrs; default = { data = "/dev/null"; }; };
          };
        }
      );
    };
  };
  mkSecret = tokenName: secretName: { targetPath, mount ? tokenName, user ? tokenName, group ? tokenName, mode, fields }: let
    name = {
      # FIXME: This needs to get recalculated from _somewhere_
      target = "turnkey";
      secret = "turnkey-${tokenName}-${secretName}-secret";
    };
    baseConfig = set: recursiveUpdate set {
      enable = true; 
      path = [ pkgs.vault-bin pkgs.util-linux pkgs.jq ];
      environment.VAULT_ADDR = "https://vault.emerald.city:8200";
      serviceConfig = {
        User = "root";
        Group = "root";
      };
    };
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
    getSecretFields = concatLines (attrValues (mapAttrs mkActualSecret fields));
  in {
    systemd.services.${name.secret} = baseConfig {
      description = "Emerald City Turnkey Secret: ${secretName}";
      after = [ "${name.target}.target" ];
      wantedBy = [ "${name.target}.target" ];
      requires = [ "${name.target}.target" ];
      serviceConfig = {
        Type = "simple";
        RemainAfterExit = "yes";
        ExecStart = pkgs.writeShellScript "${name.secret}-acquire.sh" ''
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
  };
in configtree.mkOneLevelTree {
  inherit parentName childrenName parentDescription parentOptions childOptions;

  mkParent = cfg: let
    name = {
      target          = "turnkey"; # The name of the target
      unlockOneshot   = "${cfg.appRole}-unlock";  # Converts role/secret -> root, isolates turnkey target
      renewalService  = "${cfg.appRole}-renewal"; # Keeps the root token alive via token renewal
      refreshService  = "${cfg.appRole}-refresh"; # Halts the renewal service, re-acquires the token, and restarts the renewal service
    };
    tokenServices = (builtins.map tokenService cfg.turnkey.tokenServices);
    secretServices = (builtins.map secretService cfg.turnkey.secretServices);
  in {
    systemd = {
      targets.${name.target} = {
        enable = true;
        description = mkDescription "Post-unlock target";
        requires = [ "multi-user.target" ];
        unitConfig.AllowIsolate = true;
      };
      
      services = let 
        baseConfig = cfg: recursiveUpdate cfg {
          enable = true; 
          after = [ "multi-user.target" ];
          path = [ pkgs.vault-bin pkgs.util-linux ];
          environment.VAULT_ADDR = "https://vault.emerald.city:8200";
          serviceConfig = {
            User = "root";
            Group = "root";
            Type = "oneshot";
          };
        };
      in {
        # Responsible for turning the role/secret -> root token and starting
        # all the other services by isolating to the target
        ${name.unlockOneshot} = baseConfig {
          description = mkDescription "Root Token Retriever Script";
          bindsTo = [ "${name.target}.target" ];
          serviceConfig = { 
            RemainAfterExit = "yes";
            ExecStart = with pkgs; pkgs.writeShellScript "${name.unlockOneshot}-start.sh" ''
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
                              
              systemctl isolate ${name.target}.target
            '';
            ExecStartPost = with pkgs; pkgs.writeShellScript "${name.unlockOneshot}-start-post.sh" ''
              rm -f ${secretIDPath}
              rm -f ${roleIDPath}
            '';
            ExecStopPost = with pkgs; pkgs.writeShellScript "${name.unlockOneshot}-stop-post.sh" ''
              rm -f ${secretIDPath}
              rm -f ${roleIDPath}
            '';
            ExecStop = with pkgs; pkgs.writeShellScript "${name.unlockOneshot}-stop.sh" ''
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
              systemctl stop ${name.target}.target
            '';
          };
        };
      
        # Periodically, the token needs to get renewed, this service does that
        # with the help of the timer associated with it
        ${name.renewalService} = baseConfig {
          description = mkDescription "Root Token Renewal Script";
          serviceConfig = {
            RemainAfterExit = "no";
            ExecStart = with pkgs; pkgs.writeShellScript "${name.renewalService}.sh" ''
              flock -s ${rootTokenPath} -c "{
                vault login token=$(cat ${rootTokenPath})
                vault token renew
              }" &> /dev/null
            '';
          };
        };
      };
      
      timers = let 
        baseTimerConfig = {
          enable = true;
          wantedBy = [ "${name.target}.target" ];
          after = [ "${name.unlockOneshot}.service" ];
        };
      in {
        ${name.renewalService} = baseTimerConfig // {
          description = mkDescription "Root Token Renewal Timer";
          partOf = [ "${name.renewalService}.service" ];
          timerConfig.OnCalendar = "*:0/1"; # renew every minute
          timerConfig.RandomizedDelaySec = "10s";
        };
      };
    };
  };

  mkChild = tokenName: cfg: let 
    # many of these need to be recalculated from the parent
    name = {
      target                = "${cfg.__parent.appRole}-turnkey";
      parentUnlockOneshot   = "${cfg.__parent.appRole}-unlock";
      parentRenewalService  = "${cfg.__parent.appRole}-renewal";
      parentRefreshService  = "${cfg.__parent.appRole}-refresh";

      childGetTokenOneshot  = "${cfg.__parent.appRole}-${tokenName}-token";
      childTokenRenewalSvc  = "${cfg.__parent.appRole}-${tokenName}-renewal";
      childTokenRefreshSvc  = "${cfg.__parent.appRole}-${tokenName}-refresh";
    };
    tokenPath = "/run/keys/${tokenName}.token";
    baseConfig = set: recursiveUpdate set {
      enable = true; 
      path = [ pkgs.vault-bin pkgs.util-linux pkgs.jq ];
      environment.VAULT_ADDR = "https://vault.emerald.city:8200";
      serviceConfig = {
        User = "root";
        Group = "root";
      };
    };
    secretServices = joinAttrSets (attrValues (mapAttrs (name: cfg: mkSecret tokenName name cfg) cfg.secrets)); 
    joinAttrSets = foldl' (a: v: recursiveUpdate a v) {};
  in recursiveUpdate secretServices {
    systemd.services = {
      ${name.childGetTokenOneshot} = baseConfig {
        description = "Emerald City Turnkey Token: ${tokenName}";
        after = [ "${name.target}.target" ];
        wantedBy = [ "${name.target}.target" ];
        serviceConfig = {
          Type = "simple";
          RemainAfterExit = "yes";
          # NOTE: Maybe these shouldn't be oneshots, but rather end in a loop which kills the service if the managed token goes blank.
          # it can wake up every few seconds, get a read lock, verify it's nonempty, then repeat. If it ever gets a readlock and it's empty
          # it shuts itself down, and then restart policy can trigger to re-acquire?
          ExecStart = with pkgs; pkgs.writeShellScript "${name.childGetTokenOneshot}-acquire.sh" ''
            flock -s ${rootTokenPath} -c "{
              vault login token=$(cat ${rootTokenPath})

              vault token create -field=token -policy=${concatStringsSep " -policy=" cfg.policies} -ttl=${cfg.ttl} > ${tokenPath} 

              chown ${cfg.user}:${cfg.group} ${tokenPath}
              chmod 600 ${tokenPath}
            }" &>/dev/null
            
            echo "Token acquired, entering monitoring loop."
            while true ; do
              flock -s ${tokenPath} -c "{
                # If the token has been removed, we need to exit
                [ -e ${tokenPath} ] && exit 1
                # If the token has gone empty, we need to fail.
                [ -z $(cat ${tokenPath}) ] && exit 2
              }" &>/dev/null
              echo "Token still fresh"
              sleep 15;
            done 
            
          '';
          ExecStop = with pkgs; pkgs.writeShellScript "${name.childGetTokenOneshot}-cleanup.sh" ''
            flock -x ${tokenPath} -c "rm -f ${tokenPath}"
          '';
        };
      };

      ${name.childTokenRenewalSvc} = baseConfig {
        description = "Emerald City Turnkey Token: Renew ${tokenName}";
        partOf = [ "${name.childGetTokenOneshot}.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = with pkgs; pkgs.writeShellScript "${name.childTokenRenewalSvc}.sh" ''
            flock -x ${rootTokenPath} -c "{
              vault login token=$(cat ${rootTokenPath})
              vault token renew $(cat ${tokenPath})
            }" &>/dev/null
            echo "Token expires at:"
            vault token lookup -format=json | jq .data.expire_time
          '';
        };
      };
    };


    timers = let
      baseTimerConfig = {
        enable = true;
        wantedBy = [ "${name.target}.target" ];
        partOf = [ "${name.childGetTokenOneshot}.service" ];
        after = [ "${name.parentUnlockOneshot}.service" ];
      }; 
    in {
      ${name.childTokenRenewalSvc} = baseTimerConfig // {
        description = "Emerald City Turnkey Token: Renew Minder for ${tokenName}";
        timerConfig.OnCalendar = "*:0/1"; # renew every minute
        timerConfig.RandomizedDelaySec = "10s";
      };

    };
  };
} { inherit config lib pkgs; }