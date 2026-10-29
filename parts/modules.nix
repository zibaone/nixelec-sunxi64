{ inputs, ... }:

let
  # Same kernel as the reference deployment selects for its sunxi64 boards:
  # the nixbian family kernel, not the per-board buildKernel of the nixbian
  # module. Without this, store paths diverge and the shared cache no longer
  # serves. A consumer can set `null` to use nixbian's per-board kernel.
  familyKernel =
    { config, pkgs, ... }:
    let
      system = pkgs.stdenv.hostPlatform.system;
      family = "sunxi64";
      key = "sunxi64-${config.hardware.nixbian.kernelVendor}";
      legacy = inputs.nixbian.legacyPackages.${system} or { };
      familyPackages = legacy.${family} or { };
      kernels = familyPackages.kernels or { };
    in
    if builtins.hasAttr key kernels then
      kernels.${key}
    else
      throw ''
        nixelec: nixbian does not expose legacyPackages.${system}.${family}.kernels.${key}.
        Check the nixbian input and hardware.nixbian.kernelVendor.
      '';
in
{
  flake.nixosModules = {
    # Family base: nixbian + sunxi64 quirks (GPU, HDMI audio, console).
    sunxi64 =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        imports = [
          inputs.nixbian.nixosModules.nixbian
          ../modules/family/sunxi64.nix
        ];

        nixelec.kernelPackage = lib.mkDefault (familyKernel {
          inherit config pkgs;
        });
      };

    # Board: Orange Pi Zero 3 (H618).
    orangepizero3 =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        imports = [
          inputs.nixbian.nixosModules.nixbian
          ../modules/family/sunxi64.nix
          ../modules/boards/orangepizero3.nix
        ];

        nixelec.kernelPackage = lib.mkDefault (familyKernel {
          inherit config pkgs;
        });
      };

    # UWE5622 WiFi: driver, firmware, wpa_supplicant. Disabled by default.
    wifi-uwe5622 = ../modules/services/wifi-uwe5622.nix;

    # Allwinner SD image: U-Boot at offset 8 KiB, extlinux, DTB.
    sd-image = ../modules/image/sunxi-sd.nix;
  };
}
