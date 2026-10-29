{
  description = "nixelec-sunxi64 — reusable NixOS appliance for Allwinner H616/H618 (Orange Pi Zero 3)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    flake-parts.url = "github:hercules-ci/flake-parts";

    nixbian = {
      url = "github:zibaone/nixbian";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    v4l2request = {
      url = "github:zibaone/nix-v4l2-request";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Couche kiosque neutre : service Kodi GBM, CEC, watchdog, sans nom de SoC.
    # Ce dépôt ne l'importe que pour réexporter le module sous son ancien nom
    # (`nixosModules.kodi-gbm`) et publier les faits de la carte.
    nixelec-kiosk = {
      url = "github:zibaone/nixelec-kiosk";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [
        ./parts/modules.nix
        ./parts/configurations.nix
        ./parts/packages.nix
        ./parts/checks.nix
      ];
    };
}
