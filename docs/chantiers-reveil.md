# Réveil de la box — IR, WoL, WoWLAN

> **État au 2026-11-28.** Trois chemins sont étudiés ; aucun ne réveille une
> box **réellement hors tension** — c'est un fait de matériel, pas un manque de
> patch (voir §5, « arrêt réel »). Depuis, les mesures ont avancé : le réveil
> **IR** est validé, le **WoL** est implémenté (série `packages/sunxi-gmac/patches/`,
> verdict silicium à faire), le **WoWLAN** reste un chantier vendor non mesuré.

## Résumé

| Chemin | Verdict | Ce qui bloque | Coût |
|---|---|---|---|
| IR (télécommande) | **réveil validé** (IRQ 300, 2026-11-27) ; le CIR mainline coupe l'IR en suspend, patch `sunxi-7.0-veille` déployé | rien pour s2idle | fait |
| WoL Ethernet | **implémenté** (2026-11-27/28, module `sunxi-gmac`) | reste le verdict silicium, cf. `wol-h96.md` §4 | L |
| WoWLAN (AIC8800) | **plausible, non mesuré** | driver et s2idle OK ; `hostwake` PG15 absent du DTS | S/M |

Les trois reposent sur un **état de veille**, pas sur un poweroff complet :
l'AXP1530 coupe les rails à l'extinction, donc ni IR, ni PHY, ni WiFi ne
peuvent réveiller. Le vendor contourne par un super-standby (nœud
`box_start_os` sur la Transpeed, logique boot0/ARISC sur la H96) ; le mainline
n'a que `s2idle` (`freeze`), qui garde la SoC et les périphériques nécessaires
alimentés.

**Le super-standby n'est pas portable en mainline (mesuré 2026-11-28)** : TF-A
2.14 refuse le SCPI sur H616 (`plat/allwinner/sun50i_h616/platform.mk` :
`SUNXI_PSCI_USE_SCPI := 0`, `$(error "H616 does not support SCPI PSCI ops")`),
et crust ne supporte pas le SoC (sa table s'arrête à A64/H5/H6, sans DRAM
self-refresh). `/sys/power/mem_sleep` n'offre que `[s2idle]`. Conclusion :
l'arrêt réel avec réveil IR relève du matériel, pas d'un chantier logiciel.

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

**Fait (2026-11-27)** : la série `sunxi-7.0-veille` garde le bloc IR alimenté et
arme son IRQ ; le réveil par la touche power de la télécommande est mesuré
(`PM: Triggering wakeup from IRQ 300`). Le faux arrêt vendor n'a pas été
poursuivi : voir §5, il n'est pas portable en mainline sur H616.

## 2. WoL Ethernet — implémenté, verdict silicium à faire

Le driver porté `packages/sunxi-gmac/src/sunxi-gmac.c` avait des stubs
(`Not support WOL`) et son suspend coupait MAC/PHY. La série
`packages/sunxi-gmac/patches/` (appliquée au module, pas au noyau) rend
`ethtool -s eth0 wol g` effectif et garde MAC/RX ring/PHY vivants en s2idle
quand `wol` est armé. Le MAC n'a **pas** de filtre magic-packet : toute trame
acceptée par le filtre d'adresse réveille (ARP, SSDP, ping). Protocole de test
et pièges : `wol-h96.md` §4. Coût : `sunxi-gmac.ko` seulement.

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

1. **WoL** : verdict silicium sur `.22` (eth0 câblé, carrier=1) — série
   mergée, coût `sunxi-gmac.ko`.
2. **WoWLAN** : test `freeze` + magic packet, puis DTS `hostwake` (S/M) —
   non mesuré, deux inconnues bloquantes (§10 de `wowlan-h96.md`).
3. **IR** : fait (§1).

## 5. Arrêt réel (rails coupés) — impossible en mainline

« Réveil depuis complètement éteint » n'est pas une option de configuration :
depuis un `poweroff`, ni le CIR, ni le PHY, ni le SDIO ne sont alimentés, et
seul le bouton PWRON de l'AXP redémarre la carte (mesuré 2026-11-26). Le vendor
contourne par un super-standby piloté par boot0 + ARISC (binaires fermés).

Ce chemin **n'est pas portable en mainline sur H616** : TF-A 2.14 refuse le
SCPI (`plat/allwinner/sun50i_h616/platform.mk` : `SUNXI_PSCI_USE_SCPI := 0`,
`$(error "H616 does not support SCPI PSCI ops")`), et crust ne supporte pas le
SoC (A64/H5/H6 seulement, sans DRAM self-refresh). `/sys/power/mem_sleep` ne
propose que `[s2idle]`, ce qui confirme que le firmware ne publie pas
`SYSTEM_SUSPEND`. Un vrai 0 W relève du matériel (MCU always-on, prise
pilotée), pas d'un chantier logiciel.

## Références

- `packages/sunxi-gmac/src/sunxi-gmac.c` (WoL, suspend).
- `patches/kernel/sunxi-7.0-h96-max/0001-arm64-dts-allwinner-add-sun50i-h618-h96-max.patch`
  (`sdio_wifi`).
- `drivers/media/rc/sunxi-cir.c` (mainline).
- [`ir-recepteur.md`](ir-recepteur.md) (récepteur et keymaps).
- [`chantiers-drivers-transpeed.md`](chantiers-drivers-transpeed.md) (port gmac).
