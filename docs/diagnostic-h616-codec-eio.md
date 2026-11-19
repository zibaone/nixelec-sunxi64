# Diagnostic — `sun4i-codec` H616 : ecriture PCM en `-EIO`

Date : 2026-11-19. Carte : Transpeed 8K618-T (Allwinner H618, noyau 7.0.14,
`sun50i-h618-transpeed-8k618-t.dtb`). Carte son `h616-audio-codec`,
PCM `hw:0,0` (`CDC PCM Codec-0`).

## Symptome

Toute lecture PCM echoue immediatement, sans message noyau :

```
$ aplay -D hw:0,0 --buffer-time=200000 /root/tone5s.wav
aplay: pcm_write:2191: write error: Input/output error
```

`speaker-test` et Kodi (`snd_pcm_writei returned -5`) donnent le meme `-EIO`.
Les `hw_params` sont acceptes, `dmesg` ne contient aucune erreur du pilote.

## Chaine causale mesuree

1. **L'`-EIO` ne vient pas du DMA ni du codec** : c'est le timeout de
   `wait_for_avail()` dans `sound/core/pcm_lib.c` (seul `-EIO` du chemin
   d'ecriture), journalise en `pcm_dbg()` donc invisible sans
   `CONFIG_DYNAMIC_DEBUG` — ce qui explique l'absence de message noyau.

2. **Le DMA ne progresse pas.** Pendant l'echec :

   ```
   # /proc/asound/card0/pcm0p/sub0/status
   hw_ptr   : 32        appl_ptr : 72000
   # grep 3002000.dma /proc/interrupts
   15:        12          0          0          0    GICv2  74 Level  3002000.dma-controller
   ```

   `hw_ptr` est fige a 32 trames = 128 octets = la profondeur de la FIFO TX,
   et le compteur d'IRQ du controleur DMA n'avance plus : le DMA a rempli la
   FIFO puis s'est arrete faute de `DRQ`, la FIFO ne se vidant pas.

3. **La FIFO ne se vide pas parce que le bloc numerique du DAC est eteint.**
   Pendant l'echec, via `/sys/kernel/debug/regmap/5096000.codec/registers` :
   `000:=00000000` (`DAC_DPC`, bit 31 `EN_DA` = 0), `314:=00000133`. Et
   `/sys/kernel/debug/asoc/H616 Audio Codec/5096000.codec/dapm/*` :
   tous les widgets `Off`, `DAC Enable: Off`, `bias_level: Standby`.

4. **Pourquoi DAPM ne met rien sous tension.** `DAC Enable` (alimentation
   `EN_DA`) n'est atteignable que par les routes
   `{ "Left DAC", NULL, "DAC Enable" }`, donc le widget DAC doit etre
   alimente ; son `power_check` exige un chemin de sortie complet, et le seul
   chemin vers `LINEOUT` traverse les commutateurs de route des mixers
   (`"DAC Playback Switch"`, `"DAC Reversed Playback Switch"`). Or
   `dapm_set_mixer_path_status()` (`sound/soc/soc-dapm.c`) lit la valeur du
   controle au moment du bind et fait `p->connect = !!val` : a 0, la route
   est ouverte et rien n'est alimente. Ces bits valent 0 au reset du H616
   (`0x314` = `0x00000133`).

## Preuve par A/B/C (aucune modification noyau)

Trois etats de mixeur, meme fichier, meme commande
(`aplay --buffer-time=200000 --period-time=50000`) :

| Etat | `0x314` | `0x000` (EN_DA) | IRQ DMA | `hw_ptr` | resultat |
|---|---|---|---|---|---|
| 1. defaults de boot (`DAC Playback Switch` off, line out off, vol 0) | `00000133` | `00000000` | 12 | fige | `write error: Input/output error` |
| 2. seul `numid=5` (DAC Playback Switch) on | `00220d33` | `80000000` | 36 | 57792 | succes, **silencieux** (`0x310`=`0015c000`) |
| 3. etat 2 + `numid=3` on + `numid=2`=26 (defaults BSP) | `00220d33` | `80000000` | 136 | 57760 | succes, audible (`0x310`=`0015e81a`) |

L'etat 1 reproduit la panne, l'etat 2 la corrige : le seul verrou de l'`-EIO`
est la route DAPM `DAC -> mixer`. L'etat 3 montre un **second defaut
distinct** : les bits d'activation de la sortie ligne (`0x310` bits 13 et 11)
et son volume (bits 0-4, 0 = mute) sont aussi a zero au reset, donc le
playback « reussit » mais reste muet.

## Hypotheses eliminees

- **Horloges** : pendant la lecture, `audio-codec-1x` est a 24 576 000 Hz,
  `enable=1 prepare=1 hardware=Y` (`/sys/kernel/debug/clk/clk_summary`) ;
  `bus-audio-codec` actif. Hors de cause.
- **Plomberie DMA (canal / DRQ / maxburst)** : le canal est bien lie
  (`/sys/kernel/debug/dmaengine` : `dma0chan0 | 5096000.codec:tx`) et le DMA
  transfere les 128 premiers octets — la ligne de requete fonctionne. Le
  blocage vient de l'absence de `DRQ`, pas d'un descripteur refuse.
- **Sequence d'activation de la FIFO** : `0x010` passe de `01604f00` a
  `01604f10` (bit 4 `DAC_DRQ_EN`) au demarrage du flux ; la sequence du
  pilote est donc bien executee.
- **Conflit avec les patches du projet** : aucun patch de `patches/kernel/`
  ne touche `sound/soc/sunxi/sun4i-codec.c` ; la serie Armbian 7.0 n'y ajoute
  qu'un mux de source de capture pour A10/A20 (`drv-asoc-sunxi-sun4i-codec-
  select-capture-source.patch`), sans rapport avec le H616.

## Correctif

`patches/kernel/0006-asoc-sun4i-codec-h616-analog-out-defaults.patch`
(declare dans `localPatches` de `parts/modules.nix`) : au probe, pour le
quirk H616 uniquement (`analog_out_defaults`), le pilote programme les
defaults du BSP Allwinner (`sunxi_codec_init()`) —

- `0x314` : `LMIX_LDAC | RMIX_RDAC` (DAC L/R -> mixers L/R, c.-a-d.
  `DAC Playback Switch`) ;
- `0x310` : `LINEOUTL_EN | LINEOUTR_EN` et `LINEOUT_VOL = 0x1a`, comme le BSP.

Le probe precede `snd_soc_register_card()`, donc `dapm_set_mixer_path_status()`
lit ces valeurs au bind et la route est connectee des le premier flux : plus
de blocage FIFO, plus d'`-EIO`, et le mixeur n'a pas besoin d'etre restaure
par l'espace utilisateur.

Verifie : le patch s'applique sans `fuzz` sur un arbre ou la serie Armbian
(`drv-asoc-sunxi-sun4i-codec-select-capture-source.patch`) est deja
appliquee (`patch -p1 --dry-run`, offsets uniquement).

Controles passes localement (aucun build noyau) :

- `nix build .#nixosConfigurations.transpeed-8k618-t.config.nixelec.kernelPackage.configfile`
  reussit : toute la serie (Armbian + patches locaux + vendor) s'applique sur
  la source reelle du noyau et `olddefconfig` passe ;
- la derivation noyau reference bien le fichier
  (`nix derivation show <drv> | grep 0006-asoc-sun4i-codec-h616`) ;
- `nix flake check --system x86_64-linux --no-build` : `all checks passed`.
  (Un premier passage peut echouer sur `path ...-kernel is not valid` : c'est
  `--no-build` qui refuse de realiser la copie en store du dossier
  `patches/kernel` ; le realiser par une evaluation qui stringifie les chemins,
  puis relancer.)

## Verification apres CI

1. `nix eval .#nixosConfigurations.transpeed-8k618-t.config.boot.kernelPackages.kernel.drvPath`
   puis, sur le runner ARM, `nix build .#packages.aarch64-linux.transpeed-8k618-t-sd-image`.
2. Flash, demarrage **a froid** (sans restauration ALSA), puis :

   ```
   grep -i codec /proc/asound/cards
   awk '/^000:|^310:|^314:/{print}' /sys/kernel/debug/regmap/5096000.codec/registers
   # attendu : 000 = 80000000 (EN_DA), 310 = 0015e81a, 314 = 00220d33
   aplay -D hw:0,0 --buffer-time=200000 /root/tone5s.wav   # doit rendre 0
   speaker-test -D hw:0,0 -t sine -f 440 -l 1              # aucun "Write error"
   ```

3. Verifier l'absence d'`-EIO` dans `journalctl -u kodi -b` et l'audibilite
   reelle sur la prise jack (mesure physique, non automatisable).
4. Regression autres cartes : `orangepizero3` et `h96-max-h618` utilisent le
   meme noyau de famille ; le quirk n'est arme que pour
   `allwinner,sun50i-h616-codec`, les autres codecs ne changent pas.

## Ce qui reste incertain

- **Non compile ni demarre ici** : aucun build noyau local (interdit) ; la
  preuve est la mesure « espace utilisateur equivalent » (A/B/C ci-dessus) et
  la lecture du code DAPM. La compilation est a valider en CI.
- **Mute en cours de flux** : si un client remet `DAC Playback Switch` a 0
  pendant la lecture, DAPM rouvre la route et l'`-EIO` peut revenir (c'est le
  comportement ASoC standard d'un interrupteur de route). Non couvert : cela
  demanderait de decoupler l'alimentation du DAC des commutateurs analogiques
  (routes sans controle), changement de topologie DAPM non teste ici.
- **Valeurs de sortie ligne** : `LINEOUT_VOL = 0x1a` (-7.5 dB) et l'unicite du
  chemin stereo sont reprises du BSP, pas mesurees a l'oscilloscope.
- Le fichier DTS de la carte n'a pas eu besoin d'etre modifie
  (`allwinner,audio-routing = "Line Out", "LINEOUT"` est deja present).

## Etat laisse sur la carte

Les essais A/B/C ont modifie le mixeur **en cours de boot** : la carte est
actuellement dans l'etat 3 (`DAC Playback Switch` on, `Line Out Playback
Switch` on, volume 26), donc l'audio y fonctionne sans le patch. Pour
reproduire la panne d'origine, reboot a froid, ou :

```
amixer -c0 cset numid=5 off,off   # DAC Playback Switch
amixer -c0 cset numid=3 off,off   # Line Out Playback Switch
amixer -c0 cset numid=2 0         # Line Out Playback Volume
```

`/root/tone5s.wav` est laisse sur la carte pour la verification post-CI.
