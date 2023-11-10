{ config, pkgs, lib, ...}: with lib; let
  mkDescription = component: "Emerald City Turnkey Service: ${component}";
  roleIDPath = "/run/keys/role-id";
  secretIDPath = "/run/keys/secret-id";
  rootTokenPath = "/run/keys/root.token";

  tokenPath = tokenName: "/run/keys/${tokenName}.token";

  root = (import ./rootToken.nix)({ inherit pkgs rootTokenPath mkDescription roleIDPath secretIDPath; });

  token = (import ./token.nix)({ inherit pkgs lib rootTokenPath tokenPath; });
  secret = (import ./secret.nix)({ inherit config pkgs lib; });

in {
  options.turnkey = with types; {
    enable = mkEnableOption "Enable Turnkey";

    appRole = mkOption {
      description = "The name of the approle to use, usually the hostname of the machine";
      type = str;
    };

    period = mkOption {
      description = "The renewal period to apply to the root token";
      default = "3m";
      type = str;
    };

    tokens = mkOption {
      type = attrsOf (
        submodule { 
          options = {
            user = mkOption { 
              description = "user who will own the token, defaults to name of token";
              type = nullOr str; 
            };
            group = mkOption { 
              description = "group who will own the token defaults to name of token";
              type = nullOr str; 
            };
            ttl = mkOption { 
              description = "How long before renewing the token"; 
              type = str; 
            };
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
                });
              };
            };
          });
        };
      };


      config = let 
        tokenNames = attrNames config.turnkey.tokens;
        secretNamesFor = token: attrNames config.turnkey.tokens.${token}.secrets;
        dbg = x: trace x x;

        tokenServices = map (token.mkServices config.turnkey.tokens) tokenNames;
        tokenTimers   = map token.mkTimers tokenNames;

        secretServices = map (token: map (secret.mkServices token) (secretNamesFor token)) tokenNames;
        secretTimers   = []; # map (token: map (secret token).mkTimers (secretNamesFor token)) tokenNames;
      in { 
        systemd = {
          targets.turnkey = {
            enable = true;
            description = mkDescription "Post-unlock target";
            requires = [ "multi-user.target" ];
            unitConfig.AllowIsolate = true;
          };

          services = mkMerge (tokenServices ++ (builtins.elemAt secretServices 0)
                          ++ [ root.mkService root.mkUnlockOneshot ]);

          timers =  mkMerge ( tokenTimers ++ secretTimers 
                          ++ [ root.mkTimer ]);
        };
    };

}
