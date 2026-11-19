{
  config,
  pkgs,
  lib,
  ...
}:

{
  # H96 Max H618 — box Allwinner H618, **eMMC uniquement** (pas de slot SD).
  #
  # Entrée nixbian locale :
  # `src/armbian_extractor/local_boards/h96-max-h618.csc`. Aucun defconfig
  # U-Boot amont pour cette carte : le build utilise
  # `transpeed-8k618-t_defconfig` (même SoC, même AXP1530, même DDR3-648), qui
  # a amorcé cette carte en RAM depuis le FEL puis depuis la eMMC. Le DTS est
  # fourni par le patch de la couche famille
  # `patches/kernel/sunxi-7.0-h96-max` — la carte n'a aucun DTS amont.
  #
  # Mesuré sur la carte (boot0 UART, FDT vendor, boot NixOS depuis la eMMC) :
  # PMIC AXP1530 (= AXP313a), DDR3-1333 @648 MHz, 2 Gio, eMMC 15 028 Mo sur
  # mmc2 (8 bits, HS-SDR52 50 MHz, **pas de HS200**), pas de slot SD (mmc0
  # désactivé dans le DTS), WiFi AIC8800 sur SDIO1 (`wlan_regon` = PG18),
  # Ethernet EMAC1 + PHY AC300 co-packagé sur MDIO **0x10**, RMII,
  # 24 MHz du PHY fabriqués par le canal 5 du PWM.
  hardware.nixbian.board = lib.mkDefault "h96-max-h618";
  hardware.nixbian.kernelVendor = lib.mkDefault "edge";

  # Ethernet : le noyau de famille (parts/modules.nix) porte déjà les patches
  # AC300/EMAC1 et les CONFIG_AC300_PHY/AW_GMAC/PWM_SUNXI_ENHANCE. La carte ne
  # garde ici que les modules hors arbre et leur ordre de chargement : le PWM
  # fabrique l'horloge du PHY, puis le bus MDIO, puis le MAC.
  # Ordre mesuré sur la Transpeed : le PWM fabrique l'horloge du PHY, puis le
  # bus MDIO, puis le MAC. Dans le désordre le PHY tombe sur `genphy`.
  boot.extraModulePackages = [
    (pkgs.callPackage ../../packages/sunxi-gmac {
      kernel = config.boot.kernelPackages.kernel;
    })
  ];
  # Present dans l'image mais jamais charge automatiquement : le driver
  # xpowers revendique la meme PHY que le vendor (meme ID 0x00441400) et le
  # probe du MAC vendor dereference NULL quand les deux se disputent l'appareil
  # (mesure : Internal error: Oops [#1], pc sunxi_gmac_probe+0x1c4, eth0 absent).
  # On le charge a la main, uniquement avec un DT en forme de package, ou le
  # driver vendor ne matche pas.
  boot.blacklistedKernelModules = [ "xpowers-acx00" ];
  boot.kernelModules = [
    "xpowers-acx00"
    "pwm-sunxi-enhance"
    "clk-pwm"
    "sunxi-mdio"
    "sunxi-gmac"
  ];

  # Le VE et l'affichage n'ont pas d'IOMMU : tout passe par CMA. Valeur de la
  # Zero 3 / Transpeed ; la box a 2 Gio, il n'y a pas à la réduire.
  boot.kernelParams = [ "cma=256M" ];

  # WiFi AIC8800D80 sur SDIO1. Mesuré sur la carte le 15/11 : la carte SDIO
  # s'énumère déjà sans pilote (`mmc0:390b`, `0xc8a1:0x0082` + func2 `0x0182`),
  # ce qui identifie un D80 — ni DC (`0xc08d`), ni D80x2 (`0x2082`).
  #
  # Le SDK lit ses blobs par `filp_open` (`CONFIG_USE_FW_REQUEST = n` dans
  # `aic8800_bsp/Makefile`), pas par `request_firmware` : sous NixOS il n'y a
  # pas de `/lib/firmware`, les firmwares vivent dans
  # `/run/current-system/firmware` (via `hardware.firmware`) et c'est donc
  # `aic_fw_path` du module bsp qui est pointé dessus. Corollaire : les blobs ne
  # doivent pas être compressés — `hardware.firmwareCompression = "none"` est
  # déjà posé par la famille sunxi64.
  #
  # `aic8800_btlpm` reste non chargé : la box n'a pas de Bluetooth et le pilote
  # réclame les propriétés DT `bt_hostwake`/`bt_wake`, absentes ici.
  nixelec.wifiHardware = lib.mkDefault "aic8800";
  hardware.firmware = [ (pkgs.callPackage ../../packages/aic8800-firmware { }) ];
  boot.extraModprobeConfig = ''
    options aic8800_bsp aic_fw_path=/run/current-system/firmware/aic8800_sdio
    options aic8800_fdrv aicwf_dbg_level=0
  '';
}
