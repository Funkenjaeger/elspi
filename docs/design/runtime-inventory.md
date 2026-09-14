# What the image has to produce

Captured **2026-08-17** from the live elspi, from `C:\projects\reflex\ui`, and from
`bartei/ospi@main` for comparison. This is the input spec for our custom stage.
Re-verify before trusting it — it is a snapshot of a machine, not a contract.

Nothing here has been decided. Open decisions are collected at the bottom.

## The target

Raspberry Pi 5 Model B Rev 1.0 · Raspbian GNU/Linux 13 (trixie) · kernel
`6.18.34+rpt-rpi-v8` (`aarch64`) over an **`armhf` userland** — every dpkg entry is
`:armhf`. System `python3` is **3.13.5**.

`reflex-ui` runs as **root** from `/reflex-ui` (a symlink to
`/home/default/projects/reflex/ui`), unit `/etc/systemd/system/reflex-ui.service`,
`ExecStart=/reflex-ui/start.sh`, `Restart=on-failure`,
`After=network.target auditd.service`.

## Kivy must be compiled, not downloaded

The single most consequential finding. The installed
`Kivy-2.3.1.dist-info/WHEEL` reads `Tag: cp313-cp313-linux_armv7l` — **no such
wheel exists on PyPI**. It was built from sdist on the device.

ospi does not hit this: on its Python version `rotary-controller-python` pulls a
prebuilt wheel, so its stage installs *runtime* SDL2 packages only. Ours cannot.
The stage needs the build toolchain as well:

```
libsdl2-dev libsdl2-image-dev libsdl2-mixer-dev libsdl2-ttf-dev
libmtdev-dev python3-dev build-essential pkg-config
```

(Cython arrives transiently through build isolation; it is not installed on elspi
as a package.)

## Packages

ospi's graphics stage (`stage-base/40-rotary-controller/00-packages`) is the right
starting point but is **incomplete for us**:

```
python3-virtualenv libgl1 libgles2 libegl1 libmtdev1t64
libsdl2-2.0-0 libsdl2-gfx-1.0-0 libsdl2-image-2.0-0
libsdl2-mixer-2.0-0 libsdl2-net-2.0-0 libsdl2-ttf-2.0-0
```

Add, with reasons:

| Package | Why |
|---|---|
| the `-dev` set above | Kivy compiles from source here |
| `libgbm1`, `libdrm2` | SDL2's `kmsdrm` driver dlopens both. They arrive as Mesa/SDL2 dependencies today, i.e. by accident of resolution — name them if KMS/DRM is a requirement rather than a coincidence |
| `libgl1-mesa-dri`, `mesa-libgallium` | the actual V3D DRI driver (`OpenGL renderer V3D 7.1.7.0`). Without it you get llvmpipe or a hard EGL failure. A lean pi-gen base may not seed these |
| `network-manager` | the `nmcli` **Python** package shells out to the `nmcli` **binary**. No Python manifest declares this. ospi enables the service but never lists the package — it inherits it from the Raspberry Pi OS base |

Two things **not** to do:

- **Do not install `libinput`.** It is absent on the working machine. Kivy's touch
  path is `MTD`/`ProbeSysfs` on `/dev/input/event6` via **libmtdev**.
- **Do not strip the X11 client libraries.** `libsdl2-2.0-0` carries hard `NEEDED`
  links to `libX11`, `libXext`, `libXcursor`, `libXi`, `libXfixes`, `libXrandr`,
  `libXss`, `libxkbcommon`, `libdecor-0` and the Wayland client libs. They come in
  as its dependencies and must stay. What must be absent is the X *server* and any
  Wayland *compositor* — see the SDL fallback note below.

## The application

`pyproject.toml` (hatchling, `requires-python = ">=3.11,<4.0"`), resolved through
`uv.lock` — there is no `requirements.txt` and no `poetry.lock`:

```
cachetools 7.0.5 · keke 0.2.0 · kivy 2.3.1 · kivy-garden 0.1.5
minimalmodbus 2.1.1 · nmcli 1.7.0 · pydantic 2.12.5 · pyserial 3.5
pyyaml 6.0.3 · aiohttp 3.13.3 · sentry-sdk 2.55.0 · transitions 0.9.3
```

The venv at `/reflex-ui/.venv` is **uv-created and has no `pip`**. `uv` itself is a
hand-placed ~50 MB binary at `/home/default/.local/bin/uv` (version 0.11.23) — it
is not a Debian package and nothing provisions it today.

The live venv also carries the `dev` group (pytest, coverage,
python-semantic-release, python-gitlab, gitpython, rich, …) because elspi runs
`uv sync` against a live checkout. An image should install the main group only —
roughly 20 fewer packages.

## Launch environment

`deploy/start.sh` on the desktop is **byte-identical** to the live
`/reflex-ui/start.sh`. It exports exactly:

```sh
export KCFG_KIVY_KEYBOARD_MODE="systemanddock"
export KCFG_KIVY_LOG_DIR="/var/log"
export KCFG_GRAPHICS_WIDTH=1024
export KCFG_GRAPHICS_HEIGHT=600
export KCFG_GRAPHICS_FULLSCREEN=auto
export REFLEX_CONFIG_DIR=/var/lib/reflex-config
```

then sources `$UI_DIR/.venv/bin/activate` and `exec python -m reflex.main`.

**KMS/DRM is selected by absence, not by configuration.** There is no
`SDL_VIDEODRIVER`, no `DISPLAY`, no `KIVY_WINDOW`, no `KIVY_GL_BACKEND`. SDL2 falls
back to `kmsdrm` only because neither `DISPLAY` nor `WAYLAND_DISPLAY` exists. If
the image ever ships a compositor, the backend changes silently.

Runtime confirmation from `/var/log/kivy_26-08-17_6.txt`: `Window: Provider: sdl2`,
`GL: Backend used <sdl2>`, `OpenGL version 3.1 Mesa 25.0.7-2+rpt4`, vendor
`Broadcom`, renderer `V3D 7.1.7.0`, `virtual keyboard allowed, single mode, docked`.

## Boot configuration

Live `/boot/firmware/config.txt` differs from stock pi-gen in exactly these ways:

```
dtparam=i2c_arm=on          # stock ships this COMMENTED
dtparam=spi=on              # stock ships this COMMENTED
enable_uart=1               # not in stock
camera_auto_detect=0        # stock ships =1
disable_splash=1            # not in stock
usb_max_current_enable=1    # local addition: "Force high current USB mode to
                            # mitigate brownouts of USB-attached touchscreen display"
```

`cmdline.txt`: `console=tty1 root=… rootfstype=ext4 fsck.repair=yes rootwait quiet
splash logo.nologo plymouth.ignore-serial-consoles`.

Keep upstream's `[pi5] dtoverlay=nospi10` block — elspi is a Pi 5 that uses SPI,
and this is one of the two lines ospi dropped.

`usb_max_current_enable=1` is a **hardware workaround for the real display** and
must survive into the image; it exists nowhere in ospi or upstream.

## Found while inventorying: audio is broken on elspi right now

Not a provisioning issue — a live defect, recorded here because it was found here
and because it changes what "reproduce the machine" should mean.

```
[CRITICAL] AudioSDL2: Unable to open mixer: ALSA: Couldn't open audio device:
           Unknown error 524
```

plus a failed `snap.wav` load. Elspi's `/etc/asound.conf` is a single malformed
line — `defaults.pcm.card 1 defaults.ctl.card 1` run together — where ospi ships a
proper `stage-base/14-asound` file. So the image should take **ospi's** approach
rather than copying elspi's current state, which would faithfully reproduce a bug.

## Open decisions — do not resolve these silently

1. **The image-vs-deltas seam.** Everything above has to land on one side or the
   other. This is the first blocking decision and it is Evan's.
2. **`uv` or `python3-venv` + `pip`?** The machine uses `uv` (unpackaged, hand
   placed, pinned nowhere). ospi uses `python3-virtualenv` + `pip install .`.
   Falling back to pip resolves versions differently from `uv.lock`.
3. **Pillow.** The live Kivy log shows `img_pil` among active image providers, but
   `pillow>=10.0.0` is declared only in the **dev** group. Installing the main
   group alone silently drops that provider. Promote it, or accept `img_sdl2`.
4. **Pin `SDL_VIDEODRIVER=kmsdrm`?** Today the requirement is enforced by absence.
   Pinning makes it a stated contract; not pinning keeps upstream's flexibility.

## Decided 2026-09-01: the image runs `reflex-ui` as a NON-ROOT service user

Evan's call, on a closeloops card: *"is there any reason we need to / should
persist the OSPI decision to run the UI as root? that feels like it's been a pain
in the ass on a regular basis because agents don't have access to read configs and
junk, and even I have to do sudo shenanigans when I'm ssh'ed in."* He chose to
relieve the live pain now **and** bake the real fix into the image.

Root was inherited from ospi. It was never justified against this machine, and
when it finally was — measured on the live elspi 2026-09-01, not reasoned — four
of the five reasons turned out to be self-inflicted:

| what | live state 2026-09-01 | needs root? |
|---|---|---|
| `/dev/ttyAMA0` (Modbus to the STM32) | `crw-rw---- root dialout`; `default` **is** in `dialout` | **No** |
| `/root/.kivy/config.ini` | root-only — see the section below | **No.** It is root-only *because* the service is |
| `/var/lib/reflex-config` | `drwxr-xr-x root root`, and reflex **writes** there | **No** — one `chown` |
| `KCFG_KIVY_LOG_DIR=/var/log` | Kivy writes `kivy_*.txt` straight into `/var/log` | **No** — gratuitous |
| **DRM/KMS master** | `/dev/dri/card0` `crw-rw----+ root video`; `default` **is** in `video` (44) and `render` (992) | **This is the only real one** |

`default`'s full group set, for the record:
`adm dialout cdrom sudo audio video plugdev games users input render netdev spi i2c gpio`.
Every device permission the application needs is **already granted to that user**.

### The one real blocker: DRM master, not device permission

Group permission on `/dev/dri/*` is already satisfied. What root actually buys is
**DRM master arbitration**. `reflex-ui.service` is a plain system unit with
`User=root`/`Group=root` and no logind session, so it is not attached to a seat —
`seat0` exists on the machine, but the service never joins it. A non-root process
becomes DRM master by being the active session on a seat, which means an autologin
session on tty1 plus a user service, or an explicit grant.

**So the stage must decide HOW, not WHETHER.** Options, none yet tested:

1. autologin on tty1 + a `systemd --user` unit, so logind grants the seat;
2. a system unit with `TTYPath=/dev/tty1` and the seat plumbing done explicitly;
3. keep a system unit and grant only the capability needed rather than full root.

### RESOLVED 2026-09-07: the stage ships ALL THREE, selectable at runtime

Not by picking one. The stage installs each option as a systemd drop-in under
`/usr/share/elspi/drm-modes/` plus a switcher, `/usr/local/sbin/elspi-drm-mode`.

The reason is the constraint that dominates this machine: **Evan has no
terminal on elspi.** Choosing one option and baking it in makes every wrong
guess cost a reflash and a lathe power cycle. With the switcher, an attempt
costs one SSH command:

```sh
elspi-drm-mode cap-sys-admin && systemctl restart reflex-ui
```

`first-opener` is the image default, and the reasoning behind it corrects the
model above. **"A non-root process becomes DRM master only as a seat's active
session" is not the whole picture.** The DRM core also grants master to the
*first opener* of a device that has no master -- `drm_master_open()` on the
`open()` path, which carries no `CAP_SYS_ADMIN` check; the capability test in
`drm_master_check_perm()` guards the `SET_MASTER` ioctl for a process that is
*not already* master. On a console-only machine with no compositor there is no
competing master, so the seat machinery may simply not be needed.

**This is reasoning from kernel source, not a measurement**, and it is recorded
as a hypothesis rather than a finding. What it does buy is a cheap first thing
to try and a clear prediction: if `first-opener` fails, the most likely cause
is **Plymouth**, whose DRM renderer *is* a master. Hence
`After=plymouth-quit-wait.service` in the fragment -- load-bearing, not
cosmetic.

`logind-seat` was option 1 verbatim, kept as the first fallback. It
deliberately did **not** enable lingering: a lingering user manager starts at
boot with no session and therefore no seat, which is the opposite of the point.

`cap-sys-admin` is the floor, so the flash session always has a way to leave
the lathe working. If the machine ends up resting there, that is a finding to
write up, not a resting place.

### SETTLED 2026-09-13 on hardware: two modes, not three

`first-opener` took the display on the real Pi at the **first attempt**. The
hypothesis above — that the DRM core grants master to the first opener of an
unclaimed device, so the seat machinery is not needed on a console-only
machine — is now a measurement, and the `After=plymouth-quit-wait.service`
ordering was enough to keep Plymouth out of the way.

So **`logind-seat` was deleted**, not kept: the fragment, the tty1 autologin
fragment, and the user-unit generation inside `elspi-drm-mode`. It existed for
exactly one case — first-opener failing — which did not happen, and it was
strictly more machinery on a machine with no terminal.
The 2026-09-13 flash-session notes said to delete it if first-opener worked,
and it did. The switcher now refuses the name with a message naming the two
surviving modes rather than a bare "unknown mode", because an old note or the
printed field sheet is the likeliest reason anyone types it.

`cap-sys-admin` **stays**, for the reason stated above: it is the floor, not a
preference, and a verified default does not remove the need for a way to leave
the lathe working.

The option list earlier in this section is left as written. It is the record of
what was reasoned before anything was measured, and options 1 and 2 are the
part that turned out to be unnecessary rather than wrong.

### The other half of not being able to test this: SSH must survive a UI failure

`elspi.conf` sets `ENABLE_SSH=1` with `PUBKEY_ONLY_SSH=1`, and the build
**refuses to produce an image without `ELSPI_PUBKEY`**. That is deliberate and
it follows directly from the above. The service account's password is locked by
design, so password SSH cannot work; without a baked key, a first boot where
the UI does not come up is reachable only from the touchscreen -- which is
exactly the thing in question. An image with no way in turns every DRM
experiment back into a power cycle, which is what the switcher exists to avoid.


### THE HARNESS CANNOT ANSWER THIS — state it out loud

The planned verification harness is `systemd-nspawn --boot` under
`qemu-user-static`, and this document already records that it has **no GPU**, so
KMS/DRM and V3D are outside what it can see. **A non-root DRM-master path is
therefore NOT provable in CI.** The harness can assert the user exists, the groups
are right, the ownerships are right, the unit's `User=` is what we declared, and
that the app imports and starts far enough to fail on the display — and no
further. Whether it actually takes DRM master is a **hardware SD-card test item**,
which is exactly why that test stays mandatory.

Writing this here rather than discovering it during the build: a green CI run on a
non-root image means *"the userland is what we declared"*, never *"the appliance
comes up"*.

### What the stage must produce

- a service user (`default` is the obvious candidate — it already holds every
  needed group) and `User=`/`Group=` set explicitly in `reflex-ui.service`,
  never left to default to root;
- `/var/lib/reflex-config` owned by that user — it is **written** at runtime, so
  read permission is not enough;
- a log directory owned by that user, with `KCFG_KIVY_LOG_DIR` pointing at it
  instead of `/var/log`. Do **not** reproduce the current state, which scatters
  root-owned `kivy_*.txt` files across `/var/log`;
- Kivy's `config.ini` lands in that user's `~/.kivy`, not `/root/.kivy`.

### Interim, on the live machine (2026-09-01)

The live half was applied ahead of the image work, and deliberately **without**
changing `User=root` — so it cannot stop the lathe UI from starting: the config
directory and a new `/var/log/reflex` were chowned to `default`, the stray Kivy
logs moved out of `/var/log`, and `KCFG_KIVY_LOG_DIR` repointed. Root still runs
the service and can still write into a `default`-owned tree, so the change is
inert to the running application and purely removes the `sudo` friction.

**Sequencing note, and it is not optional:** the log directory must exist and be
writable *before* `KCFG_KIVY_LOG_DIR` moves. Evan has no terminal on elspi — the
machine is a touchscreen — so a UI that fails to start is recovered by physically
power-cycling a lathe. Nothing here is worth that.

### This also dissolves an existing blind spot

`/root/.kivy/config.ini` was carried in this document for weeks as an UNKNOWN
needing Evan's hands, precisely because the SSH user could not read it. It is
root-only **because the service is root**. Under a non-root service user the file
lives in that user's home, readable by Evan and by any rebuild. The fix removes
the blind spot rather than documenting around it.

## Resolved: `/root/.kivy/config.ini` exists, and is stock

Checked 2026-08-18 (needed root). The file is present, dated 22 March — written
when the machine was set up and never hand-edited since. Its contents are Kivy's
own defaults at `config_version = 27`.

It does **not** silently override the launch environment, because `KCFG_*`
environment variables take precedence over `config.ini` — and there is direct
evidence of that on this machine rather than just documentation: `config.ini` says
`log_dir = logs`, `start.sh` exports `KCFG_KIVY_LOG_DIR=/var/log`, and the live
logs are in `/var/log`. The environment wins.

So every graphics value that disagrees is won by `start.sh`:

| Key | config.ini | start.sh | effective |
|---|---|---|---|
| `width` | 800 | `KCFG_GRAPHICS_WIDTH=1024` | 1024 |
| `height` | 600 | `KCFG_GRAPHICS_HEIGHT=600` | 600 |
| `fullscreen` | 0 | `KCFG_GRAPHICS_FULLSCREEN=auto` | auto |

**Consequence for the image: nothing here to reproduce.** Kivy writes this file
with defaults on first run when it is absent, so a fresh image regenerates an
equivalent one — provided the Kivy version matches, since defaults and
`config_version` can move between releases. We pin 2.3.1.

Do not "tidy" the `[input]` section, though: `mouse = mouse` and
`%(name)s = probesysfs` are what put the touchscreen on Kivy's MTD/ProbeSysfs
path. Stock, but load-bearing.

### Two things noticed while reading it

Neither is a provisioning issue; both are about the running machine.

- `show_cursor = 1` — a mouse cursor on a touchscreen kiosk.
- `exit_on_escape = 1` against the unit's `Restart=on-failure`. A Kivy
  escape-exit is a **clean** exit, so systemd would not restart it and the lathe
  UI would stay down until someone intervened. Whether it is reachable depends on
  a keyboard being attached — the docked virtual keyboard may not expose Escape at
  all — but it is cheap to close from either end (`exit_on_escape = 0`, or
  `Restart=always`).
