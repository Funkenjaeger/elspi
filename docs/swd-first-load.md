# First load: getting firmware onto a brand-new controller board

A new Provvedo controller board ships with **OEM firmware and no field
bootloader**. The UI checks the register layout at connect and will tell you
plainly if the board is not running Reflex firmware — so this has to happen
before the board is trusted with anything. Getting from "OEM, blank" to
"running and updatable over RS-485" takes exactly one session with an ST-Link
programmer; nothing about the board's design intends for you to need it twice.

This page covers the software half — what runs on the Pi to put the first
firmware on. The physical half (connecting the programmer) is a bench
procedure and is a placeholder below.

## What this image already has

The firmware toolchain is baked into the image unconditionally, never behind
an interactive prompt (`stage-elspi/02-firmware-dev/00-packages`):

- `gcc-arm-none-eabi`
- `cmake`
- `openocd`

`openocd`'s packaging installs the udev rules granting the `plugdev` group
access, so the flash itself needs no `sudo` for the device permissions. There
is no package-install step on this image — it is already done, at build time,
so the day the card died is not the day a package mirror has to be reachable.

## Where the checkout is, and who owns it

`deltas/lib.sh` deliberately does **not** default the application checkout
path — `require_app_dir()` takes it as `--app` and refuses to guess — but its
comment (`deltas/lib.sh:96-100`) records what the path is on the live machine:

```
/home/default/projects/reflex
```

(monorepo layout since the 2026-08-17 weld; the older standalone `/reflex-ui`
checkout was deleted 2026-08-25). The account that owns it is the service
user resolved by `resolve_service_user()` in the same file: read from
`/etc/elspi-image.json`'s `service_user` key if the image carries one,
otherwise the built-in fallback `default` — the same account name as the path
above.

## Flash from the Pi

Build and flash from the Pi itself, using that checkout — not a workstation —
so what ends up on the controller cannot be a different revision from what is
in front of you:

```sh
cd /home/default/projects/reflex/fw
./scripts/provision.sh
```

`provision.sh` puts *two* things on the board in this one session: the field
bootloader in sector 0, and the application in the RUN slot behind it. The
toolchain and the udev rules it needs are already on this image (above), so
there is nothing to install first.

## After this, updates go over RS-485

**This is the only time the ST-Link is needed.** Once the bootloader is on
the board, every later firmware update goes over the RS-485 link the UI
already uses — no programmer, no power cycle, nothing to unplug at the
machine. In practice that is the touchscreen's *Setup → Update*, which drives
the same underlying path (`modbus-flash.py`) that a manual re-flash would.

## Wiring the ST-Link (to be written at the bench)

*Placeholder.* The pinout, the connector, and any board-revision caveats are
Evan's to fill in once he is at the bench with the hardware in hand — this
page intentionally says nothing about them yet.
