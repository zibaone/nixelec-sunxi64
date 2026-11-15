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

### Transpeed 8K618-T — **PI11 = CLK, PI12 = DAT** (DTS vendor), mais **aucune puce sur ces broches au boot**

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

**Mais la puce ne repond pas sur ces broches sous NixOS** : en configurant
PI12 en entree avec pull-down cote SoC, la ligne lit **0** — comme PI13/PI14,
qui ne sont reliees a rien — alors que sur la H96 la meme mesure sur PH3 lit
**1** (le pull-up interne de la puce, 150-400 uA, gagne). Autrement dit :
rien n'est electriquement present sur PI11/PI12 au moment du test. Aucune
trame (FD650 ou FD628, MSB ou LSB, 2 fils, 100 kHz ou 300 Hz) n'allume quoi
que ce soit.

L'afficheur existe pourtant : il s'allumait sous Android, et la puce FD650B-S
est soudée sur cette carte.

Deux hypotheses restent, a departager **avant** de sonder d'autres broches :

1. **La dalle est alimentee par une ligne que le pilote vendor commande**
   (regulateur ou GPIO d'enable absent du noeud DT, donc invisible dans les
   deux proprietes). Une puce non alimentee ne tire pas ses pull-ups, ce qui
   explique exactement la mesure.
2. **Les broches diffèrent sur cette revision** : le DTB est celui de la
   reference `apollo-p17`, pas forcement celui de la carte.

Prochaine experience (non faite) : balayer prudemment les GPIO voisins en
sortie pendant que PI12 est en entree pull-down, et garder le premier qui fait
passer PI12 a 1 — c'est la puce qui se signale elle-meme, sans supposition sur
le protocole. A faire hors du boot, avec `fd6xx` en mode manuel.

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
