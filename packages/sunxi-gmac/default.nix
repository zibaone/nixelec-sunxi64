{
  lib,
  stdenv,
  kernel,
}:

# Pilote Ethernet vendor Allwinner `sunxi-gmac`, hors arbre.
#
# Source : radxa/allwinner-bsp, ref `cubie-aiot-v1.4.6`, `drivers/gmac/`
# (4 856 lignes : sunxi-gmac.c, sunxi-mdio.c, sunxi-ephy.c, tracepoints).
# `src/` porte **l'arbre complet tel qu'il est compilé** : le BSP d'origine,
# porté sur l'API 7.0.14, plus les correctifs mesurés sur la carte (voir
# `docs/etude-portage-sunxi-gmac.md`). Il n'y a plus de patch appliqué par la
# dérivation : une seule source de vérité, éditable directement.
# `src/shim/` remplace les en-têtes du BSP absents de l'arbre principal
# (journalisation, SID, tracepoints).
#
# Pourquoi ce pilote : la variante mainline (`allwinner,sun50i-h616-emac1`,
# patches 0001-0003) ne reçoit **aucune** trame sur cette carte — MAC, DMA et
# ring prouvés sains par loopback, PHY configuré comme le vendor, mais
# `rx_packets` reste à 0. Le pilote vendor, lui, reçoit : mesuré 10/10 pings
# en 56, 1000, 1400 et 1472 octets, 0 % de perte.
#
# Deux propriétés DT sont lues par le patch et doivent être posées par la
# carte (patch DTS 0004) :
#   - `allwinner,syscfg-value` : valeur du sysconf EMAC. La logique du BSP
#     écrit `0x5bfe0` sur cette puce, ce qui coupe l'EPHY (PHY muet,
#     `phy_poll_reset: -110`) ; `0x3fe1` est la valeur mesurée qui tient.
#   - `allwinner,no-crc-check` : le MAC compte 7 octets de préambule dans la
#     longueur de trame (71 au lieu de 64, 109 au lieu de 102), donc le CRC
#     de chaque trame est faux alors que les données sont saines. On coupe le
#     contrôle CRC (`RX_CTL0` bit 27) et on ne rejette que les erreurs
#     structurelles (`len_err`, `over_err`, `mii_err`, `desc_err`).
stdenv.mkDerivation {
  pname = "sunxi-gmac-${kernel.version}";
  version = "unstable-2026-11-06";

  src = ./src;

  buildInputs = [ kernel.dev ];

  dontConfigure = true;
  enableParallelBuilding = true;

  buildPhase = ''
    runHook preBuild
    # Pas de -DCONFIG_AW_EPHY=1 : ce define n'active pas le pilote PHY (il
    # n'apparait que dans sunxi-gmac.c, jamais dans sunxi-ephy.c) mais le bloc
    # d'integration ephy du MAC, qui fait chip->ephy_ops->resource_get() avec
    # ephy_ops = match->data. Or notre DTS utilise le compatible simple
    # "allwinner,sunxi-gmac", dont l'entree de of_match n'a pas de .data :
    # ephy_ops vaut NULL et le probe dererence (Oops sunxi_gmac_probe+0x1c4,
    # eth0 absent). Avec la macro absente, IS_ENABLED() est faux et le chemin
    # n'est pas compile -- c'est l'etat qui fonctionnait avant 7fe4012.
    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build M=$PWD \
      KERNELRELEASE=${kernel.modDirVersion} \
      ARCH=${stdenv.hostPlatform.linuxArch} \
      KCFLAGS="-DCONFIG_AW_GMAC=1 -DCONFIG_AW_GMAC_MDIO=1" \
      modules
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -d $out/lib/modules/${kernel.modDirVersion}/extra
    cp sunxi-gmac.ko sunxi-mdio.ko sunxi-ephy.ko $out/lib/modules/${kernel.modDirVersion}/extra/
    runHook postInstall
  '';

  meta = {
    description = "Allwinner vendor GMAC driver (sunxi-gmac) for ${kernel.version}";
    homepage = "https://github.com/radxa/allwinner-bsp";
    license = lib.licenses.gpl2Only;
    platforms = [ "aarch64-linux" ];
  };
}
