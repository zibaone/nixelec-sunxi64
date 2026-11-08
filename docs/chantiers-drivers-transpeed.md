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

## Vue d'ensemble

| # | Chantier | Type | Coût | Bloqué par |
|---|---|---|---|---|
| 1 | Retirer `NETIF_F_RXCSUM` de `hw_features` | correction | 15 min | — |
| 2 | MAC stable (propriété DT `mac-address`) | correction | 30 min | — |
| 3 | `-EPROBE_DEFER` au lieu de l'ordre de chargement | robustesse | 1–2 h | — |
| 4 | `sunxi-mdio` qui lit `phy_id = 0` | dette | 2–3 h | — |
| 5 | `dwmac-sun8i` en `=n` propre | propreté | 30 min | #6 |
| 6 | `dwmac-sun8i` dans `boot.kernelModules` (nixbian) | bug latent | 1 h | — |
| 7 | Cause racine du désaccord BTF (nixbian) | bug latent | à cadrer | — |
| 8 | `CONFIG_KEXEC` absent | capacité | 30 min + 1 rebuild | — |
| 9 | Loopback MAC en test scripté | outillage | 1 h | — |
| 10 | Panique `brcmfmac` (WiFi) | chantier de fond | élevé | — |

---

## 1. Retirer `NETIF_F_RXCSUM`

**Symptôme** : `ethtool -k eth0` annoncera `rx-checksumming: on` alors que le
MAC ne vérifie aucun checksum.

**Preuve** : `hw_features` inclut `NETIF_F_RXCSUM` (≈ ligne 3824), et le même
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
(≈ ligne 3537) : si le DT porte `mac-address`, elle est utilisée. Sans
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
3317) fait `if (IS_ERR(...)) chip->ephy_clk = NULL;` — l'erreur est **avalée**.
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

**État actuel** : `CONFIG_DWMAC_SUN8I=m` **uniquement** pour satisfaire le
pruning, qui échoue sur un module listé dans `boot.kernelModules` mais absent.
Le module charge et ne se lie à rien (`emac1` porte
`compatible = "allwinner,sunxi-gmac"` depuis le patch 0004, `emac0` est
désactivé), donc c'est inoffensif — mais c'est un contournement qui masque le
vrai bug.

**Correction** : une fois #6 réglé côté nixbian, repasser à `=n` et retirer
`dwmac-sun8i` de la liste des modules.

## 6. `dwmac-sun8i` dans `boot.kernelModules` (nixbian)

**Symptôme** : la couche nixbian liste `dwmac-sun8i` dans `boot.kernelModules`
pour toutes les cartes sunxi64. Toute carte qui compile ce pilote en `=n` casse
le pruning d'image (`module not found`).

**Correction** : côté `nixbian`, ne lister `dwmac-sun8i` que si
`CONFIG_DWMAC_SUN8I` n'est pas `n` — ou le sortir de la liste et le laisser
être chargé par le `compatible` du DT (`MODALIAS`).

**Vérification** : construire l'image d'une carte avec `DWMAC_SUN8I=n` ; elle
doit passer le pruning.

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

**Correction** : côté nixbian, aligner l'outillage de compilation des modules
sur celui du noyau (même `pahole`, même GCC). Sinon chaque bump de noyau
ramènera la panne, et chaque carte devra porter l'option.

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

## Décision matérielle en attente

Tester une **deuxième unité** (H96 Max H618, ou une autre Transpeed) tranche la
seule question que le logiciel ne peut pas trancher : cette unité est-elle
défectueuse, ou le PHY interne de ces boîtiers est-il mal implémenté ? Tant que
ce n'est pas fait, la réserve C reste ouverte et la voie dongle USB
(`enu1`, DHCP, ~6,4 Mbps) est la seule utilisable.
