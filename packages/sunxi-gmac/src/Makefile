# SPDX-License-Identifier: GPL-2.0-only
ccflags-y += -I$(src)/shim

# `obj-m` en dur et non `obj-$(CONFIG_*)` : kbuild retire les variables
# CONFIG_* de l'environnement pour les modules hors arbre, et ces symboles
# n'existent pas dans la config du noyau nixbian (ils sont donc vides). Les
# macros correspondantes sont posées par KCFLAGS dans default.nix.
obj-m += sunxi-gmac.o
obj-m += sunxi-mdio.o
obj-m += sunxi-ephy.o
