# Deployment

The default target is an Orange Pi Zero 3 booting from SD. The image uses
U-Boot at offset 8 KiB and a 30 MiB `FIRMWARE` partition followed by the NixOS
root partition.

## Build the image

The image is an aarch64 derivation. Build it on an aarch64 host or through an
ARM builder:

```bash
nix build .#packages.aarch64-linux.orangepizero3-sd-image
```

The result is a directory under `result/sd-image/` containing the `.img` file.
Evaluation without building works on any host:

```bash
nix eval --raw .#nixosConfigurations.orangepizero3-kodi.config.system.build.sdImage
```

## Flash

Check the target device twice before writing. The image is destructive.

```bash
lsblk
sudo dd if=result/sd-image/*.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Use a cold power cycle after flashing. Do not write the vendor SPI image: it is
the recovery path on this board.

## First boot

1. Connect HDMI, Ethernet if available, and the serial console on `ttyS0` at
   115200 if you need kernel logs.
2. Power on and wait for the network. DHCP is requested on both `en*` and
   `wl*`.
3. Log in over SSH with the key you added to
   `users.users.root.openssh.authorizedKeys.keys`. The example leaves the list
   empty, so add your key before flashing.
4. Check the unit state:

```bash
systemctl --failed
journalctl -b --no-pager
```

WiFi is optional. Enable `nixelec.wifi` and provide `pskFile`; the image does
not contain a PSK.

## Secrets

The modules never put secrets in the Nix store. They read paths at runtime:

- `nixelec.wifi.pskFile` for the WiFi PSK;
- `nixelec.kodi.webServer.passwordFile` for the Kodi web server.

Generate those files with your secret mechanism (agenix, sops-nix, tmpfs or a
manual file under `/run`). The web server fails closed if the password file is
missing.

## Updates

Build a new image, or deploy a new generation with the usual NixOS mechanism
from a machine that can reach the board. The Kodi unit is marked
`restartIfChanged = false`: a changed unit takes effect on the next boot instead
of restarting Kodi during the switch. This avoids `nixos-rebuild switch`
returning 4 while leaving Kodi stopped.

Keep the previous SD card bootable when testing a new image. Cold boot only;
warm reset is not a reliable recovery path on this board.

## Validation checklist

- U-Boot banner on `ttyS0`;
- `/dev/dri/renderD128` present;
- `cec-ctl -S` if CEC is enabled;
- `wlan0` associated if WiFi is enabled;
- Kodi draws on HDMI and the web server answers if enabled;
- `systemctl --failed` empty.

Record the date and command for anything you add to
[`verified.md`](verified.md).
