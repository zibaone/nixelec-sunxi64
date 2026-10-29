# Exemple de base + pilote WiFi UWE5622.
#
# Sert à deux choses : montrer comment brancher le WiFi de la carte, et donner
# une configuration de référence au CI pour construire et pousser la closure du
# pilote et du firmware. Aucun SSID ni PSK : wpa_supplicant n'est pas démarré.
{ ... }:

{
  imports = [ ./zero3-base.nix ];

  nixelec.wifi.enable = true;

  # Le régulateur radio n'est réglé que pour une carte qui a du WiFi.
  boot.kernelParams = [ "cfg80211.ieee80211_regdom=FR" ];
}
