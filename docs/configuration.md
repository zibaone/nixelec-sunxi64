# Configuration

The public modules expose ordinary NixOS options under `nixelec.*`. Import the
board, the Kodi profile and the image module, then set the options you need.

```nix
{
  imports = [
    nixelec.nixosModules.orangepizero3
    nixelec.nixosModules.kodi-gbm
    nixelec.nixosModules.sd-image
  ];

  nixelec.kodi.enable = true;
}
```

Start from [`examples/zero3-kodi.nix`](../examples/zero3-kodi.nix) for a base
appliance, or from
[`examples/zero3-kodi-addons.nix`](../examples/zero3-kodi-addons.nix) when you
also want the public add-ons.

## Kodi

| Option | Default | Purpose |
|---|---|---|
| `nixelec.kodi.enable` | `false` | Enable the Kodi GBM kiosk (no compositor). |
| `nixelec.kodi.package` | `pkgs.kodi-gbm` | Kodi package to launch; the `kodi-gbm` module replaces it with the v4l2-request kiosk build. |
| `nixelec.kodi.user` | `kodi` | User that runs Kodi. |
| `nixelec.kodi.home` | `/var/lib/kodi` | Kodi home directory. |
| `nixelec.kodi.extraGroups` | video, audio, input, render, tty | Extra groups for the Kodi user. |
| `nixelec.kodi.extraKernelParams` | `[]` | Extra kernel parameters, for example `video=HDMI-A-1:1920x1080@60`. |
| `nixelec.kodi.uiSounds` | `false` | Disable Kodi UI sounds (`guisoundmode=0`, empty sound skin). |
| `nixelec.kodi.homeMenu.hidden` | `[]` | Estuary home-menu entries to hide. |
| `nixelec.kodi.addons` | `null` | Function that adds packages to the Kodi package set. |
| `nixelec.kodi.autoEnableAddons` | `[]` | Add-on IDs enabled at boot through JSON-RPC. |
| `nixelec.kodi.webServer.enable` | `false` | Kodi web server, HTTP Basic. |
| `nixelec.kodi.webServer.passwordFile` | `null` | Runtime file containing the web-server password. |
| `nixelec.kodi.webServer.username` | `kodi` | Web-server username. |
| `nixelec.kodi.webServer.port` | `8080` | Web-server port. |
| `nixelec.kodi.cec.enable` | `false` | HDMI-CEC helper services. |

### Add-ons

`nixelec.kodi.addons` receives the Kodi package set. nixpkgs uses hyphens in
attribute names, while Kodi uses dots in add-on IDs:

```nix
nixelec.kodi.addons =
  kodi:
  with kodi;
  [
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
```

Kodi leaves add-ons installed by Nix disabled until an install event occurs. The
`autoEnableAddons` oneshot calls `Addons.SetAddonEnabled` over the local JSON-RPC
socket after Kodi starts. It stays independent from the Kodi restart cycle so a
`nixos-rebuild switch` cannot leave Kodi stopped.

### Web server

Enable the web server only when the password file exists at boot:

```nix
nixelec.kodi.webServer = {
  enable = true;
  passwordFile = "/run/secrets/kodi-web";
};
```

The file is read by a root oneshot and is never copied into the Nix store. If the
file is missing or empty, `kodi-settings` fails before Kodi starts; this is
intentional.

### CEC

```nix
nixelec.kodi.cec = {
  enable = true;
  standbyPcOnTvStandby = "ignore";
  reprobeOnBoot = true;
  hotplugRecovery = false;
};
```

| Option | Default | Purpose |
|---|---|---|
| `device` | `/dev/cec0` | CEC device used by the helpers. |
| `connector` | `card0-HDMI-A-1` | DRM connector checked before a recovery restart. |
| `standbyPcOnTvStandby` | `ignore` | Keep the appliance on, or follow the TV (`default`). |
| `manageAdapterSettings` | `true` | Create or update the Kodi CEC adapter file before start. |
| `reprobeOnBoot` | `true` | Reload `dw-hdmi-cec` when the physical address is invalid. |
| `hotplugRecovery` | `false` | Restart Kodi after a hotplug when the address is invalid. |

`hotplugRecovery` is a workaround, not a kernel fix. It is opt-in because it
restarts Kodi.

## WiFi

```nix
nixelec.wifi = {
  enable = true;
  interface = "wlan0";
  ssid = "MyNetwork";
  pskFile = "/run/secrets/wifi-psk";
  powerSaveOff = true;
};
```

| Option | Default | Purpose |
|---|---|---|
| `enable` | `false` | Install the UWE5622 driver, firmware and supplicant wiring. |
| `interface` | `wlan0` | Interface created by the driver. |
| `ssid` | `null` | Network to join; if null, `wpa_supplicant` is not started. |
| `pskFile` | `null` | Runtime file containing the PSK. Never put the PSK in the store. |
| `powerSaveOff` | `true` | Toggle power save off after association. |

`iwd` must not be used with this driver: it deletes the interface at startup and
deadlocks cfg80211. The module enforces `wpa_supplicant`.

## Image and board

`nixelec.nixosModules.sd-image` builds the Allwinner SD image with U-Boot at
8 KiB. `nixelec.nixosModules.orangepizero3` selects the Zero 3 board, the edge
kernel and `cma=256M`.

`nixelec.kernelPackage` defaults to the nixbian family kernel used by the
reference cache. Set it to `null` to use nixbian's per-board kernel, for example
with `nixelec.prcmPpu.mode = "builtin"`:

```nix
nixelec.prcmPpu.mode = "builtin";
nixelec.kernelPackage = null;
```

The builtin mode requires a kernel rebuild; see
[`development.md`](development.md#gpu-power-domain).
