# elspi

The SD-card image for **elspi**, the Raspberry Pi 5 that runs the
[Reflex](https://github.com/Funkenjaeger/reflex) electronic-leadscrew UI on a
manual lathe. A soft fork of
[RPi-Distro/pi-gen](https://github.com/RPi-Distro/pi-gen) — this repo is the
recovery path for that machine: a dead SD card should cost a flash, not a
rebuild.

* **Raspberry Pi OS trixie, 64-bit (`arm64`) userland**, built by pi-gen from
  `stage0`–`stage2` plus our own `stage-elspi/`. The `master` branch builds the
  legacy 32-bit (`armhf`) line, frozen.
* **The Kivy runtime is compiled in.** The venv ships Kivy from PyPI's
  prebuilt `aarch64` wheel (pinned by `uv.lock`), with every dependency already
  built — recovery still does not need PyPI.
* **The firmware toolchain is baked** (`gcc-arm-none-eabi`, `cmake`, `openocd`):
  STM32 firmware is flashed *from* the lathe.
* **First boot is seeded from Raspberry Pi Imager's customisation page** —
  hostname, the account password and/or your SSH public key (at least one of
  the two, or the card has no SSH way in), Wi-Fi. Nothing is committed here and
  nothing is baked — not even a public key; a oneshot unit applies what
  cloud-init cannot and then takes the credentials off the card.
* **The app runs as a non-root service user** (`default`), with no seat and no
  session machinery.

What the image deliberately does *not* contain is the application itself and the
commissioned machine data. Those arrive from the delta layer — see
[Provisioning](docs/provisioning.md).

## Flash a card

Raspberry Pi Imager **2.x** from
[raspberrypi.com](https://www.raspberrypi.com/software/) is required; one
command, no checkout, nothing downloaded by hand.

**Windows**, from Win+R, cmd or PowerShell alike:

    cmd /c start rpi-imager --repo https://github.com/Funkenjaeger/elspi/releases/latest/download/os_list.json

**Linux**:

    rpi-imager --repo https://github.com/Funkenjaeger/elspi/releases/latest/download/os_list.json

Full instructions, including every field on the customisation page and what it
becomes on the machine: **[docs/flashing.md](docs/flashing.md)**.

## Documentation

| Page | What it covers |
|---|---|
| [Flashing a card](docs/flashing.md) | requirements, the two commands, the customisation page, first boot |
| [Provisioning](docs/provisioning.md) | the delta layer — app, commissioned config, starting the UI |
| [Where the image ends](docs/design/seam.md) | what belongs in the image and what belongs in a delta run |
| [This is not pi-gen](docs/design/fork.md) | the fork contract, merging upstream, the merge surface |
| [Runtime inventory](docs/design/runtime-inventory.md) | what the live machine has, as measured |
| [Verifying the image](docs/design/verification.md) | the three test tiers and what each can prove |
| [Changelog](docs/changelog.md) | releases |

`README.pi-gen.md` is upstream pi-gen's README, unmodified — it documents
`build.sh` and the stage mechanism this fork still uses.

Building the image: `./build-elspi.sh` (no arguments -- the image is keyless;
your SSH key and/or password go on Imager's customisation page at flash time);
tests are in `tests/`. One installation's own hardware and defaults go in an
optional site build config, `ELSPI_SITE_CONF=/path/to/site.conf` -- see
[Provisioning](docs/provisioning.md#a-site-build-config).

## License

Two licenses, because this is a fork with additions:

* **Our additions are MIT** — `stage-elspi/`, `deltas/`, `tests/`, `tools/`,
  `docs/`, `build-elspi.sh`, `elspi.conf`, this README and the GitHub
  workflows. See [`LICENSE-elspi`](LICENSE-elspi).
* **Upstream pi-gen is BSD 3-Clause**, © Raspberry Pi (Trading) Ltd —
  `stage0` through `stage5`, `export-image`, `export-noobs`, `scripts`,
  `depends`, `build.sh`, `build-docker.sh`, `Dockerfile` and
  `README.pi-gen.md`. See [`LICENSE`](LICENSE), which is upstream's file,
  unmodified.

`LICENSE-elspi` names the split itself, so the boundary lives in one place
rather than in a header on every file.
