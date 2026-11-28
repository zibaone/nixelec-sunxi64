# Wake-on-LAN sur la H96 Max H618 (sunxi-gmac, s2idle)

État au 2026-11-27. Objet : rendre `ethtool -s eth0 wol g` effectif, puis
réveiller la box d'un `systemctl suspend` (s2idle) avec un magic packet.

Série : `packages/sunxi-gmac/patches/` (2 patchs, cible = le module hors
arbre `packages/sunxi-gmac/src`, **pas** l'arbre noyau).

## 1. Verdict

| Question | Réponse | Pourquoi |
|---|---|---|
| Réveil depuis s2idle sur une trame reçue | **oui**, avec cette série | s2idle ne coupe pas la SoC ; l'IRQ RX reste armable |
| Filtrage matériel du magic packet | **non** | le MAC n'a pas de bloc PMT documenté (§2.2) |
| Réveil depuis `poweroff` | **non** | l'AXP1530 coupe les rails ; plus rien n'écoute |
| Réveil depuis `mem` (suspend-to-RAM) | **non** | non supporté sur cette famille ; `mem_sleep` = `[s2idle]` |

Conséquence à assumer : `ethtool -s eth0 wol g` arme bien le réveil et un
magic packet réveille bien la box, mais **toute trame que le filtre du MAC
accepte la réveille aussi** (ARP, SSDP, ping). Ce n'est pas du WoL filtré,
c'est du « réveil sur réception ». Le comportement produit demandé est
obtenu ; la sélectivité du magic packet, non.

Coût du test : **aucun rebuild de noyau**. Seul `sunxi-gmac.ko` change, donc
un `nixos-rebuild switch` + rechargement du module suffit (voir §4).

## 2. Investigation : ce que le matériel permet réellement

### 2.1 Quel driver pilote eth0

Le dmesg mesuré sur la carte le 2026-11-27 :

```
sunxi-gmac 5030000.ethernet: eth0: Type(7) PHY ID 00000000 at 0 IRQ poll (5030048.mdio-mii:00)
```

Cette ligne vient de `packages/sunxi-gmac/src/sunxi-gmac.c:1867`. Deux détails
trompent :

- `Type(7)` n'est pas un type de PHY : c'est `phydev->interface`, et 7 vaut
  `PHY_INTERFACE_MODE_RMII` dans l'énumération `phy_interface_t` du noyau
  7.0.14 (`include/linux/phy.h`). Le lien est en RMII, comme le DTS le dit.
- `PHY ID 00000000` ne dit pas que le PHY est absent : l'AC300 co-packagé ne
  présente pas d'ID 802.3 standard à l'adresse MDIO 0 (0x00000000 mesuré). Le
  driver `drivers/net/phy/ac300-phy.c` (patch
  `patches/kernel/0001-net-phy-add-ac300-ephy.patch`) s'apparie par compatible
  DT (`allwinner,sun50i-h618-ac300-ephy`), pas par ID. Un ID nul est donc
  cohérent avec ce PHY, pas la signature d'un PHY manquant.

Le driver lié est le **module vendor hors arbre**, pas `dwmac-sun8i` :

- DTS de la carte : `&emac1 { compatible = "allwinner,sunxi-gmac"; ... }`,
  voir `patches/kernel/sunxi-7.0-h96-max/0001-arm64-dts-allwinner-add-sun50i-h618-h96-max.patch` ;
- `modules/boards/h96-max-h618.nix` charge `sunxi-gmac` dans `boot.kernelModules`
  et le construit dans `boot.extraModulePackages` (`packages/sunxi-gmac`) ;
- le noyau 7.0.14 ne contient **aucun** compatible `allwinner,sunxi-gmac`
  (`grep -rn sunxi-gmac drivers/` : vide) : c'est forcément le module ;
- `dwmac-sun8i` n'apparaît dans aucun `dmesg` de la carte. Sa variante
  `allwinner,sun50i-h616-emac1` (patchs `patches/kernel/0002` et `0003`) a été
  mesurée **incapable de recevoir** sur ces boîtiers (MAC/DMA/ring sains en
  loopback, `rx_packets` reste à 0) : voir `docs/etude-portage-sunxi-gmac.md`
  §1 et §3.

Corollaire : un patch de `drivers/net/ethernet/stmicro/stmmac/dwmac-sun8i.c`
serait inerte sur cette carte. La série WoL cible donc le module vendor. C'est
la seule cible qui puisse faire fonctionner `ethtool -s eth0 wol g` sur la H96.

### 2.2 Ce que le MAC sait faire (et ne sait pas faire)

La carte des registres du vendor (`sunxi-gmac.c:99-123`) s'arrête à
`SUNXI_GMAC_RGMII_STA` (0xD0). Il n'y a **aucun** registre de gestion
d'énergie, de type PMT/wakeup frame. Les offsets utilisés sont :

```
0x00 BASIC_CTL0   0x04 BASIC_CTL1   0x08 INT_STA   0x0C INT_EN
0x10 TX_CTL0      0x14 TX_CTL1      0x1C TX_FLOW_CTL
0x24 RX_CTL0      0x28 RX_CTL1      0x34 RX_DESC_LIST   0x38 RX_FRM_FLT
0x48 MDIO_ADDR    0x4C MDIO_DATA    0x50.. ADDR_HI/LO
0xB0.. TX_DMA_STA/CUR_*             0xC0.. RX_DMA_STA/CUR_*   0xD0 RGMII_STA
```

Le coeur DesignWare `dwmac1000` place son `GMAC_PMT` à **0x2C**
(`dwmac1000.h:43`) et l'écrit via `dwmac1000_pmt()` (`dwmac1000_core.c:251`).
Dans la carte Allwinner, 0x2C tombe entre `RX_CTL1` (0x28) et `RX_DESC_LIST`
(0x34) : c'est un trou non documenté. Rien dans le BSP, rien dans le mainline,
ne dit que ce registre existe sur ce silicium.

Côté mainline, `sun8i_dwmac_ops` (`dwmac-sun8i.c:1031`) ne fournit pas de
callback `.pmt` ; `stmmac_pmt()` passe par `stmmac_do_void_callback`
(`hwif.h:463`), donc l'appel serait un **no-op silencieux**, pas un crash.
Autrement dit, même le chemin mainline ne peut pas programmer de filtrage
magic packet sur ce MAC.

Conclusion : le seul événement de réveil que ce MAC sait produire est son
**IRQ de réception** (GIC SPI 15), levée pour toute trame acceptée par le
filtre d'adresses. Un magic packet en fait partie, mais il n'est pas
distinguable des autres trames en matériel. Toute affirmation « WoL filtré »
exigerait la documentation vendor du bloc PMT (ou une mesure qui prouve que
0x2C en est un — voir §5, point 5).

### 2.3 Ce que s2idle permet

`s2idle` (`freeze`) n'éteint ni la SoC ni ses domaines d'alimentation : il
exécute les callbacks PM, puis met les CPU en idle. Une IRQ qui reste armée
réveille un coeur, et la boucle de s2idle sort si l'IRQ est marquée comme
source de réveil.

- `enable_irq_wake()` sur une SPI du GIC n'écrit rien dans le contrôleur
  (`IRQCHIP_SKIP_SET_WAKE`, `drivers/irqchip/irq-gic.c:892`), mais le noyau
  pose `IRQD_WAKEUP_ARMED` sur la description de l'IRQ : c'est ce marquage,
  et non le GIC, qui fait sortir s2idle de sa boucle.
- phylib ne suspend pas le PHY quand le netdev a WoL activé : le coeur
  ethtool pose `dev->ethtool->wol_enabled = !!wol.wolopts`
  (`net/ethtool/ioctl.c:1867`) après un `set_wol` réussi, et
  `mdio_bus_phy_may_suspend()` (`drivers/net/phy/phy_device.c:300`) rend
  `false` dans ce cas. En plus, le driver pose `mac_managed_pm = true` à
  l'open (`sunxi-gmac.c:1913`), ce qui fait sortir `mdio_bus_phy_suspend()`
  (`phy_device.c:346`) immédiatement. **Aucun patch du driver AC300 n'est donc
  nécessaire** : il suffit de ne pas appeler `sunxi_gmac_stop()`, qui écrit
  `BMCR_PDOWN` (`sunxi-gmac.c:1602`).
- L'horloge 24 MHz du PHY vient du canal 5 du PWM (`pwm-sunxi-enhance` +
  `clk-pwm`, voir le DTS de carte). Aucun de ces drivers n'a de callback PM
  qui couperait la PWM ; c'est une déduction de code, pas une mesure (§5.2).

### 2.4 Ce que le driver faisait

- `get_wol`/`set_wol` (`sunxi-gmac.c:2938` et `:2960`) : stubs. `get_wol`
  journalisait « Not support WOL », `set_wol` retournait 0 sans rien stocker.
  `ethtool -s eth0 wol g` semblait donc réussir et ne faisait rien ; aucune
  wakeup source n'était enregistrée sur le device
  (`/sys/class/net/eth0/device/power/wakeup` n'existait pas — mesuré).
- `sunxi_gmac_suspend()` (`sunxi-gmac.c:1974`) : `netif_device_detach()` +
  `sunxi_gmac_stop()` → `sunxi_gmac_phy_release()` (`:1602`, qui écrit
  `BMCR_PDOWN` et déconnecte le PHY), puis `sunxi_gmac_power_off()` (le
  regulator) et `sunxi_gmac_clk_disable()`. PHY éteint, MAC non cadencé,
  ring DMA libéré : aucun magic packet ne pouvait être reçu, même avec l'IRQ
  armée.

### 2.5 Ce qui reste hors de portée

- **Poweroff** : l'AXP1530 coupe les rails. Ni le PHY, ni le MAC, ni le PWM
  ne sont alimentés ; aucune trame ne peut être reçue. Le « faux arrêt »
  vendor (super-standby/ARISC) est un autre chantier, non mainline
  (`docs/chantiers-reveil.md` §1).
- **Veille `mem`** : le mainline n'a pas de suspend-to-RAM pour cette famille ;
  `/sys/power/mem_sleep` ne propose que `[s2idle]`.
- **Filtrage magic packet** : voir §2.2 ; nécessiterait un registre PMT
  documenté ou un FPGA.

## 3. Les patchs

Les deux patchs s'appliquent au module (`a/sunxi-gmac.c`), dans cet ordre.
`series.conf` porte le détail et les commandes.

### 0001 — `net: sunxi-gmac: add Wake-on-LAN ethtool callbacks`

- ajoute `u32 wolopts` à `struct sunxi_gmac` ;
- `get_wol` annonce `WAKE_MAGIC | WAKE_UCAST | WAKE_MCAST | WAKE_BCAST` et
  rend les flags courants ; `set_wol` refuse tout autre flag
  (`-EOPNOTSUPP`), stocke et recopie l'état dans la wakeup source du device
  (`device_set_wakeup_enable`) ;
- au probe, `device_set_wakeup_capable(&pdev->dev, true)` crée
  `/sys/class/net/<if>/device/power/wakeup`.

Après ce patch seul : `ethtool -s eth0 wol g` est mémorisé, `Wake-on: g`
s'affiche, `power/wakeup` passe à `enabled` — mais le suspend continue de tout
éteindre, donc aucun réveil.

### 0002 — `net: sunxi-gmac: keep the MAC and PHY alive across s2idle for WoL`

- dans `sunxi_gmac_suspend()`, si l'interface est up, que
  `device_may_wakeup(dev)` est vrai et que `wolopts` est non nul : arme
  `ndev->irq` en wakeup source (`enable_irq_wake`), puis détache le netdev de
  la pile, arrête les files TX et **retourne sans** `sunxi_gmac_stop()`,
  `sunxi_gmac_power_off()` ni `sunxi_gmac_clk_disable()`. Le MAC reste
  cadencé, le ring RX armé, le PHY alimenté et le pinctrl RMII en place. Si
  l'armement de l'IRQ échoue, le chemin `power_off` normal est repris (mieux
  vaut une veille qui consomme moins qu'un réveil qui ne peut pas marcher) ;
- dans `sunxi_gmac_resume()`, si `wol_armed` : `disable_irq_wake`,
  `netif_device_attach()` (qui relance les files TX), remise de l'état
  `uevent_suppress`, et retour. Rien n'a été démonté, donc rien à
  reconfigurer : le ring et l'état du lien sont ceux d'avant la veille.

Le premier patch est indispensable au second (`wolopts`), et le second seul
ne servirait à rien (aucun flag ne serait armé).

### Ce que la série ne fait pas

- pas de programmation PMT (inexistante, §2.2) ;
- pas de filtre « magic packet seulement » ;
- pas de réveil depuis poweroff ;
- pas de patch DTS : le driver ne lit pas `wakeup-source`, et la capacité est
  créée au probe.

### Vérification des patchs

Série appliquée dans l'ordre sur une copie inscriptible de la source du
module, puis checkpatch (0 erreur, 0 warning mesuré sur les deux patchs) :

```bash
T=$(mktemp -d); cp -a packages/sunxi-gmac/src/. "$T"/
cd "$T"
for p in <repo>/packages/sunxi-gmac/patches/000*.patch; do
    patch -p1 < "$p" || break
done

perl <noyau>/scripts/checkpatch.pl --no-tree --strict \
    "<repo>/packages/sunxi-gmac/patches/0001-…patch"
```

Deux pièges de vérification, tous deux mesurés :

- `patch -p1 --dry-run` du patch 0002 sur une source **non patchée** réussit
  avec `fuzz 2` : 0002 modifie des lignes ajoutées par 0001, il se vérifie
  après 0001, pas seul.
- `checkpatch.pl` traite comme fichier source (et signale alors les lignes de
  contexte vides comme du « trailing whitespace ») tout fichier **suivi par
  git** qu'on lui passe en chemin **relatif**. Utiliser un chemin absolu, ou
  une copie hors du dépôt.

## 4. Protocole de test sur carte

### 4.1 Prérequis

- câble Ethernet sur `eth0`, lien établi :
  `cat /sys/class/net/eth0/carrier` doit rendre `1` et
  `ip -brief link show eth0` doit montrer `UP` avec une adresse ;
- un accès qui ne dépend pas du lien testé (WiFi, ou console série) : le
  suspend coupe aussi le SSH s'il passe par `eth0` ;
- `ethtool` (déjà dans `examples/h96-max-base.nix` ; sinon
  `nix run nixpkgs#ethtool -- …`) ;
- une seconde machine sur le même L2, avec `wakeonlan` (ou `python3`).

### 4.2 Construire et charger le module

```bash
# sur le poste, dans la couche qui fournit l'hôte
cd ~/src/nixelec-sunxi64-wol
nix build .#nixosConfigurations.h96-max-h618-emmc.config.system.build.toplevel
nixos-rebuild switch --flake .#h96-max-h618-emmc --target-host root@<ip>
```

Le noyau ne change pas : seul `sunxi-gmac.ko` est reconstruit. Pour que le
code tourne sans redémarrer la box :

```bash
# sur la box
ip link set eth0 down
modprobe -r sunxi-gmac
modprobe sunxi-gmac
ip link set eth0 up          # networkd refait le bail
```

Si `modprobe -r` refuse (« module in use »), redémarrer la box : c'est le seul
moyen de charger le nouveau `.ko` sans laisser l'ancien en mémoire.

Contrôles que le bon module est chargé :

```bash
dmesg | grep -i "sunxi-gmac.*eth0"
ethtool -s eth0 wol g        # doit rendre 0, sans "Not support WOL"
ethtool eth0 | grep -i wake  # "Supports Wake-on: …" puis "Wake-on: g"
cat /sys/class/net/eth0/device/power/wakeup   # enabled
```

### 4.3 Réveil

```bash
# sur la box
systemctl suspend
# (ou : echo freeze > /sys/power/state)

# sur l'autre machine, même L2
nix run nixpkgs#wakeonlan -- <MAC_ETH0>
# équivalent sans wakeonlan :
python3 - <<'PY'
import socket
mac = bytes.fromhex("<mac sans séparateurs>")
pkt = b"\xff" * 6 + mac * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for _ in range(3):
    s.sendto(pkt, ("255.255.255.255", 9))
PY
```

Attendu : la box revient en moins d'une seconde. Vérifications :

```bash
journalctl -k -b 0 | grep -E "PM: suspend entry|PM: suspend exit|WoL armed|WoL resume"
cat /proc/interrupts | grep 5030000     # compteur de l'IRQ gmac pendant la veille
uptime                                   # boottime continue de courir en s2idle
ip -brief addr show eth0 && ping -c3 <passerelle>
```

Les traces attendues au suspend : `WoL armed, MAC and PHY kept powered`, puis
`PM: suspend entry (s2idle)` ; au réveil : `PM: suspend exit` et
`WoL resume, MAC kept running`.

### 4.4 Test de contrôle (négatif)

Il prouve que le réveil vient bien de WoL et pas d'une autre source :

```bash
ethtool -s eth0 wol d
rtcwake -m freeze -s 30        # la box se réveille seule dans 30 s
# envoyer le magic packet immédiatement après l'entrée en veille
```

Attendu : la box **ne se réveille pas** avant l'alarme RTC. Si elle se réveille
quand même, une autre source (IRQ partagée, timer, watchdog) la sort de
veille : lire `dmesg` et `/sys/power/suspend_stats/last_failed_dev`.

### 4.5 Triage

| Symptôme | Cause probable | Contrôle |
|---|---|---|
| `ethtool -s` rend `Device or resource busy` | interface down (`.begin` = `sunxi_gmac_check_if_running`, `-EBUSY`) | `ip link set eth0 up` |
| `power/wakeup` reste `disabled` après `wol g` | ancien module encore chargé | `modinfo sunxi-gmac`, `dmesg` après reload |
| `PM: suspend entry` absent | un autre device refuse la veille | `dmesg`, `last_failed_dev` |
| réveils en boucle | trafic permanent (ARP/SSDP) : toute trame acceptée réveille | `tcpdump` côté pair, lien direct isolé |
| `WoL armed` mais aucun réveil | IRQ non délivrée : PWM5 coupée, horloge EMAC gatée, ou PHY éteint | §5.1–5.4 |
| la box ne revient pas | blocage au resume | série + `PM: suspend entry` sans `exit` ; coupure secteur |

### 4.6 Retour arrière

Sans redéployer : `ethtool -s eth0 wol d` puis `systemctl suspend` reprend le
chemin `power_off` + `clk_disable` d'avant. Sinon, revenir à la génération
précédente (`/nix/var/nix/profiles/system-*-link`) et recharger le module.

## 4 bis. Mesure silicium du 2026-11-28 (`.22`, eth0 câblé, carrier=1)

Verdict : **la série fait ce qu'elle annonce — et c'est inutilisable tel quel.**

| Test | Résultat |
|---|---|
| `Supports Wake-on` | `umbg` (l'ancien module répondait `d`) |
| `ethtool -s eth0 wol g` puis `systemctl suspend` | `WoL armed, MAC and PHY kept powered`, reprise `WoL resume, MAC kept running` |
| Réveil **sans envoyer aucun paquet** | **20 ms** après l'armement, `pm_wakeup_irq` = `5030000.ethernet` |
| Réveil avec magic packet | inutile à mesurer : la boîte était déjà réveillée |
| Témoin `wol d`, même suspend | dort 27,7 s, réveil par l'alarme RTC — le socle est sain |

Donc « réveil sur réception » n'est pas seulement non sélectif vis-à-vis des
trames : sur un LAN vivant (ARP, RA/ND, mDNS), la boîte ne reste pas endormie.

**Itération 2 — filtre unicast (0002, 2026-11-28) : posé, effet NON démontré.**
Le chemin suspend sauvegarde `RX_FRM_FLT`/`INT_EN`, passe le filtre en unicast
parfait (`DBF`, `PR`/`PM`/`RA`/`HUC`/`HMC` à 0), purge `INT_STA` et ne garde que
`RX_INT`. Mesure après déploiement et reboot : le réveil **persiste**, ~90-270 ms
après `WoL armed`, toujours avec `pm_wakeup_irq` = GMAC. Le compteur
`rx_packets` n'est pas concluant : il est lu après la reprise, donc il compte
aussi le trafic des secondes où la box était réveillée (+28 trames).

Ce qui manque pour trancher : un instantané **au moment du réveil** (première
chose que fait un hook de reprise : `rx_packets` + `INT_STA`), ou une sonde sur
la ligne d'IRQ. Deux hypothèses restent ouvertes :

1. le MAC accepte les trames malgré le filtre (mauvais registre, ou un bit de
   « receive all » posé ailleurs) — le filtre serait alors un no-op ;
2. le réveil vient d'une IRQ **déjà latchée** au moment de l'armement (la DMA
   reçoit pendant les ~12 s que prend la mise en veille de l'ACI8800) : vider
   `INT_STA` ne suffit pas si une trame est en cours de réception.

Tant que ce n'est pas tranché : **ne pas activer `wol g` par défaut** et ne pas
annoncer WoL comme utilisable — la politique A (« éteindre = suspendre »)
resterait cassée sur toute box câblée.

## 5. Inconnues qui exigent une mesure silicium

1. **Horloge 24 MHz du PHY en veille.** Rien dans `pwm-sunxi-enhance` ni dans
   `clk-pwm` ne coupe la PWM en s2idle, mais ce n'est pas mesuré. Mesure :
   oscilloscope sur la broche de sortie PWM5 (groupe `pwm5_pin` du DTS) pendant
   la veille, ou `cat /sys/kernel/debug/pwm` avant/après.
2. **Horloge AHB du MAC (`CLK_BUS_EMAC1`).** Le driver ne la coupe pas dans le
   chemin WoL, mais la CCU ou un `clk_disable_unused()` tardif pourrait la
   gater. Mesure : `devmem` des registres de gate CCU avant/après, ou
   simplement le test de réveil.
3. **Livraison de l'IRQ comme événement de réveil.** `IRQCHIP_SKIP_SET_WAKE`
   signifie que rien n'est écrit dans le GIC ; c'est `IRQD_WAKEUP_ARMED` qui
   fait sortir s2idle. À confirmer : `cat /proc/interrupts` (compteur gmac)
   avant/après, et `cat /sys/power/suspend_stats/success`.
4. **État du PHY AC300 après la veille.** On suppose qu'il n'est ni en
   `BMCR_PDOWN` ni en `SHUTDOWN` (le driver ne l'appelle pas). Mesure :
   `ethtool eth0` (lien/vitesse) au réveil, et lecture MDIO de `BMCR` (0x00)
   et du registre 0x06 de l'AC300 (bit `SHUTDOWN`) via `phytool` ou `mdio-tools`.
5. **0x2C est-il un PMT ?** Le trou entre `RX_CTL1` et `RX_DESC_LIST` pourrait
   être le `GMAC_PMT` du coeur DesignWare. Mesure prudente, sur une box de
   banc : MAC arrêté (`ip link set eth0 down`), `devmem 0x0503002c` (lecture
   seule) ; comparer à la valeur de reset attendue. Ne pas écrire à l'aveugle :
   un bit « power down » mal placé peut figer la réception jusqu'au reload.
6. **Quelles trames réveillent.** Tester séparément : magic packet seul, une
   requête ARP, un ping. Si ARP réveille, le documenter comme comportement
   assumé (pas de filtre matériel) et l'annoncer côté produit.
7. **Consommation en veille avec WoL armé.** Le MAC + PHY + PWM restent
   alimentés : mesurer le courant 12 V en s2idle, WoL armé vs. chemin
   `power_off` actuel. C'est le prix du réveil.
8. **Remplissage du ring RX.** 256 descripteurs (`SUNXI_GMAC_DMA_DESC_RX`) :
   après une longue veille sous trafic, vérifier `ip -s link show eth0`
   (dropped/overrun) et que le réveil se produit sur la première trame.
9. **Re-négociation du lien.** Débrancher/rebrancher le câble pendant la
   veille : la machine à états du PHY est gelée (workqueue) ; vérifier qu'au
   réveil le lien remonte et que le trafic repart, ou documenter la limite.
10. **Persistance du réglage.** `ethtool -s eth0 wol g`, puis
    `ip link set eth0 down/up` : `wolopts` est dans `chip`, il survit ; mais
    `sunxi_gmac_stop()` éteint le PHY. Vérifier que le réveil fonctionne
    encore après un cycle down/up, et si non, le documenter (interface doit
    rester up).

## 6. Références

- `packages/sunxi-gmac/src/sunxi-gmac.c` — registres (99-123), `get_wol`/
  `set_wol` (2938/2960), suspend/resume (1974/1947), `phy_release` (1602),
  message dmesg (1867), `mac_managed_pm` (1913).
- `packages/sunxi-gmac/patches/series.conf` — ordre, cible, limites.
- `patches/kernel/sunxi-7.0-h96-max/0001-…` — DTS de la carte (`&emac1`).
- `docs/etude-portage-sunxi-gmac.md` — pourquoi le module vendor et pas
  `dwmac-sun8i`.
- `docs/chantiers-reveil.md` — inventaire des chemins de réveil (IR, WoL,
  WoWLAN) et état du faux arrêt vendor.
- Noyau 7.0.14 : `drivers/net/ethernet/stmicro/stmmac/dwmac1000.h:43`
  (`GMAC_PMT`), `dwmac1000_core.c:251` (`dwmac1000_pmt`),
  `dwmac-sun8i.c:1031` (`sun8i_dwmac_ops`), `hwif.h:463` (`stmmac_pmt`),
  `drivers/net/phy/phy_device.c:300/346/2016`,
  `drivers/irqchip/irq-gic.c:892`.
