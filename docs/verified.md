# Verified status

This document separates what is **built/evaluated** from what is **measured on
the board**. An unchecked box is not a promise.

## In this repository

| Check | Command | Status |
|---|---|---|
| Toplevel evaluation | `nix eval .#nixosConfigurations.orangepizero3.config.system.build.toplevel.drvPath` | verified on 2026-10-25 |
| WiFi cache evaluation | `nix eval .#nixosConfigurations.orangepizero3-cache.config.system.build.toplevel.drvPath` | verified on 2026-10-29 |
| Eval + format | `nix flake check --system x86_64-linux` | verified on 2026-10-25 |
| CEC/add-on unit wiring | `nix build .#checks.x86_64-linux.kodi-cec-addons` | verified on 2026-10-25 |
| SD image build | `nix build .#packages.aarch64-linux.orangepizero3-sd-image` | built locally on 2026-10-24; U-Boot at offset 8 KiB verified |
| SD image boot | spare SD, cold boot on 2026-10-25 | nixelec layout (`FIRMWARE` + `NIXOS_SD`), U-Boot at 8 KiB, CEC `/dev/cec0`, WiFi, NTP, Kodi and 8080 validated |
| UWE5622 firmware | `nix build .#uwe5622-firmware` | verified on 2026-10-24 |
| Kernel/U-Boot/Kodi parity | `drvPath` comparison against the reference pins | verified on 2026-10-24 |
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
| HDMI audio level | `wpctl get-volume @DEFAULT_AUDIO_SINK@` as the kiosk user | measured on the reference board on 2026-10-26: WirePlumber 0.5 creates sinks at `device.routes.default-sink-volume` = 0.064 linear (0.40 cubic, ≈ −24 dB) and Kodi does not raise the sink — its 100 % is the stream volume — so the kiosk played 24 dB low; `51-default-sink-volume` sets 1.0. Validated with a deployed generation the same day: `default-routes` removed, the HDMI sink comes back at 1.00 from this default and the state file is not recreated |
| WiFi | `wlan0` associated, stable RTT | validated with `nixelec.wifi` on 2026-10-25 (5 GHz, power save off, cold boot); not replayed with this image |
| WiFi regulatory DB | `/run/current-system/firmware/regulatory.db` uncompressed | validated on cold boot 2026-10-25: no `failed to load regulatory.db`; fix in `c0580bf` |
| mDNS stack | `resolvectl` shows `-mDNS`; only Avahi listens on 5353 | validated on cold boot 2026-10-25: no duplicate-stack warning; fix in `c0580bf` |
| CPU governor | `cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor` | validated on the reference board on 2026-10-27: `schedutil` (it read `ondemand` before) from the kiosk profile (module now in `nixelec-kiosk`); `cpu-governor` active, exit 0 |
| Hardware watchdog | `systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec` + `/sys/class/watchdog/watchdog0` | validated on the reference board on 2026-10-27: `15s`/`15s`, `state=active`, `timeleft=15`, 0 failed units, no reboot needed to arm it |
| VPU decode | `v4l2-ctl --list-devices` + 1080p playback | Kodi opened `CDVDVideoCodecDRMPRIME` on a 1080p sample; CPU measurement pending; not replayed with this image |
| Kodi web server | `0.0.0.0:8080`, HTTP Basic; 401 without auth, 200 with | validated on the reference board on 2026-10-24; not replayed with this image |
| Kodi UI sounds | `audiooutput.guisoundmode=0`, empty `lookandfeel.soundskin` | validated on the reference board on 2026-10-24; not replayed with this image |
| Estuary home menu | `addon_data/skin.estuary/settings.xml` + Kodi log | validated on the reference board on 2026-10-25: `music`, `weather`, `musicvideos`, `radio`, `pictures` and `games` hidden; feature in `3f69e84` |
| CEC cold boot / TV standby | `cec-ctl -S`, Kodi CEC settings | validated on the reference board on 2026-10-25 (`hdmi-cec-reprobe`, `standby_pc_on_tv_standby=36028`). The same workaround now lives in `nixelec-kiosk` (`nixelec.kiosk.cec`); hotplug recovery is opt-in and not replayed with this image |

## On the board (Transpeed 8K618-T)

Measured on the bench on 2026-11-06/07, kernel `7.0.14` with patches 0001-0004.

| Check | Command / observation | Status |
|---|---|---|
| Toplevel evaluation | `nix eval .#nixosConfigurations.transpeed-8k618-t.config.system.build.toplevel.drvPath` | verified 2026-11-06 |
| `sunxi-gmac` package | CI job `cache` (aarch64): built and pushed as `b18dppjjy…-sunxi-gmac-7.0.14` | verified 2026-11-06 |
| DTB (0002 + 0004) | `dtc -I dtb -O dts` on the built DTB | verified: `allwinner,sunxi-gmac`, `mdio@5030048`, `allwinner,syscfg-value`, `allwinner,no-crc-check` |
| Internal Ethernet, link | `ip link`, `LPA` read through the vendor MDIO | **10 Mbps only**, and the PHY decodes the partner as 10BASE-T alone (`LPA 0x4461`) on a router port that advertises 10/100/1000 |
| Internal Ethernet, traffic | `ping` both ways, 56/1000/1400/1472 bytes | PC → box: 30/30, 0 % loss. Box → PC: `+N corrupted` before the checksum fixes; with `CHECKSUM_NONE` nothing is received — the RX payload is corrupt |
| Internal Ethernet, driver sanity | MAC internal loopback (`BASIC_CTL0 |= BIT(1)`) + `ping` on its own address | **3/3 received, checksums validated**: MAC, DMA, descriptors, ring and the driver RX path are sound. The defect is the AC300 PHY of this unit |
| USB dongle (SR9700) | `enu1`, DHCP, `ssh` | validated 2026-11-07: `192.168.1.23/24` via DHCP, default route, ping 3/3 from the PC, TCP/22 open, 10 MB in 13.09 s (≈ 6.4 Mbps) |
| WiFi (BCM4334) | `iw dev wlan0 scan` | **measured 2026-11-16** after `045ad20`: 2.4/5 GHz scan. The earlier panic ~1.5 s after the radio started (write to read-only memory, RCU stalls, `sunxi-wdt` reset) was measured **before `4219ece`** (firmware, NVRAM, `wireless-regdb`, stable `wlan0`, `brcmfmac-wcc`, `firmwareCompression = "none"`). |
| Toplevel after shared-layer evolutions | `nix eval --raw .#nixosConfigurations.transpeed-8k618-t.config.system.build.toplevel.drvPath` | verified 2026-11-08: evaluates in 3 s against the current nixelec family layer and nixbian metadata |

## On the board (H96 Max H618)

The board (`.50`) is **reachable on 2026-11-16** (`eth0` DHCP
`192.168.1.50/24`, 100 Mb/s, SSH root). The hardware rows that are still not
measured are marked as such.

| Check | Command / observation | Status |
|---|---|---|
| Ethernet (`sunxi-gmac`) | `ip -br addr`; `ping`/SSH from the PC | measured 2026-11-16: `eth0 UP`, DHCP `192.168.1.50/24`, 100 Mb/s, ping 0 % loss, SSH root OK |
| Toplevel evaluation (eMMC) | `nix eval --raw .#nixosConfigurations.h96-max-h618-emmc.config.system.build.toplevel.drvPath` | verified 2026-11-16 |
| HavenOS kiosk evaluation | `nix eval --raw .#nixosConfigurations.h96-max-h618-edge-kodi.config.system.build.toplevel.drvPath` | verified 2026-11-16; eMMC root label `nixelec-h96` |
| AIC8800 kbuild hook | `nix derivation show` on the kernel | `3401-net-wireless-backport-aic8800-sdio` and `0001-…kbuild` present; `0006` absent. `.ko` not materialized |
| eMMC cold boot | boot with HDMI | **not measured** |
| IR (`sunxi-ir`, overlay `ir@7040000`) | `ir-keytable -t` | **not measured**; the overlay path is only evaluated |
| Front panel (FD655, PH2/PH3, text `H96`) | screen read | measured 2026-11-15; **confirmed again 2026-11-16** after `fd6xx --chip /dev/gpiochip1 --clk 226 --dat 227 --brightness 3 write H96`. The boot service was starting before `dev-gpiochip1.device`; fixed in `nixelec-common 722e300` (image redeploy pending). |
| WiFi AIC8800D80 | `iw dev wlan0 scan` | **not measured** |
| HDMI / Kodi GBM | `modetest`, 1080p playback | **not measured** |

## Sources

- `nix-v4l2-request/docs/fenetrage-kodi-gbm.md`
- `nix-v4l2-request/docs/domaine-alimentation-gpu.md`
- `docs/affichage-facade.md` (front-panel wiring and screen measurements)
- raw reference-board logs kept outside this repository

These documents describe measurements made on the reference board. They are not
automatically valid for this extraction until they have been replayed with the
image produced here.
