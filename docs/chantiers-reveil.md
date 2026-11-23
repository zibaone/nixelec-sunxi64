# Réveil de la box — IR, WoL, WoWLAN

État au 2026-11-23. Objet : démarrer ou réveiller une box H616/H618
(H96 Max H618, Transpeed 8K618-T) sans débrancher le DC. Trois chemins sont
étudiés ; aucun n'est un simple réglage, et **aucun ne réveille une box
réellement hors tension**.

## Résumé

| Chemin | Verdict | Ce qui bloque | Coût |
|---|---|---|---|
| IR (télécommande) | non aujourd'hui | vendor = faux arrêt + ARISC ; `sunxi-cir` mainline coupe l'IR en suspend ; U-Boot sans driver IR | M |
| WoL Ethernet | non avec le driver actuel | `sunxi-gmac` : `Not support WOL` ; suspend coupe MAC/PHY | L |
| WoWLAN (AIC8800) | **plausible** | driver et s2idle OK ; `hostwake` PG15 absent du DTS | S/M |

Les trois reposent sur un **état de veille**, pas sur un poweroff complet :
l'AXP1530 coupe les rails à l'extinction, donc ni IR, ni PHY, ni WiFi ne
peuvent réveiller. Le vendor contourne par un super-standby (nœud
`box_start_os` sur la Transpeed, logique boot0/ARISC sur la H96) ; le mainline
n'a que `s2idle` (`freeze`), qui garde la SoC et les périphériques nécessaires
alimentés.

## 1. IR — le vendor fait un faux arrêt

Le DTB vendor de la Transpeed montre le mécanisme :

- `s_cir@07040000` (`allwinner,s_cir`) : `wakeup-source` et une table de
  10 télécommandes `ir_power_key_code0..9` / `ir_addr_code0..9` ;
- `box_start_os0` (`allwinner,box_start_os`, `start_type = <1>`) : le nœud du
  faux arrêt ;
- le PMIC AXP1530 est aussi `wakeup-source`.

Le driver vendor `sunxi-ir-rx.c` (BSP Allwinner) parse cette table, appelle
`device_init_wakeup()` et, en suspend, `enable_irq_wake()` : le décodeur IR
reste alimenté. Allwinner documente le faux arrêt et la whitelist `s_cir0` ;
sur H3, l'ARISC surveille l'IR pendant le standby.

Côté mainline :

- `drivers/media/rc/sunxi-cir.c` : `sunxi_ir_suspend()` appelle
  `sunxi_ir_hw_exit()` (horloges/reset coupés), `sunxi_ir_shutdown()` aussi ;
  aucun `wakeup-source`, aucun `enable_irq_wake()` ;
- le DTS mainline H616 n'a pas `wakeup-source` sur `&ir` ;
- U-Boot v2025.04 n'a aucun driver IR (`drivers/input`, `arch/arm/mach-sunxi`).
  U-Boot n'est pas le bloqueur premier : il ne tourne pas quand la box est
  éteinte. Même un driver IR dans U-Boot ne démarrerait pas un PMIC coupé.

**Détail mesuré (DTB vendor H96, relevé au banc)** : la table `s_cir` de la
H96 contient `ir_power_key_code1 = <0x08>` / `ir_addr_code1 = <0xfb04>` —
c'est exactement la touche POWER de la télécommande H96 (`0x04/0x08` en
scancode mainline). Le vendor H96 sait donc réveiller la box avec cette
télécommande. La table de la Transpeed a la même adresse mais la commande
`0x1a` : elle ne couvre pas cette télécommande.

Le **boot0 vendor H96** (dump de la tête eMMC) contient le chemin de veille :
les chaînes `rtc standby flag`, `super standby flag`, `find standby flag, jump
to addr`, `set arisc reset to assert/de-assert state`. Le FDT vendor H96 n'a
pas de nœud `box_start_os` (contrairement à la Transpeed), mais le boot0/ARISC
gère le super-standby et le `s_cir` est `wakeup-source`. Les dumps
`boot0.bin`/`boot1.bin` de l'archive vendor sont vides ; c'est la tête eMMC de
la H96 qui porte le vrai boot0.

**Prochaine étape** : le vendor est identifié (table + boot0/ARISC) ; il reste
le chemin mainline : `wakeup-source` sur `&ir`, garder le bloc IR alimenté et
`enable_irq_wake()` dans `sunxi-cir`, tester `freeze` + une touche. C'est un
rebuild noyau aarch64. Le faux arrêt vendor (super-standby/ARISC) est un
chantier séparé, plus lourd ; il n'est pas nécessaire si `s2idle` suffit.

## 2. WoL Ethernet — le driver ne le fait pas

Le driver porté `packages/sunxi-gmac/src/sunxi-gmac.c` :

- `get_wol`/`set_wol` : `TODO: need to support wol`, `Not support WOL` ;
- `sunxi_gmac_suspend()` : `sunxi_gmac_power_off()` + `clk_disable()`.

Donc le MAC/PHY est éteint en suspend ; aucun magic packet n'est reçu. Le
PHY AC300 tire son horloge 24 MHz de PWM5 ; il faut garder la PHY, son
horloge et son rail alimentés, programmer le PMT/magic packet du MAC et
armer l'IRQ de wake. C'est une fonctionnalité du port gmac (P2), pas un
réglage. Sur la H96, `eth0` est sans porteuse (WiFi only) : il faut aussi
rebrancher le câble.

## 3. WoWLAN (AIC8800) — le plus proche

Mesuré sur la H96 le 2026-11-23 :

- `iw phy` annonce WoWLAN magic packet ; `iw phy0 wowlan enable magic-packet`
  passe (`WoWLAN is enabled: wake up on magic packet`) ;
- `/sys/power/state` = `freeze mem`, `mem_sleep` = `[s2idle]` ;
- le driver AIC8800 a `aicbsp_sdio_suspend` avec « keep power while host
  suspended ».

Le FDT vendor H96 a le nœud `wlan` (`allwinner,sunxi-wlan`) avec
`wlan_regon = <&pio 6 18 ...>`, `wlan_hostwake = <&pio 6 15 ...>` et
`wakeup-source` ; son log de boot dit `wlan_hostwake gpio=207 assert=1` et
`wakeup source is enabled`. Notre DTS mainline (`sdio_wifi`) ne déclare que
`reg = <1>` et le commentaire `hostwake = PG15` n'est pas repris. Ajouter
`hostwake`/`wakeup-source` (ou vérifier que l'IRQ SDIO suffit) et tester :

1. `iw phy0 wowlan enable magic-packet` ;
2. `echo freeze > /sys/power/state` ;
3. envoyer un magic packet à la MAC WiFi ;
4. ping/SSH.

Si la box ne revient pas, cycle d'alimentation (pas de bouton). C'est un
petit patch DTS/PM, pas un port de driver.

## 4. Ordre conseillé

1. **WoWLAN** : test `freeze` + magic packet, puis DTS `hostwake` (S/M).
2. **IR** : DTB vendor H96, puis spike `sunxi-cir` + `freeze` (M).
3. **WoL** : pendant le port gmac, PMT + PHY/PWM5 + wake IRQ (L).

## Références

- `packages/sunxi-gmac/src/sunxi-gmac.c` (WoL, suspend).
- `patches/kernel/sunxi-7.0-h96-max/0001-arm64-dts-allwinner-add-sun50i-h618-h96-max.patch`
  (`sdio_wifi`).
- `drivers/media/rc/sunxi-cir.c` (mainline).
- [`ir-recepteur.md`](ir-recepteur.md) (récepteur et keymaps).
- [`chantiers-drivers-transpeed.md`](chantiers-drivers-transpeed.md) (port gmac).
