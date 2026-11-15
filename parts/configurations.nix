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

  # Transpeed 8K618-T (box H618) : même socle, board fournie par nixbian
  # (`local_boards`) faute d'entrée Armbian. Référence pour le bring-up SD.
  flake.nixosConfigurations.transpeed-8k618-t = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.transpeed-8k618-t
      self.nixosModules.sd-image
      self.nixosModules.wifi-client
      ../examples/transpeed-base.nix
    ];
  };

  flake.packages.aarch64-linux.orangepizero3-sd-image =
    self.nixosConfigurations.orangepizero3.config.system.build.sdImage;

  flake.packages.aarch64-linux.transpeed-8k618-t-sd-image =
    self.nixosConfigurations.transpeed-8k618-t.config.system.build.sdImage;

  # H96 Max H618 (box eMMC-only). Même socle, board nixbian locale ; le DTS
  # vient du patch nixbian `kernel/sunxi-7.0-h96-max` (aucun DTS amont).
  flake.nixosConfigurations.h96-max-h618 = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.h96-max-h618
      self.nixosModules.sd-image
      ../examples/h96-max-base.nix
    ];
  };

  flake.packages.aarch64-linux.h96-max-h618-sd-image =
    self.nixosConfigurations.h96-max-h618.config.system.build.sdImage;

  # Variantes eMMC : machine installée sur sa eMMC, pas une image SD.
  #
  # Sans `sd-image`, deux choses changent et c'est le but : `fileSystems."/"`
  # est déclaré par `emmc-root` sur une étiquette propre à la machine, et le
  # label système devient la date+rev au lieu de `sd-card-…` — il ne ment plus
  # sur ce qui tourne. Le DTB, lui, reste fourni par `hardware.deviceTree`
  # (nixbian), donc `FDT` apparaît toujours dans l'extlinux généré.
  flake.nixosConfigurations.transpeed-8k618-t-emmc = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.transpeed-8k618-t
      self.nixosModules.wifi-client
      self.nixosModules.emmc-root
      self.nixosModules.mac-from-sid
      ../examples/transpeed-base.nix
      {
        nixelec.emmc.rootLabel = "nixelec-8k618";
        nixelec.macFromSid.enable = true;
      }
    ];
  };

  flake.nixosConfigurations.h96-max-h618-emmc = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.h96-max-h618
      self.nixosModules.emmc-root
      self.nixosModules.mac-from-sid
      # Afficheur facade : opt-in explicite ici, le module reste desactive par
      # defaut. La H96 est la carte ou le cablage PI/PH a ete mesure et ou
      # l'affichage a ete relu a l'ecran (docs/affichage-facade.md).
      self.nixosModules.front-panel
      ../examples/h96-max-base.nix
      {
        nixelec.emmc.rootLabel = "nixelec-h96";
        nixelec.macFromSid.enable = true;
        nixelec.frontPanel.enable = true;
        nixelec.frontPanel.text = "H96";
      }
    ];
  };


  # Pilote Ethernet vendor de la Transpeed, hors arbre. Construit contre le
  # noyau de la carte (qui porte les patches 0001-0004), donc hors du système :
  # le CI doit le construire et le pousser explicitement pour le cache.
  flake.packages.aarch64-linux.sunxi-gmac =
    inputs.nixpkgs.legacyPackages.aarch64-linux.callPackage ../packages/sunxi-gmac
      {
        kernel = self.nixosConfigurations.transpeed-8k618-t.config.boot.kernelPackages.kernel;
      };

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
