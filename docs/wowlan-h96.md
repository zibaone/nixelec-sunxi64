# WoWLAN magic-packet sur la H96 Max H618 (AIC8800D80)

État au 2026-11-27. Objet : savoir si la box peut être réveillée depuis
`s2idle` par un paquet magique reçu en WiFi, et ce qu'il faut écrire pour
cela. **Aucune mesure sur carte n'a été faite pour ce document** : tout vient
de la lecture du noyau 7.0.14, du pilote vendor et des arbres vendor
comparables. Les deux mesures qui décident du verdict sont listées au §10.

## Résumé

| Question | Réponse |
|---|---|
| Le noyau peut-il réveiller la box sur une IRQ GPIO en `s2idle` ? | oui, si l'action porte `IRQF_NO_SUSPEND` (`kernel/irq/pm.c:65-71`) |
| Le réveil SDIO in-band (DAT1) est-il possible ? | non : `sunxi-mmc` n'a aucun support de wake système (`sunxi-mmc.c:1534`) |
| La ligne OOB est-elle câblée et utilisable ? | oui, PG15 = EINT15, gpio 207, actif haut (FDT + log vendor) |
| Le pilote programme-t-il quelque chose au suspend ? | non : ni op `suspend` cfg80211, ni appel `WAKEUP_INFO_REQ` |
| Le firmware sait-il matcher un motif de réveil ? | l'API existe dans l'en-tête, jamais appelée ; **non prouvé** |
| Verdict | **faisable avec travail vendor**, sous deux mesures bloquantes |

### État au 2026-11-28 (mesuré sur carte)

Ce document a été écrit le 2026-11-27 par lecture de source. Depuis, trois
choses ont été mesurées sur les H96 et changent le point de départ :

- **Le prérequis DT est rempli** : `keep-power-in-suspend` est présent sur
  `mmc@4021000` dans le DTB des générations courantes. Sans lui,
  `aicbsp_sdio_suspend` renvoie `-EINVAL` (« can't keep power while host is
  suspended ») et **toute la veille est annulée** — mesuré sur `.18` avant
  reboot sur une génération dont le DTB ne l'avait pas.
- **Le réveil IR est le modèle qui marche** (`sunxi-7.0-veille` 0002) :
  `device_init_wakeup(dev, true)` au probe, `enable_irq_wake(ir->irq)` au
  suspend. C'est le patron à imiter pour l'IRQ PG15 du WoWLAN.
- **Le faux positif est confirmé sur la box** : `rc0` a bien `[nec]` et
  `[lirc]`, mais le pilote SDIO n'a aucune op `suspend`/`resume` cfg80211 —
  `iw phy0 wowlan enable magic-packet` ne fait que valider `wiphy->wowlan`.

Banc de test : `.22` (headless, câblé) pour les cycles de veille ; `.18` est le
kiosque TV, à ne pas suspendre sans accord.

## 1. Méthode

Sources lues, sans build ni carte :

- noyau cible : `linux-7.0.14` (arbre source `/nix/store/941577…-linux-458c607`) ;
- pilote vendor : `drivers/net/wireless/aic8800_sdio/`, tel qu'ajouté par le
  patch Armbian 3401 (`nixbian/metadata/nix/patches/kernel/archive/sunxi-7.0/patches.armbian/3401-…-mm2.patch`),
  millésime `RELEASE_DATE 2025_0926_91c9dae5` (`rwnx_version_gen.h`) ;
- arbres vendor comparés : `radxa-pkg/aic8800` (`2026_0123_5f7be68d`) et
  `susers/aic8800_linux_driver`, récupérés pour vérifier ce que les versions
  voisines font du WoWLAN. Ils ne sont pas dans ce dépôt et ne sont pas
  construits ici.

Les numéros de ligne du pilote renvoient à l'état **après** 3401 (et après
`sunxi-7.0-aic8800-kbuild`, qui ne touche que `drivers/net/wireless/{Kconfig,Makefile}`).

## 2. Ce que le noyau 7.0.14 attend d'un pilote WoWLAN

L'API a changé, et c'est le point qui invalide la mesure du 2026-11-23
reprise dans `chantiers-reveil.md` §3 :

- l'op `set_wowlan` **n'existe plus** ; `struct cfg80211_ops` n'a que
  `suspend`, `resume` et `set_wakeup` (`include/net/cfg80211.h:4901-4904`) ;
- `nl80211_set_wowlan` se contente de valider les déclencheurs contre
  `wiphy->wowlan`, de les copier dans `wiphy->wowlan_config` puis d'appeler
  `set_wakeup` **s'il existe** (`net/wireless/nl80211.c:15153-15165`) ;
- au suspend, `wiphy_suspend()` passe `wiphy->wowlan_config` à l'op
  `suspend` du pilote (`net/wireless/sysfs.c:103-110`), et le wiphy est
  enfant du device SDIO (`rwnx_main.c:5787`, `set_wiphy_dev`), donc il est
  suspendu **avant** le bus : l'ordre « programmer puis couper le bus » est
  garanti par la parenté.

Conséquence : `iw phy0 wowlan enable magic-packet` renvoie 0 et affiche
« WoWLAN is enabled » même si le pilote n'implémente rien. La mesure du
23/11 prouve seulement que `wiphy->wowlan` est renseigné — ce que le pilote
fait depuis toujours (`rwnx_main.c:5910-5915`) sans jamais lire
`wowlan_config`.

## 3. Inventaire de ce que le pilote vendor expose réellement

| Élément | Où | État |
|---|---|---|
| `WIPHY_WOWLAN_ANY \| WIPHY_WOWLAN_MAGIC_PKT` | `rwnx_main.c:5534-5537` | annoncé, sous `CONFIG_PM` |
| `wiphy->wowlan = …` | `rwnx_main.c:5910-5915` | posé à l'enregistrement |
| op `suspend` / `resume` cfg80211 | `rwnx_main.c:5359-5413` | **absents** |
| lecture de `wiphy->wowlan_config` | — | **aucune** |
| op `set_wakeup` | — | absent (facultatif) |
| `WAKEUP_INFO_REQ` (moteur de réveil) | `lmac_msg.h:2012`, `:2105-2112` | déclaré, **aucun appelant** |
| `rwnx_send_vendor_hwconfig_req()` | `rwnx_msg_tx.c:1473` | `switch` sans cas `WAKEUP_INFO_REQ` |
| ligne OOB (`WL_WAKE_HOST`) | `aicwf_sdio.c:579-683` | code présent, **compilé seulement sous `CONFIG_GPIO_WAKEUP`** |
| lookup de l'IRQ OOB | `aicwf_sdio.c:595-603` | `sunxi_wlan_get_oob_irq()`, symbole du noyau **BSP** Allwinner |
| `CONFIG_GPIO_WAKEUP` | `aic8800_fdrv/Makefile:123`, `Makefile:14` | `?= n` puis `export … = n` : chemin mort |
| `CONFIG_AUTO_POWERSAVE` | `aic8800_fdrv/Makefile:124` | `= n` (non surchargeable) |
| suspend SDIO | `aicwf_sdio.c:978-1079` | exige `MMC_PM_KEEP_POWER`, détache les netdev |
| suspend BSP | `aic8800_bsp/aicsdio.c:411-450` | même exigence, pour la fonction 2 |

Deux chemins de réveil existent donc dans le code vendor, et aucun n'est
vivant ici :

1. **GPIO OOB** : `rwnx_register_hostwake_irq()` demande une IRQ avec
   `IRQF_NO_SUSPEND`, fait `device_init_wakeup()` puis
   `dev_pm_set_wake_irq()`. Mais l'IRQ vient de `sunxi_wlan_get_oob_irq()`,
   qui n'existe que dans le noyau BSP Allwinner (déclaré `extern` en
   `aicwf_sdio.c:471-478`), et le Makefile désactive le drapeau.
2. **Motif firmware** : aucune implémentation, seulement l'API.

Le `CONFIG_GPIO_WAKEUP` du vendor est par ailleurs accroché à
`rfkill_rk_sleep_bt()` côté Rockchip (`aic8800_bsp/aicsdio.c:418-421`,
`442-446`) : l'activer tel quel pour sunxi ne compilerait pas.

## 4. Ce que le firmware accepte (et ce qui n'est pas prouvé)

`struct mm_set_wakeup_info_req` (`lmac_msg.h:2105`) :

```c
struct mm_set_wakeup_info_req {
	u32_l hwconfig_id;   /* WAKEUP_INFO_REQ */
	u16_l offset;        /* offset fixe dans la trame */
	u8_l  length;        /* nombre d'octets comparés */
	u8_l  mask_and_patten[];  /* 2 * length octets : masque, motif */
};
```

Les arbres vendor plus récents l'utilisent pour le magic packet
(`radxa-pkg/aic8800`, `rwnx_msg_tx.c:4704`) : `code = 1`, `offset = 42`,
`length = 6`, douze octets `0xff`. `42 = 14 (Ethernet) + 20 (IPv4) + 8 (UDP)`
est le début du payload d'un paquet magique UDP simple, et ses six premiers
octets sont bien les six `0xff`. Le moteur compare donc **un motif à offset
fixe**, pas un paquet magique au sens cfg80211 : les seize répétitions de la
MAC ne sont pas vérifiées, et une étiquette VLAN, des options IP ou un mot de
passe SecureOn décalent l'offset et font échouer la détection.

Deux différences entre l'arbre livré et `2026_0123` :

- la structure de `2026_0123` intercale un `u16_l code` avant `offset` ; celle
  de `2025_0926` n'en a pas. La disposition attendue par le blob de la carte
  n'est pas vérifiable hors carte : seul le statut du CFM tranchera ;
- le code de `2026_0123` ne vérifie pas l'erreur du CFM autrement qu'en
  loguant, et son `CONFIG_WOWLAN` est un drapeau de compilation par défaut à
  `n` : personne ne l'a validé récemment.

Enfin, le motif est comparé au début du payload **Ethernet** : cela n'a de
sens que si le moteur voit la trame déchiffrée. Le magic packet part en
général en unicast chiffré (ou en broadcast avec la clé de groupe) ; si le
firmware comparait le ciphertext, l'offset 42 ne tomberait jamais juste.
C'est une hypothèse forte du chemin vendor, pas un fait mesuré.

## 5. Chemin de réveil matériel

- **In-band SDIO (DAT1)** : impossible sans toucher `sunxi-mmc`. Le pilote
  hôte n'a que `SYSTEM_SLEEP_PM_OPS(pm_runtime_force_suspend,
  pm_runtime_force_resume)` (`sunxi-mmc.c:1534`) et ne traite jamais
  `MMC_PM_WAKE_SDIO_IRQ` ; le cœur MMC ne pose ce drapeau que si le nœud
  hôte porte `wakeup-source` (`drivers/mmc/core/host.c:382-384`). Il
  faudrait garder horloge, pinctrl et IRQ du contrôleur vivants en s2idle :
  c'est un autre chantier, et le contrôleur MMC1 n'est pas dans un domaine
  toujours alimenté.
- **OOB PG15** : PG15 est EINT-capable (`pinctrl-sun50i-h616.c:624-629`,
  `PG_EINT15`, banque G, GIC SPI 56). `sunxi_pinctrl_irq_set_wake()`
  (`pinctrl-sunxi.c:1237`) relaie à la banque, et `IRQF_NO_SUSPEND` suffit à
  ce que `suspend_device_irqs()` laisse l'action armée : la fonction sort
  immédiatement quand `desc->no_suspend_depth` est non nul
  (`kernel/irq/pm.c:65-71`), sans passer par `IRQCHIP_MASK_ON_SUSPEND`.
  En s2idle la SoC n'est pas éteinte et le banc de pinctrl reste alimenté :
  un front sur PG15 sort le CPU de l'inactivité.

C'est le même modèle que le réveil IR de `sunxi-7.0-veille`, à la différence
que la source est ici une GPIO et non le bloc `s_cir`.

## 6. Ce que le DTS doit porter

`&mmc1` porte déjà `keep-power-in-suspend` dans
`patches/kernel/sunxi-7.0-h96-max/0001-…` (commentaire daté du 2026-11-26 :
sans ce drapeau le suspend du pilote renvoie `-EINVAL`). La prémisse « le DTS
n'a pas `keep-power-in-suspend` » n'est plus vraie.

Il manque la ligne de réveil. Le FDT vendor donne
`wlan_hostwake = <&pio 6 15 …>` et son log de boot dit
`wlan_hostwake gpio=207 assert=1` / `wakeup source is enabled` : gpio 207 =
banque G (6) × 32 + 15. Le nœud mainline ne décrit que `reg = <1>`.

Le patch 0001 ajoute, sur `sdio_wifi: wifi@1` :

```dts
interrupt-parent = <&pio>;
interrupts = <6 15 IRQ_TYPE_EDGE_RISING>;
```

Format sunxi `<bank pin type>` exigé par `sunxi_pinctrl_irq_of_xlate()`
(`pinctrl-sunxi.c:1274-1301`, `intsize < 3` refusé). La polarité vient du
log vendor (`assert = 1`, actif haut) ; elle n'est pas mesurée au scope, et
un type niveau sera peut-être nécessaire si la ligne reste haute jusqu'à la
reprise du bus.

Pas de `wakeup-source` : sur un nœud d'hôte MMC il demanderait le réveil
in-band, que `sunxi-mmc` ne sait pas faire ; le pilote active le wakeup du
device lui-même (`device_init_wakeup`).

## 7. Verdict

**Faisable avec travail vendor**, pas « bloqué par le firmware » : le
firmware expose une API de réveil sur motif, le matériel a une ligne OOB
utilisable et le noyau sait la garder armée. Mais la fonction ne s'annonce
pas avant deux mesures sur carte (§9) :

1. le blob `8800d80_u02` répond-il au `WAKEUP_INFO_REQ` avec la disposition
   de `2025_0926` (sans `code`) ?
2. la puce hisse-t-elle PG15 quand une trame correspond, association et clés
   en place ?

Si (1) échoue, il reste à essayer la disposition `2026_0123` (avec `code`)
ou un firmware plus récent ; si (2) échoue, la voie OOB tombe et il ne reste
que l'in-band, c'est-à-dire un chantier `sunxi-mmc` — autant dire bloqué.

Ce que le travail vendor représente, une fois les mesures faites : les trois
patchs ci-dessous, soit ~120 lignes de pilote, sans changement de firmware
ni de userspace.

## 8. Patchs fournis

`patches/kernel/sunxi-7.0-wowlan/`, ajouté à `parts/modules.nix` après
`sunxi-7.0-veille` :

| Patch | Portée |
|---|---|
| `0001-arm64-dts-allwinner-h96-max-add-aic8800-wake-irq.patch` | IRQ PG15 sur `wifi@1` |
| `0002-net-wireless-aic8800-arm-sdio-wake-line.patch` | demande l'IRQ du DT, `IRQF_NO_SUSPEND`, `device_init_wakeup`, `enable_irq_wake` |
| `0003-net-wireless-aic8800-program-wake-pattern-on-suspend.patch` | `suspend`/`resume` cfg80211 → `WAKEUP_INFO_REQ` (offset 42, 6 octets `0xff`) |

État de validation : `git apply --check` et `patch --dry-run --fuzz=0` OK sur
l'arbre après 3401 et après le DTS H96 ; `checkpatch.pl` 0 erreur,
0 avertissement, 0 check sur les trois. **Aucun build** : pas de compilation
ARM possible ici, les patchs 0002/0003 ne sont donc pas compilés. Le patch
0003 en particulier n'est pas mergeable avant les mesures du §9.

## 9. Protocole de test sur carte

Prérequis : image avec les trois patchs, `mem_sleep` en `s2idle`, interface
`wlan0` associée. Pas de bouton de reset sur cette box : un échec de réveil
se termine au secteur.

### 9.1 Contrôles avant veille

```sh
cat /sys/power/mem_sleep                 # doit afficher [s2idle]
iw dev wlan0 link                        # associe, signal correct
iw phy0 info | sed -n '/WoWLAN/,/^$/p'   # magic packet annonce
grep -i aic8800-wake /proc/interrupts    # l'IRQ du patch 0002 est demandee
grep -i pg15 /sys/kernel/debug/gpio      # ligne vue par le pinctrl (gpio-207)
```

Si `aic8800-wake` n'apparaît pas, le patch 0002 n'a pas trouvé l'IRQ :
`dmesg | grep -i wake` donne le motif (`wake irq lookup failed`).

### 9.2 Armer et suspendre

```sh
iw phy0 wowlan enable magic-packet
iw phy0 wowlan show                      # magic packet: enabled
dmesg -C
rtcwake -m freeze -s 180                 # filet : reprise RTC dans 180 s
```

`rtcwake` arme l'alarme RTC puis passe en `freeze` ; si le paquet magique ne
réveille pas, la box revient au bout du délai et le test ne condamne pas la
carte. Remplacer par `echo freeze > /sys/power/state` seulement quand le
réveil RTC est connu bon.

### 9.3 Envoyer le paquet magique depuis l'hôte

Sur l'hôte, même segment L2 que l'AP, MAC WiFi de la box relevée par
`iw dev wlan0 link` (ou `ip link show wlan0`) :

```sh
nix shell nixpkgs#wakeonlan -c wakeonlan -i 192.0.2.255 AA:BB:CC:DD:EE:FF
```

Sans `wakeonlan`, équivalent Python (broadcast UDP/9, trame complète) :

```sh
python3 - <<'EOF'
import socket, struct
mac = bytes.fromhex("aabbccddeeff")          # MAC WiFi de la box
payload = b"\xff" * 6 + mac * 16             # 102 octets
ip  = b"\x45\x00" + struct.pack("!H", 20 + 8 + len(payload)) + b"\x00\x00\x00\x00\x40\x11\x00\x00"
ip += socket.inet_aton("192.0.2.255") + socket.inet_aton("198.51.100.1")
udp = struct.pack("!HHHH", 9, 9, 8 + len(payload), 0)
eth = b"\xff" * 6 + mac + b"\x08\x00"
s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
s.sendto(eth + ip + udp + payload, ("192.0.2.255", 0))
EOF
```

Le paquet doit partir en broadcast (ou en unicast vers la MAC WiFi si
l'entrée ARP existe encore) : la box reste associée, donc l'AP le livre.

### 9.4 Après reprise

```sh
dmesg | grep -iE 'aic|wake|PM:'          # "host wake" attendu du handler 0002
cat /sys/power/suspend_stats/success
iw dev wlan0 link                        # association conservee ?
```

Lecture des résultats :

| Observation | Interprétation |
|---|---|
| reprise immédiate + `host wake` dans dmesg | chaîne complète OK |
| reprise à 180 s par `rtcwake`, aucun `host wake` | PG15 n'a pas bougé, ou le motif n'a pas armé |
| `wakeup info rejected (…)` au suspend | le firmware refuse `WAKEUP_INFO_REQ` : disposition à revoir (§4) |
| pas de reprise du tout, box muette | la veille a échoué ailleurs : repasser par la série `sunxi-7.0-veille` |

Contrôle négatif indispensable : `iw phy0 wowlan disable`, puis la même
veille avec le même paquet. La box doit rester endormie jusqu'à `rtcwake`.
Sans ce contrôle, un réveil par trafic ordinaire (le handler se déclenche
sur tout front) ne distingue pas le magic packet d'autre chose.

### 9.5 Mesure de la ligne seule

Pour séparer « le firmware n'arme pas » de « la puce n'hisse pas » : garder
la box éveillée, armer `wowlan`, puis surveiller PG15 avec
`gpiomon --chip gpiochip0 15` (ou `/sys/kernel/debug/gpio` avant/après
l'envoi du paquet). Un front isolé après le paquet, hors veille, prouve que
la puce réagit ; son absence renvoie au firmware.

## 10. Points à mesurer (inconnues)

Bloquants pour annoncer la fonction :

1. statut du CFM de `WAKEUP_INFO_REQ` sur le blob `8800d80_u02` (2025_0926) —
   la structure du pilote n'a pas le champ `code` de `2026_0123` ;
2. comportement de PG15 sur trame correspondante, box éveillée puis endormie ;
3. polarité et niveau de PG15 (log vendor `assert=1`, non mesuré) ;
4. le moteur compare-t-il après déchiffrement (offset 42 sur le payload
   Ethernet) ? sinon aucun magic packet chiffré ne peut correspondre.

Non bloquants mais à documenter :

5. consommation en veille avec l'association maintenue
   (`CONFIG_AUTO_POWERSAVE` est à `n`, la puce reste active) ;
6. `reg_dldo1` (vmmc de mmc1) reste-t-il alimenté en s2idle — `keep-power` est
   présent et le suspend SDIO réussit (2026-11-28), mais l'alimentation réelle
   du rail pendant la veille n'est pas mesurée ;
7. le paquet magique doit-il être broadcast (clé de groupe) ou unicast
   (clé par station) pour que le moteur le voie ;
8. compilation réelle des patchs 0002/0003 (aucun build ARM fait ici).

## 11. Références

- `patches/kernel/sunxi-7.0-h96-max/0001-arm64-dts-allwinner-add-sun50i-h618-h96-max.patch`
  (`&mmc1`, `sdio_wifi`, commentaire `keep-power-in-suspend`).
- `patches/kernel/sunxi-7.0-aic8800-kbuild/0001-…` (accroche kbuild).
- `patches/kernel/sunxi-7.0-veille/0002-media-rc-sunxi-cir-wake-on-ir.patch`
  (même modèle de réveil, source IR).
- `docs/chantiers-reveil.md` §3 : mesure du 2026-11-23 et piste WoWLAN ;
  ce document corrige sa conclusion (« petit patch DTS/PM ») — le DTS seul
  ne réveille rien, le pilote ne lit pas `wowlan_config`.
- Noyau 7.0.14 : `net/wireless/sysfs.c`, `net/wireless/nl80211.c`,
  `include/net/cfg80211.h`, `kernel/irq/pm.c`,
  `drivers/pinctrl/sunxi/pinctrl-sunxi.c`,
  `drivers/pinctrl/sunxi/pinctrl-sun50i-h616.c`,
  `drivers/mmc/core/host.c`, `drivers/mmc/host/sunxi-mmc.c`.
- Vendor : `drivers/net/wireless/aic8800_sdio/{aic8800_fdrv,aic8800_bsp}`,
  `radxa-pkg/aic8800@2026_0123` (`rwnx_msg_tx.c:4704`).
