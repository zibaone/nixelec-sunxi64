{
  lib,
  ...
}:

{
  # Transpeed 8K618-T — TV box Allwinner H618 (DDR3-1333 4 Go, eMMC 64 Go).
  #
  # La carte n'existe pas dans Armbian : son entrée vient de
  # `nixbian/src/armbian_extractor/local_boards/transpeed-8k618-t.csc`
  # (defconfig U-Boot `transpeed-8k618-t_defconfig`, DTB mainline).
  #
  # Mesuré au boot0 UART : PMIC AXP1530 (= AXP313a), DDR3 @648 MHz, eMMC
  # 59 640 Mo sur mmc2 (8 bits), vendor U-Boot 2018.07.
  hardware.nixbian.board = lib.mkDefault "transpeed-8k618-t";
  hardware.nixbian.kernelVendor = lib.mkDefault "edge";

  # Broadcom BCM4334 (SDIO 0x02d0:0x4334, module AP6334). Le pilote est
  # `brcmfmac`, dans le noyau : contrairement à l'UWE5622 il n'y a pas de
  # module hors arbre à construire. Le marqueur évite que `nixelec.wifi`
  # (importé pour toute la couche sunxi64) ne compile et ne charge le pilote
  # UWE5622 sur cette carte.
  nixelec.wifiHardware = lib.mkDefault "brcmfmac";

  # Le VE et l'affichage n'ont pas d'IOMMU : tout passe par CMA. 256M est la
  # valeur mesurée sur la Zero 3 ; la box a 4 Go, il n'y a pas à la réduire.
  boot.kernelParams = [ "cma=256M" ];
}
