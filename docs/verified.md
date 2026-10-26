# Verified status

This document separates what is **built/evaluated** from what is **measured on
the board**. An unchecked box is not a promise.

## In this repository

| Check | Command | Status |
|---|---|---|
| Toplevel evaluation | `nix eval .#nixosConfigurations.orangepizero3-kodi.config.system.build.toplevel.drvPath` | verified on 2026-10-25 |
| Add-ons example evaluation | `nix eval .#nixosConfigurations.orangepizero3-kodi-addons.config.system.build.toplevel.drvPath` | verified on 2026-10-25 |
| Eval + format | `nix flake check --system x86_64-linux` | verified on 2026-10-25 |
| CEC/add-on unit wiring | `nix build .#checks.x86_64-linux.kodi-cec-addons` | verified on 2026-10-25 |
| SD image build | `nix build .#packages.aarch64-linux.orangepizero3-sd-image` | built locally on 2026-10-24; U-Boot at offset 8 KiB verified |
| SD image boot | spare SD, cold boot on 2026-10-25 | nixelec layout (`FIRMWARE` + `NIXOS_SD`), U-Boot at 8 KiB, CEC `/dev/cec0`, WiFi, NTP, Kodi and 8080 validated |
| UWE5622 firmware | `nix build .#uwe5622-firmware` | verified on 2026-10-24 |
| Kernel/U-Boot/Kodi parity | `drvPath` comparison against the reference pins | verified on 2026-10-24 |
| `v4l2request` pin | `flake.lock` comparison + `kodi-kiosk` `drvPath` | verified on 2026-10-25 (`885d9a0b`, `qb66fcbh…`) |
| PPU modes `module` / `builtin` | `nix build .#checks.x86_64-linux.prcm-ppu-loading` | verified on 2026-10-24 |
| Kodi restart policy | `nix build .#checks.x86_64-linux.kodi-restart-policy` + generated unit | verified on 2026-10-25 (`X-RestartIfChanged=false`) |
| Builtin kernel `CONFIG_SUN50I_H6_PRCM_PPU=y` | `nix build .#checks.aarch64-linux.prcm-ppu-builtin-config` | to run on an ARM runner |
| Driver `uwe5622` + `kernel.dev` in cache | `cache` job | pushed explicitly, same `drvPath` as the reference closure |

Parity was re-measured after pinning nixbian `038d3092` and nixpkgs `cd4ea8d5`.
That pin is one CI commit before `v0.4.0` and carries both sunxi audio patches
(DT `#sound-dai-cells` and AHUB PLL retune). The shared kernel is
`dsrz3rnrb4n6qz5bqp7qm09q1xqa5rc0-linux-7.0.14.drv`. The `v4l2request` pin is
`885d9a0b`.

## On the board (Orange Pi Zero 3)

| Check | Command / observation | Status |
|---|---|---|
| U-Boot boot | `U-Boot` banner on `ttyS0` | cold boot on the reference board uses the nixbian U-Boot from the SD. Warm reset validated on 2026-10-25 through the mainline SPI fallback; not replayed with this image alone |
| SPI fallback U-Boot | `flashcp` at offset 0 + readback `cmp` | written on the reference board on 2026-10-25 (nixbian v2025.04, sha256 `e40d4657…`); 8/8 warm resets and a cold boot returned with Kodi/WiFi up |
| CMD0 shutdown hook | warm reset + UART | tested on the reference board on 2026-10-25: negative, the BootROM still fell back to SPI (`Trying to boot from sunxi SPI`); hook disabled in the reference consumer |
| GPU | `/dev/dri/renderD128` present | present on the reference board (panfrost); not replayed with this image |
| HDMI audio | `cat /proc/asound/card*/pcm0p/info` -> `i2s-hifi` | validated on the reference board on 2026-10-24 with kernel `dsrz3rnrb` and this DTB; not replayed with this image. The wireplumber `ccu_helper_wait_for_lock` warning was analyzed as a benign second-open race on the single-stream HDMI codec |
| AHUB clock | 48 kHz playback not slowed down | validated on the reference board on 2026-10-24 (`audio-hub` 49.125 MHz, 0.055 % error); not replayed with this image |
| HDMI audio level | `wpctl get-volume @DEFAULT_AUDIO_SINK@` as the kiosk user | measured on the reference board on 2026-10-26: WirePlumber 0.5 creates sinks at `device.routes.default-sink-volume` = 0.064 linear (0.40 cubic, ≈ −24 dB) and Kodi does not raise the sink — its 100 % is the stream volume — so the kiosk played 24 dB low; `51-default-sink-volume` sets 1.0. Not replayed with this image: the board currently relies on the restored `default-routes` state |
| WiFi | `wlan0` associated, stable RTT | validated with `nixelec.wifi` on 2026-10-25 (5 GHz, power save off, cold boot); not replayed with this image |
| WiFi regulatory DB | `/run/current-system/firmware/regulatory.db` uncompressed | validated on cold boot 2026-10-25: no `failed to load regulatory.db`; fix in `c0580bf` |
| mDNS stack | `resolvectl` shows `-mDNS`; only Avahi listens on 5353 | validated on cold boot 2026-10-25: no duplicate-stack warning; fix in `c0580bf` |
| VPU decode | `v4l2-ctl --list-devices` + 1080p playback | Kodi opened `CDVDVideoCodecDRMPRIME` on a 1080p sample; CPU measurement pending; not replayed with this image |
| Kodi web server | `0.0.0.0:8080`, HTTP Basic; 401 without auth, 200 with | validated on the reference board on 2026-10-24; not replayed with this image |
| Kodi UI sounds | `audiooutput.guisoundmode=0`, empty `lookandfeel.soundskin` | validated on the reference board on 2026-10-24; not replayed with this image |
| Estuary home menu | `addon_data/skin.estuary/settings.xml` + Kodi log | validated on the reference board on 2026-10-25: `music`, `weather`, `musicvideos`, `radio`, `pictures` and `games` hidden; feature in `3f69e84` |
| CEC cold boot / TV standby | `cec-ctl -S`, Kodi CEC settings | validated on the reference board on 2026-10-25 (`hdmi-cec-reprobe`, `standby_pc_on_tv_standby=36028`). The same workaround is in `nixelec.kodi.cec`; hotplug recovery is opt-in and not replayed with this image |

## Sources

- `nix-v4l2-request/docs/fenetrage-kodi-gbm.md`
- `nix-v4l2-request/docs/domaine-alimentation-gpu.md`
- raw reference-board logs kept outside this repository

These documents describe measurements made on the reference board. They are not
automatically valid for this extraction until they have been replayed with the
image produced here.
