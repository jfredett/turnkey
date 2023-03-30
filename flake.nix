{
  description = "Turnkey Secret Management System";
  
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }: let
    linux = "x86_64-linux";
    pkgs = import nixpkgs {
      system = "${linux}";
      config.allowUnfree = true;
    };
  in {
    nixosModules.turnkey = import ./turnkey.nix;
    nixosModules.default = self.nixosModules.turnkey;

    devShells.${linux}.default = pkgs.mkShell {
      packages = with pkgs; [ 
        vault-bin
        jq
      ];
    };
  };
}
