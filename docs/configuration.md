# Configuration

The public modules expose ordinary NixOS options under `nixelec.*`. Import the
board and the image module, then set the options you need.

```nix
{
  imports = [
    nixelec.nixosModules.orangepizero3
    nixelec.nixosModules.sd-image
  ];
}
```

Start from [`examples/zero3-base.nix`](../examples/zero3-base.nix) for a bare
board, or from [`examples/zero3-cache.nix`](../examples/zero3-cache.nix) when you
also want the WiFi driver and firmware.

## Board facts

This layer publishes `nixelec.platform.*`; it never sets `nixelec.kiosk.*`. The
facts are inert unless the kiosk contract is imported, so a bare image gets no
phantom options. On H616/H618:

| Fact | Value |
|---|---|
| `cecDriver` | `"dw-hdmi-cec"` |
| `hdmiConnector` | `"HDMI-A-1"` |
| `videoMode` | `"1920x1080@60"` (preference, never forced with `D`) |
| `watchdog.enable` / `watchdog.maxTimeout` | `true` / `16` (sunxi-wdt `max_timeout`, measured) |

## Adding a player

The kiosk lives in the neutral layer
[`nixelec-kiosk`](https://github.com/zibaone/nixelec-kiosk). Import it next to
this layer and do the wiring in your own profile — this repository deliberately
does not ship it:

```nix
{
  imports = [
    nixelec.nixosModules.orangepizero3
    nixelec.nixosModules.sd-image
    nixelec-kiosk.nixosModules.kodi-gbm
  ];

  nixelec.kiosk = {
    enable = true;
    package = kodi-kiosk; # required; no default in the neutral layer
    cec.driver = config.nixelec.platform.cecDriver;
    cec.connector = "card0-${config.nixelec.platform.hdmiConnector}";
    watchdog.enable = config.nixelec.platform.watchdog.enable;
    extraKernelParams = [
      "video=${config.nixelec.platform.hdmiConnector}:${config.nixelec.platform.videoMode}"
    ];
  };
}
```

The option reference (CEC, add-ons, web server, home menu) is in
[`nixelec-kiosk/docs/contrat.md`](https://github.com/zibaone/nixelec-kiosk/blob/main/docs/contrat.md).

`nixelec.kiosk.package` has no default on purpose. A `pkgs.kodi-gbm` built
without the `nix-v4l2-request` decoder makes `CDVDVideoCodecDRMPRIME::Create()`
return nullptr, and Kodi silently decodes in software.

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

The WiFi module is not imported by `nixosModules.orangepizero3`; import
`nixosModules.wifi-uwe5622` explicitly (the cache example does).

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
