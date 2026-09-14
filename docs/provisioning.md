# Provisioning

Everything the image deliberately does **not** contain. The image is
*flash → boot*; this is *restore → run*.

[The seam](design/seam.md) decides what lives on which side of the line. This
page is the other side of it: the application, the commissioned machine data,
and the credentials that could not be typed into Imager.

!!! warning "Read this before you start: the one gap that will stop you"
    `provision.sh` **requires** `--config-backup`, and it refuses to run without
    one. That is correct for the machine this repository was built to recover —
    but it means **a brand-new lathe, never commissioned, cannot be provisioned
    by this tooling today.** `/var/lib/reflex-config` holds axis geometry, servo
    polarity, backlash calibration and Z scale counts/mm, all measured off a
    physical lathe; nothing can generate it, and coming up with defaults would
    produce a machine that runs and is silently wrong.

    So the refusal is deliberate, and the missing path is a real gap rather than
    a flag somebody forgot. There is no `--fresh`, and inventing one is not the
    fix — first commissioning needs a procedure of its own, and it does not
    exist yet. If this is a first commissioning, stop here.

## What you need on the Pi

**A checkout of this repository**, for the delta scripts. `git` is in the image
precisely so this works with no network setup beyond the Wi-Fi you seeded:

```sh
git clone https://github.com/Funkenjaeger/elspi ~/projects/elspi
```

**A checkout of the application, at a release tag.** `provision.sh` will not
clone it for you — the application is not this repository's to fetch on a whim,
and the image is paired with a specific application version:

```sh
git clone https://github.com/Funkenjaeger/reflex ~/projects/reflex
git -C ~/projects/reflex checkout v1.2.0-rc.3
```

`v1.2.0-rc.3` is the tag the current image's venv was locked against
(see the [changelog](changelog.md)). A different tag may add a dependency the
image's venv does not carry, in which case provisioning needs the network after
all — acceptable for development, not for recovery.

**The commissioned config capture.** A directory or a tarball, carried to the Pi
by hand. `02-restore.sh` cannot fetch it: that would mean this repository
knowing where the backup host lives, and nothing machine-specific lives here.
**Check the date on it** — a stale capture restores stale geometry, and nothing
downstream notices.

**Optionally, `flashed.json`** — the record of what firmware is on the STM32.
Its loss costs knowledge, not function, which is why it is a separate optional
argument.

## Run it

```sh
cd ~/projects/elspi/deltas
sudo ./provision.sh --app /home/default/projects/reflex \
                    --config-backup /path/to/elspi-reflex-config-YYYY-MM-DD \
                    --firmware /path/to/flashed.json      # optional
```

`--dry-run` is available on `provision.sh` and on each phase, and changes
nothing. Missing arguments are checked **up front**, before phase 1 does half
the work: a machine with an enabled service and no commissioned config is the
one most likely to get started by mistake.

## Three phases, three different failure contracts

`provision.sh` runs the three phases in order. It is a convenience, not a merge:
each keeps its own contract and its own exit code, and a failure stops
everything after it. Each is also runnable alone.

| Phase | Contract | Re-runnable? |
|---|---|---|
| `01-converge.sh` | idempotent — run it as many times as you like | yes, always |
| `02-restore.sh` | **refuses to invent data**; hard-fails when the backup is absent | yes, but never silently |
| `03-interactive.sh` | blocks on a human; asks, never assumes | yes; skips what is already set |

The ordering is load-bearing: converge before restore, because restore needs the
service user's ownership settled; restore before the application is ever
*started*, because starting first means coming up on whatever
`/var/lib/reflex-config` happens to hold — which after a fresh flash is nothing.

### Phase 1 — converge

Installs the application wiring and prints what it resolved: the service user
and where it learned it (`/etc/elspi-image.json`, or a built-in fallback), the
application path, and the venv path. Then, step by step with an `ok` line for
each:

* **The venv bridge.** The image's venv lives at `/opt/reflex-venv`, outside the
  application checkout, while the application's own `start.sh` activates
  `<app>/ui/.venv`. Converge symlinks the checkout's `.venv` at the image venv
  and runs `uv sync --no-dev` against it, so stock `start.sh` works unmodified
  and the sync finishes in seconds. It **hard-fails if `/opt/reflex-venv` is
  missing** — on a machine without it, `uv` would silently start compiling Kivy
  from source, which is the hours-long network-dependent step the image exists
  to remove.
* **The unit.** `reflex-ui.service` is installed *from the checkout*, never
  copied into this repository. A copy would drift from the application that has
  to start under it.
* **The DRM mode.** Converge calls `/usr/local/sbin/elspi-drm-mode`; it never
  writes `User=` itself. Then it gates on systemd's **resolved** `User=` and
  refuses to continue if it still says `root` — the application's stock unit
  says `User=root`, and the drop-in the switcher writes is what overrides it.
  If that gate fires, the drop-in did not take.
* **The sudoers grants.** It asserts the `NOPASSWD` grants exist for restarting
  the UI, and — the check that matters — that they do **not** extend to any
  other unit or to an arbitrary command.
* **The polkit rule.** The service user has no seat and no login session, and
  NetworkManager authorizes by active session, so without the rule the UI can
  read network state and change nothing. Converge exercises it with the one
  side-effect-free operation available (turning an already-on radio on) and
  reports **UNPROVEN** rather than `ok` if it could not — for instance if the
  radio is off, or `systemd-run` is missing.

It ends by saying the application is **not started**, and why.

### Phase 2 — restore

Accepts a directory or a tarball and normalises it. It gates on the *content*,
not the path: a non-empty `Els-0.yaml` must be present, and there must be at
least 15 `.yaml` files (the live machine carried 19 at last count). A partial
capture is refused rather than restored as a subset.

Then it **prints the commissioned values it is about to install** — the backlash
steps, the last measured calibration, the ceiling, the drift notice — because
"these files were copied" is checkable and "these are the right numbers" is not,
and only a human who knows the machine can make that call.

Any existing config is **moved aside**, never overwritten in place, so a wrong
run leaves the previous state on the disk. After writing it asserts the files
landed, the count matches the source, and the directory is owned by and
*writable by* the service user — the application writes there at runtime, and
read-only would look fine until the first write.

It ends by telling you the values above are what this machine will use, and to
stop now if they are not what you expect.

### Phase 3 — interactive

Five prompts, in order, and it skips whatever is already set:

1. **The password** for the service user — for the case where Imager's seed did
   not carry one, or you want to change it.
2. **SSH access** for your workstation.
3. **Network** — anything the Wi-Fi seed did not cover.
4. **The firmware toolchain — report only.** The dev-role question is retired.
   The toolchain bytes are baked into the image unconditionally, and since the
   firmware moved into the application monorepo there is no second repository to
   clone and nothing for a "no" to withhold. This phase reports whether the
   toolchain is present and whether `<app>/fw` landed in the checkout.
5. **The OT state-pull key.**

It is the only phase that cannot run unattended, which is why it is last.
`--skip-interactive` skips it; the account may then still be locked.

## Starting the UI

**Nothing in provisioning starts the application.** That is deliberate: phase 2
printed the commissioned values, and starting before a human has looked at them
means coming up on whatever happened to be in the file.

When you are satisfied:

```sh
sudo systemctl start reflex-ui
journalctl -u reflex-ui -f
```

The touchscreen should show the UI within a few seconds. That is the end state
of provisioning: the screen is live, the journal is quiet, and
`systemctl is-active reflex-ui` says `active`.

### If the screen stays black — the DRM ladder

The application draws directly to KMS/DRM: no X server, no compositor, and a
service user with no seat and no session. Taking the display therefore depends
on a mechanism, and the image ships **two** of them plus a switcher, so changing
mechanism costs one SSH command instead of a reflash.

```sh
elspi-drm-mode                  # what is it now?
elspi-drm-mode first-opener     # the image default, verified on hardware 2026-09-13
elspi-drm-mode cap-sys-admin    # the floor, a last resort
```

Stop at the first rung that works.

1. **`first-opener`** is already active and is the verified mode. If the UI takes
   the display, you are done.
2. **If it fails, check Plymouth before changing mode.** Plymouth's DRM renderer
   is itself a DRM master, and the likeliest failure is that it has not released
   the display. `systemctl status plymouth-quit-wait.service`; try stopping
   Plymouth by hand and restarting the application. **If that fixes it, the
   fault is ordering rather than mechanism** — a much better answer than
   escalating privilege, and one that changes what the image should ship, so
   write it up.
3. **`cap-sys-admin`** takes the display regardless of who else opened the
   device. If a machine ends up resting here, that is worth recording: it is a
   floor, not a destination.

There is no rung between 2 and 3. A third mechanism (`logind-seat` — autologin
on tty1 plus a user unit) existed for the case where `first-opener` failed; it
did not fail, so the machinery was deleted rather than maintained, and the
switcher now refuses that name. If both the Plymouth check and `cap-sys-admin`
fail, that is a new finding and not a mode to switch to — read `git log` for the
deleted seat machinery rather than reinventing it.

## Firmware on a brand-new board

The firmware toolchain is **already in the image** — `gcc-arm-none-eabi`,
`cmake`, `openocd` and their udev rules — because firmware is built and flashed
*from* the lathe. Nothing here needs installing.

But a **brand-new controller board has no bootloader and no firmware**, and the
first load has to go in over SWD with a hardware programmer. That is a separate
procedure on the electronics bench rather than a provisioning step, and it is
documented in the application repository:

**→ [Installing Reflex — firmware](https://github.com/Funkenjaeger/reflex/blob/main/docs/setup/installing.md)**

Once a board has firmware on it, subsequent updates are built and flashed from
the Pi with the toolchain this image already carries. Note that this board
requires a **power cycle** after flashing before the new firmware executes.
