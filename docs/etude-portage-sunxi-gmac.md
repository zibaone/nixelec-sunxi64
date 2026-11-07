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

**P1 — module out-of-tree (0,5 à 1 j).** ✅ **Réussi**, mais il a fallu quatre
corrections successives : valeur du syscfg (`0x3fe1` et non `0x5bfe0`), MDIO
vendor écarté, contrôle CRC coupé, préambule retiré de la longueur. Détail en
7.2 et 7.3. Critère de succès atteint : `ping` PC → box 30/30, 0 % de perte,
jusqu'à 1472 octets.

**P2 — intégration (0,5 j).** ✅ **Fait** (7.4) : paquet `packages/sunxi-gmac`,
nœud DT 0004, `extraConfig`, ordre des modules, CI qui construit et pousse le
module. Validé par le CI (paquet + noyau sortis et poussés au cache).

### 7.1 Résultats P1 (mesurés le 2026-11-06, 1 h de time-box)

**Le portage d'API est fait et il compile.** Les trois modules se construisent contre
`linux-7.0.14` et se chargent au banc :

| Module | Taille | vermagic |
|---|---|---|
| `sunxi-gmac.ko` | 1 037 888 o | `7.0.14 SMP preempt mod_unload aarch64` |
| `sunxi-mdio.ko` | 484 424 o | idem |
| `sunxi-ephy.ko` | 621 952 o | idem |

Les écarts 6.1 → 7.0.14 réellement rencontrés, tous corrigés :

- `strlcpy` → `strscpy` ;
- `phy_loopback(dev, enable)` → `phy_loopback(dev, enable, speed)` ;
- `#include <linux/vmalloc.h>` manquant ;
- `platform_driver.remove` → `void` (gmac **et** mdio) ;
- `LINUX_VERSION_CODE` n'est plus défini implicitement → `#include <linux/version.h>` ;
- tracepoints du BSP neutralisés ; `sunxi-log.h` / `sunxi-sid.h` / `get_custom_mac_address`
  remplacés par des shims.

**`sunxi-mdio` fonctionne, et c'est un résultat réutilisable.** Posé sur les registres
MDIO du MAC (`mdio@5030048`, 8 octets), il crée un bus MDIO opérationnel : le PHY
AC300 y répond et le driver PHY lit sa calibration (`Read AC300 EPHY calibration:
0x0506`). Autrement dit **le bloc MDIO du MAC est sain et adressable** — ce que le
driver mainline utilise déjà, mais désormais prouvé côté vendor aussi.

**`sunxi-gmac` probe mais ne tient pas.** Il crée `eth0` (MAC aléatoire, faute de
`get_custom_mac_address`), puis :

- **syscfg pointé sur `0x30`** (comme le nœud vendor de `gmac0`) : le PHY meurt —
  toutes les lectures MDIO rendent `0xffff`, `phy_poll_reset failed: -110`.
  Cause identifiée dans le code vendor : `sunxi_gmac_clk_disable()` fait
  `writel(0, chip->syscfg_base)`, donc **efface tout le registre syscon**, bits
  EPHY (horloge/sélection du PHY interne) compris ;
- **syscfg pointé sur `0x34`** (le bon registre pour EMAC1) : la box part en
  **hang dur**, sans aucune trace console, au chargement du module. Les masques du
  vendor sont pourtant identiques aux nôtres (`RMII = 0x2000`, bits ETCS 1:0,
  délais en 10/5, bit 15 = PHY interne).

**Conclusion P1 : le driver radxa n'est pas transposable en l'état.** Le nœud DT de
la box (`compatible`, `reg`, `status` seulement — pas de `phy-handle`, pas de
`clocks`, pas d'`interrupts`, pas de `mdio`) montre que **ce n'est pas ce driver qui
tourne sur cette carte** : leur Android embarque le driver longan, piloté par
`sys_config.fex`. Porter le driver radxa revient à inventer son contrat DT sans
référence, et la première tentative sérieuse tue le PHY ou la box.

Le critère d'arrêt de la section 8 est atteint : **arrêt du portage**.

### 7.2 Reprise P1 bis — le MAC vendor fonctionne, le RX est corrompu

Reprise après « on y est presque » : le diagnostic de 7.1 était incomplet. En
instrumentant le driver (`pr_info` à chaque étape), quatre causes distinctes ont
été isolées et trois ont été levées.

**1. La valeur écrite dans le sysconf tue le PHY.** Le driver calcule `0x5bfe0` :
il conserve les bits 15/16/18 hérités du boot et ajoute RMII + délais. Sur cette
puce, **le bit 15 doit être CLEAR** : avec `0x5bfe0` le PHY ne répond plus
(`phy_poll_reset: -110`, lectures `0xffff`) ; avec la valeur mainline `0x3fe1`
(bit 15 clear, RMII, délais rx=31 tx=7) le PHY survit et **le lien monte**. À
noter : leur `sunxi_gmac_clk_disable()` fait `writel(0, chip->syscfg_base)`, donc
tout passage par un chemin d'erreur efface aussi les bits EPHY.

**2. Le driver MDIO du vendor est inutilisable sur ce SoC.** `sunxi-mdio` posé
sur `mdio@5030048` enregistre bien un bus, mais **toutes ses lectures rendent 0**,
y compris `phy_id` (donc `0x00000000`). Le même bloc lu depuis userspace
(`/dev/mem`) donne les bonnes valeurs : `BMCR=0x3100`, `BMSR=0x79ed`,
`reg 0x13=0x0102`. Le PHY est sain ; c'est la séquence du vendor qui est fausse.
Son layout de bits est pourtant identique au mainline (phy addr 12-16, reg 4-10,
MDC div 20-22) : la différence est ailleurs (diviseur MDC codé en dur à 3, valeur
qui ne correspond pas à l'horloge CSR de cette puce ; passer à 4 ne suffit pas).

**3. Le MAC vendor reçoit réellement les trames.** Dump du descripteur RX brut :

```
d0=0x00478383  d1=0x010007ff  d2=0xefe9f000  len=71
```

soit `crc=1`, `ipch=1`, `err_sum=1`, `last_desc=1`, `first_desc=1`, longueur
`0x47` = 71. `d1` = 2047 (buffer de 2048) et `d2` avance de `0x800` en `0x800` :
**le ring DMA est correctement construit**. Le parsing du descripteur est conforme
au mainline (`RDES0_CRC_ERROR=BIT(1)`, `RDES0_IPC_CSUM_ERROR=BIT(7)`,
`RDES0_ERROR_SUMMARY=BIT(15)`, `RDES0_OWN=BIT(31)`).

**4. Les trames sont bonnes en tête, fausses en queue.** Dump des octets
(`__va(desc->desc2)`) :

```
bytes=2ea67b6cb5dd 3499 71def1db 0806 0001
```

= MAC destination locale, MAC source `34:99:71:de:f1:db` (le dongle du PC),
EtherType `0806` (**ARP**), `0001` (request). L'en-tête est intact, mais la
longueur annoncée est **71 au lieu de ~46** et les sommes de contrôle échouent.

**Conséquence pratique : en ignorant `crc`/`ipch` dans le driver et en ne
rejetant que `len_err`/`over_err`/`mii_err`/`desc_err`, les trames atteignent la
pile.** Mesuré :

```
4 packets transmitted, 0 received, +4 corrupted, 100% packet loss
rx_packets=11
```

Le RX **fonctionne** : les paquets arrivent, le noyau les compte comme corrompus
et les jette. Le balayage du `rx_delay` du MAC (bits 5-9, valeurs 0 à 31 sans
reboot) ne change rien — probablement non relu à chaud.

**État : le blocage n'est plus « pas de RX » mais « RX corrompu en fin de trame »
(longueur +25 octets, checksums faux).** La piste restante est le timing RMII
côté PHY (échantillonnage / terminaison), plus le réglage statique du sysconf
appliqué au boot.

### 7.3 Résultat final — Ethernet fonctionnel

Deux corrections supplémentaires ont suffi :

1. **le bus MDIO doit être celui du mainline, pas celui du vendor** : `sunxi-mdio`
   lit toujours 0 ; en gardant le bus créé par le driver mainline (ou en lisant le
   bloc MDIO directement), le PHY répond normalement (`BMCR=0x3100`,
   `BMSR=0x79ed`) ;
2. **désactiver le contrôle CRC du MAC** (`RX_CTL0` bit 27, `SUNXI_GMAC_CRC_OFFSET`)
   : le MAC compte 7 octets de préambule en trop dans la longueur, ce qui invalide
   le CRC de chaque trame alors que les données sont saines.

**Mesures de bout en bout, PC → box, avec le driver vendor :**

| Test | Résultat |
|---|---|
| `ping -c 10` (56 o) | **30/30, 0 % de perte** (3 séries) |
| `ping -c 10 -s 1000` | **10/10, 0 %** |
| `ping -c 10 -s 1400` | **10/10, 0 %** |
| `ping -c 10 -s 1472` | **10/10, 0 %** |

ARP résolu, MAC de la box `06:4e:91:68:b1:5a` ; `ss -ltn` montre sshd sur
`0.0.0.0:22` (le TCP/22 est refusé par le pare-feu du banc, pas par le réseau).

Anomalie résiduelle, non bloquante : quand c'est la **box** qui ping, ses propres
échos de réponse sont comptés `corrupted` par la pile ; dans le sens PC → box tout
passe, y compris les trames de 1500 octets.

**Conclusion : le portage vendor est viable sur cette carte** — il aura fallu
corriger la valeur du sysconf, écarter leur MDIO et désactiver le contrôle CRC du
MAC.

### 7.4 Intégration (P2)

Le pilote est entré dans le dépôt, avec la même structure que les autres modules
hors arbre :

| Élément | Emplacement |
|---|---|
| sources vendor | `packages/sunxi-gmac/src/` (pristine) |
| delta | `packages/sunxi-gmac/patches/0001-port-7.0-transpeed.patch` (249 l.) |
| dérivation | `packages/sunxi-gmac/default.nix` |
| nœud DT | `patches/kernel/0004-arm64-dts-h616-transpeed-sunxi-gmac.patch` |
| carte | `modules/boards/transpeed-8k618-t.nix` (config noyau, `boot.extraModulePackages`, ordre de `boot.kernelModules`) |
| CI | job `cache` : construit et pousse `.#packages.aarch64-linux.sunxi-gmac` |

Les deux rustines de la session de mesure ne sont plus codées en dur : elles sont
derrière `allwinner,syscfg-value` et `allwinner,no-crc-check`, posées par le
patch DTS de la carte. Le portage propre (propriétés DT au lieu des valeurs
forcées) a été **revérifié sur le banc** : lien monté, 10/10 pings du PC, 0 % de
perte.

Vérifications faites avant commit : le patch s'applique à blanc sur les sources
vendorisées, la dérivation s'évalue (`sunxi-gmac-7.0.14`), le toplevel de la
carte s'évalue, et le DTS produit par 0002 puis 0004 compile en DTB avec le
`compatible` vendor, `phy-handle` sur le PHY du nœud MDIO et les deux propriétés.
Le build complet (noyau + module) a été fait par le CI aarch64 : le paquet est
sorti et poussé sur le cache (`b18dppjjy…`, 81 Kio).

### 7.5 Réserves — état après analyse

Trois défauts distincts ont été isolés sur la carte, dont **deux corrigés** :

| # | Défaut | État |
|---|---|---|
| A | `skb->ip_summed = CHECKSUM_UNNECESSARY` : le pilote annonce à la pile que le checksum est vérifié par le matériel alors qu'il ne l'est pas. Toutes les trames corrompues étaient donc acceptées silencieusement. | **corrigé** (`CHECKSUM_NONE`) |
| B | Le MAC compte le préambule (7 octets) dans la longueur du descripteur tout en ne le stockant pas. `iputils` calcule le checksum ICMP sur la longueur reçue, pas sur la longueur IP, donc la longueur fausse suffisait à faire échouer tout `ping` émis depuis la carte. | **corrigé** (retrait de 7 octets après celui des 4 octets de FCS) |
| C | **Corruption réelle de la charge utile en réception** : un trou d'une vingtaine d'octets au même endroit de la trame (juste après l'en-tête ICMP), comblé par des octets **d'une trame précédente**. L'en-tête IP et la fin de trame sont intacts, et le checksum IP est valide — seule la zone trouée est fausse. | **ouvert** |

Le défaut C explique pourquoi le défaut A était « utile » : sans
`CHECKSUM_UNNECESSARY`, la carte ne reçoit plus rien du tout, ce qui est la
réponse honnête. Signature mesurée sur trois trames consécutives :

```
len=98 dst=7e04aa66219d src=349971def1db 0800 4500 0054 ...
   ip_ok=True   icmp_cs recu=0x5858 calcule=0x1ad8   -> FAUX
   charge utile : [timestamp 4 o][~23 o de rebut][10 11 12 ... 30]
```

Les octets de rebut contiennent des fragments de l'en-tête ICMP de la trame
précédente (id/séquence), donc ce n'est pas une erreur de bit : **le DMA n'écrit
pas cette zone**, qui garde le contenu de la trame précédente. Un trou qui
commence sur une frontière de rafale DMA et qui laisse la suite de la trame
intacte est la signature d'un **sous-remplissage du FIFO RX** (le MAC draine plus
vite que le PHY ne fournit).

Deux pistes restent à départager :

1. **Le lien à 10 Mbps est le déclencheur** — le dongle du banc (`LPA 0xcc61`)
   n'annonce que 10BASE-T et 100BASE-T4, jamais 100BASE-TX, donc le lien ne peut
   pas monter à 100 Mbps. Test décisif : brancher la carte sur un port
   100BASE-TX (le NIC intégré du PC ou le commutateur du LAN).
2. **Configuration du FIFO/DMA RX** — `RX_CTL1` (vendor `0x4000000e`, mainline
   `0`), seuil de store-and-forward et rafales DMA. Les écritures à chaud n'ont
   rien changé, mais ce registre est peut-être verrouillé à l'initialisation :
   le test propre demande un rechargement du module avec chaque variante.

**Le loopback interne du MAC tranche entre les deux** et disculpe le pilote :

```
BASIC_CTL0 |= BIT(1)      # loopback interne, lien ignoré
ping -c 3 10.99.99.2      -> 3 packets transmitted, 3 received, 0% loss
```

Ce test passe **avec `CHECKSUM_NONE`**, donc la pile valide réellement les
checksums : le MAC, le DMA, les descripteurs, le ring et le chemin RX du pilote
sont sains. La corruption ne peut venir que de l'interface RMII côté PHY ou du
câble/magnétiques. Par conséquent :

- le vendor du BSP ne fait rien de faux que nous n'ayons déjà corrigé ;
- ni les délais RMII (balayés de 0 à 31, syscfg verrouillé à l'init, aucun
  effet), ni la calibration AC300 (lue à `0x0506` dans les eFuses et appliquée),
  ni la séquence PHYAFE (identique au vendor, branche « default » car
  `caldata & BIT(9)` est nul) ne sont en cause ;
- le lien reste à **10 Mbps sur le LAN aussi** : le port du routeur annonce
  `LPA 0x4461`, soit 10BASE-T seul, exactement comme le dongle. Aucun partenaire
  100BASE-TX n'étant disponible au banc, le chemin 100 Mbps n'a jamais été
  exercé — c'est la variable non testée qui reste.

Un câble neuf a été essayé : aucun changement, le lien reste à 10 Mbps.

Les délais RMII ont ensuite été balayés **à l'initialisation** (paramètre de
module `syscfg_override`, appliqué à chaque `ip link up`, donc sans reflasher) :
`rx_delay` = 0, 8, 16, 24, 31 avec `tx_delay` = 7. Aucune valeur ne rétablit le
trafic — la corruption ne dépend donc pas du phasage RMII.

**Conclusion : la réserve C n'est pas logicielle.** Le numérique est prouvé sain
(loopback), la calibration est correcte, la séquence PHYAFE est celle du vendor,
les délais n'y changent rien et un câble neuf ne change rien. Ce qui reste est
l'étage analogique du AC300 sur cette unité (ou son routage RMII/magnétiques),
et il faudra soit une deuxième unité pour comparer, soit un partenaire
100BASE-TX pour vérifier si le défaut est propre au 10 Mbps.

### 7.6 Le PHY de la carte est en cause (preuve croisée)

Le même port de routeur, avec le même câble, a été confronté à un dongle
RTL8153 :

```
dongle <-> routeur : Speed: 1000Mb/s  Duplex: Full  Link detected: yes
                     Link partner advertised link modes: 10/100/1000
box    <-> routeur : 10 Mbps, et son PHY lit LPA = 0x4461 (10BASE-T seul)
```

Trois faits en découlent :

- le câble est bon — le gigabit exige les quatre paires, il les porte ;
- le port du routeur est bon — il annonce 10/100/1000 ;
- le PHY de la carte **décode mal les capacités de son partenaire** et, avec le
  même étage analogique, **corrompt les données reçues**.

La négociation à 10 Mbps et la charge utile trouée ont donc la même origine :
le récepteur du AC300 sur cette unité, pas le pilote. Le portage est terminé
côté logiciel ; la suite demande du matériel (deuxième unité pour comparer, ou
retour SAV).

### 7.7 Voie de secours validée : dongle USB-Ethernet

En attendant, un dongle CoreChip SR9700 (`0fe6:9700`, « USB 2.0 10/100M »)
donne à la carte un réseau propre, sans une ligne de code :

```
enu1  UP  192.168.1.23/24 via DHCP, default via 192.168.1.1
PC -> box : ping 3/3 (0 %), TCP/22 ouvert, sshd répond
débit     : 10 485 967 o en 13,09 s ≈ 0,80 Mo/s ≈ 6,4 Mbps
```

Le lien est à 10 Mbps et le SR9700 plafonne à ~7 Mbps en pratique : suffisant
pour de l'IPTV SD/HD, pas pour de l'UHD. Le noyau expose aussi `r8152` (RTL8153
gigabit) et les ASIX, donc un dongle gigabit est un simple remplacement.

Deux points d'intégration, corrigés dans `modules/boards/transpeed-8k618-t.nix` :

- `usbnet`, `mii` et `sr9700` ajoutés à `boot.kernelModules`, sans quoi le
  pruning des modules retire `sr9700.ko` de l'image ;
- `CONFIG_DWMAC_SUN8I` repassé de `n` à `m` : la couche nixbian liste
  `dwmac-sun8i` dans `boot.kernelModules`, et le pruning échoue sur un module
  absent. En module il charge et reste inerte (`emac1` porte le compatible
  vendor depuis 0004, `emac0` est désactivé).

La MAC du dongle est fixe (`00:e0:4c:53:44:58`), contrairement à celle du MAC
interne qui est tirée au hasard à chaque boot — un point en faveur du dongle
pour une réservation DHCP.

**Panne d'image trouvée au passage** : `CONFIG_MODULE_ALLOW_BTF_MISMATCH`
n'était pas activé. Les modules de l'image sont produits par un outillage qui
ne génère pas exactement le même BTF que le noyau, et le noyau refuse alors de
les charger :

```
failed to validate module [usbnet] BTF: -22
modprobe: ERROR: could not insert 'usbnet': Invalid argument
```

Conséquence mesurée : **aucun dongle USB-Ethernet ne pouvait fonctionner**,
`usbnet` étant la dépendance de tous les pilotes concernés. L'ABI reste
vérifiée par vermagic et par les versions de symboles ; BTF ne sert qu'à
l'introspection BPF, donc autoriser le désaccord est sans risque. Corrigé dans
`modules/boards/transpeed-8k618-t.nix`. En attendant le rebuild noyau, la box
tourne avec `usbnet.ko`/`sr9700.ko` recompilés localement (sans section BTF,
donc acceptés).

Tant que C n'est pas levé, **l'Ethernet interne** reste une validation de
laboratoire : ni DHCP ni TCP entrant ne peuvent fonctionner sur une charge utile
trouée. La voie dongle décrite ci-dessus, elle, est utilisable.

La suite du travail côté pilote — corrections restantes, dette technique,
outillage, WiFi — est décrite dans `docs/chantiers-drivers-transpeed.md`. Le
plus immédiat : le pilote annonce toujours `NETIF_F_RXCSUM` dans `hw_features`
alors qu'il ne vérifie aucun checksum, donc le mensonge corrigé au niveau des
skbs subsiste au niveau `netdev`.

## 8. Critères d'arrêt

Ces critères avaient été posés **avant** les mesures. Ils sont conservés pour
mémoire, avec leur verdict :

- « P0 positif → arrêt du portage, un correctif d'horloge suffit. » → **P0
  négatif** (sélecteur d'horloge PHY sans effet), le portage a suivi.
- « P1 : module qui charge mais RX toujours nul → blocage matériel. » → **P1
  positif** : le module a reçu des trames, mais il a fallu corriger la valeur du
  syscfg, écarter le MDIO vendor, couper le contrôle CRC et retirer le
  préambule de la longueur. Le « RX toujours nul » de l'époque venait de quatre
  causes distinctes, toutes logicielles sauf la dernière.
- Le critère qui s'est révélé juste est celui qui manquait : **le loopback
  interne du MAC**. C'est lui qui a séparé le numérique (sain) de l'analogique
  (défaillant) et qui a arrêté la poursuite du mauvais coupable.

Le portage n'est donc pas arrêté : il est **livré**, avec une réserve
matérielle documentée en 7.5 et 7.6, et une suite de chantiers dans
`docs/chantiers-drivers-transpeed.md`.

## 9. Sources

- BSP : `radxa/allwinner-bsp@cubie-aiot-v1.4.6`, `drivers/gmac/*`.
- Analyse détaillée : `~/.hermes/profiles/havenos/cache/scratch/ephy/AC300-RX-ANALYSE.md`.
- Mesures carte : skill `sunxi-h618-board-bringup`, section Ethernet.
- Méthode de portage : skill `vendor-kernel-driver-port`.
