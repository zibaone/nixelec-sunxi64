{ inputs, self, ... }:

{
  # Référence de la carte : noyau nixbian, DTB, U-Boot, image SD. Aucun
  # lecteur — la couche kiosque vit dans `nixelec-kiosk`.
  flake.nixosConfigurations.orangepizero3 = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.orangepizero3
      self.nixosModules.sd-image
      ../examples/zero3-base.nix
    ];
  };

  # Même carte avec le pilote UWE5622 : le CI construit et pousse la closure du
  # pilote et du firmware. Pas de SSID/PSK, donc wpa_supplicant ne démarre pas.
  flake.nixosConfigurations.orangepizero3-cache = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.orangepizero3
      self.nixosModules.wifi-uwe5622
      self.nixosModules.sd-image
      ../examples/zero3-cache.nix
    ];
  };

  flake.packages.aarch64-linux.orangepizero3-sd-image =
    self.nixosConfigurations.orangepizero3.config.system.build.sdImage;

  # SPI fallback bootloader: U-Boot alone, written at SPI offset 0 (not 8 KiB,
  # which is the SD offset). The SPL header is eGON.BT0 and the U-Boot FIT
  # follows at 0xA000. `flash-spi-uboot` on the board backs up the SPI first.
  flake.packages.aarch64-linux.orangepizero3-spi-uboot =
    inputs.nixpkgs.legacyPackages.aarch64-linux.runCommand "orangepizero3-spi-uboot" { }
      ''
        mkdir -p $out
        cp ${self.nixosConfigurations.orangepizero3.config.hardware.nixbian.uBoot.package}/u-boot-sunxi-with-spl.bin $out/
        echo "Write this file to SPI offset 0 (not 8 KiB); see docs/deployment.md." > $out/README
      '';

  # Driver and kernel headers: kernel.dev is a build input, not part of the
  # system closure, so it must be built and pushed explicitly for the cache.
  flake.packages.aarch64-linux.uwe5622 =
    inputs.nixpkgs.legacyPackages.aarch64-linux.callPackage ../packages/uwe5622
      {
        kernel = self.nixosConfigurations.orangepizero3-cache.config.boot.kernelPackages.kernel;
      };

  flake.packages.aarch64-linux.kernel-dev =
    self.nixosConfigurations.orangepizero3-cache.config.boot.kernelPackages.kernel.dev;
}
