# Récepteur IR — `nixelec.ir`

État au 2026-11-16. Le H616/H618 décode l'IR **dans le SoC** (`ir@7040000`,
`allwinner,sun50i-h616-ir`) : pas de récepteur USB, pas de bit-bang, pas de
LIRC. Le noyau expose un device `rc-core`, `ir-keytable` charge une table
scancode → `KEY_*`, et Kodi voit un périphérique d'entrée ordinaire.

## 1. Ce qui est déjà vrai sur nos noyaux

| Élément | État |
|---|---|
| `CONFIG_IR_SUNXI` | `=y` (nixbian, sunxi64 current et edge) |
| `CONFIG_RC_CORE` | `=y` |
| `CONFIG_IR_NEC_DECODER` | `=m` — **module**, donc élagable |
| Nœud DT | présent dans `sun50i-h616.dtsi`, `status = "disabled"` |
| Broche | PH10, groupe `ir-rx-pin`, fonction `ir_rx` |

**Le piège principal est l'élagage.** nixbian ne garde dans l'arbre de modules
que ce que `boot.kernelModules` déclare ; `ir_nec_decoder` n'a aucun
`compatible` OF, donc il disparaît sans déclaration. Le symptôme est muet : le
device `rcN` existe, `protocols` contient bien `nec`, mais `ir-keytable -p nec`
échoue et rien n'arrive à Kodi. Mesuré sur la Transpeed avant correctif :
`media/rc/` vide, `modules.alias` sans `ir-nec-decoder`.

Le module déclare `ir_nec_decoder` pour cette raison. Ça ne recompile pas le
noyau : le `.ko` est déjà construit, il est seulement filtré à l'installation.

## 2. Activer

```nix
nixelec.ir.enable = true;

# H96 Max H618 : son DTS de carte laisse le nœud en `disabled`.
nixelec.ir.enableDeviceTree = true;

# Transpeed 8K618-T : le DTS mainline active déjà `ir@7040000`, rien à faire.
```

### Le piège de l'overlay : il peut coûter un noyau

Mesuré le 2026-11-16 en activant `enableDeviceTree` sur la H96 : le build
part en `building 'linux-7.0.14.drv'` — plusieurs heures sous émulation.

Cause : `hardware.deviceTree.overlays` accepte deux formes. Avec un `dtsFile`,
nixpkgs appelle `compileDTS`, qui a besoin de `kernel.dev`
(`include-prefixes`) ; cette sortie n'est pas au cache, donc le noyau est
reconstruit pour l'obtenir. Avec un `dtboFile`, il n'y a plus de compilation
DTS : `applyOverlays` applique le binaire au DTB déjà construit avec
`fdtoverlay`, et le build tombe à quelques secondes.

Le module compile donc son `.dtbo` lui-même (`dtc -@ -I dts -O dtb`) et
fournit `dtboFile`. C'est pour ça que `enableDeviceTree` reste bon marché ;
un overlay écrit ailleurs avec un `dtsFile` ne le sera pas.

Options utiles :

Le contrat (`remotes`, `remoteOverrides`, `extraRemotesDir`, `protocols`, la
fusion, la keymap et la règle udev) vit dans `nixelec-common`. Cette couche
ajoute le récepteur `sunxi-ir`, l'overlay DT et le nom d'entrée.

| Option | Défaut | Rôle |
|---|---|---|
| `remotes` | `[]` = toutes | télécommandes activées, par nom de fichier |
| `remoteOverrides` | `{}` | `"0x116" = "KEY_ENTER"` réaffecte, `null` neutralise |
| `extraRemotesDir` | `null` | tables d'une couche carte, publique ou privée, même nom = la supplémentaire gagne |
| `enableDeviceTree` | `false` | overlay `&ir { status = "okay"; }` |
| `dtCompatible` | `["allwinner,sun50i-h618"]` | `compatible` de l'overlay |
| `inputName` | `"sunxi-ir"` (posé ici) | nom du device d'entrée pour la règle udev |
| `protocols` | `["nec"]` | décodeurs passés à `ir-keytable -p` |

## 3. Plusieurs télécommandes

Un fichier TOML par télécommande dans `nixelec-common/modules/remotes/`. La table
chargée au boot est la **fusion** de toutes celles activées : rc-core ne garde
qu'un keycode par scancode, donc plusieurs télécommandes cohabitent tant
qu'aucun scancode n'est revendiqué avec deux keycodes différents.

Ajouter une télécommande :

```bash
# 1. relever les scancodes sur la carte, en appuyant sur les touches
dev=$(for d in /sys/class/rc/rc*; do grep -qw nec "$d/protocols" && basename "$d" && break; done)
ir-keytable -s "$dev" -p nec -t

# 2. écrire nixelec-common/modules/remotes/<nom>.toml
#    [[protocols]]
#    name = "<nom>"
#    protocol = "nec"
#    [protocols.scancodes]
#    0x116 = "KEY_UP"

# 3. déployer : le fichier est repris automatiquement (`remotes = []`)
```

Un conflit non tranché **échoue à l'éval**, en nommant le scancode et les
télécommandes : c'est volontaire, l'erreur doit se voir au build et pas à la
télécommande. `remoteOverrides` tranche. Une surcharge qui ne correspond à
aucun scancode chargé échoue aussi (faute de frappe, ou télécommande
désactivée).

Réserve mesurée ailleurs dans la flotte : une table dont **tous** les
scancodes tiennent sur 8 bits vient d'un récepteur à décodage matériel
(`meson-ir`, `mceusb`) ; le décodeur sunxi rend `adresse << 8 | commande` et
elle ne matchera que si l'adresse NEC vaut `0x00`. Le module émet un
avertissement à l'éval pour ces tables.

Plafond : 512 scancodes par device rc sur le noyau 7.0.14 ; au-delà,
`ir-keytable` rend `Cannot allocate memory` et **annonce quand même** le
nombre de tentatives. La mesure fiable est
`ir-keytable -r | grep -c '^scancode'`.

## 4. Ce que fait le service

`ir-keymap` (oneshot) choisit le device **par protocole**, jamais par numéro —
sur ces SoC le CEC HDMI peut occuper `rc0` et l'IR `rc1`, l'ordre n'est pas
stable :

```bash
for d in /sys/class/rc/rc*; do grep -qw nec "$d/protocols" && dev=$(basename "$d"); done
ir-keytable -s "$dev" -c -p nec -w /etc/rc_keymaps/remotes.toml
```

Une règle udev tague le périphérique d'entrée `ID_SEAT=seat0`,
`ID_INPUT_KEYBOARD=1` et retire `ID_INPUT_POINTINGSTICK` (faux positif du
classifieur : le bitmask d'une télécommande ressemble à un stick). Sans ce
ticket, libinput — donc Kodi — n'énumère jamais le device.

`ir-keytable` n'est **pas** un démon : il configure `rc-core` une fois puis
sort. Le chemin des événements est entièrement dans le noyau.

## 5. Vérification

Sur la carte, après déploiement :

```bash
dmesg | grep -i sunxi-ir                 # « initialized sunXi IR driver »
ls /sys/class/rc/                        # rcN + le device CEC s'il existe
cat /sys/class/rc/rc0/protocols          # doit contenir [nec]
ir-keytable -r | grep -c '^scancode'     # 172 dans la couche publique (six tables)
systemctl status ir-keymap               # oneshot, sortie 0
```

Critère d'acceptation : le device dont `protocols` contient `nec` accepte
`-p nec`, et le device CEC le refuse. La preuve finale reste la touche qui
arrive à Kodi — pas `systemctl is-active`.

Un consommateur peut ajouter une septième table (H96, NEC adresse `0x04`,
12 touches, pas de pavé numérique) : la carte mesure alors **184** scancodes.
La table vit dans la couche consommatrice, pas ici ; la couche publique garde
ses six tables et 172 scancodes.

## 6. Réveil

Le récepteur IR ne réveille pas la box sous le mainline : `sunxi-cir` coupe
le bloc en suspend (`sunxi_ir_suspend()` → `sunxi_ir_hw_exit()`) et le DTS
n'a pas `wakeup-source`. Le vendor utilise un faux arrêt (`box_start_os`) et
l'ARISC pour garder l'IR vivant. U-Boot v2025.04 n'a pas de driver IR.

Détail des trois chemins (IR, WoL Ethernet, WoWLAN), preuves et prochaines
étapes : [`chantiers-reveil.md`](chantiers-reveil.md).
