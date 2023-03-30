let
  supportedKeys = [ 
    "boot" "containers" "environment" "fonts"
    "networking" "nix" "nixpkgs" "programs"
    "security" "services" "systemd" 
  ];
in {
 mkOneLevelTree = { parentName, parentDescription, parentOptions, mkParent, childrenName, childOptions, mkChild }:
                  { config, lib, pkgs, ... }:
                  with lib;
                  let
                    parentConfig = mkParent config.${parentName};
                    # This lets me reference the parent from a child's definition
                    mkChild' = name: cfg: mkChild name (cfg // { __parent = config.${parentName}; });
                    childrenConfig = joinAttrSets (attrValues (mapAttrs mkChild' config.${parentName}.${childrenName}));
                    joinAttrSets = foldl' (a: v: recursiveUpdate a v) {};
                    configTree = recursiveUpdate parentConfig childrenConfig;
                  in {
                    options.${parentName} = with types; parentOptions // {
                      ${childrenName} = mkOption {
                        type = attrsOf (submodule { options = childOptions; });
                      };        
                    };
                        
                    # TODO: Add some kind of warning if configTree's keys aren't fully contained in supportedKeys
                    # adding support is as easy as copy-pasting the a line below and changing the toplevel key.
                    config.boot = if (hasAttr "boot" configTree) then configTree.boot else {};
                    config.containers = if (hasAttr "containers" configTree) then configTree.containers else {};
                    config.fonts = if (hasAttr "fonts" configTree) then configTree.fonts else {};
                    config.environment = if (hasAttr "environment" configTree) then configTree.environment else {};
                    config.networking = if (hasAttr "networking" configTree) then configTree.networking else {};
                    config.nix = if (hasAttr "nix" configTree) then configTree.nix else {};
                    config.nixpkgs = if (hasAttr "nixpkgs" configTree) then configTree.nixpkgs else {};
                    config.programs = if (hasAttr "programs" configTree) then configTree.programs else {};
                    config.security = if (hasAttr "security" configTree) then configTree.security else {};
                    config.services = if (hasAttr "services" configTree) then configTree.services else {};
                    config.systemd = if (hasAttr "systemd" configTree) then configTree.systemd else {};
                  }; 
}