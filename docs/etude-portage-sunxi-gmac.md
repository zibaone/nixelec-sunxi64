# Étude de portage : driver Ethernet vendor `sunxi-gmac` (Allwinner BSP)

État au 2026-11-06. Objet : évaluer le portage du driver Ethernet du BSP Allwinner
sur Linux 7.0.14 pour débloquer le **RX de l'Ethernet intégré** de la Transpeed
8K618-T (H618 + PHY AC300 co-packagé), que le driver mainline `dwmac-sun8i` ne
parvient pas à faire fonctionner en réception.

## 1. Pourquoi cette piste

Mesures sur banc (voir `docs/verified.md` et la skill `sunxi-h618-board-bringup`) :

- MAC, DMA, driver et ring RX mainline **prouvés sains** : en loopback interne du
  MAC (`EMAC_BASIC_CTL0` bit 1), `rx_packets` passe de 0 à 6.
- Lien établi à 10 Mbps full, TX fonctionnel (les trames de la box sont vues côté PC).
- **RX = 0 paquet, 0 CRC, 0 erreur** : le PHY ne pousse rien sur le bus RMII.
- Toutes les séquences d'init connues du vendor ont été rejouées via MDIO (pages
  1/2/6/8, `reg 0x13`, BGS, DLDOEN, pulse shutdown) : aucune n'a ranimé le RX.
- Le bit « SIP mode » que `sunxi-gmac` pose (`sysconf + 0x150` = `0x3000180` bit 0)
  est **en lecture seule** sur cette carte, depuis Linux **comme depuis U-Boot**.

Il ne reste donc que le code vendor lui-même, ou le matériel.

## 2. Inventaire des sources (mesuré)

BSP `radxa/allwinner-bsp`, branche `cubie-aiot-v1.4.6`, `drivers/gmac/` :

| Fichier | Lignes | Rôle |
|---|---|---|
| `sunxi-gmac.c` | 3 965 | MAC : descripteurs DMA maison, NAPI TX/RX, phylib, ethtool, DT |
| `sunxi-mdio.c` | 452 | driver de bus MDIO dédié (`AW_GMAC_MDIO`) |
| `sunxi-ephy.c` | 342 | PHY AC300/AC200 : init pages, calibration efuse, clock |
| `sunxi-gmac-trace.h` | 97 | tracepoints |
| `Kconfig` / `Makefile` | — | `AW_GMAC`, `AW_GMAC_MDIO`, `AW_EPHY`, tous sous `depends on AW_BSP` |
| **Total** | **4 856** | |

Dépendances hors arbre : `sunxi-log.h`, `sunxi-sid.h` (API `sunxi_efuse_readn`).

Compatibles DT exposés : `allwinner,sunxi-gmac`, `allwinner,sunxi-gmac-ephy-v1`,
`allwinner,sunxi-gmac-ephy-v2`.

## 3. Ce que le vendor fait et que mainline ne fait pas

1. **`clk_set_rate(phy25m, 24 MHz)` avant activation** (`sunxi-gmac.c:3144-3163`).
   Notre driver AC300 se contente d'activer les deux horloges du nœud PHY. Or
   `CLK_EMAC_25M` est à 25 MHz et nous annonçons **24M** au PHY (`reg 0x00`,
   bits 7:6 = 2). Un écart de 4 % sur la référence fausserait le REF_CLK RMII :
   TX tolère, RX échantillonne mal. **C'est la piste la moins chère et la plus
   crédible.**
2. Mode **SIP EPHY** (`sysconf + 0x150` bit 0) : mesuré **non inscriptible** ici.
3. Son propre driver MDIO (`sunxi-mdio.c`) au lieu du MDIO du MAC.
4. Init EPHY + calibration lue dans l'efuse **nommé** (`sunxi_efuse_readn`).
5. Application du `pinctrl` depuis le DT (`devm_pinctrl_get` + `pinctrl_select_state`,
   `sunxi-gmac.c:1923-1935`).

## 4. Delta d'API réel : 6.1 → 7.0.14 (vérifié dans l'arbre cible)

Le driver porte déjà **18 gardes `LINUX_VERSION_CODE`**, dont plusieurs pour 6.1
(`dev_addr_mod`, `netif_napi_add_weight`, `mac_managed_pm`). L'écart à couvrir est
donc 6.1 → 7.0.14, pas 5.15 → 7.0.

| API | État dans 7.0.14 | Action |
|---|---|---|
| `platform_driver.remove` | `void (*)(struct platform_device *)` | passer `sunxi_gmac_remove` en `void` |
| `pwm_request()` / `pwm_free()` | **supprimés** | supprimer le chemin de repli, garder `devm_pwm_get()` |
| `pwm_config()` / `pwm_enable()` / `pwm_disable()` | présents (wrappers inline) | aucun |
| `netif_napi_add_weight()` | présent | aucun |
| `.ndo_do_ioctl` | présent | aucun |
| `.get_drvinfo` | présent | aucun |
| `dev_addr_mod()` | présent | aucun |
| `sunxi-log.h`, `sunxi-sid.h` | absents | shims (cf. skill `vendor-kernel-driver-port`) |
| `AW_BSP` (Kconfig) | absent | neutraliser la dépendance |
| tracepoints | à enregistrer ou retirer | retirer d'abord |

**Estimation : 40 à 80 lignes modifiées + 2 en-têtes de compat.** Le port est
mécanique, pas architectural.

## 5. Contrat DT à fournir

D'après le probe (`sunxi-gmac.c:3300-3530`) :

```dts
ethernet@5020000 {
        compatible = "allwinner,sunxi-gmac-ephy-v2";
        reg = <0x05020000 0x10000>, <0x03000030 0x4>;   /* MAC + syscfg */
        interrupts = <GIC_SPI 14 IRQ_TYPE_LEVEL_HIGH>;
        interrupt-names = "gmacirq";
        clocks = <&ccu CLK_EMAC0>, <&ccu CLK_BUS_EMAC0>, ...;
        clock-names = "gmac", "hbus", "mbus", "phy25m";
        phy-mode = "rmii";
        phy-handle = <&ac300_ephy>;
        pinctrl-names = "default";
        pinctrl-0 = <&rmii_pins>;
        status = "okay";
};
```

## 6. Risques structurels

1. **Contrôleur** : le vendor pilote `gmac0` (**0x5020000**, EMAC0). Or sur cette
   carte les pads PA0-PA9 — **MDC/MDIO compris** — ne sont exposés qu'en fonction
   `emac1` par le pinctrl mainline ; on a mesuré qu'EMAC0 ne peut alors pas joindre
   le PHY (`MDIO device at address 0 is missing`). Le port devra soit réutiliser le
   mux réellement posé par U-Boot (absente : notre U-Boot n'a pas d'Ethernet), soit
   écrire le mux vendor à la main.
2. **SIP mode** : si le driver en dépend réellement, le port ne changera rien
   puisque le bit est en lecture seule. Contre-argument : l'Ethernet vendor
   fonctionne sous Android sans que ce bit soit posable depuis le CPU.
3. **Coexistence MDIO** : deux drivers MDIO sur les mêmes adresses (vendor +
   `dwmac-sun8i`) → un seul nœud Ethernet actif à la fois.
4. **Désassemblage** : cf. skill, `rmmod` d'un driver vendor peut figer la carte ;
   chaque essai raté coûte une coupure d'alimentation.

## 7. Stratégie recommandée en trois paliers

**P0 — test d'horloge (1 h, aucun code kernel).** ❌ **Mesuré négatif le 2026-11-06.**
Sur le driver actuel, sélection 25M / 27M / 24M du CLKIN du PHY (`reg 0x00` bits 7:6
→ `0x1f37` / `0x1f77` / `0x1fb7`) : le lien reste debout dans les trois cas
(`carrier=1`) mais `rx_packets` reste à **0**. Le sélecteur d'horloge n'est donc pas
la porte du RX ; cette piste est close.

**P1 — module out-of-tree (0,5 à 1 j).**
Les 4 fichiers vendor + shims, compilés en module externe contre l'arbre du noyau
cible (`…-linux-7.0.14-dev/lib/modules/7.0.14/build`) selon la méthode de la skill
`vendor-kernel-driver-port` (itération en secondes, pas de build noyau complet).
Chargement au banc par UART + clé USB. Critère de succès : `ping` qui répond.

**P2 — intégration (0,5 j)** si P1 réussit : paquet module dans nixbian, nœud DT
dans la carte, `extraConfig` (`CONFIG_AW_GMAC=m`), CI, commits séparés.

## 8. Critères d'arrêt

- P0 positif → arrêt du portage, un correctif d'horloge suffit.
- P1 : module qui charge mais RX toujours nul → le blocage est matériel/strapping ;
  le portage n'apportera rien, revenir à un adaptateur USB ou à un autre modèle de box.

## 9. Sources

- BSP : `radxa/allwinner-bsp@cubie-aiot-v1.4.6`, `drivers/gmac/*`.
- Analyse détaillée : `~/.hermes/profiles/havenos/cache/scratch/ephy/AC300-RX-ANALYSE.md`.
- Mesures carte : skill `sunxi-h618-board-bringup`, section Ethernet.
- Méthode de portage : skill `vendor-kernel-driver-port`.
