# Development

## Layout

- `modules/family/`: quirks shared by the H616/H618 family.
- `modules/boards/`: one module per board (board name, kernel vendor, CMA).
- `modules/image/`: Allwinner SD image layout and U-Boot placement.
- `modules/profiles/`: the Kodi GBM kiosk and its CEC/add-on helpers.
- `modules/services/`: optional services, currently UWE5622 WiFi.
- `packages/`: out-of-tree driver and firmware derivations.
- `parts/`: flake outputs (modules, configurations, packages, checks).
- `examples/`: public configurations used by the flake and as copy-paste
  starting points.

## Local checks

```bash
nix flake check --system x86_64-linux -L
```

The x86_64 checks cover evaluation of the Zero 3 toplevel, the add-ons example,
the PPU wiring, the Kodi restart policy, and `nixfmt`. The aarch64 check builds
the kernel config for the builtin PPU mode and needs an ARM builder:

```bash
nix build .#checks.aarch64-linux.prcm-ppu-builtin-config
```

Formatting uses `nixfmt`. The formatter is exposed by the flake:

```bash
nix fmt
nixfmt --check $(find . -name '*.nix')
```

## CI

`.github/workflows/ci.yml` has four jobs:

- `eval` (x86_64): flake check, aarch64 evaluation and image dry-run, firmware
  build.
- `aarch64-eval`: builtin kernel config and aarch64 image evaluation.
- `cache`: builds and pushes the WiFi-enabled toplevel, `uwe5622` and
  `kernel.dev`. It runs on `push` to `main` and on manual dispatch.
- `image`: manual artifact build.

The cache uses `CACHIX_CACHE` (default `nixelec`). The push is explicit and both
the toplevel and the image are checked through their narinfo. `kernel.dev` is a
build input, not part of the system closure, so it is pushed explicitly.

See [`cache.md`](cache.md) for a consumer cache.

## Pins

Store paths are content-addressed. Keep these aligned with the cache you want to
reuse:

- `nixpkgs`;
- `nixbian`;
- `v4l2request`.

The current pins are visible with `nix flake metadata`. Bumping one without the
others can recompile the kernel, Kodi or U-Boot under emulation. Prefer a
deliberate bump plus a cache refill.

The default configuration uses the nixbian family kernel. `nixelec.kernelPackage
= null` hands control back to nixbian's per-board kernel; the `builtin` PPU
example does this.

## GPU power domain

`nixelec.prcmPpu.mode` selects how the H616/H618 power domain is provided:

- `module` (default): `CONFIG_SUN50I_H6_PRCM_PPU=m`, loaded from the initrd so
  it is registered before panfrost probes.
- `builtin`: `CONFIG_SUN50I_H6_PRCM_PPU=y`, no module and no initrd ordering
  dependency.

The builtin variant requires a kernel build with `=y` and a cache refill:

```bash
nix build .#packages.aarch64-linux.orangepizero3-sd-image
```

## Adding a board

1. Add `modules/boards/<board>.nix` with `hardware.nixbian.board`,
   `hardware.nixbian.kernelVendor` and the CMA value for the RAM size.
2. Expose it in `parts/modules.nix`.
3. Add a configuration and, when relevant, a package in
   `parts/configurations.nix`.
4. Add evaluation checks and a board section in `docs/verified.md`.
5. Document missing features (WiFi, IR, eMMC, U-Boot) instead of claiming them.

## Kodi add-ons

nixpkgs attribute names use hyphens (`inputstream-adaptive`); Kodi add-on IDs use
dots (`inputstream.adaptive`). `nixelec.kiosk.addons` receives the Kodi package
set and adds packages to the closure. `nixelec.kiosk.autoEnableAddons` contains the
IDs passed to `Addons.SetAddonEnabled` at boot.

Keep private or consumer-specific add-ons out of this repository. A consumer can
override `nixelec.kiosk.package` with its own `withPackages` call.
