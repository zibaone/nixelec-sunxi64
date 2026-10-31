# Rechargement sûr du module CEC (item 49)

Conception du barreau de secours CEC et de la reprise du mode HDMI au réveil de
la TV (B7). **Papier seulement** : rien de ce document n'a été rejoué sur une
carte. Les chiffres datés viennent des items 46/49/50 de `docs/backlog.md` et des
mesures B7 du donneur d'ordre ; tout le reste est explicitement marqué
« non mesuré ».

Portée : sunxi64 (Zero 3, H618). Les commandes ne nomment jamais le pilote en
dur — elles le lisent sur le nœud, et le fait publié
`nixelec.platform.cecDriver` (`dw-hdmi-cec` ici, `cec-meson-ao` sur meson64)
reste la référence de configuration. Le service de récupération hotplug
(`hdmi-cec-hotplug`), le kiosque `kodi-gbm` et `nixelec.kiosk.cec` vivent dans
`nixelec-kiosk`, pas dans cette couche.

## 1. Le problème

### 1.1 `modprobe -r` avec un client ouvert

Mesuré le 2026-10-28 (item 49) : le barreau de secours exécutait
`modprobe -r dw_hdmi_cec` alors que Kodi tenait encore `/dev/cec0`. Le module
s'est déchargé, puis la fermeture du descripteur a appelé `cec_devnode_release`
— fonction dont le texte n'était plus mappé — et le noyau est parti en
`Fixing recursive fault but reboot is needed`.

Conséquence pratique : le mécanisme censé sauver une carte sans écran exige une
coupure d'alimentation, c'est-à-dire un accès physique. C'est le pire résultat
possible pour une carte qui n'a ni image ni télécommande.

Ce qui n'est **pas** établi : le mécanisme exact qui a laissé `rmmod` réussir
(refcount de module non pris à l'ouverture, ou désinscription qui n'attend pas
le dernier `close`) n'a pas été identifié. Le correctif de fond reste l'item 46
côté noyau (réarmement / relecture EDID) ; ce document ne fait que rendre le
contournement non destructif.

### 1.2 Un `stop` long casse le sink audio

Mesuré le même jour (item 49) : `systemctl stop kodi-gbm` avec un trou de plus
de ~10 s fait fermer la session kiosque par logind, qui relance la pile audio
utilisateur **derrière** Kodi. Résultat : Kodi tourne sans sink HDMI —
`ActiveAE::InitSink - failed to init` toutes les 5 s pendant 7 h (23:44 →
06:47), `wpctl status` qui ne répond plus. Un stop/start dans la même seconde ne
produit pas ce défaut.

### 1.3 Les deux dangers se cumulent

Un rechargement sûr prend nécessairement plus de 10 s : arrêt, attente de la
sortie du processus, `rmmod`, `modprobe`, redémarrage. **La procédure
franchit donc elle-même le seuil mesuré.** La vérification du sink n'est pas un
cas limite, c'est une étape obligatoire à chaque exécution.

## 2. Procédure

À exécuter en root sur la carte. `cec-ctl` vient de `v4l-utils`. Les commandes
`wpctl`/`systemctl --user` s'adressent au gestionnaire utilisateur du compte
kiosque (`kodi`), d'où le `runuser` + `XDG_RUNTIME_DIR`.

### 0. Pré-vol — obligatoire, voir §3

```sh
systemctl is-active kodi-gbm
pgrep -u kodi -x kodi.bin
cec-ctl -S | grep -E 'Physical Address|Logical Address|Vendor ID'
runuser -u kodi -- env XDG_RUNTIME_DIR=/run/user/$(id -u kodi) \
  wpctl inspect @DEFAULT_AUDIO_SINK@ 2>&1 | grep -E 'node.name|Error'
systemctl show -p RuntimeWatchdogUSec
ss -ltn | grep -E ':(22|8080)\b'
```

Attendu avant de continuer : kiosque actif, un `kodi.bin`, une adresse physique
valide, un sink par défaut, `RuntimeWatchdogUSec=15s`, et au moins un accès
réseau de secours (SSH, ou le serveur web Kodi si `nixelec.kiosk.webServer` est
activé).

### 1. Arrêter le kiosque

```sh
systemctl stop kodi-gbm
```

### 2. Attendre la sortie du processus (borné à 10 s)

```sh
for i in $(seq 1 20); do pgrep -u kodi -x kodi.bin >/dev/null || break; sleep 0.5; done
pgrep -u kodi -x kodi.bin && echo 'ENCORE VIVANT' || echo 'kiosque arrêté'
```

### 3. Dernier recours seulement

Uniquement si l'étape 2 a expiré **et** que `kodi.bin` est encore là. Ce n'est
pas une étape de confort : elle tue Kodi sans lui laisser fermer ses
périphériques.

```sh
pkill -9 -u kodi -x kodi.bin
for i in $(seq 1 10); do pgrep -u kodi -x kodi.bin >/dev/null || break; sleep 0.5; done
pgrep -u kodi -x kodi.bin && echo 'ECHEC: ne pas continuer' || echo 'libéré'
```

Si le processus survit à `SIGKILL`, **arrêter ici** : le descripteur
`/dev/cec0` est probablement encore ouvert et l'étape 5 serait le geste qui tue
la carte.

### 4. Identifier le module CEC sur le nœud

```sh
MOD=$(basename "$(readlink -f /sys/class/cec/cec0/device/driver/module)")
echo "$MOD"     # attendu : dw_hdmi_cec (module, tirets -> soulignés)
```

Le nom vient du noyau, pas du document : sur meson64 il vaut `cec_meson_ao`. Si
le lien `driver/module` n'existe pas (pilote lié en dur), retomber sur le fait
publié `nixelec.platform.cecDriver` et convertir les tirets en soulignés.

### 5. Décharger

```sh
modprobe -r "$MOD"; echo "rc=$?"
ls /dev/cec0 2>&1        # doit avoir disparu
```

Point de non-retour franchi ici — voir §3.

### 6. Recharger

```sh
modprobe "$MOD"; echo "rc=$?"
ls -l /dev/cec0          # doit réapparaître
```

### 7. Redémarrer le kiosque

```sh
systemctl start kodi-gbm
```

### 8. Vérifier l'adresse logique

Après le démarrage de Kodi (l'adapter n'est plus à nous une fois libCEC
installé ; item 46) :

```sh
cec-ctl -S | grep -E 'Physical Address|Logical Address|Vendor ID'
```

Attendu : adresse physique non nulle, LA 4, et `Vendor ID : 0x001582` (libCEC).
Un `Vendor ID : 0x000c03` signifie que le nœud est encore tenu par `cec-ctl` :
la télécommande restera morte.

### 9. Vérifier le sink audio

```sh
runuser -u kodi -- env XDG_RUNTIME_DIR=/run/user/$(id -u kodi) \
  wpctl inspect @DEFAULT_AUDIO_SINK@ 2>&1 | grep -E 'node.name|Error'
```

Un `node.name` qui contient `hdmi` est le bon cas. Pas de sink, ou commande qui
ne rend pas la main (symptôme mesuré le 2026-10-28) ⇒ étape 10.

### 10. Réparer l'audio, kiosque arrêté

```sh
systemctl stop kodi-gbm
runuser -u kodi -- env XDG_RUNTIME_DIR=/run/user/$(id -u kodi) \
  systemctl --user restart pipewire pipewire-pulse wireplumber
for i in $(seq 1 20); do
  runuser -u kodi -- env XDG_RUNTIME_DIR=/run/user/$(id -u kodi) \
    wpctl inspect @DEFAULT_AUDIO_SINK@ 2>&1 | grep -q node.name && break
  sleep 1
done
systemctl start kodi-gbm
```

Puis re-vérifier les étapes 8 et 9, et compter les erreurs de sink dans le
journal :

```sh
journalctl -u kodi-gbm -b --since '-2 min' | grep -c 'ActiveAE::InitSink - failed to init'
```

Attendu : `0`.

## 3. Le point de non-retour

Il est franchi à l'instant précis où **`modprobe -r` retourne 0** (étape 5).
À partir de là :

- le texte de `cec_devnode_release` n'est plus mappé, donc tout descripteur
  encore ouvert sur `/dev/cec0` transforme une fermeture banale en faute
  récursive ;
- il n'existe plus de pilote pour réarmer le CEC ; le seul retour est un
  redémarrage, donc le watchdog s'il est armé (15 s, item 48), sinon la prise de
  courant.

Un second seuil suit immédiatement : si, après l'étape 6, `/dev/cec0` ne
réapparaît pas (bridge HDMI non re-probé, pas d'EDID côté TV) **et** qu'aucun
sink par défaut n'existe, la carte n'a plus ni image ni télécommande. L'écran
est noir et le seul accès restant est le réseau.

À vérifier **avant** de franchir, sans exception :

| Contrôle | Commande | Seuil d'abandon |
|---|---|---|
| Accès réseau de secours | `ss -ltn \| grep -E ':(22\|8080)\b'` | aucun port ⇒ ne pas commencer |
| Watchdog armé | `systemctl show -p RuntimeWatchdogUSec` | `0` ⇒ une faute = coupure physique |
| Aucun `kodi.bin` | `pgrep -u kodi -x kodi.bin` | non vide après §2.3 ⇒ arrêt |
| Nœud CEC présent | `ls -l /dev/cec0` | absent ⇒ le rechargement n'a rien à réparer |
| Sink présent | étape 0 | absent ⇒ réparer (§2.10) **avant** de toucher au module |
| Nom du module connu | étape 4 | vide ⇒ arrêt |
| Possibilité de couper le courant | — | hors watchdog, aucune |

Le watchdog ne couvre qu'un noyau bloqué : il ne rend pas la main sur une carte
dont l'écran est noir et le CEC mort. C'est pour cela que la dernière ligne du
tableau n'est pas négociable.

## 4. Test qui prouve la branche de secours

Protocole reproductible sur la Zero 3. **Aucune de ces étapes n'a été exécutée
pour ce document** : la branche est *non exercée* ici, et le restera tant que le
rejeu n'a pas eu lieu.

État initial exigé : TV allumée et sélectionnée sur le connecteur, Kodi affiché,
étape 0 du §2 entièrement verte.

| # | Geste | Observation attendue | Critère d'échec |
|---|---|---|---|
| T1 | §2 étapes 1→4, puis contrôler `pgrep` | `kiosque arrêté`, `MOD=dw_hdmi_cec` | processus vivant ⇒ branche non testable |
| T2 | §2 étape 5 (`modprobe -r`) | `rc=0`, `/dev/cec0` disparaît, **aucune** ligne `recursive fault` dans `dmesg -T \| tail` | faute noyau ⇒ branche dangereuse, arrêter et rapporter |
| T3 | §2 étape 6 (`modprobe`) | `rc=0`, `/dev/cec0` réapparaît | pas de nœud ⇒ §3 second seuil |
| T4 | §2 étape 7 (démarrage) | Kodi réaffiche, `cec-ctl -S` : PA valide, LA 4, `0x001582` | PA nulle ou `0x000c03` ⇒ CEC non repris |
| T5 | §2 étape 9 (sink) | `node.name` HDMI présent | absent ⇒ T6 |
| T6 | §2 étape 10 (réparation) | sink de retour, `ActiveAE::InitSink` = 0 | sink toujours absent après 20 s, ou `wpctl status` qui pend ⇒ **échec de la branche**, coupure nécessaire |

Le trou de l'étape 1→7 dépasse déjà les ~10 s mesurés : T5/T6 sont donc le cas
nominal, pas une variante. Pour prouver T6 sans dépendre du hasard, une variante
T5' est possible — `systemctl stop kodi-gbm; sleep 12; systemctl start kodi-gbm`
(12 s est un choix de test, non mesuré) — et doit reproduire le sink manquant
avant d'exécuter §2.10.

Un test dont la lecture de retour est impossible (journal vide, commande qui
pend) est **nul** : il ne prouve ni la branche ni son absence, et aucun chiffre
n'en est tiré.

## 5. B7 — le mode d'affichage quand la TV est en veille au boot

Constat rapporté par le donneur d'ordre (non rejoué ici) : TV en veille au boot
⇒ pas d'EDID ⇒ `video=HDMI-A-1:1920x1080@60` ne s'applique pas, la carte
retombe en 576p. `echo detect > /sys/class/drm/card0-HDMI-A-1/status` suivi d'un
redémarrage de Kodi laisse toujours 576p ; seul un reboot TV allumée restaure le
1080p.

Tension à assumer : la mesure B7 dit que ce levier a **déjà** échoué à la main.
La règle ci-dessous ne fait pas mieux sur le fond — elle l'automatise au bon
instant, sur le vrai événement de hotplug, au lieu d'un `echo detect` à
l'aveugle. Si T7 ci-dessous rend encore 576p, le levier est mort et il faut
passer à la variante « attendre l'EDID avant de démarrer Kodi » (§5.4).

### 5.1 La règle udev

Le noyau émet `KOBJ_CHANGE` sur le kobject du connecteur à chaque hotplug, avec
`HOTPLUG=1` dans l'environnement. Fichier complet :

```
# /etc/udev/rules.d/70-hdmi-mode-reprobe.rules
# Repli de mode au réveil de la TV : un seul déclencheur, le hotplug du
# connecteur. Le travail long est délégué à une unité (RUN+ est synchrone).
ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card0-HDMI-A-1", ENV{HOTPLUG}=="1", \
  RUN+="/run/current-system/sw/bin/systemctl --no-block start hdmi-mode-reprobe.service"
```

`card0-HDMI-A-1` se construit depuis `nixelec.platform.hdmiConnector`
(`card0-${hdmiConnector}`) : ne pas le figer si la couche kiosque est réutilisée
sur un autre SoC.

### 5.2 L'unité et le script

Les chemins `/etc/...` ci-dessous ne valent que pour un essai à la main sur la
carte. En NixOS (couche `nixelec-kiosk`) le même corps s'écrit
`services.udev.extraRules = ''…''` pour la règle et
`systemd.services.hdmi-mode-reprobe.script = ''…''` pour le script — le chemin
`ExecStart` devient alors le `writeShellScript` généré.

```ini
# /etc/systemd/system/hdmi-mode-reprobe.service
[Unit]
Description=Re-read the HDMI mode after a hotplug and restart the kiosk
After=systemd-udevd.service

[Service]
Type=oneshot
ExecStart=/run/current-system/sw/bin/hdmi-mode-reprobe
TimeoutStartSec=60
```

```sh
#!/bin/sh
# /run/current-system/sw/bin/hdmi-mode-reprobe
set -eu
CONN=/sys/class/drm/card0-HDMI-A-1
STAMP=/run/hdmi-mode-reprobe.last

# Anti-rebond : la TV peut clignoter (HPD bref). On laisse retomber l'edge.
sleep 5
[ "$(cat "$CONN/status")" = connected ] || exit 0

# Garde de 5 min, même patron que hdmi-cec-hotplug.
last=$(cat "$STAMP" 2>/dev/null || echo 0)
[ $(( $(date +%s) - last )) -ge 300 ] || exit 0
date +%s > "$STAMP"

# Forcer une relecture EDID, puis exiger le mode voulu dans la liste.
echo detect > "$CONN/status" || exit 0
grep -qx '1920x1080' "$CONN/modes" || {
  logger -t hdmi-mode "pas de 1920x1080 dans modes: rien a faire"
  exit 0
}

systemctl stop kodi-gbm
for i in $(seq 1 20); do pgrep -u kodi -x kodi.bin >/dev/null || break; sleep 0.5; done
systemctl start kodi-gbm
```

### 5.3 Risque et garde-fou

- **Risque nommé** : une TV qui fait clignoter HPD (veille profonde, mauvais
  câble, switch HDMI) redémarre le kiosque en boucle. Chaque redémarrage coûte
  ~40 s d'écran noir (mesuré, item 50 : délai entre relance et prise du DRM
  master).
- **Garde-fous, dans cet ordre** : (1) `HOTPLUG=1` seul déclenche, pas tout
  `change` ; (2) relecture de `status` après 5 s, un edge isolé est ignoré ;
  (3) horodatage de 5 min, au plus un redémarrage par fenêtre — le patron de
  `hdmi-cec-hotplug` ; (4) `--no-block` côté règle, pour ne jamais bloquer
  udev ; (5) abandon si `1920x1080` n'est pas dans `modes`, donc pas de
  redémarrage inutile quand l'EDID n'est pas encore là.
- Le garde de 5 min vit dans `/run` : il se réinitialise au reboot, ce qui est
  voulu.

### 5.4 Ce que la règle ne répare pas

Le boot lui-même. Si la TV ne fournit son EDID qu'après le démarrage de Kodi, la
règle attend le hotplug et redémarre le kiosque — d'où un écran noir de ~40 s au
lieu d'un 576p permanent. La variante propre, **non mesurée**, consiste à
attendre l'EDID **avant** de démarrer Kodi : `ExecStartPre` sur `kodi-gbm` qui
boucle (borné, par exemple 60 s) jusqu'à ce que `status` vaille `connected` et
que `modes` contienne `1920x1080`. Les deux se cumulent mal (deux redémarrages
possibles au boot) ; à trancher après rejeu de T7.

### 5.5 Commandes de vérification

```sh
# 1. l'événement existe et porte bien HOTPLUG=1
udevadm monitor --udev --subsystem-match=drm      # puis réveiller la TV

# 2. la règle matche (affiche les RUN+=, ne les exécute pas)
udevadm control --reload                          # après installation de la règle
udevadm test --action=change /sys/class/drm/card0-HDMI-A-1

# 3. l'état du connecteur et les modes réellement vus par le noyau
cat /sys/class/drm/card0-HDMI-A-1/status          # connected
head -3 /sys/class/drm/card0-HDMI-A-1/modes       # 1920x1080 en tête

# 4. ce que le DRM expose, Kodi arrêté (modetest vient de libdrm)
modetest -c | sed -n '/HDMI-A-1/,/^$/p'

# 5. ce que Kodi a réellement pris (la seule preuve d'effet)
journalctl -u kodi-gbm -b | grep -iE 'Found resolution|Mode:'

# 6. l'unité a bien tourné une fois, pas en boucle
systemctl status hdmi-mode-reprobe.service
journalctl -t hdmi-mode -b
```

T7 (le test qui vaut preuve) : TV en veille, booter, constater 576p via (5),
réveiller la TV, attendre l'événement (1), puis relire (3), (4) et (5).
Attendu : `1920x1080` en tête de `modes`, `Found resolution: 1920x1080` dans le
journal. Échec : toujours 576p après le redémarrage ⇒ §5.4, et la règle ne doit
pas être présentée comme un correctif.

## 6. Décisions laissées au donneur d'ordre

1. **Langue et emplacement** : cette note est en français alors que `docs/` est
   en anglais. La replier en anglais, ou assumer le français pour les notes
   d'exploitation.
2. **`nixelec.kodi.cec` vs `nixelec.kiosk.cec`** : l'item 46 nomme encore
   `nixelec.kodi.cec`, `docs/verified.md` et `docs/configuration.md` disent
   `nixelec.kiosk.cec` (couche `nixelec-kiosk`). Ce document suit le second.
3. **Attente bornée** : 10 s (§2.2) est un choix ; la seule mesure est le seuil
   de ~10 s de logind, pas un temps de sortie de `kodi.bin`.
4. **`pkill -9`** : conservé en dernier recours avec un point d'arrêt explicite.
   Une variante plus sûre serait de refuser la suite dès que le processus
   survit, sans jamais envoyer `SIGKILL`.
5. **B7** : automatiser un levier déjà négatif (règle udev) ou attaquer l'ordre
   de démarrage (`ExecStartPre` sur l'EDID) — les deux ne se cumulent pas
   proprement.
6. **B7 n'a pas de numéro de backlog** : à créer, ou à rattacher à l'item 46.
