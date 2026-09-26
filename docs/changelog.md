# Changelog

Releases of the elspi image. Each entry names the commit the image was built
from, because the image is the artifact and the commit is the only thing that
says what is in it.

## Unreleased — a fresh card boots straight into the UI

On branch `feat/first-boot-ui`, not yet released or verified on hardware.

* **First boot lands in the UI, UNCOMMISSIONED.** `stage-elspi/14-first-boot-ui`
  runs phase 1 of the delta layer (converge) against the baked reflex release,
  offline, and starts `reflex-ui`, once. It starts nothing unless the release
  carries reflex's commissioning guard, so the screen says *UNCOMMISSIONED* and
  nothing is saved until a restore or a deliberate dismissal. No SSH step. See
  [Flashing → After first boot](flashing.md#after-first-boot).
* **The venv is locked against reflex `v1.2.0`** (was `v1.2.0-rc.3`), the same
  release the image bakes. The only new dependency is `segno`.
* **The app is installed into the venv at build time** (`10b-app-install`),
  which proves an offline re-sync, so neither first boot nor recovery needs
  PyPI.
* **The delta scripts ship in the image** at `/usr/local/lib/elspi/deltas`.
* **`provision.sh`** refuses `--fresh` up front on a card that already holds
  config, and stops a running `reflex-ui` before phase 2.

## v2026.09.13 — first release

Built from [`8388fb5`](https://github.com/Funkenjaeger/elspi/commit/8388fb5),
**verified on hardware 2026-09-13**: a card flashed from this tree booted on the
real Pi 5, the display came up under a non-root process, and the first-boot seed
unit ran.

The first image that is a recovery path rather than a build experiment. Flashing
it is [one Imager command](flashing.md); making it run the lathe is
[one provisioning run](provisioning.md).

**What this release contains beyond the base image**

* **`git` is in the image.** The application half is a git checkout, so
  provisioning cannot clone or update it without `git` already present — and
  installing it at provision time would put a package mirror back on the
  recovery path.
* **A polkit rule for the session-less service user.** `default` runs the UI
  with no seat and no login session, and NetworkManager's default policy
  authorizes by *active session*. Without the rule the app can read network
  state and change nothing. The rule grants exactly that, to exactly that user.
* **The dependency lock is vendored from `reflex` `v1.2.0-rc.3`.**
  `stage-elspi/08-venv` builds `/opt/reflex-venv` from a `pyproject.toml` and
  `uv.lock` copied out of the application repo at that tag, plus a
  `REFLEX_COMMIT` stamp — so the image and the app are a version *pair*, and
  the pairing is written down rather than inferred.
* **The image manifest declares what has been proven on hardware.**
  `/etc/elspi-image.json` carries `verified_on_hardware` flags — set for the
  `first-opener` DRM mode and for the first-boot seed unit on the strength of
  this boot, and not set for anything that has only been checked offline. The
  test harness reads the manifest's declarations rather than hardcoding paths.
* **Delta-layer fixes.** Converge gates its sudoers check on the `NOPASSWD`
  grants themselves rather than on permission in general; the interactive phase
  retires the dev-role question (the firmware moved into the application
  monorepo, so there is no second repository to clone) and reports on `<app>/fw`
  instead.

**The predecessor, `addcb2e`, was never released.** It is the commit that
anchored the first-boot seed unit in `cloud-init.target` after the ordering
cycle that had stopped it running at all — a real fix, but the image built from
it was the one that exposed the cycle, not one anybody should flash.

**Documentation.** The design notes moved out of the repository root into
`docs/` at the same time as this release, and upstream pi-gen's `README.md`
moved to `README.pi-gen.md` so the front page could describe elspi. The
previous root `ELSPI.md` was retired into [Flashing a card](flashing.md) and
this page. `FORK.md`, `SEAM.md`, `RUNTIME-INVENTORY.md` and `VERIFICATION.md`
are now `docs/design/fork.md`, `seam.md`, `runtime-inventory.md` and
`verification.md`; `git log --follow` reaches their full history.

**Known gaps at this release**, stated rather than discovered:

* `deltas/provision.sh` **requires** `--config-backup`, and a brand-new machine
  has no backup to give it. Commissioning a lathe that has never been
  commissioned is not yet a path this repository supports — see
  [Provisioning](provisioning.md).
* Pillow is still a development dependency in the application's
  `pyproject.toml` while the UI uses `img_pil` at runtime. The fix belongs in
  the application repo and has not landed.
* There is no release automation. `tools/release-notes.sh` is run by hand when a
  release is cut and its output pasted into the GitHub release page.
