# What goes in the image, and what is left to provisioning

## Context: the layers

A working elspi card is built up in four layers, each with a different owner
and a different moment:

| Layer | When | What it does |
|---|---|---|
| **Image** | built by this repo, flashed to the card | the OS, every package, the Python environment, and the newest full reflex release |
| **First boot** | once, on the card's first start | applies the password and SSH keys entered in Raspberry Pi Imager, then starts the UI if it is safe to |
| **Provisioning** | run over SSH against a booted card (`deltas/provision.sh`) | links and syncs the app, restores the machine's configuration from a backup, and asks for anything the Imager left out |
| **The app itself** | from then on | in-app updates, commissioning, and its own backups to USB or a gist |

A site can add its own steps to provisioning through hooks (`--site-hooks`);
nothing in this repo depends on them.

"Provisioning" in this document means the third layer. The question here is
where the line between the first and third layers falls.

## The rule

Put a step in the image unless it changes with every application release.
Two reasons push work into the image:

- **CI can check the image** on every build (packages, units, users, files).
  Provisioning needs a real Pi and a person.
- **Recovery must not need the network.** A dead SD card should be survivable
  from a backup and an image, even if PyPI or a package mirror is down that day.

So the image carries the Python environment, the reflex checkout and the
firmware toolchain. Provisioning does only what depends on the particular
machine: its restored configuration and its credentials.

## Restore is the step that must stay strict

The configuration directory holds geometry measured on the machine. A lathe
running on defaults looks fine and cuts wrong, so restore refuses rather than
generating data. `--fresh` is the explicit path for a machine that has never
been commissioned.

## No credentials in the repo or the image

The repo and its images are public. The service account ships locked, and no
SSH key is baked in. Passwords and keys come only from Raspberry
Pi Imager's customization page, applied once on first boot and then wiped from
the card. A card flashed without them is reachable only from its touchscreen.
