# Chantiers drivers — Transpeed 8K618-T

État au 2026-11-07, après la session qui a rendu l'Ethernet fonctionnel via le
portage vendor `sunxi-gmac` et prouvé que la corruption RX restante est
matérielle.

Ce document liste ce qui reste à faire **côté pilote**, dans l'ordre où ça a du
sens de le faire. Chaque chantier donne : le symptôme, la preuve mesurée,
l'endroit du code, la correction visée, comment vérifier, et le coût.

Les références de ligne valent pour l'état actuel de
`packages/sunxi-gmac/src/sunxi-gmac.c` (l'arbre compilé, sans patch appliqué
par la dérivation) ; elles bougeront, chercher le symbole plutôt que la ligne.

**Ce qui n'est plus un chantier driver** : la corruption de la charge utile en
réception (réserve C de l'étude). Le loopback interne du MAC reçoit 3/3 pings
avec checksums validés, donc MAC, DMA, descripteurs, ring et chemin RX du
pilote sont sains. La même carte, sur le même port de routeur et le même câble,
reste à 10 Mbps avec `LPA 0x4461` alors qu'un dongle RTL8153 y monte à
1000 Mb/s. C'est le récepteur du PHY AC300 de cette unité. Ne pas rouvrir ce
dossier sans une deuxième unité ou une mesure au scope.

## État au 2026-11-08 — chantier mis en standby

Le portage Ethernet est **livré et utilisable par la voie dongle**, mais
l'Ethernet interne de cette unité est défaillant. Le chantier est mis en pause
ici ; tout le contexte nécessaire à la reprise est ci-dessous.

**Fait et vérifié**

- P2 intégré : paquet `packages/sunxi-gmac`, nœud DT 0004, `extraConfig`,
  ordre des modules, CI qui construit et pousse le module (`9da603b`,
  `444ac25`, run `42296083338` vert).
- Deux vrais bugs du pilote vendor corrigés : `CHECKSUM_UNNECESSARY` (le
  pilote validait des trames corrompues) et les 7 octets de préambule comptés
  dans la longueur (`ceac46d`).
- Corruption RX restante prouvée **matérielle** par loopback interne du MAC
  (`fde3d8c`, `3cd3f37`) : MAC, DMA, descripteurs, ring et chemin RX du pilote
  sont sains.
- Voie de secours validée : dongle SR9700 (`enu1`, DHCP, SSH, ~6,4 Mbps),
  modules `usbnet`/`mii`/`sr9700` gardés dans l'image et
  `CONFIG_MODULE_ALLOW_BTF_MISMATCH=y` (`197bfae`, `b5c24aa`, `3f3e399`).
- Provenance du paquet assainie : `src/` porte l'arbre réellement compilé, la
  dérivation n'applique plus de patch (`61719e7`) — désassemblage aarch64
  identique, seul le `.drv` change, **donc le cache CI doit être re-rempli**.
- Docs : ce fichier, `etude-portage-sunxi-gmac.md`, `verified.md`, backlog.

**Bloqué**

- Ethernet interne : PHY AC300 de cette unité. Il faut une **deuxième unité**
  (H96 Max H618 ou autre Transpeed) pour séparer panne d'unité et défaut de
  conception. Aucun travail logiciel ne peut lever ce doute.
- Banc hors ligne depuis le 2026-11-08 : la box ne répond plus sur
  `192.168.1.23` (dongle débranché ou box éteinte).

**Pour reprendre**

1. Rebrancher le banc : dongle SR9700 **présent au boot** (coupure
   d'alimentation, pas un reboot à chaud — `dhcpcd` démarre avant
   l'énumération USB), UART CH340 sur `/dev/ttyUSB0` en secours.
2. Vérifier que la configuration évalue encore : `nix eval --raw
   .#nixosConfigurations.transpeed-8k618-t.config.system.build.toplevel.drvPath`
   (3 s le 2026-11-08, après les évolutions des couches partagées).
3. Recompiler le module contre `kernel.dev` (`linux-7.0.14-dev`), `strip
   --strip-debug`, transférer par SSH, `rmmod`/`insmod`, mesurer.
4. Attaquer les chantiers 1 à 3 (voir le plan
   `.hermes/plans/2026-11-08_115500-suite-chantiers-drivers-transpeed.md`).
5. Construire l'image HavenOS avec `--override-input nixelec` si le lock n'a
   pas suivi.

## Dérive des couches partagées (vérifiée le 2026-11-08)

Les couches communes avec la Zero 3 ont évolué après la rédaction initiale de
ces docs. Points vérifiés, et ce qu'ils changent ici :

| Évolution | Effet sur le Transpeed |
|---|---|
| `4219ece` — firmware BCM4334, NVRAM et `wireless-regdb` déplacés dans `modules/boards/transpeed-8k618-t.nix` ; `wlan0` figé par `systemd.network.links` | la mesure de panique WiFi (§10) est **antérieure** à ce durcissement, à rejouer |
| Famille `sunxi64` : `brcmfmac` + `brcmfmac-wcc` listés quand `nixelec.wifiHardware == "brcmfmac"` | le sous-module `brcmfmac-wcc` est indispensable (`brcm_fwvid_request_module: mod=wcc: failed 256`) |
| Famille `sunxi64` : `hardware.firmwareCompression = "none"` | sans ça le firmware part en `.zst` et n'est jamais chargé (ce noyau n'a pas `CONFIG_FW_LOADER_COMPRESS`) |
| Famille `sunxi64` : `boot.kernelModules` = HDMI audio, `sun8i_ce`, `zram` (+ brcmfmac) — **pas** `dwmac-sun8i` | le chantier 6 était mal attribué, corrigé ci-dessous |
| HavenOS : lock nixelec à `4180a2f` (`299b95d`) | contient **tous** les correctifs Ethernet ; `61719e7` n'est qu'une remise à plat de provenance, code identique |
| nixbian : `ebb7fe3b` (board transpeed dans les métadonnées), `c4fc0746` (boards locales, génération incrémentale), `152a5c67` (crust) | le DTB et la config du noyau viennent toujours de ces métadonnées générées ; ne pas les éditer à la main |

**Contradiction à trancher au banc** : `examples/transpeed-base.nix` affirmait
que « l'ordre n'importe pas : le driver PHY diffère son probe tant que l'horloge
n'existe pas », alors que le module de carte note l'inverse (dans le désordre,
le PHY tombe sur `genphy`). L'un des deux a été écrit avant une correction de
l'autre ; le commentaire de l'exemple a été corrigé pour signaler les deux
versions. À re-mesurer avant d'écrire le `-EPROBE_DEFER` du chantier 3.

## Vue d'ensemble

| # | Chantier | Type | Coût | Bloqué par |
|---|---|---|---|---|
| 1 | Retirer `NETIF_F_RXCSUM` de `hw_features` | correction | 15 min | — |
| 2 | MAC stable (propriété DT `mac-address`) | correction | 30 min | — |
| 3 | `-EPROBE_DEFER` au lieu de l'ordre de chargement | robustesse | 1–2 h | — |
| 4 | `sunxi-mdio` qui lit `phy_id = 0` | dette | 2–3 h | — |
| 5 | `dwmac-sun8i` en `=n` propre | propreté | 30 min | #6 |
| 6 | `dwmac-sun8i` dans `boot.kernelModules` (exemple) | propreté | 15 min | — |
| 7 | Cause racine du désaccord BTF (nixbian) | bug latent | à cadrer | — |
| 8 | `CONFIG_KEXEC` absent | capacité | 30 min + 1 rebuild | — |
| 9 | Loopback MAC en test scripté | outillage | 1 h | — |
| 10 | Panique `brcmfmac` (WiFi) | chantier de fond | élevé | — |

---

## 1. Retirer `NETIF_F_RXCSUM`

**Symptôme** : `ethtool -k eth0` annoncera `rx-checksumming: on` alors que le
MAC ne vérifie aucun checksum.

**Preuve** : `hw_features` inclut `NETIF_F_RXCSUM` (≈ ligne 3853), et le même
pilote posait `skb->ip_summed = CHECKSUM_UNNECESSARY` sur chaque trame, ce qui
déjà masquait toutes les corruptions. Ce dernier point est corrigé
(`CHECKSUM_NONE`), mais le drapeau `netdev` reste : les chemins qui s'y fient
(tunnel, forwarding, XDP) continueront de croire à une vérification.

**Correction** : retirer `NETIF_F_RXCSUM` de `hw_features`. Ne pas toucher à
`NETIF_F_IP_CSUM` / `NETIF_F_IPV6_CSUM` : l'offload TX, lui, fonctionne — le PC
reçoit les trames de la carte avec des checksums valides.

**Vérification** : `ethtool -k` doit donner `rx-checksumming: off`, et un
`ping` dans les deux sens doit continuer à passer.

## 2. MAC stable

**Symptôme** : `net eth0: Use random mac address` à chaque boot. Pas de
réservation DHCP, pas de suivi, adresse différente à chaque redémarrage.

**Preuve** : le pilote appelle déjà `of_get_ethdev_address(np, ndev)`
(≈ ligne 3563) : si le DT porte `mac-address`, elle est utilisée. Sans
propriété, le noyau en tire une au hasard.

**Correction** : deux options, dans cet ordre de préférence.

1. **Propriété DT** dans le patch de carte : `mac-address` sur le nœud
   `emac1`. Zéro code, mais une MAC en dur par carte — acceptable pour une
   flotte, pas pour une image générique.
2. **Lecture de l'eFuse** : la MAC de la puce est dans le SID. C'est ce que
   faisait `get_custom_mac_address()`, retirée au portage faute de symbole BSP.
   Réimplémenter avec `nvmem` (le SID est déjà exposé en DT pour la
   calibration du PHY) donne une MAC stable **et** par unité.

**Vérification** : deux reboots consécutifs, même `ip link` ; puis vérifier
que la MAC n'apparaît pas en double sur le réseau.

## 3. `-EPROBE_DEFER` au lieu de l'ordre de chargement

**Symptôme** : si le PWM n'est pas encore là, le PHY tombe sur `genphy` et n'en
décroche plus. D'où l'ordre imposé `pwm-sunxi-enhance` → `clk-pwm` →
`sunxi-mdio` → `sunxi-gmac` dans `boot.kernelModules`.

**Preuve** : `chip->ephy_clk = devm_clk_get(&pdev->dev, "phy25m")` (≈ ligne
3342) fait `if (IS_ERR(...)) chip->ephy_clk = NULL;` — l'erreur est **avalée**.
Or `devm_clk_get` renvoie `-EPROBE_DEFER` quand le provider n'est pas encore
enregistré : c'est précisément le signal à propager pour que le driver soit
reprobe plus tard, au lieu de démarrer sans horloge.

**Correction** : remplacer le `return -EINVAL` / `NULL` par
`return dev_err_probe(dev, ret, ...)` quand `ret == -EPROBE_DEFER` (et garder
une erreur franche dans les autres cas). Même traitement pour `pwm_get` et pour
les horloges `gmac`/`hbus`/`mbus`.

**Vérification** : charger `sunxi-gmac` **avant** `pwm-sunxi-enhance` ; le
probe doit différer puis réussir seul quand le PWM apparaît. Ensuite, l'ordre
dans `boot.kernelModules` devient indifférent (le garder pour la lisibilité,
pas pour la correction).

**Risque** : un `-EPROBE_DEFER` mal placé transforme un échec en attente
infinie. Vérifier `dmesg` : la ligne `deferred probe pending` doit disparaître
après le chargement du PWM.

## 4. `sunxi-mdio` qui lit `phy_id = 0`

**Symptôme** : au probe, `eth0: Type(7) PHY ID 00000000 at 0 IRQ poll`. Le PHY
s'attache quand même, mais uniquement parce que le DT porte `phy-handle` et que
le driver PHY se lie par `compatible`.

**Preuve** : les lectures MDIO du module vendor rendent 0 (`/root/mdio`, accès
direct `/dev/mem`, rend au même instant `BMCR=0x3100`, `BMSR=0x79ed`,
`ANAR=0x01e1`). Le bloc MDIO du MAC n'est donc pas cassé : c'est la séquence du
driver qui l'est. `SUNXI_MDIO_MDC_DIV` passé de 3 à 4 n'a rien changé.

**Correction** : deux voies.
- Diagnostiquer la séquence vendor (attente du `MDIO_BUSY`, `phy_id` lu trop
  tôt, horloge MDC non encore active au moment du probe). C'est probablement un
  problème d'ordre : l'ID est lu avant que l'horloge du PHY soit stable.
- Ou assumer le bus mainline (`stmmac-mdio` / `mdio-gpio`) et supprimer
  `sunxi-mdio` du portage.

**Vérification** : `phy_id` non nul dans `dmesg`, et `BMSR` cohérent avec
l'état du lien.

## 5. `dwmac-sun8i` en `=n` propre

**État actuel** : `CONFIG_DWMAC_SUN8I=m` par précaution contre le pruning, qui
échoue sur un module listé dans `boot.kernelModules` mais absent. **Vérifié le
2026-11-08** : le module de carte ne liste pas ce module ; seul
`examples/transpeed-base.nix` le fait. Le module charge et ne se lie à rien
(`emac1` porte `compatible = "allwinner,sunxi-gmac"` depuis le patch 0004,
`emac0` est désactivé), donc c'est inoffensif — mais `=n` suffirait pour
l'image de la carte.

**Correction** : passer à `=n` dans `modules/boards/transpeed-8k618-t.nix`, et
retirer `dwmac-sun8i` de la liste de l'exemple (ou l'y laisser avec `=m` si
l'exemple doit rester autonome).

## 6. `dwmac-sun8i` listé dans un `boot.kernelModules` (exemple, pas nixbian)

**Correction du 2026-11-08** : ce chantier était mal attribué. La couche
nixbian **ne liste pas** ce module (vérifié : `grep '"dwmac-sun8i"'` ne rend que
`examples/transpeed-base.nix`). La famille `sunxi64` liste `dw-hdmi-i2s-audio`,
`snd-soc-hdmi-codec`, `sun8i_ce`, `zram`, et `brcmfmac`/`brcmfmac-wcc` quand
`nixelec.wifiHardware == "brcmfmac"`.

Le risque reste réel mais il est **local à l'exemple** : une configuration qui
liste `dwmac-sun8i` tout en compilant le pilote en `=n` casse le pruning
(`module not found`). Ce n'est pas un bug de la couche partagée.

**Correction** : dans l'exemple, soit garder `=m`, soit retirer l'entrée et
laisser le `compatible` du DT charger le module (`MODALIAS`).

## 7. Cause racine du désaccord BTF (nixbian)

**Symptôme** : le noyau refuse des modules de sa propre image :

```
failed to validate module [usbnet] BTF: -22
modprobe: ERROR: could not insert 'usbnet': Invalid argument
```

Conséquence mesurée : **aucun dongle USB-Ethernet ne fonctionnait**, `usbnet`
étant la dépendance de tous ces pilotes.

**Contournement en place** : `CONFIG_MODULE_ALLOW_BTF_MISMATCH=y` dans
`modules/boards/transpeed-8k618-t.nix`. C'est sain (l'ABI reste vérifiée par
vermagic et les versions de symboles, BTF ne sert qu'à l'introspection BPF),
mais ça **masque** le problème : les modules de l'image ne sont pas produits
par le même outillage que le noyau.

**Hypothèse à confirmer** : les modules de l'image ne seraient pas produits par
le même outillage que le noyau (même `pahole`, même GCC). Ce n'est **pas
démontré** — la vérification consiste à comparer la version de `pahole` et de
GCC utilisée pour le noyau et pour les modules de l'image (`nix log` du noyau
et de la dérivation des modules). Si l'hypothèse est fausse, la cause est
ailleurs (par exemple une section `.BTF` générée à partir de sources
différentes) et `ALLOW_BTF_MISMATCH` restera nécessaire.

**Correction** : si l'hypothèse se vérifie, aligner l'outillage côté nixbian.
Sinon chaque bump de noyau ramènera la panne, et chaque carte devra porter
l'option.

## 8. `CONFIG_KEXEC` absent

**Symptôme** : impossible de déployer par kexec ; le `.config` Armbian ne
l'active pas.

**Correction** : `CONFIG_KEXEC=y` (et `CONFIG_KEXEC_FILE` si la carte a un
`/proc/kcore` utilisable) dans `extraConfig`.

**Coût** : 30 min de config + un rebuild noyau de ~45 min en CI.

## 9. Loopback MAC en test scripté

**Ce que ça vaut** : c'est le test qui a évité des heures de poursuite du
mauvais coupable. Il sépare « pilote/MAC/DMA » de « PHY/ligne » en 30 secondes.

**Recette mesurée** :

```bash
/root/regrw 0x5030000 0x0000000b     # BASIC_CTL0 : duplex + 10M + loopback
ping -c 3 <sa propre IP>             # doit rendre 3/3, checksums validés
/root/regrw 0x5030000 0x00000009     # restaurer
```

**À faire** : en faire un script du skill (`scripts/`), qui monte une IP de
test, active le loopback, ping, restaure, et conclut. À passer sur toute
nouvelle carte H616/H618 juste après le lien.

## 10. Panique `brcmfmac` (WiFi)

**Symptôme** : ~1,5 s après le début d'émission radio (`iw dev wlan0 scan`
suffit), panique noyau : écriture en mémoire read-only à
`ffff80008012cfd0`, puis `paging request at virtual address 17ff7ff9d0041491`,
`Comm: wpa_supplicant`, `__cgroup_account_cputime`, `Attempted to kill the
idle task!`. Stalls RCU `Possible timer handling issue on cpu=2`, watchdog
`sunxi-wdt` 16 s.

**Attention, mesure antérieure au durcissement.** La panique a été observée
avant `4219ece` (2026-11-08), qui a fait entrer le firmware dans le module de
carte : `brcmfmac4334-sdio.bin` + NVRAM + `wireless-regdb`, `wlan0` figé par
`systemd.network.links` (sans quoi systemd renomme l'interface en `wld1`),
`brcmfmac-wcc` listé par la famille, et `hardware.firmwareCompression = "none"`
(ce noyau n'a pas `CONFIG_FW_LOADER_COMPRESS`, donc un firmware `.zst` n'était
jamais chargé). **Rejouer le test avant d'ouvrir le dossier** : il est possible
que la panique ait eu une cause de chargement de firmware.

**Ce qui est établi** : le firmware et la NVRAM sont les bons (BCM4334, NVRAM
extraite du dump Android, MAC issue de l'OTP) ; le module se charge et
l'interface monte. La panique survient au début du trafic radio, pas au probe.

**Pistes, dans l'ordre** :
1. Reproductibilité sur une deuxième unité (une seule mesure aujourd'hui).
2. `brcmfmac` en mode `SDIO` : vérifier les réglages `sdhci`/`sunxi-mmc`
   (largeur de bus, `cap-sdio-irq`, tension de signalisation) — une écriture
   read-only qui part en vrille évoque souvent un DMA qui déborde son buffer.
3. Découper : `wpa_supplicant` en `-dd`, `dmesg` en `loglevel=8`, et voir si la
   panique précède ou suit la première interruption SDIO.
4. Comparer avec le noyau vendor de la box (le WiFi y fonctionnait sous
   Android) pour isoler ce qui relève du pilote mainline.

**Coût** : élevé, et c'est le vrai blocage pour un kiosque sans câble. À
traiter comme un chantier à part, pas comme une finition du portage Ethernet.

---

## Vérifier une image Transpeed

Une image qui se construit ne prouve pas qu'elle embarque les bons modules : le
pruning en retire 1707 sur 2643. `kernel-modules` est un **symlink** — un `find`
sans `-L` renvoie faussement « absent ».

```bash
SYS=$(ls -dt /nix/store/*nixos-system-*transpeed-8k618-t* | head -1)
M=$(readlink -f $SYS/kernel-modules)
```

| Élément | Attendu |
|---|---|
| `$M/…/net/usb/sr9700.ko` et `usbnet.ko` | présents (dongle de secours) |
| `$M/…/pwm/pwm-sunxi-enhance.ko` | présent (24 MHz du PHY) |
| `find -L $SYS/kernel-modules -path '*extra*' -name '*.ko'` | `sunxi-gmac.ko`, `sunxi-mdio.ko` (hors arbre) |
| `$SYS/etc/modules-load.d/*.conf` | `pwm-sunxi-enhance`, `clk-pwm`, `sunxi-mdio`, `sunxi-gmac`, `usbnet`, `mii`, `sr9700` |
| config du noyau | `CONFIG_MODULE_ALLOW_BTF_MISMATCH=y`, `CONFIG_AC300_PHY=y`, `CONFIG_DWMAC_SUN8I=m` |
| DTB | `sun50i-h618-transpeed-8k618-t.dtb` porte `allwinner,sunxi-gmac`, `allwinner,syscfg-value`, `mdio@5030048` |
| firmware | `$SYS/firmware/brcm/brcmfmac4334-sdio.bin` + `.txt`, `regulatory.db` **non compressés** |

Trouver la config du noyau : `nix-store -q --deriver $(readlink -f $SYS/kernel)`
puis, dans les références du `.drv`, la `*.config`.

## Décision matérielle en attente

Tester une **deuxième unité** (H96 Max H618, ou une autre Transpeed) tranche la
seule question que le logiciel ne peut pas trancher : cette unité est-elle
défectueuse, ou le PHY interne de ces boîtiers est-il mal implémenté ? Tant que
ce n'est pas fait, la réserve C reste ouverte et la voie dongle USB
(`enu1`, DHCP, ~6,4 Mbps) est la seule utilisable.
