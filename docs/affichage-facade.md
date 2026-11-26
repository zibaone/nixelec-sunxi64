# Afficheur de facade FD650/FD655 — broches, protocole, arbitrage

État au 2026-11-16 : **les deux cartes affichent**, vérifié à l'écran et après
redémarrage. Ce document fixe **ce qui est mesuré** et ce qui reste ouvert,
pour qu'une session ne reparte pas d'une hypothese fausse. Il prime sur les
notes de prompt du chantier, qui contenaient une erreur de banque (voir §2).

## 1. Ce que sont ces afficheurs

Deux fils, pas d'I2C materiel du SoC : `CLK` et `DAT`, bit-banges. La puce est
de la famille Fuda Hisi (FD650B-S / FD655). Le DTS vendor de chaque carte
declare un noeud dedie, avec un pilote vendor different de l'autre carte :

| Carte | Noeud vendor | Pilote vendor | Proprietes |
|---|---|---|---|
| H96 Max H618 | `leds { compatible = "allwinner,fd655_dev"; }` | `fd655_dev` (kernel, log `FD655: …` au boot) | `leds_clk`, `leds_dat` |
| Transpeed 8K618-T | `fd628_dev { compatible = "allwinner,fd628_dev"; }` | `fd628` (kernel, symboles `FD628_WrD`, `FD628_SET_BRIGHTNESS`) | `fd628_gpio_clk`, `fd628_gpio_dat` |

Le pilote vendor de la Transpeed ne lit **que** `fd628_gpio_clk` et
`fd628_gpio_dat` (verifie par recherche des chaines dans l'Image noyau du
firmware stock : `fd628_gpio_stb` est absent, 0 occurrence). C'est donc un
pilote 2 fils, pas le SPI 3 fils d'OpenVFD.

## 2. Broches — établies, et une correction

### H96 Max H618 — **PH2 = CLK, PH3 = DAT** (confirmé à l'écran)

Le DTS vendor donne `<0x27 0x07 0x02 0x00>` et `<0x27 0x07 0x03 0x00>`, soit
*(phandle, banque 7, broche 2/3, fonction 0)*. **La banque 7 est PH, pas PI** :
la numerotation Linux des banques est PA=0 … PH=7, PI=8. Trois preuves
concordantes :

1. le pilote vendor imprime sur la carte, au boot :
   `FD655: leds_clk = 226` et `FD655: leds_dat = 227` — or 226 = 7×32+2 ;
2. le pinctrl du noyau en cours nomme `pin 226 (PH2)` et `pin 227 (PH3)` ;
3. l'ecriture d'une trame sur 226/227 **allume l'afficheur** (mesure du
   2026-11-15, segments puis chiffres lus a l'ecran).

La note « PI2/PI3 » du prompt de chantier etait donc fausse : elle venait d'une
lecture de `0x07` comme « 8e banque ». Une erreur de banque sur un GPIO est
exactement le risque que le chantier voulait eviter.

> **Énumération des chips (2026-11-16)** : ne pas se fier à l'index
> `/sys/class/gpio` ; `gpiodetect` tranche. Sur la H96 comme sur la Transpeed,
> le PIO `300b000.pinctrl` (288 lignes) est `/dev/gpiochip1` ; `/dev/gpiochip0`
> est le r_pio `7022000.pinctrl` (32 lignes). Un `fd6xx --chip /dev/gpiochip0`
> sur la H96 échoue en `GPIO_V2_GET_LINE_IOCTL` (ligne hors du r_pio), et
> `/sys/class/gpio/gpiochip0 -> 300b000.pinctrl` ne reflète pas l'index du
> chardev. Vérifier avec `gpiodetect` avant de changer la donnée de carte.
>
> **Confirmé le 2026-11-16** : `fd6xx --chip /dev/gpiochip1 --clk 226 --dat 227
> --brightness 3 write H96` allume bien l'écran H96. Le service au boot
> écrivait avant la création du GPIO (l'écran restait éteint alors que `fd6xx`
> sortait 0) ; il démarre maintenant après `dev-gpiochip1.device`
> (`nixelec-common 722e300`).

### Transpeed 8K618-T — **PI11 = CLK, PI12 = DAT**, push-pull obligatoire, **résolue le 2026-11-16**

Le DTB vendor du firmware stock (`H618.apollo-p17.8K618-T_100M_12_FD650`,
decompresse, FDT a l'offset 144384) donne :

```dts
fd628_dev {
    compatible = "allwinner,fd628_dev";
    fd628_gpio_clk = <0x23 0x08 0x0b 0x00>;   /* banque 8 = PI, broche 11 */
    fd628_gpio_dat = <0x23 0x08 0x0c 0x00>;   /* banque 8 = PI, broche 12 */
    pinctrl-0 = <0x6e>;
    status = "okay";
};

fd628_dev@0 {
    pins = "PI11", "PI12";
    function = "gpio_out";
    drive-strength = <0x14>;
};
```

`PI11` = GPIO 267, `PI12` = GPIO 268 (8×32+11 / +12).

#### Ce que dit vraiment la chaîne vendor (établi le 2026-11-16)

Le pilote n'est pas un module : `aml_fd628` est **compilé dans le noyau**.
Faits lus dans l'Image du noyau et dans le rootfs vendor de l'image stock :

| Fait | Preuve |
|---|---|
| Pilote lié au noyau, dérivé Amlogic | `aml_fd628.parmtype=test:int`, `aml_fd628.description=fd628 Driver`, `aml_fd628.license=GPL` (section modinfo de l'Image) |
| Build **2 fils** : la troisième ligne a été retirée | `fd628_gpio_stb` : **0 occurrence** dans toute l'image ; `can't request gpio of fd628_stb` : **0** ; `fd628_gpio_clk`/`fd628_gpio_dat` et leurs deux messages d'erreur : présents |
| Le contenu de la dalle est écrit par un démon | `init.sun50iw9p1.rc` : `service vfdsrv /system/bin/vfdsrv` (class main, root, oneshot, `u:r:vfdsrv:s0`) |
| Nœud caractère exposé par le pilote | `chmod 0666 /dev/fd628_dev` + `/sys/module/aml_fd628/parameters/{test,stress,time}` |
| LED d'état, pas la dalle | `gpio_para` : `normal_led` = PH6, `standby_led` = PH7 |

Le pilote amont éponyme (`aml_fd628.c`, noyau Amlogic) est **3 fils** et
s'arrête au probe si `fd628_gpio_stb` manque. Le vendor l'a donc modifié pour
ce build, et la puce n'est pas un FD628 (qui exige un STB) mais un **FD650** —
cohérent avec le nom de l'image (`..._12_FD650`) et avec le marquage du PCB.

#### La cause : le mode de pilotage, pas les broches

Les broches du DTB étaient **bonnes** du premier coup. Ce qui manquait est le
mode électrique : le pilote vendor pilote les deux lignes en **sortie franche
(push-pull)**, avec un `udelay(1)` par phase, alors que `fd6xx` les demandait
en open-drain + pull-up — le réglage qui marche sur la H96. Sur la Transpeed,
la carte n'a pas de pull-up : la ligne ne remonte jamais, la puce ne voit que
des zéros, la dalle reste éteinte. En push-pull, elle s'allume immédiatement.

C'est aussi ce qui explique la mesure « PI12 = 0 en pull-down » : sans
pull-up, cette lecture était attendue, puce présente ou non. Le test ne
distinguait rien.

Deuxième différence, mesurée à l'écran : **l'adresse `0x68` porte le chiffre
de gauche** sur la Transpeed, alors que c'est celui de droite sur la H96.
Troisième, matérielle : la dalle n'a que **quatre positions** (et pas de
glyphe K), d'où le texte « 8618 » et non « 8K618 ».

#### Le protocole vendor, lu au désassembleur

Tout le reste est **identique à la H96**, ce que le désassemblage confirme
(Image du noyau à l'offset `0x184b000`, symboles récupérés par
`vmlinux-to-elf`, `FD628_Write_Byte` à `0xffffffc01093a2a4`) :

- START : DAT haut, CLK haut, puis DAT bas ; STOP : CLK haut puis DAT haut ;
- octets **MSB d'abord**, **9 tops**, DAT relâché en entrée sur le 9e ;
- `udelay(1)` par phase (0x10c7 = `__const_udelay` d'1 µs) ;
- `fd628_dev_open` écrit `0x48` puis `0x01` ; la luminosité passe par `0x68` ;
- `FD628_WrDisp_AddrINC` écrit `0x66` suivi des octets d'affichage et laisse
  la puce incrémenter l'adresse — mais cette forme **n'a pas marché** sur la
  carte, alors que l'écriture adresse par adresse (`0x68`, `0x6A`, `0x6C`,
  `0x6E`) fonctionne. L'outil garde donc les transactions séparées.

Détail qui vaut d'être noté : la police du vendor (`FD628Service.c`) donne
`3 = 0x79` et `4 = 0x74`, qui s'affichent « E » et « h » sur cette dalle. La
police **standard** (`3 = 0x4F`, `4 = 0x66`) donne bien « 3 » et « 4 ». Les
constantes du vendor sont fausses pour cet écran.

#### Vérification

À l'écran, pas dans les journaux : « 8618 » après `nixos-rebuild switch`, puis
**après un vrai redémarrage** (uptime 0:00, service `active`, sortie 0, eth0
UP, MAC `02:a1:15:a7:4f:94` inchangée, 0 % de perte vers la passerelle).

### Où sont les DTBs vendor (inventaire vérifié)

Les DTBs extraits du firmware stock vivent dans le bench, pas dans le dépôt :

```
~/bench/h96-2026-11-12/fw/fdt/        7 .dtb + 7 .dts décompilés
  fdt-144384.dtb        67 669 o  1babe2735d1e  DTB vendor COMPLET de la Transpeed, porte fd628_dev
  fdt-2523136.dtb       67 669 o  1babe2735d1e  identique
  fdt-92584960.dtb      67 669 o  1babe2735d1e  identique
  fdt-1232092.dtb       18 901 o  75cd3a032563  DTS SoC vendor `sun50iw9` (= vendor-a de l'archive)
  fdt-2195676.dtb       18 901 o  75cd3a032563  identique
  fdt-1952736320.dtb     4 532 o  05f3ce206029  overlay de carte, PMU/régulateurs (= vendor-b)
  fdt-2328576.dtb        4 532 o  05f3ce206029  identique
```

Trois tailles, trois contenus : le seul qui porte un nœud d'affichage est le
DTB complet (3 065 lignes une fois décompilé). Le DTB vendor de la **H96** est
un fichier distinct : `~/bench/h96-2026-11-12/vendor-fdt.dts` (2 540 lignes,
`model = "sun50iw9"`), et c'est le seul à porter `fd655_dev`.

**Piège d'inventaire, payé le 2026-11-15** : un `find ~/bench -maxdepth 3` rate
`fw/fdt/` (profondeur 4) et fait conclure à tort qu'aucun dump ne contient de
nœud d'affichage — conclusion fausse qui a envoyé chercher un DTB inexistant
pendant une session. Chercher par **contenu** (`grep -rl "fd628\|fd655" ~/bench`),
jamais par liste de chemins.

## 3. Protocole mesuré (H96)

TWI maison, 2 fils, **la puce n'ACK pas** :

- START (DAT descend alors que CLK est haut), octet **MSB d'abord**, puis un
  **9e top d'horloge** que la puce ne tire pas mais qui est **obligatoire** :
  sans lui des octets sont perdus silencieusement (mesure : une trame de 8 tops
  par octet laisse l'afficheur eteint, la meme en 9 tops fonctionne) ;
- commande `0x48` = controle, donnee = `(luminosite + 1) << 4 | 0x01` ;
- adresses de donnees `0x68, 0x6A, 0x6C, 0x6E, 0x70` (5 grilles) ;
- **l'adresse 0x68 est le chiffre le plus a droite** (mesure : « 1 » ecrit sur
  0x68 apparait a droite, « 2 » ecrit sur 0x6E apparait a gauche) ;
- octet de donnee = `DP G F E D C B A` (bit 0 = segment A) : `0x06` = « 1 »,
  `0x5B` = « 2 », `0x7F` = « 8 ».

Deux reglages diffèrent d'une carte a l'autre, et ce sont eux qui coutent une
session quand on les suppose identiques :

| Reglage | H96 | Transpeed |
|---|---|---|
| Mode des deux lignes | **push-pull** depuis le 2026-11-19 (voir ci-dessous) | **push-pull** (aucun pull-up sur la carte) |
| Sens des adresses | `0x68` = chiffre de **droite** | `0x68` = chiffre de **gauche** |
| Nombre de positions | 5 | **4** |

**H96 : open-drain + pull-up ne suffit plus avec le noyau de famille
(2026-11-19).** La donnée de carte était `open-drain` depuis le bring-up vendor.
Après passage au noyau de famille, la dalle reste éteinte alors que `fd6xx`
sort 0 : les lignes **sont** demandées et pilotées (`gpio-226 | fd6xx | out hi`,
`gpio-227 | fd6xx | out lo` dans `/sys/kernel/debug/gpio`), le chip est le bon
(`/dev/gpiochip1` → `300b000.pinctrl`, PH2/PH3 `UNCLAIMED` dans le pinmux), mais
le pull-up interne ne ramène pas la ligne à l'état haut. En `--push-pull`,
l'écran affiche immédiatement. `pushPull = true` est donc posé dans la donnée
de carte H96, et non dans l'outil : c'est un fait de câblage vu par ce noyau,
pas un défaut de `fd6xx`.

Les trois réglages sont des options de l'outil (`--push-pull`, `--ltr`) ou du module
(`nixelec.frontPanel.pushPull`, `.leftToRight`, `.text`).

## 4. Arbitrage : pilote noyau ou espace utilisateur

**Retenu : espace utilisateur (`nixelec-common/packages/fd6xx`), pour la premiere iteration.**

Le chemin noyau naturel — `i2c-gpio` sur les deux GPIO + `tm16xx_i2c`
(compatible `fdhisi,fd650`, present dans le jeu de patches Armbian
`general-driver-tm16xx-led-driver.patch`) — a d'abord ete **bloque par une
mesure** : en mode bidirectionnel, `i2c-gpio` lit l'ACK de l'esclave et rend
`-ENXIO` au premier octet ; la puce n'ACK pas.

**Correction du 2026-11-23** : ce n'est pas une impasse du noyau. Le mainline
sait depuis 2023 ne pas lire SDA/SCL (`i2c-gpio,sda-output-only`,
`i2c-gpio,scl-output-only`), precisement pour les controleurs FD650 et
derives ; le driver tiers `leds-fd6551` documente cette combinaison
(`reg` `state`/`icon-set`/`dig1..4`, soit `0x48`/`0x66`/`0x68..0x6E` sur le
fil). Le `-ENXIO` mesure venait donc du mode bidirectionnel, pas de la puce.

Ce qui reste vrai : le chemin noyau demande un module hors arbre (pas une
recompilation complete du noyau, mais un build par noyau de famille) et un
`.dtbo` ; il apporte la description dans le DT et les icones en LED class,
mais il itere beaucoup moins vite que `fd6xx`. L'outil en espace utilisateur
reste le bon choix pour figer le protocole et mesurer les bits ; le module
noyau redevient un candidat serieux pour l'etat final, sans le cout « patch
noyau a chaque essai » qui avait motive le choix initial.

Ce que le pilote noyau apporterait, et qui reste l'objectif si l'afficheur
devient un produit : survie aux mises a jour, description dans le DT, pas de
daemon, et des icones en LED class. Ce qu'il coute : un module hors arbre a
maintenir par noyau de famille (un build de module, pas une recompilation
complete), un `.dtbo`, et un acces aux GPIO qui ne peut pas casser un boot.
L'outil en espace utilisateur permet d'iterer en secondes et de figer le
protocole avant d'ecrire le module — c'est l'ordre qui a du sens.

## 5. Verification

`fd6xx` est installe par le module et utilisable a la main :

```sh
fd6xx test                    # tous les segments
fd6xx write 1234              # chiffres, de gauche a droite
fd6xx blank
```

Ce qui compte est **ce qui s'affiche**, jamais ce que l'outil annonce. Sur la
H96 : `test` allume tout, `write 1234` affiche 1234 (mesure du 2026-11-15).
Sur la Transpeed : rien, cf. §2.

## 6. Module

`nixelec-common/modules/front-panel.nix`, option `nixelec.frontPanel`,
**desactivee par defaut**. L'unite est `oneshot` + `RemainAfterExit`, sans
dependance `before=` sur le boot, et son script sort toujours en 0 : un
afficheur ne peut pas empecher une carte de demarrer. Les broches
(`chip`, `clk`, `dat`) sont des **donnees de carte** : l'eval refuse
`enable = true` s'il en manque une. Les valeurs mesurees sont posees dans
`parts/configurations.nix` (H96 : 226/227 ; Transpeed : 267/268).

## 7. Icones et colonne : modele generique

`fd6xx` expose maintenant un rendu complet, `show`, qui compose le texte et
des bits arbitraires dans une seule trame :

```sh
fd6xx --chip /dev/gpiochip1 --clk 267 --dat 268 --push-pull --ltr \
      --digits 4 --base 0x68 --stride 2 \
      show --text 8618 --bit 0x66:0x20 --clear 0x66:0x40
```

Chaque `ADDR:MASK` est applique a l'octet de l'adresse : si l'adresse est une
grille de chiffre (`base + stride*i`), le bit est OR/AND dans l'octet du
chiffre — c'est le cas d'une colonne portee par le point decimal ; sinon
l'outil emet une transaction separee. `--bit` allume, `--clear` eteint.
`show` est volontairement **un rendu complet** : la puce n'a pas de lecture de
la RAM d'affichage, donc toutes les icones connues du profil doivent etre
passees, actives ou non, sinon une ancienne icone reste allumee.

Un `--dry-run` global imprime la trame composee sans ouvrir le GPIO : c'est le
moyen de verifier les arguments generes par Nix sur le poste x86, avant tout
deploiement.

```sh
fd6xx ... --dry-run show --text 8618 --bit 0x66:0x20
# grid[0] addr=0x68 byte=0x7f ... extra addr=0x66 byte=0x20
```

Deux commandes servent a decouvrir les bits, pas a les deviner :

```sh
fd6xx ... test                       # tous les segments, colonne incluse
fd6xx ... scan --scan-delay 800      # un bit a la fois sur les 5 grilles
fd6xx ... scan --addr 0x66 --scan-delay 800   # un bit a la fois sur une adresse
fd6xx ... raw 0x66 0x20              # ecriture brute, pour sonder
```

`scan` affiche sur stderr `grid=N addr=0x.. mask=0x..` avant chaque bit : on
regarde la dalle, on note ce qui s'allume, puis on restaure le texte avec
`write` ou `show`.

Cote Nix, le profil de dalle est une donnee de carte :

```nix
nixelec.frontPanel = {
  enable = true;
  chip = "/dev/gpiochip1";
  clk = 267;
  dat = 268;
  pushPull = true;
  leftToRight = true;
  text = "8618";

  layout = {
    digits = 4;
    digitBase = 104;  # 0x68
    digitStride = 2;
    icons = {
      eth  = { address = 102; mask = 32; };   # 0x66 / 0x20
      wifi = { address = 102; mask = 64; };   # 0x66 / 0x40
    };
  };

  icons = [ "eth" ];          # etat statique au boot
  status.enable = true;       # eth0/wlan0 -> icones, timer 30 s
};
```

Les noms suivent le vocabulaire OpenVFD (`alarm`, `usb`, `play`, `pause`,
`colon`, `eth`, `wifi`, `hdmi`, `cvbs`, `sd`, etc.). Une icone absente de
`layout.icons` n'existe pas sur cette dalle : la demander dans `icons` fait
echouer l'eval. Le module genere un service `front-panel-status` (timer, pas
de daemon) qui lit `/sys/class/net/<if>/operstate` pour Ethernet et
`iw dev <if> link` pour le WiFi, puis reecrit l'etat complet. Le timer couvre
aussi la fenetre ou le bring-up video reinitialise le banc PIO.

## 8. H96 : sept icones mesurees sur `0x66`

Constat visuel de l'utilisateur (2026-11-23) : **la H96 a une colonne (`:`) et
des icones** (`usb`, `alarm`, `play`, `pause`, `lan`, `wifi`). Ce n'est donc pas
une dalle purement chiffres, meme si le DTS vendor ne declare que
`leds_clk`/`leds_dat` et aucune table d'icones.

Deux sources independantes donnaient le meme ordre **partiel** des bits, sans
avoir ete mesurees sur cette carte : le driver tiers `leds-fd6551` (`clock` bit
0, `usb` 1, `pause` 2, `play` 3, `colon` 4, `net` 5, `wifi` 6, en precisant
lui-meme qu'il faut experimenter) et la table vendor de la Transpeed
(`alarm` 0x01, `usb` 0x02, `play` 0x04, `pause` 0x08, `colon` 0x10, `eth`
0x20, `wifi` 0x40). Elles concordaient sur `usb` = 0x02 et `colon` = 0x10 et
divergeaient sur play/pause : c'etait une hypothese de depart.

**Mesure du 2026-11-23, bit par bit sur la H96 (`fd6xx ... scan --addr 0x66`),
ordre confirme a l'ecran :**

| Bit | Masque | Icône |
|---|---|---|
| 0 | `0x01` | `alarm` |
| 1 | `0x02` | `usb` |
| 2 | `0x04` | `pause` |
| 3 | `0x08` | `play` |
| 4 | `0x10` | `colon` |
| 5 | `0x20` | `lan` |
| 6 | `0x40` | `wifi` |

Toutes sur l'adresse **102 (`0x66`)**. Controle du 2026-11-25 sur la H96 #2 :
`--bit 102:16` allume le « : », `--clear 102:16` l'eteint, `--bit 102:32`
allume `lan` — les chiffres ne bougent pas.

**Ne jamais ecrire `0x7f` (ni `0xff`) sur `0x66` :** la valeur qui porte les
sept bits a la fois **eteint la dalle**. C'est ce qui a fait croire, le
2026-11-25 au matin, que « l'ecriture de `0x66` eteint l'ecran » et fait
retirer les icones du profil ; un bit isole s'ecrit normalement. Corollaire
pour `show` : il efface les icones connues une par une (`--clear ADDR:MASK`),
jamais par une ecriture globale.

La consequence pratique est importante : l'octet d'icones n'est **pas** une
grille de chiffre. La disposition des commandes FD650/FD655 le donne :

| Registre (datasheet, `reg`) | Commande sur le fil (`reg × 2`) | Role |
|---|---|---|
| `state` 0x24 | **0x48** | controle/luminosite |
| `icon-set` 0x33 | **0x66** | octet des icones |
| `dig1` 0x34 | **0x68** | chiffre 1 |
| `dig2` 0x35 | **0x6A** | chiffre 2 |
| `dig3` 0x36 | **0x6C** | chiffre 3 |
| `dig4` 0x37 | **0x6E** | chiffre 4 |
| `dig5` 0x38 | **0x70** | chiffre 5 (H96, extrapole : le driver tiers s'arrete a `dig4`) |

Le driver tiers `leds-fd6551` documente exactement ces registres
(`state`, `icon-set`, `dig1`..`dig4`) et un jeu d'icones par defaut. Les
adresses mesurees sur nos deux dalles (`0x48`, `0x68`..`0x70`) coincident :
**l'octet d'icones est donc `0x66`, pas `0x70`**. C'est aussi ce que fait le
vendor Transpeed : son `write_buffer[0]` (masque d'icones) est ecrit juste
avant les quatre chiffres.

Consequence pour le service : `write`/`blank` n'ecrivent que `0x68`..`0x70` et
**ne touchent jamais `0x66`** ; c'est `show` qui porte les icones, une par une
(`--bit ADDR:MASK` / `--clear ADDR:MASK`). Le profil de la H96 pose donc les
sept icones dans `layout.icons` et laisse `icons = [ ]` : rien d'allume en
permanence, ce sont `status` (lan/wifi d'apres `operstate` et `iw link`) et
`clock.colonIcon` (le « : » une seconde sur deux) qui pilotent l'octet.

Procedure de mesure :

```sh
# 1. segments des chiffres, puis tous les bits de l'octet d'icones
fd6xx --chip /dev/gpiochip1 --clk 226 --dat 227 test
fd6xx --chip /dev/gpiochip1 --clk 226 --dat 227 raw 0x66 0x7f

# 2. l'octet d'icones : un bit a la fois, en commencant par les candidats
#    usb=0x02 et colon=0x10
fd6xx --chip /dev/gpiochip1 --clk 226 --dat 227 scan --addr 0x66 --scan-delay 1200

# 3. si la colonne est portee par le point decimal d'une grille, balayer
#    les cinq grilles
fd6xx --chip /dev/gpiochip1 --clk 226 --dat 227 scan --scan-delay 1200
```

`scan`/`show`/`raw` sont dans la version courante de `fd6xx` ; sur une
installation qui porte encore l'ancien binaire, `seg` ne sait pas ecrire
`0x66` (il ne couvre que `0x68`..`0x70`) : il faut deployer le module a jour
ou copier le nouveau binaire.

Profil H96 — les candidats `usb`/`colon` viennent des deux tables ci-dessus,
mais **les masques restent a confirmer a l'ecran** :

```nix
layout = {
  digits = 5;              # H96 : cinq grilles mesurees
  digitBase = 104;         # 0x68, chiffre de droite sur la H96
  digitStride = 2;
  icons = {
    usb   = { address = 102; mask = 2; };   # 0x66 / 0x02 (candidat)
    colon = { address = 102; mask = 16; };  # 0x66 / 0x10 (candidat)
  };
};
icons = [ "colon" "usb" ];
```

Tant que la mesure n'est pas faite, ne pas activer `icons` : une mauvaise
adresse ou un mauvais bit peut eteindre un chiffre, et le service de boot doit
rester en texte seul. La Transpeed, elle, a un candidat vendor pour le meme
octet `0x66` (`0x01 alarm`, `0x02 usb`, `0x04 play`, `0x08 pause`,
`0x10 colon`, `0x20 eth`, `0x40 wifi`) mais **rien n'est mesure a l'ecran** :
c'est une hypothese de travail, pas un profil.
