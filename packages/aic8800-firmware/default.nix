{
  lib,
  stdenvNoCC,
  fetchurl,
}:

# Firmware du AIC8800D80 SDIO (H96 Max H618, SDIO1).
#
# Le pilote vient du backport in-tree de la série Armbian sunxi-7.0 (patch
# nixbian 3401) : il lit ses blobs dans `CONFIG_AIC_FW_PATH`, codé en dur à
# `/lib/firmware/aic8800_sdio` par `aic8800_bsp/Makefile`, sans sous-répertoire
# par variante. Les noms ci-dessous sont ceux de la table `fw_8800d80_u02`
# (`aic_bsp_driver.c`), sélectionnée quand la puce répond `chip_rev` U02 sur
# `0xc8a1:0x0082`. Les tables voisines (`fw_8800d80_h_u02`, `fw_8800dc*`,
# `fw_8800d80x2`) demandent d'autres fichiers : un `IS_CHIP_ID_H` ou un
# `unsupport chip rev` dans dmesg signifie que ce jeu n'est pas le bon.
#
# Épinglé à la révision `armbian/firmware` que nixbian utilise déjà comme
# source de firmwares (`metadata/nix/firmware.nix`), pour que les blobs soient
# ceux que la couche plateforme distribue. Rien n'est réhébergé ici : le paquet
# ne fait que les récupérer et les poser au chemin attendu par le noyau.
let
  rev = "617ccae735b1bff23b2d90ee711786ed42b8dc18";
  base = "https://raw.githubusercontent.com/armbian/firmware/${rev}/aic8800/SDIO/aic8800D80";

  blob =
    name: sha256:
    fetchurl {
      url = "${base}/${name}";
      inherit sha256;
    };

  blobs = {
    "fmacfw_8800d80_u02.bin" =
      blob "fmacfw_8800d80_u02.bin" "1gxzc7n4c1qzmavyf1ij3kvd0zgj7ng3bmbsqa43mp70m3rmns05";
    "fw_adid_8800d80_u02.bin" =
      blob "fw_adid_8800d80_u02.bin" "0mhsxqpmh386d9qhqy8n9fccs26b6dcnpbgk97q9bi6d5z8cn9m5";
    "fw_patch_8800d80_u02.bin" =
      blob "fw_patch_8800d80_u02.bin" "082dgyhxknl3a406ardss04wp6napi2hva55kfn4y8k8zaqrkpb4";
    "fw_patch_table_8800d80_u02.bin" =
      blob "fw_patch_table_8800d80_u02.bin" "1lq9darrvrvfclrss2jjhihprcanz77phf0ybyf1wckkn5jdaf9r";
    "lmacfw_rf_8800d80_u02.bin" =
      blob "lmacfw_rf_8800d80_u02.bin" "0bin61jmlynz6zaksyb402cjiqd34pqh187zx9x0cq5glr24hwpy";
    "aic_userconfig_8800d80.txt" =
      blob "aic_userconfig_8800d80.txt" "1idwimmyrm91rx95rrl4cba5j8gyk8q6gi5j6f57i0ypqiym221i";
  };
in
stdenvNoCC.mkDerivation {
  pname = "aic8800-firmware";
  version = "8800d80_u02";

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    ${lib.concatStrings (
      lib.mapAttrsToList (
        name: path: "install -Dm644 ${path} $out/lib/firmware/aic8800_sdio/${name}\n"
      ) blobs
    )}
    runHook postInstall
  '';

  meta = {
    description = "Firmware and RF userconfig for the AIC8800D80 SDIO WiFi (chip_rev U02)";
    homepage = "https://github.com/armbian/firmware";
    # Blobs propriétaires AICSemi, distribués par armbian/firmware. Leur
    # licence de redistribution propre n'a pas été vérifiée : d'où le fetch
    # plutôt qu'un fichier versionné dans ce dépôt public.
    platforms = lib.platforms.linux;
  };
}
