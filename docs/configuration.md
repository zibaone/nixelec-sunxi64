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

  nixelec.kiosk.enable = true;
}
```

Start from [`examples/zero3-kodi.nix`](../examples/zero3-kodi.nix) for a base
appliance, or from
[`examples/zero3-kodi-addons.nix`](../examples/zero3-kodi-addons.nix) when you
also want the public add-ons.

## Kodi

The kiosk module lives in the neutral layer
[`nixelec-kiosk`](https://github.com/zibaone/nixelec-kiosk); this repository
re-exports it as `nixosModules.kodi-gbm` and wires the board facts
(`nixelec.platform.*`) into the kiosk options. Option names below are the
neutral layer's.

| Option | Default | Purpose |
|---|---|---|
| `nixelec.kiosk.enable` | `false` | Enable the Kodi GBM kiosk (no compositor). |
| `nixelec.kiosk.package` | board's `nixelec.platform.kodiPackage` | Kodi package to launch. No default in the neutral layer: the `kodi-gbm` module supplies the v4l2-request kiosk build. |
| `nixelec.kiosk.user` | `kodi` | User that runs Kodi. |
| `nixelec.kiosk.home` | `/var/lib/kodi` | Kodi home directory. |
| `nixelec.kiosk.extraGroups` | video, audio, input, render, tty | Extra groups for the Kodi user. |
| `nixelec.kiosk.extraKernelParams` | `[]` | Extra kernel parameters, for example `video=HDMI-A-1:1920x1080@60`. Only defined when non-empty. |
| `nixelec.kiosk.uiSounds` | `false` | Disable Kodi UI sounds (`guisoundmode=0`, empty sound skin). |
| `nixelec.kiosk.homeMenu.hidden` | `[]` | Estuary home-menu entries to hide. |
| `nixelec.kiosk.addons` | `null` | Function that adds packages to the Kodi package set. |
| `nixelec.kiosk.autoEnableAddons` | `[]` | Add-on IDs enabled at boot through JSON-RPC. |
| `nixelec.kiosk.webServer.enable` | `false` | Kodi web server, HTTP Basic. |
| `nixelec.kiosk.webServer.passwordFile` | `null` | Runtime file containing the web-server password. |
| `nixelec.kiosk.webServer.username` | `kodi` | Web-server username. |
| `nixelec.kiosk.webServer.port` | `8080` | Web-server port. |
| `nixelec.kiosk.cec.enable` | `false` | HDMI-CEC helper services. |
| `nixelec.kiosk.cec.driver` | board's `nixelec.platform.cecDriver` | Kernel CEC module; `null` keeps the kernel CEC units off (USB libCEC adapters still work). |
| `nixelec.kiosk.cec.connector` | `card0-` + board's `hdmiConnector` | DRM connector watched before a hotplug restart. |
| `nixelec.kiosk.watchdog.enable` | board's `nixelec.platform.watchdog.enable` | systemd hardware watchdog (`sunxi-wdt`, 16 s cap published as `maxTimeout`). |

## Board facts

The board layer publishes `nixelec.platform.*`; it never sets
`nixelec.kiosk.*`. On H616/H618:

| Fact | Value |
|---|---|
| `cecDriver` | `"dw-hdmi-cec"` |
| `hdmiConnector` | `"HDMI-A-1"` |
| `videoMode` | `"1920x1080@60"` (preference, never forced with `D`) |
| `watchdog.enable` / `watchdog.maxTimeout` | `true` / `16` (sunxi-wdt `max_timeout`, measured) |
| `kodiPackage` | the `nix-v4l2-request` kiosk build (set by `nixosModules.kodi-gbm`) |

### Add-ons

`nixelec.kiosk.addons` receives the Kodi package set. nixpkgs uses hyphens in
attribute names, while Kodi uses dots in add-on IDs:

```nix
nixelec.kiosk.addons =
  kodi:
  with kodi;
  [
    inputstream-adaptive
    inputstream-ffmpegdirect
    inputstream-rtmp
    pvr-iptvsimple
  ];

nixelec.kiosk.autoEnableAddons = [
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
nixelec.kiosk.webServer = {
  enable = true;
  passwordFile = "/run/secrets/kodi-web";
};
```

The file is read by a root oneshot and is never copied into the Nix store. If the
file is missing or empty, `kodi-settings` fails before Kodi starts; this is
intentional.

### CEC

```nix
nixelec.kiosk.cec = {
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
