{
  description = "nixelec-sunxi64 — reusable NixOS appliance for Allwinner H616/H618 (Orange Pi Zero 3)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    flake-parts.url = "github:hercules-ci/flake-parts";

    nixbian = {
      url = "github:zibaone/nixbian";
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
