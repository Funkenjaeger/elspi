# Provisioning

Everything the image deliberately does **not** contain. The image is
*flash → boot*; this is *restore → run*.

[The seam](design/seam.md) decides what lives on which side of the line. This
page is the other side of it: the application, the commissioned machine data,
and the credentials that could not be typed into Imager.

!!! warning "First commissioning: `--fresh`, then measure everything before use"
    `provision.sh` **requires** either `--config-backup` or `--fresh` — never
    both, and never neither. That is correct for the machine this repository
    was built to recover, and it is also how a **brand-new lathe, never
    commissioned,** gets provisioned: pass `--fresh` in place of
    `--config-backup`.

    `--fresh` is a deliberate, loud choice that first commissioning is
    happening, not a guess and not a default. It skips the restore phase
    entirely — nothing is written into `/var/lib/reflex-config`, nothing is
    generated, the application's own defaults apply — and it refuses outright
    if that directory already holds anything, so a fresh provision can never
    mask existing commissioned data. It prints an UNCOMMISSIONED banner at the
    start of phase 2 and again in its final summary, because axis geometry,
    servo polarity, backlash calibration and Z scale counts/mm are
    commissioned machine data that nothing here can generate — every one of
    them must still be measured off the physical lathe before this machine is
    trusted to cut anything.

    If you already have commissioned values to bring onto this machine — a
    capture from the machine's own history, or from another Pi — that is
    `--config-backup`, not `--fresh`, and it belongs on this command line. If
    instead you want to bring them on **after** the machine is up and running
    on `--fresh` defaults, that is the **USB import on the reflex Setup
    screen** — the user-facing route onto a machine this tooling deliberately
    left uncommissioned, and it needs no SSH, no CLI and no re-run of
    `provision.sh`.

## USB sticks

The **USB import/export** mentioned above (and the reflex Setup screen's
Export button, for pulling a commissioning bundle back off the machine) needs
a plugged-in stick to actually show up as a filesystem before either button
can see it. `stage-elspi/13-usb-automount` is what makes that happen; nothing
in the application mounts anything itself.

**Consumer**: `ui/reflex/utils/usb.py`'s `list_removable()` (the reflex
`integration` branch) reads `/proc/mounts` and treats anything mounted under
`/media` or `/run/media` as removable media — no udisks, no subprocess, no
polkit prompt, by that module's own design. `export_bundle()` and
`find_bundles()` both build on it. This stage mounts under `/media/<name>`,
one of those two roots, and changes nothing on the reflex side.

**Mechanism**: a udev rule
(`/etc/udev/rules.d/90-elspi-usb-automount.rules`) matches `ACTION=="add"`
USB block partitions carrying a filesystem (`ENV{ID_FS_USAGE}=="filesystem"`)
of type `vfat`, `exfat` or `ntfs`, runs a small sanitizer helper
(`/usr/local/lib/elspi/elspi-usb-mount-name`) to turn the partition's
filesystem label into a safe, collision-free directory name, and hands the
result to **`systemd-mount`** — not `mount(8)` and not udisks2. That is not a
style preference: `systemd-udevd.service` ships `PrivateMounts=yes`, so a
`mount` invoked directly from a udev rule's `RUN+=` would only take effect
inside udevd's own private mount namespace and would never become visible to
`reflex-ui`. `systemd-mount` instead asks `systemd` (PID 1, unsandboxed) to
perform the mount over its D-Bus API, which is why it works from here at all.
`--no-block` is required, not optional, because `RUN+=` programs must be
short-lived (`udev(7)`).

The mount is owned by the **service user** — `-o uid=,gid=` are the service
user's real uid/gid, read out of the image's own `/etc/passwd` at build time
and substituted into the rule (never a hardcoded number), because the vfat
and exfat kernel drivers accept only a numeric `uid=`/`gid=`, never a
username. `umask=022,nosuid,nodev,noexec` round out the mount options.

**Filesystems**: `vfat` and `exfat` are kernel drivers on this image's
Raspberry Pi kernel (`docs/design/runtime-inventory.md` records
`6.18.34+rpt-rpi-v8`); this was **not independently verified against a built
image** in this repository — no pi-gen/docker build was run to produce one —
and is worth confirming on real hardware. `ntfs` here means **ntfs-3g**
(FUSE), already installed by `stage2/01-sys-tweaks/00-packages` for its own
reasons; that package is what provides the `mount.ntfs` helper `-t ntfs`
dispatches to. It is **not** the newer in-kernel `ntfs3` driver. No package
was added by this stage: `systemd-mount`, `blkid`/`mount` and the two kernel
drivers above are all already part of the base image or the RPi kernel, and
`ntfs-3g` is already installed for reasons of its own
(`stage2/01-sys-tweaks/00-packages`, which also installs `udisks2` — unused
by this design; see below).

**Removal**: the rule passes **`--bind-device`** to `systemd-mount`, which
binds the automount unit to the backing device's lifetime — `systemd-mount(1)`
is explicit that *without* it, "the automount unit stays around, and
subsequent accesses will block until backing device is replugged" after a
stick is pulled. `--bind-device` is what makes removal actually unmount
cleanly; `--collect` on top unloads the resulting stopped/failed transient
units instead of leaving them as clutter in `systemctl list-units`. There is
deliberately no separate `ACTION=="remove"` rule calling `systemd-mount
--umount` — by the time a remove event fires, the device node it would need
to resolve is already gone, and `--bind-device` has already torn the mount
down.

**Why not udisks2**: `stage2/01-sys-tweaks/00-packages` already installs
`udisks2`, for reasons unrelated to this stage, but this design does not use
it. udisks2 authorizes mounts over polkit against a logind session, and the
service user runs `reflex-ui` with none — the same failure shape
`stage-elspi/05-service-user` already worked around for NetworkManager (see
its polkit rule). A udev rule plus `systemd-mount` sidesteps that
requirement entirely.

## Image identity: `/etc/elspi-release` and `IMAGE_RELEASE`

Every image declares what it is in `/etc/elspi-image.json`
(`stage-elspi/11-manifest/00-run.sh`), and, from order 2026-09-14#5 onward,
in a second file rendered FROM the same data: `/etc/elspi-release`, in
os-release's flat `KEY=VALUE` shape. One declaration, two renderings --
`stage-elspi/11-manifest/files/render-release.sh` owns the mapping between
them, so nobody hand-writes the flat file to agree with the JSON by eye.

The **UI and order 2026-09-14#6's reflex updater read the flat file**; the
verification harness and the delta layer keep reading the JSON. Agreed key
names:

| `/etc/elspi-release` key | `/etc/elspi-image.json` path        | What it is |
|---------------------------|--------------------------------------|------------|
| `ELSPI_IMAGE_RELEASE`     | `.image_release`                     | monotonic integer, see below |
| `ELSPI_IMAGE_BUILD`       | `.image_build_sha`                   | git rev of this repo at build (elspi is a soft fork of pi-gen; there is no separate checkout) |
| `ELSPI_IMAGE_DATE`        | `.built_utc`                         | build timestamp, UTC |
| `ELSPI_REFLEX_COMMIT`     | `.reflex_lock_commit`                | the reflex commit the venv was locked against |
| `ELSPI_PYTHON`            | `.runtime_versions.python`           | `python3 --version`, measured in the chroot |
| `ELSPI_KIVY`              | `.runtime_versions.kivy`             | installed Kivy's dist-info version |
| `ELSPI_UV`                | `.runtime_versions.uv`               | `uv --version`, measured in the chroot |

`ELSPI_IMAGE_RELEASE` is the one field that is **not** measured -- it is a
manually maintained counter, like a version file, that the reflex updater
compares against to decide whether an image is new enough. It started at `1`
for v2026.09.13's successor (the first image to carry this file).

**Bump `IMAGE_RELEASE` whenever an image adds an apt package or moves a
runtime dependency** -- anything that changes what the venv or the rootfs
provides such that a delta or the application could depend on the new state.
A change that touches only this repository's own scripts (a sed anchor, a
comment, a test) does not need a bump. When in doubt, bump: the updater
comparing a stale number against a newer image is a much smaller failure than
the reverse.

`stage-elspi/11-manifest/00-run.sh` measures `ELSPI_PYTHON` and `ELSPI_UV` by
actually running `python3 --version` / `uv --version` inside the chroot
(`on_chroot`, the same mechanism `stage-elspi/08-venv` uses to build the venv
in the first place) rather than hardcoding a number that could drift from
what the build actually produced. That measurement needs a real chroot, so
`tests/dry-run-stages.sh` -- which exercises this substage without one, on a
plain CI runner -- gets a loudly-labelled placeholder value instead
(`"unmeasured (no chroot available)"` / `"unmeasured (no venv)"`) rather than
a number nobody took. Only a real pi-gen build produces the true values.

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

*AMENDED 2026-09-21 — this is the PROVISION path and still holds here. It is
no longer the whole story for a FRESH CARD: the image now carries the app
(`docs/design/seam.md`, call 1 amendment 2026-09-21), and first boot starts it
GATED on commissioned config being present. An unrestored card must come up in
an explicit uncommissioned state, never silently on in-code defaults.*

### Phase 2 — restore

Accepts a directory or a tarball and normalises it. It gates on the *content*,
not the path: a non-empty `Els-0.yaml` must be present — that is the public
minimum, because it is the one file reflex cannot start *correctly* without.
Every other settings file the application recreates with its own defaults
when it is missing, and with no `Axis-*.yaml` it builds four identity axes, so
a missing `Axis-*.yaml` is named in a warning. **A site that knows how many
files its machine carries should raise the bar**:
`ELSPI_RESTORE_MIN_YAML=<n>` in its `site.env` (see [Site hooks](#site-hooks)),
and a capture with fewer `.yaml` files is then refused as partial rather than
restored as a subset. A site can raise the bar, never lower it. All of these
checks only read, so they run before the phase asks for root.

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

Four prompts, in order, and it skips whatever is already set:

1. **The password** for the service user — for the case where Imager's seed did
   not carry one, or you want to change it.
2. **SSH access** for your workstation.
3. **Network** — anything the Wi-Fi seed did not cover.
4. **The firmware toolchain — report only.** The dev-role question is retired.
   The toolchain bytes are baked into the image unconditionally, and since the
   firmware moved into the application monorepo there is no second repository to
   clone and nothing for a "no" to withhold. This phase reports whether the
   toolchain is present and whether `<app>/fw` landed in the checkout.

It is the only phase that cannot run unattended, which is why it is last.
`--skip-interactive` skips it; the account may then still be locked.

There was a fifth prompt until 2026-09-13: enrolling the machine with one
estate's monitoring collector, via a purpose-scoped forced-command SSH key.
That named a particular network, so it is a **site hook** now.

## Site hooks

Some provisioning steps are true of **one installation** rather than of the
image — enrolling with a monitoring system, installing a payload that knows a
backup host's name. Nothing machine-specific lives in this repository, so those
steps live in a directory of their own, outside it, and `provision.sh` runs
them:

```sh
sudo ./provision.sh --app /home/default/projects/reflex \
                    --config-backup /path/to/elspi-reflex-config-YYYY-MM-DD \
                    --site-hooks /path/to/site/hooks
```

A hook is an **executable `*.sh` directly in that directory**. All of them run,
in sorted filename order, as root, after phase 3 — and still after phase 2 if
`--skip-interactive` skipped phase 3. The directory must exist, and
`provision.sh` refuses a path that does not *before* phase 1 changes anything.

Each hook is run with `DELTAS_DIR`, `SERVICE_USER`, `HOME_DIR`, `APP_DIR`,
`CONFIG_DIR` and `DRY_RUN` exported; `DELTAS_DIR` is there so a hook can
`. "${DELTAS_DIR}/lib.sh"` and get the same `say`/`run`/`assert` helpers the
phases use. `DRY_RUN` is passed through, not enforced — a hook is responsible
for honouring it. **A hook that fails stops provisioning, named**, which is why
hooks run last.

The same directory may also hold a **`site.env`**: the site's *settings* for
the phases, as opposed to steps that run after them. It is read before phase 1
and parsed as data, never sourced — every line is `ELSPI_<NAME>=<value>` (a
blank line or a `#` comment aside), anything else stops provisioning with its
line number, and each value is exported to the phases. Today one phase reads
one: `ELSPI_RESTORE_MIN_YAML` raises phase 2's content bar. Run
`02-restore.sh` on its own and pass it in the environment instead
(`sudo ELSPI_RESTORE_MIN_YAML=<n> ./02-restore.sh …`).

`--site-hooks` is optional and this repository ships no hooks. Without it,
`provision.sh` says `no site hooks (none given)` and carries on. The full
contract, for anyone writing one, is in
[`deltas/README.md`](https://github.com/Funkenjaeger/elspi/blob/master/deltas/README.md).

## A site build config

The build has the same seam. `ELSPI_SITE_CONF=/path/to/site.conf ./build-elspi.sh`
sources that shell file **after** `elspi.conf`, so it can override any of it —
`TIMEZONE_DEFAULT`, `LOCALE_DEFAULT`, `KEYBOARD_*`, `TARGET_HOSTNAME`,
`REFLEX_*` — and set the one board knob the public image leaves off:
`ELSPI_USB_MAX_CURRENT=1`, which writes `usb_max_current_enable=1` into
`config.txt`. **A Raspberry Pi 5 powering a USB touchscreen may need it**:
without it the Pi 5 limits its USB ports to 600 mA unless the supply
advertises 5 A, and a panel drawing more browns out. `build-elspi.sh` mounts
the file into the build container and forwards the variable; a name that is
set but not a readable file stops the build. The image records only *whether*
a site config was applied (`build_defaults.site_build_config_applied` and
`boot_config.usb_max_current_enable` in `/etc/elspi-image.json`), never its
path or contents, and `tests/verify-image.sh` checks `config.txt` and the time
zone against those declarations.

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

For the software steps as this image actually bakes them — the toolchain
that is already installed and where the checkout the delta layer expects
lives — see **[First load (SWD)](swd-first-load.md)**. Wiring the
programmer itself is still a bench procedure and is only a placeholder there.

Once a board has firmware on it, subsequent updates are built and flashed from
the Pi with the toolchain this image already carries. Note that this board
requires a **power cycle** after flashing before the new firmware executes.
