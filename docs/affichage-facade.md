# Afficheur de facade FD650/FD655 — broches, protocole, arbitrage

État au 2026-11-15. Ce document fixe **ce qui est mesuré** et ce qui reste
ouvert, pour qu'une session ne reparte pas d'une hypothese fausse. Il prime sur
les notes de prompt du chantier, qui contenaient une erreur de banque (voir §2).

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

### Transpeed 8K618-T — **PI11 = CLK, PI12 = DAT** (DTS vendor), chaîne vendor 2 fils, dalle muette

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

#### Correction d'une conclusion trop forte

La mesure « PI12 = 0 en entrée pull-down » ne prouve **pas** l'absence de
puce : un FD628 a un DIO *push-pull*, qui lit 0 même présent et alimenté. Le
test ne vaut que pour une puce à DAT open-drain **avec** pull-up interne — le
cas du FD655 de la H96, qui lit 1. Sur un FD650 il reste valable, mais il ne
distingue pas « puce absente » de « puce non alimentée ».

#### Établi / hypothèses / non vérifié

**Établi** : broches déclarées PI11/PI12 ; chaîne vendor entièrement 2 fils ;
démon `vfdsrv` sur `/dev/fd628_dev` ; LED d'état sur PH6/PH7 ; aucune trame
essayée n'allume la dalle.

**Hypothèses**, par ordre de plausibilité :
1. **Dalle non alimentée** — rail commuté absent du nœud DT, qui ne porte que
   clk/dat (ni `regulator`, ni `enable`).
2. **Révision différente** — ce DTB est celui de la référence `apollo-p17` ;
   rien ne prouve que la carte .51 soit exactement celle-là.
3. **Trame différente** — le 2 fils du vendor n'est ni le TWI FD650 à 9 tops
   ni le SPI FD628 que `fd6xx` implémente.

**Non vérifié** :
- la tension d'alimentation de la puce (aucune mesure au multimètre) ;
- la correspondance visuelle broche/PCB sur la carte .51 ;
- le désassemblage de `FD628_WrByte` du noyau vendor, qui donnerait la trame
  exacte (symboles présents dans l'Image, non exploités).

**Prochaine étape, dans cet ordre** : (1) mesurer VCC et GND sur la puce,
calibré sur la H96 qui fonctionne ; (2) si VCC est absent, chercher l'enable
dans le rootfs vendor ; (3) sinon, désassembler `FD628_WrByte` et rejouer sa
trame exacte. Le balayage de broches reste **en dernier** : un GPIO qui
commande un régulateur ne se sonde pas à l'aveugle.

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

## 4. Arbitrage : pilote noyau ou espace utilisateur

**Retenu : espace utilisateur (`packages/fd6xx`), pour la premiere iteration.**

Le chemin noyau naturel — `i2c-gpio` sur les deux GPIO + `tm16xx_i2c`
(compatible `fdhisi,fd650`, present dans le jeu de patches Armbian
`general-driver-tm16xx-led-driver.patch`) — est **bloque par une mesure** :
`i2c-gpio` exige un ACK de l'esclave et rend `-ENXIO` au premier octet ; la
puce n'ACK pas. Le noyau ne peut donc pas la piloter sans un pilote dedie.

Ce que le pilote noyau apporterait, et qui reste l'objectif si l'afficheur
devient un produit : survie aux mises a jour, description dans le DT, pas de
daemon. Ce qu'il coute : un pilote bit-bang maison (pas i2c-gpio), une
recompilation de noyau aarch64 par iteration (~45 min a 3 h sous emulation
sur ce poste), et un acces aux GPIO qui ne peut pas casser un boot. L'outil en
espace utilisateur permet d'iterer en secondes et de figer le protocole avant
d'ecrire le pilote — c'est l'ordre qui a du sens.

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

`modules/services/front-panel.nix`, option `nixelec.frontPanel`, **desactivee
par defaut**. L'unite est `oneshot` + `RemainAfterExit`, sans dependance
`before=` sur le boot, et son script sort toujours en 0 : un afficheur ne peut
pas empecher une carte de demarrer. Les valeurs par defaut des broches sont
celles de la H96 (226/227) ; une carte sans afficheur laisse `enable = false`.
