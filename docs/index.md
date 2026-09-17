# elspi

The SD-card image for the Raspberry Pi 5 that runs the
[Reflex](https://github.com/Funkenjaeger/reflex) electronic-leadscrew UI on a
manual lathe.

## Why this repository exists

The lathe's controller is a Raspberry Pi whose operating system was built up by
hand over months. That is fine until the SD card dies — and then a machine shop
has a lathe it cannot use and no way back except repeating the months. This
repository is the way back: a **soft fork of
[pi-gen](https://github.com/RPi-Distro/pi-gen)** that builds the card from
source, so recovery is *flash → restore → run*.

Two consequences shape everything here:

* **Recovery must not depend on the outside world.** Anything that would need
  PyPI, a package mirror or a working network on the day the card died is baked
  into the image instead — including the Kivy runtime, which has no prebuilt
  wheel for this platform and is therefore compiled during the build.
* **The image carries no machine data and no credentials.** Axis geometry,
  servo polarity and backlash calibration were measured off the physical lathe
  and can only be *restored*, never generated. Passwords and keys arrive at
  flash time from Raspberry Pi Imager and are taken off the card on first boot.

Where that line falls, in detail: [Where the image ends](design/seam.md).

## What is in the image

Raspberry Pi OS **trixie** with an `armhf` userland on a 64-bit kernel, built
from pi-gen `stage0`–`stage2` plus this fork's `stage-elspi/`:

| | |
|---|---|
| Graphics | SDL2 + Mesa DRI + `libmtdev` for the touchscreen, no X server and no compositor — Kivy talks KMS/DRM directly |
| Python | a venv at `/opt/reflex-venv` with every third-party dependency built, Kivy included, but **not** the application |
| Firmware | `gcc-arm-none-eabi`, `cmake`, `openocd` and their udev rules — STM32 firmware is flashed *from* the lathe |
| Boot | `config.txt`/`cmdline.txt` for SPI, I²C and the UART to the controller; Plymouth splash |
| Accounts | the service user `default`, shipped **locked**, in the groups the hardware needs |
| First boot | a oneshot unit that consumes Imager's customisation page and then neutralises it on the card |

## Where to go next

* **[Flashing a card](flashing.md)** — start here if you have a release and a
  blank SD card.
* **[Provisioning](provisioning.md)** — the delta layer: the application, the
  commissioned config, and starting the UI.
* **[First load (SWD)](swd-first-load.md)** — putting the first firmware on a
  brand-new controller board, before RS-485 updates are possible.
* **[This is not pi-gen](design/fork.md)** — the fork contract, how upstream is
  merged, and the merge surface.
* **[Runtime inventory](design/runtime-inventory.md)** — what the live machine
  actually has, as measured rather than as remembered.
* **[Verifying the image](design/verification.md)** — the three test tiers, and
  the honest boundary of what each can prove.
* **[Changelog](changelog.md)** — what each release is.

`README.pi-gen.md` in the repository root is upstream pi-gen's own README,
unmodified; it documents `build.sh`, the stage mechanism and the build
configuration this fork still uses.
