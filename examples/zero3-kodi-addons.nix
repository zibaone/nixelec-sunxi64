{ ... }:

{
  imports = [ ./zero3-kodi.nix ];

  # Public Kodi add-ons from nixpkgs, installed and enabled at boot. They are
  # already in the binary cache; no private add-on repository is required.
  nixelec.kodi.addons =
    kodi: with kodi; [
      inputstream-adaptive
      inputstream-ffmpegdirect
      inputstream-rtmp
      pvr-iptvsimple
    ];

  nixelec.kodi.autoEnableAddons = [
    "inputstream.adaptive"
    "inputstream.ffmpegdirect"
    "inputstream.rtmp"
    "pvr.iptvsimple"
  ];

  # Optional remote control. The password file must exist at boot; keep this
  # disabled until you provide it through your secret mechanism.
  # nixelec.kodi.webServer = {
  #   enable = true;
  #   passwordFile = "/run/secrets/kodi-web";
  # };
}
