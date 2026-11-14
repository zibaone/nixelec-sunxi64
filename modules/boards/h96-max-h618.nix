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
  # fourni par le patch nixbian `kernel/sunxi-7.0-h96-max` — la carte n'a
  # aucun DTS amont.
  #
  # Mesuré sur la carte (boot0 UART, FDT vendor, boot NixOS depuis la eMMC) :
  # PMIC AXP1530 (= AXP313a), DDR3-1333 @648 MHz, 2 Gio, eMMC 15 028 Mo sur
  # mmc2 (8 bits, HS-SDR52 50 MHz, **pas de HS200**), pas de slot SD (mmc0
  # désactivé dans le DTS), WiFi AIC8800 sur SDIO1 (`wlan_regon` = PG18),
  # Ethernet EMAC1 + PHY AC300 co-packagé sur MDIO **0x10**, RMII,
  # 24 MHz du PHY fabriqués par le canal 5 du PWM.
  hardware.nixbian.board = lib.mkDefault "h96-max-h618";
  hardware.nixbian.kernelVendor = lib.mkDefault "edge";

  # Ethernet : même chaîne que la Transpeed — le pilote retenu est celui du
  # vendor, hors arbre (`packages/sunxi-gmac`). La variante mainline
  # `dwmac-sun8i` reçoit bien les trames sur la Transpeed mais reste inerte
  # ici : le nœud `emac1` de notre DTS porte
  # `compatible = "allwinner,sunxi-gmac"`. Elle reste en module parce que la
  # couche nixbian la liste et que l'élagage échoue sur un module absent.
  #
  # `CONFIG_AC300_PHY=y` : le driver PHY doit être enregistré avant le probe
  # du MAC, sinon `genphy` s'attache au PHY et n'en décroche plus.
  # `CONFIG_MODULE_ALLOW_BTF_MISMATCH=y` : les modules hors arbre sont
  # compilés par un outillage dont le BTF diffère du noyau ; sans lui le
  # noyau refuse de les charger (`failed to validate module BTF: -22`).
  # `CONFIG_PWM_SUNXI_ENHANCE=m` : le PWM mainline ne gère pas le H616 et
  # c'est le driver vendor qui fabrique le 24 MHz du PHY via `pwm-clock`.
  #
  # Patches 0001 et 0003 seulement : 0002 et 0004 ne touchent que le DTS de la
  # Transpeed, que notre DTS remplace.
  # 0004 : backport du driver xpowers AC200/AC300 fusionne en 7.4 (acx00.c,
  # ac300.c, ac200.c + binding package). Deux ecarts d'API mesures contre
  # 7.0.14 (devm_kzalloc_obj, phy_driver.disable_autonomous_eee). Il coexiste
  # avec le driver vendorise 0001 : c'est le DT qui choisit lequel se lie.
  hardware.nixbian.extraPatches = [
    ../../patches/kernel/0001-net-phy-add-ac300-ephy.patch
    ../../patches/kernel/0003-net-stmmac-sun8i-h616-emac1.patch
    ../../patches/kernel/0004-net-phy-xpowers-acx00-backport.patch
  ];
  hardware.nixbian.extraConfig = lib.mkAfter ''
    CONFIG_AC300_PHY=y
    CONFIG_XPOWERS_ACX00_PHY=m
    CONFIG_AW_GMAC=m
    CONFIG_AW_GMAC_MDIO=m
    CONFIG_AW_EPHY=m
    CONFIG_DWMAC_SUN8I=m
    CONFIG_MODULE_ALLOW_BTF_MISMATCH=y
    CONFIG_PWM_SUNXI_ENHANCE=m
  '';

  # Ordre mesuré sur la Transpeed : le PWM fabrique l'horloge du PHY, puis le
  # bus MDIO, puis le MAC. Dans le désordre le PHY tombe sur `genphy`.
  boot.extraModulePackages = [
    (pkgs.callPackage ../../packages/sunxi-gmac {
      kernel = config.boot.kernelPackages.kernel;
    })
  ];
  # Charge dans l'initrd : le driver PHY doit etre enregistre avant que le MAC
  # ne sonde son mdio, sinon la PHY du noeud package reste sans driver et le
  # netdev n'est jamais cree. Sans noeud package, il ne se lie a rien.
  boot.initrd.kernelModules = [ "xpowers-acx00" ];
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

  # WiFi AIC8800 : le pilote est compilé en module par la série Armbian
  # (`CONFIG_AIC8800_WLAN_SUPPORT=m`), mais son firmware n'est pas encore
  # packagé dans cette couche. Rien ne le charge tant que ce n'est pas fait :
  # `nixelec.wifiHardware` reste à `none` (défaut), le service UWE5622 reste
  # inerte. À traiter dans un second temps — l'Ethernet est le chemin utile.
}
