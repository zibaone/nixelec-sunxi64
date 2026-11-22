# Netboot de famille sunxi64 — une seule image pour toutes les cartes

## Ce que c'est

`packages.uboot-sunxi64-netboot` (nixelec) : **un** binaire U-Boot, poussé en
RAM par le FEL (~850 Kio, quelques secondes) pour toute la famille. C'est lui
que `havenos load --netboot` envoie ; le payload arrive ensuite par TFTP.

Il était déjà construit depuis le defconfig `transpeed-8k618-t` — c'est ce
binaire qui boote la H96 — seul le nom (`uboot-h96-max-h618-netboot`) laissait
croire à une image par carte.

## Ce qui est commun

- **Un defconfig** : `uboot-transpeed-8k618-t-edge` de nixbian.
- **Un DTS**, celui de la Transpeed, complété par notre patch : nœud `emac1`
  (compatible `allwinner,sun50i-h616-gmac`), mux RMII PA0-PA9, et les quatre
  paires USB EHCI/OHCI.
- **Le pilote GMAC** (`packages/uboot-sunxi-gmac/`) et les quatre pilotes
  USB-Ethernet (smsc95xx, asix/ax88179, r8152).

## Ce qui varie d'une carte à l'autre, et comment c'est absorbé

| Axe | Absorbé comment |
|---|---|
| Adresse MDIO et modèle de PHY | balayage des 32 adresses au démarrage ; l'identifiant décide de la suite |
| PHY AC300 (H96, Transpeed) | quirks vendor appliqués **seulement** si `ID1 = 0x0044` |
| PHY d'une autre marque (Zero3, X96…) | autonégociation générique 100M FD |
| Aucune PHY (unité HS, PHY non alimentée) | le pilote rend `-ENODEV`, U-Boot passe au dongle USB-Ethernet |
| Port USB utilisé par le dongle | les quatre paires EHCI/OHCI sont ouvertes |
| MAC | dérivée de la SID dans le pilote (`02:` + sha256), identique au noyau |

## Ce qui reste réellement par carte

**Les paramètres DRAM**, compilés dans le SPL/BL31 : le training dépend de la
mémoire soudée (DDR3, LPDDR3, LPDDR4). Tant que deux cartes acceptent ceux du
defconfig Transpeed — c'est le cas de la H96 Max H618 — une seule image suffit.
Si une carte refuse de démarrer (DRAM non initialisée, console muette avant
U-Boot), il faut une image **par famille de mémoire**, pas par carte : c'est le
seul axe où l'on ne peut pas décider à l'exécution.

Si un jour un DT différent est indispensable (câblage divergent), l'amont
prévoit `CONFIG_MULTI_DTB_FIT` + `CONFIG_OF_LIST` : plusieurs DT dans le même
binaire, choisi par `compatible`.

## Ajouter une carte

1. Vérifier qu'elle démarre avec cette image (FEL, console) : si oui, rien à
   faire côté netboot.
2. Si son PHY n'est pas une AC300, rien à faire non plus : le balayage MDIO et
   l'autonégociation générique la couvrent. Si elle a un quirk particulier,
   c'est une branche dans `sunxi_gmac_start()`, pas un patch par carte.
3. Si le dongle n'est pas vu, vérifier d'abord que le port est câblé à l'un des
   quatre EHCI/OHCI du DT.

## Mesures

- H96 Max H618 (#2) : aucune PHY ne répond en MDIO, ni par le MAC ni en
  bit-bang, sur les 32 adresses ; le pilote rend `-ENODEV` et la main passe au
  dongle. Le MAC, lui, échantillonne le bus (`0xffff`, ligne tenue haute).
- Transpeed 8K618-T : PHY AC300 à l'adresse 0, autonégociation mal décodée
  (`LPA 0x4461`) — défaut d'unité documenté dans `HANDOFF.md` de HavenOS.
