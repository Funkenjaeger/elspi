# Where the image ends and provisioning begins

**Status: DECIDED 2026-08-22.** Ratified by Evan in full — the criterion, the
proposed line, and all three contested calls — with one amendment to call 3,
recorded there. Superseded reasoning is left in place rather than deleted: the
value of this document is that the parts he *could* have disagreed with are
still visible.

Originally written as a recommendation, with the reasoning exposed so the parts
he disagreed with could be moved without unpicking the rest. Nothing needed
moving.

## The criterion

The obvious split — "OS in the image, application in the deltas" — is roughly
right and gives the wrong answer in the one place that matters most here. Three
sharper tests, applied in order:

1. **Can CI prove it?** `VERIFICATION.md` says a booted-rootfs harness can assert
   packages, units, users, and file contents, but nothing about GPU, touchscreen,
   or the STM32 link. **Anything in the image is machine-checkable on every push;
   anything in the deltas needs a real Pi and a human.** That is a strong reason
   to push work *up* into the image wherever it is otherwise a tie.
2. **Does recovery depend on the outside world?** This repo exists so that a dead
   SD card is survivable. Every step that needs PyPI, a package mirror, or the
   network at *recovery* time is a step that can fail on the day you need it. Bake
   those in.
3. **How often does it change?** Image rebuilds are hours (see the Kivy note
   below); a delta run is minutes. Anything that changes with the application
   belongs in the deltas or the image goes stale immediately.

Test 3 alone is what produces the naive split. Tests 1 and 2 are what move the
Python dependency set — including Kivy — up into the image, which is the one
genuinely non-obvious call here.

## The proposed line

### Image — rebuilt when the OS or the dependency set changes

| What | Why here |
|---|---|
| Base trixie/armhf, pi-gen stages 0–2 | definitional |
| `config.txt`, `cmdline.txt` — SPI, I²C, UART, camera off, quiet+splash, `usb_max_current_enable=1`, upstream's `[pi5] dtoverlay=nospi10` | firmware-level, needs a reboot, and wrong means no display or no Modbus. Cheap to bake, painful to retrofit |
| Plymouth theme and splash | boot-path, invisible to deltas |
| Every Debian package: SDL2 + Mesa DRI + libmtdev, `network-manager`, the build toolchain, `gcc-arm-none-eabi`, `cmake`, `openocd` | apt at provision time is a network dependency on the recovery path |
| `openocd` udev rules | static, not secret, never changes |
| `asound.conf` pinned to **card 0** (`defaults.pcm.card 0 defaults.ctl.card 0`) | static. **CORRECTED 2026-08-22** — this row used to read "ospi's shape, not elspi's current broken one", which was wrong twice over: elspi's file is BYTE-IDENTICAL to ospi's reference, and the shape was never the bug. The bug is the card index. `aplay -l` shows two HDMI outputs (`vc4hdmi0`/`vc4hdmi1`); the kernel reports `card1-HDMI-A-1 connected` and `card1-HDMI-A-2 disconnected`; `hw:1,0` returns exactly reflex-ui's `Unknown error 524` while `plughw:0,0` plays. The live file selected card **1**, the empty port. Bake card 0 |
| Locale and **timezone** | fixes the standing `-0500` bug at the source |
| `default` user and its full group list (`dialout plugdev gpio i2c spi render input video netdev sudo`) — **no password** | group membership gates device access; the password is a secret, see below |
| **The Python venv with every third-party dependency, Kivy already compiled — but not `reflex-ui` itself** | the non-obvious call; see below |

### Deltas — every provision, idempotent, minutes

| Phase | What |
|---|---|
| **Converge** | `reflex-ui` app code · `uv sync --no-dev` (near-instant, deps already present) · `reflex-ui.service` + enable · the single sudoers `NOPASSWD` rule · `/reflex-ui/config.ini` (`use_case = lathe`) |
| **Restore** | `/var/lib/reflex-config` from backup — **hard fail if absent, never generate** · `~/firmware/flashed.json` if available (soft — its loss costs knowledge, not function) |
| **Interactive** | the `default` user's password · `authorized_keys` for the desktop · WiFi/network credentials · anything naming another machine |

The three delta phases have deliberately different failure contracts: converge is
idempotent and retryable, restore refuses to invent data, and interactive blocks
on a human. Collapsing them into one "ansible run" loses that, and the restore
contract is the one that must not be softened.

## The three calls worth arguing about

### 1. The venv goes in the image, the app does not

**RATIFIED 2026-08-22**, both consequences accepted: the venv moves to a fixed
app-independent path (`/opt/reflex-venv`) out of the application checkout, and
image+app become a version pair that wants tagging together rather than floating.

This is the load-bearing recommendation. **No `cp313`/`armv7l` Kivy wheel exists**
(`RUNTIME-INVENTORY.md`), so somebody compiles Kivy from sdist. The only question
is who.

Putting it in the deltas means every provision compiles Kivy on the Pi — natively,
so not slow, but it makes recovery depend on PyPI still serving that exact sdist
on the day the SD card dies, in a machine shop, possibly with no network. Putting
it in the image means recovery is `flash → restore → run`, hermetically.

So: the image ships a venv containing everything in `uv.lock` **except the
`reflex` package itself**. The delta layer drops the app and runs
`uv sync --no-dev`, which finds its dependencies already satisfied and completes
in seconds.

Two consequences to accept honestly:

- **The venv needs a fixed, app-independent path** (say `/opt/reflex-venv`), with
  the app pointed at it. Today it lives at `/reflex-ui/.venv`, i.e. inside the
  application checkout, which cannot work if the image ships it.
- **The image and the app become a version pair.** Add a dependency to
  `reflex-ui` and the image's venv lacks it, so that provision needs network after
  all. That is acceptable — it is the *development* case, not the *recovery* case,
  and recovery should be pinned to a known-good image/app pair anyway. But it means
  images want tagging against app versions rather than floating.

### 2. No password anywhere in this repo — it is going public

**RATIFIED 2026-08-22.** Build the user locked; no credential enters this repo.

pi-gen takes `FIRST_USER_PASS` in its build config. Putting the real one there
would commit a credential to a repository that is intended to become public. Build
the user **locked**, and let the interactive phase set the password on first
provision. This is worth deciding now rather than discovering after the visibility
flip, because git history keeps what you commit.

### 3. The firmware toolchain is a real choice, not an oversight

**RATIFIED 2026-08-22 WITH AN AMENDMENT — "optional" means offered at PROVISION
time, not chosen at image-build time.** Evan's wording: the option is presented
during the interactive provision phase.

That is a change of *when the human is asked*, and it collides with test 2 if
taken literally, so the resolution is written out rather than left implicit:

- **The packages stay baked in the image.** Installing `gcc-arm-none-eabi`,
  `cmake` and `openocd` at provision time would put a package mirror back on the
  recovery path, which is the single thing test 2 exists to remove. Disk is cheap;
  a network in a machine shop on the day the SD card died is not.
- **The interactive phase asks whether to ENABLE the dev role** — the `reflex-fw`
  checkout, the openocd udev rules being active, PATH exposure — not whether to
  install it. A "no" gives an appliance that behaves like a lean image; the bytes
  are simply present and inert.
- So `STAGE_LIST` is NOT the mechanism. The stage always runs; the interactive
  phase carries the question, alongside the password and the network credentials.

If the intent was in fact apt-at-provision, this note is where to correct it —
that trade (a leaner image, a network-dependent recovery) is a real one, just not
the one ratified here.

`gcc-arm-none-eabi`, `cmake`, `openocd` and the `reflex-fw` checkout are developer
tooling living on a production lathe controller. They are on elspi because firmware
is flashed *from* there, so they stay. The original proposal was a separate,
optional pi-gen stage arranged with `STAGE_LIST`; the amendment above moves the
choice to provision instead, keeping the honest answer to "what does the appliance
actually need" available later.

## What this settles of the open sub-decisions

- **`uv`, not `pip`.** If the image builds the venv, it must reproduce `uv.lock`
  exactly, and pip would re-resolve. The stage should fetch a **pinned** `uv`
  (elspi has 0.11.23) and verify its checksum rather than curl-to-shell the latest.
- **Promote Pillow to a runtime dependency** in `pyproject.toml`. The live log
  shows `img_pil` active while `pillow` sits in the dev group; that is a latent bug
  independent of this seam, and a one-line fix in the reflex repo.
- **Pin `SDL_VIDEODRIVER=kmsdrm`** in `start.sh`. `start.sh` is already where the
  Kivy environment is declared, and it turns "works because nothing else is
  installed" into a stated contract.

## Prove the risky part first

The single highest-risk step in the whole plan is **compiling Kivy inside pi-gen's
emulated armhf chroot**. It is slow, it is on the critical path, and native-build
failures under `qemu-user` are not exotic. Before building the rest of the stage
around it, get that one step to succeed on its own — everything else here is
conventional pi-gen work, and this is the part that could force a redesign.
