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

Options utiles :

| Option | Défaut | Rôle |
|---|---|---|
| `remotes` | `[]` = toutes | télécommandes activées, par nom de fichier |
| `remoteOverrides` | `{}` | `"0x116" = "KEY_ENTER"` réaffecte, `null` neutralise |
| `extraRemotesDir` | `null` | tables d'une couche privée, même nom = la privée gagne |
| `enableDeviceTree` | `false` | overlay `&ir { status = "okay"; }` |
| `dtCompatible` | `["allwinner,sun50i-h618"]` | `compatible` de l'overlay |
| `inputName` | `"sunxi-ir"` | nom du device d'entrée pour la règle udev |
| `protocols` | `["nec"]` | décodeurs passés à `ir-keytable -p` |

## 3. Plusieurs télécommandes

Un fichier TOML par télécommande dans `modules/services/remotes/`. La table
chargée au boot est la **fusion** de toutes celles activées : rc-core ne garde
qu'un keycode par scancode, donc plusieurs télécommandes cohabitent tant
qu'aucun scancode n'est revendiqué avec deux keycodes différents.

Ajouter une télécommande :

```bash
# 1. relever les scancodes sur la carte, en appuyant sur les touches
dev=$(for d in /sys/class/rc/rc*; do grep -qw nec "$d/protocols" && basename "$d" && break; done)
ir-keytable -s "$dev" -p nec -t

# 2. écrire modules/services/remotes/<nom>.toml
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
ir-keytable -r | grep -c '^scancode'     # 172 attendus (les six tables)
systemctl status ir-keymap               # oneshot, sortie 0
```

Critère d'acceptation : le device dont `protocols` contient `nec` accepte
`-p nec`, et le device CEC le refuse. La preuve finale reste la touche qui
arrive à Kodi — pas `systemctl is-active`.
