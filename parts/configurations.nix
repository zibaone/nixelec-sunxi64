{ inputs, self, ... }:

{
  # Default configuration: nixbian family kernel (CONFIG_..._PPU=m) and module
  # loading from the initrd. This is the reference cache path.
  flake.nixosConfigurations.orangepizero3-kodi = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.orangepizero3
      self.nixosModules.kodi-gbm
      self.nixosModules.sd-image
      ../examples/zero3-kodi.nix
    ];
  };

  # Add-ons example: public Kodi add-ons, installed and enabled at boot.
  flake.nixosConfigurations.orangepizero3-kodi-addons = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.orangepizero3
      self.nixosModules.kodi-gbm
      self.nixosModules.sd-image
      ../examples/zero3-kodi-addons.nix
    ];
  };

  # Cache configuration: same system with the UWE5622 driver and firmware, so
  # the CI can build and push the driver closure. No SSID/PSK, so
  # wpa_supplicant is not started.
  flake.nixosConfigurations.orangepizero3-kodi-cache = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.orangepizero3
      self.nixosModules.kodi-gbm
      self.nixosModules.wifi-uwe5622
      self.nixosModules.sd-image
      ../examples/zero3-kodi-cache.nix
    ];
  };

  flake.packages.aarch64-linux.orangepizero3-sd-image =
    self.nixosConfigurations.orangepizero3-kodi.config.system.build.sdImage;

  # SPI fallback bootloader: U-Boot alone, written at SPI offset 0 (not 8 KiB,
  # which is the SD offset). The SPL header is eGON.BT0 and the U-Boot FIT
  # follows at 0xA000. `flash-spi-uboot` on the board backs up the SPI first.
  flake.packages.aarch64-linux.orangepizero3-spi-uboot =
    inputs.nixpkgs.legacyPackages.aarch64-linux.runCommand "orangepizero3-spi-uboot" { }
      ''
        mkdir -p $out
        cp ${self.nixosConfigurations.orangepizero3-kodi.config.hardware.nixbian.uBoot.package}/u-boot-sunxi-with-spl.bin $out/
        echo "Write this file to SPI offset 0 (not 8 KiB); see docs/deployment.md." > $out/README
      '';

  # Driver and kernel headers: kernel.dev is a build input, not part of the
  # system closure, so it must be built and pushed explicitly for the cache.
  flake.packages.aarch64-linux.uwe5622 =
    inputs.nixpkgs.legacyPackages.aarch64-linux.callPackage ../packages/uwe5622
      {
        kernel = self.nixosConfigurations.orangepizero3-kodi-cache.config.boot.kernelPackages.kernel;
      };

  flake.packages.aarch64-linux.kernel-dev =
    self.nixosConfigurations.orangepizero3-kodi-cache.config.boot.kernelPackages.kernel.dev;
}
