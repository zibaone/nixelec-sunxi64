# MAC déterministe dérivée de la SID (eFUSE du SoC).
#
# Ces boîtes H616/H618 n'ont **aucune MAC programmée en usine** : le dump complet
# des 256 octets lisibles de la SID ne contient ni OUI ni adresse (mesuré sur
# H96 et Transpeed, 2026-11-15). C'est l'U-Boot vendor qui en inventait une et
# la transmettait au noyau par `mac_addr=` ou par un fixup du DTB. Notre chaîne
# extlinux ne fait ni l'un ni l'autre, donc le driver tombe dans
# `eth_random_addr()` : l'adresse change à chaque démarrage, et toute
# réservation DHCP ou tout inventaire de flotte devient impossible.
#
# La SID contient en revanche un identifiant **unique par unité** :
#
#   H96       : 00 20 80 33 08 48 00 4c 3c 47 46 01 90 21 73 64
#   Transpeed : 00 20 80 33 08 48 00 0c 04 c1 05 01 91 1b 78 40
#               └── identiques (ID SoC) ──┘ └── différents (unique) ──┘
#
# On en dérive un condensat tronqué à 5 octets, préfixé de `02:` — adresse
# **localement administrée** (bit 1 du premier octet), donc sans risque
# d'empiéter sur un OUI constructeur. Même puce → même MAC, à chaque boot, sans
# configuration par machine, et cette identité survit à un reflashage (contrairement
# à une clé d'hôte ou à un `machine-id`, qui n'existent de surcroît qu'après le
# premier démarrage — c'est-à-dire trop tard pour le premier bail DHCP).
#
# Aucune modification du driver n'est nécessaire : la MAC est appliquée avant que
# le réseau ne démarre, ce qui est exactement l'ordre attendu par dhcpcd et
# systemd-networkd.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.macFromSid;

  outil = pkgs.writeShellScriptBin "nixelec-mac" ''
    set -eu
    sid=/sys/bus/nvmem/devices/sunxi-sid0/nvmem

    if [ ! -r "$sid" ]; then
      echo "nixelec-mac : SID illisible ($sid)" >&2
      exit 1
    fi

    # Condensat des 16 premiers octets (ID SoC + identifiant unique), tronqué à
    # 5 octets. Le condensat évite qu'une SID vierge (tout à zéro sur certaines
    # unités) produise une MAC nulle ou une MAC en collision avec une autre carte.
    #
    # `head -c` et non `dd bs=1 count=16` : l'attribut binaire nvmem ne rend
    # qu'UN octet par lecture de 1 octet, donc dd bs=1 renvoie un seul zéro sur
    # toutes les cartes et toutes dérivent la même MAC (collision observée le
    # 2026-11-15 : deux SBC avec 02:6e:34:0b:9c:ff, et le même bail DHCP).
    h=$(head -c 16 "$sid" | sha256sum | cut -c1-10)
    mac="02:$(echo "$h" | cut -c1-2):$(echo "$h" | cut -c3-4):$(echo "$h" | cut -c5-6):$(echo "$h" | cut -c7-8):$(echo "$h" | cut -c9-10)"

    if [ "''${1:-}" = "--print" ]; then
      echo "$mac"
      exit 0
    fi

    # L'interface du MAC interne : celle dont le pilote est sunxi-gmac. On ne
    # touche pas aux autres (dongle USB, WiFi), qui ont leur propre adresse.
    iface=
    for d in /sys/class/net/*; do
      i=$(basename "$d")
      drv=$(readlink -f "$d/device/driver" 2>/dev/null || true)
      case "$drv" in
        *sunxi-gmac*) iface=$i; break ;;
      esac
    done

    if [ -z "$iface" ]; then
      echo "nixelec-mac : interface sunxi-gmac introuvable, rien à faire" >&2
      exit 0
    fi

    ip link set dev "$iface" address "$mac"
    echo "nixelec-mac : $iface -> $mac"
  '';
in
{
  options.nixelec.macFromSid = {
    enable = lib.mkEnableOption ''
      MAC déterministe dérivée de la SID du SoC, appliquée avant le démarrage du
      réseau. À activer sur les cartes sans MAC gravée (H616/H618 de ces boîtes) ;
      une carte qui a une vraie adresse en eFUSE ou dans son DTS n'en a pas besoin
    '';
  };

  config = lib.mkIf cfg.enable {
    systemd.services.mac-from-sid = {
      description = "MAC déterministe dérivée de la SID (aucune MAC gravée sur cette carte)";
      # `network-pre.target` seul ne suffit pas : c'est une cible *passive*, et
      # rien ne la tire quand le pare-feu NixOS est désactivé (cas du kiosque).
      # L'unité restait donc `inactive` au boot et la MAC aléatoire du noyau
      # était conservée. On l'attache aussi à `systemd-networkd.service` : il
      # la tire, et le `before=` ci-dessous garantit qu'elle s'exécute avant la
      # configuration des liens.
      wantedBy = [
        "network-pre.target"
        "systemd-networkd.service"
      ];
      before = [
        "network-pre.target"
        "dhcpcd.service"
        "systemd-networkd.service"
        "NetworkManager.service"
      ];
      # Une unité systemd n'hérite pas du PATH interactif : sans cette ligne,
      # `dd`, `sha256sum`, `cut`, `readlink` et `ip` sont introuvables au boot
      # (observé : le service échoue au démarrage et réussit à la main).
      path = [
        pkgs.coreutils
        pkgs.iproute2
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = "${outil}/bin/nixelec-mac";
    };

    environment.systemPackages = [ outil ];
  };
}
