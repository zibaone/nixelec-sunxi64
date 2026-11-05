{
  lib,
  writeShellApplication,
  coreutils,
  gawk,
  util-linux,
}:

# Banc d'essai sunxi64 : inventaire de la carte, noyau de test déposé sur la
# partition d'amorçage (p1), retour au boot normal.
#
# Le script vit dans le dépôt (`./bench`) pour rester lisible et testable hors
# Nix ; ce paquet ne fait que fixer son interpréteur (la première ligne du
# script est retirée, `writeShellApplication` pose la sienne) et son PATH.
let
  source = builtins.readFile ./bench;
  lines = lib.splitString "\n" source;
in
writeShellApplication {
  name = "bench";
  runtimeInputs = [
    coreutils
    gawk
    util-linux
  ];
  text = lib.concatStringsSep "\n" (lib.drop 1 lines);
}
