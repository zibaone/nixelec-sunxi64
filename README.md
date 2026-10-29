# nixelec-sunxi64

Reusable NixOS layer for Allwinner H616/H618 boards. First target: **Orange Pi
Zero 3**.

This repository is the **card layer**: kernel, DTB, boot chain, image, WiFi. It
publishes the board facts (`nixelec.platform.*`) and nothing about the player.
The Kodi GBM kiosk lives in [`nixelec-kiosk`](https://github.com/zibaone/nixelec-kiosk);
the wiring between the two layers belongs to the consumer's profile.

This repository contains public appliance code only. Runtime secrets are files
read at boot; fleet identity, provisioning and private add-ons belong to the
consumer.

## Scope

| Provided | Not provided |
|---|---|
| nixbian kernel, DTB, U-Boot, extlinux | WiFi PSK, SSH keys, root password |
| H616/H618 quirks: GPU power domain, HDMI audio, `cma` | Fleet identity and provisioning |
| Allwinner SD image (U-Boot at 8 KiB) | Kodi, add-ons, kiosk policy (`nixelec-kiosk`) |
| Board facts `nixelec.platform.*` (CEC driver, HDMI connector, video mode, watchdog) | Consumer-specific deployment |
| UWE5622 driver + firmware (optional) | |

Hardware validation is tracked separately from evaluation; see
[`docs/verified.md`](docs/verified.md).

## Layout

```
modules/
  family/sunxi64.nix             common H616/H618 quirks, nixelec.platform.* facts
  boards/orangepizero3.nix       board, edge kernel, cma
  image/sunxi-sd.nix             SD image, U-Boot at 8 KiB
  services/wifi-uwe5622.nix      optional WiFi driver/firmware
packages/
  uwe5622/                       out-of-tree driver
  uwe5622-firmware/              firmware + RF calibration
examples/
  zero3-base.nix                 base configuration (no player)
  zero3-cache.nix                base + WiFi driver/firmware, no association
```

## Quick start

```bash
# Evaluation and formatting
nix flake check --system x86_64-linux

# SD image (aarch64)
nix build .#packages.aarch64-linux.orangepizero3-sd-image

# Evaluate a configuration without building
nix eval .#nixosConfigurations.orangepizero3.config.system.build.toplevel.drvPath
nix eval .#nixosConfigurations.orangepizero3-cache.config.system.build.toplevel.drvPath
```

For a custom configuration, import the modules and supply runtime secrets:

```nix
{
  imports = [
    nixelec.nixosModules.orangepizero3
    nixelec.nixosModules.sd-image
  ];

  # The PSK is read at boot and never stored in the Nix store.
  nixelec.wifi.enable = true;
  nixelec.wifi.ssid = "MyNetwork";
  nixelec.wifi.pskFile = "/run/secrets/wifi-psk";
}
```

## Adding a player

The card publishes facts; a kiosk consumes options. The two are joined by the
consumer, never here:

```nix
{
  imports = [
    nixelec.nixosModules.orangepizero3   # this repository
    nixelec-kiosk.nixosModules.kodi-gbm  # the player
  ];

  # Wiring: facts -> options. Only the consumer sees both layers.
  nixelec.kiosk = {
    enable = true;
    package = kodi-kiosk; # required: the kiosk layer has no default
    cec.driver = config.nixelec.platform.cecDriver;
    cec.connector = "card0-${config.nixelec.platform.hdmiConnector}";
    watchdog.enable = config.nixelec.platform.watchdog.enable;
    extraKernelParams = [
      "video=${config.nixelec.platform.hdmiConnector}:${config.nixelec.platform.videoMode}"
    ];
  };
}
```

`nixelec.kiosk.package` has **no default on purpose**: a `pkgs.kodi-gbm` that
lacks the `nix-v4l2-request` decoder makes Kodi fall back to CPU decoding
silently. Use the kiosk build from `nix-v4l2-request`.

## Documentation

- [`docs/configuration.md`](docs/configuration.md): module options, WiFi, board
  facts and runtime secret paths.
- [`docs/deployment.md`](docs/deployment.md): image build, flashing, first boot,
  remote access and updates.
- [`docs/development.md`](docs/development.md): checks, formatting, CI, cache
  policy and pins.
- [`docs/cache.md`](docs/cache.md): filling a consumer cache and verifying store
  path alignment.
- [`docs/verified.md`](docs/verified.md): built/evaluated vs measured on the
  board.
- [`docs/backlog.md`](docs/backlog.md): public issues and decisions.

## Remote access

The example enables `sshd` but leaves
`users.users.root.openssh.authorizedKeys.keys` empty. Add your public key before
flashing, otherwise the image has no remote access.

## UWE5622 WiFi

The driver comes from `armbian/uwe5622`. **Do not use iwd**: at startup it
deletes an interface (`NL80211_CMD_DEL_INTERFACE`), and `sprdwl_del_iface`
unregisters the netdevice synchronously, which deadlocks cfg80211 under the
wiphy mutex. The module uses `wpa_supplicant`, which neither creates nor destroys
an interface.

The PSK is never stored in the Nix store: `nixelec.wifi.pskFile` points to a
runtime file read at boot (`/run/secrets/wifi-psk`, tmpfs, etc.).

## CI

`.github/workflows/ci.yml`:

- **`eval`** (`ubuntu-latest`): `nix flake check --system x86_64-linux`,
  evaluation of the aarch64 toplevel and image, image dry-run, and UWE5622
  firmware build.
- **`aarch64-eval`** (`ubuntu-24.04-arm`): checks the builtin kernel
  (`CONFIG_SUN50I_H6_PRCM_PPU=y`) and evaluates the aarch64 image. This is the
  only place where the ARM IFD on the `.config` is available.
- **`cache`** (`ubuntu-24.04-arm`, on `push` to `main` and manual): builds the
  WiFi-enabled toplevel (driver + firmware, no SSID/PSK), the `uwe5622` driver
  package, and `kernel.dev`, then pushes them to the cache. `kernel.dev` is a
  build input, not part of the system closure, so it is pushed explicitly.
- **`image`** (`ubuntu-24.04-arm`, **manual**): builds the SD image artifact.
  Run it via `workflow_dispatch` with `build-image`; the cache job usually
  makes it incremental.
- **Cache target**: `CACHIX_CACHE` repository variable (default `nixelec`). A
  consumer may point it at its own cache; the push is explicit
  (`skipPush: true`) and both the toplevel and the image are checked through
  their narinfo, because `cachix-action` can report "Pushed" for paths that
  stayed 404.
- **Pin alignment**: pass the consumer `nixpkgs-rev` when its nixpkgs revision
  differs. See [`docs/cache.md`](docs/cache.md).

The image artifact is never built on `push` or `pull_request`. The cache job
fills the shared closure on `push` to `main`; the image artifact remains manual.

## GPU power domain

Two modes, selected with `nixelec.prcmPpu.mode`:

| Mode | Kernel | Loading |
|---|---|---|
| `builtin` (default) | `CONFIG_SUN50I_H6_PRCM_PPU=y` | no module; domain registered during kernel init |
| `module` | `CONFIG_SUN50I_H6_PRCM_PPU=m` | initrd + `boot.kernelModules`, softdep, rebind |

The family kernel that nixbian builds already carries `=y`
(`src/armbian_extractor/family_config.json`, key `sunxi64-edge`), so the
default needs no `extraConfig` and no per-consumer config override. `module`
is the rollback path for a kernel built with `=m`.

There is no import-from-derivation: the concatenated `.config` is a plain
store path (`builtins.toFile`), so a consumer evaluates on x86 without an ARM
builder.

```bash
nix build .#checks.x86_64-linux.prcm-ppu-loading
```

## Verified status

| Check | Status |
|---|---|
| `nix flake check --system x86_64-linux` (eval + format) | verified on 2026-10-25 |
| SD image build | built locally on 2026-10-24; U-Boot at offset 8 KiB verified |
| Real boot on Zero 3 | `sd-image` booted from a spare SD on 2026-10-25 |
| VPU hardware decode (cedrus) | Kodi opened `CDVDVideoCodecDRMPRIME`; CPU measurement pending |
| HDMI audio | validated on the reference board on 2026-10-24 with this kernel/DTB |
| Cold-boot WiFi | validated with `nixelec.wifi` on 2026-10-25 |
| CEC cold boot / TV standby | validated on the reference board on 2026-10-25 |

The player rows (decode, audio, CEC) were measured with the kiosk module that
now lives in `nixelec-kiosk`; the kernel, DTB, audio and WiFi results are
properties of this layer and stay valid.

See [`docs/verified.md`](docs/verified.md) for commands and details. Evaluation
is not a hardware proof.

## Naming

- `nixelec-sunxi64` is the Allwinner arm64 family.
- `nixelec-meson64`, `nixelec-rockchip64`: future families.
- A board is a module under `modules/boards/`. A separate repository per board
  is only justified when it has its own release cycle; in that case it imports
  the family repository.

## License

MIT for this repository's code. The UWE5622 driver and kernel patches keep their
original licenses (GPL-2.0). The firmware is distributed by
`armbian/firmware`; its provenance is documented in the package.
