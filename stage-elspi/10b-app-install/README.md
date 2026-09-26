# 10b-app-install — the baked app, installed at build time so first boot is offline

`stage-elspi/14-first-boot-ui` makes a fresh card boot straight into the UI by
running the delta layer's **converge** phase against the checkout
`10a-app-checkout` baked in. Converge's one step that can touch the network is
`uv sync --no-dev --frozen`, and on a card straight out of 10a it has real work
to do:

- **the `reflex` package itself.** `08-venv` installs everything in the lock
  *except* the project (`--no-install-project`) and deletes its uv cache. The
  project is installed editable, which means building it, which means fetching
  its build backend (`hatchling`) from PyPI.
- **any difference between two locks.** `08-venv` builds from the lock vendored
  at `files/REFLEX_COMMIT`; `10a` bakes the newest *full* release. They agree
  today (both `v1.2.0`, re-vendored 2026-09-26), but a full release cut before
  the next re-vendor adds whatever it adds (`v1.2.0` added `segno` over
  `rc.3`), and converge would fetch it.

`docs/design/seam.md` test 2 says a step that needs the network at recovery
time is a step that can fail on the day it is needed, and first commissioning
of a card nobody provisioned is the same day. So this substage does converge's
sync **here**, where the build already has the network (08-venv fetched Kivy's
sdist the same way), and then **proves** the card will not need it:

1. `uv sync --no-dev --frozen` — network allowed, fresh cache. Installs the app.
2. the same command with an **empty** cache and `UV_OFFLINE=1`. It must succeed
   with nothing to do. That is the first-boot hook's exact invocation, so a
   build that passes this gate is a card whose first boot is hermetic.

uv decides whether an editable project is current from `pyproject.toml`'s
mtime (measured 2026-09-26: unchanged mtime → `Audited`, offline, exit 0; a
touched `pyproject.toml` → rebuild → offline failure). pi-gen's export
preserves mtimes, and this stage gates that nothing it does moves that one.

## What else it measures

**Whether the baked release carries reflex's commissioning guard**, through
`../14-first-boot-ui/files/commissioning-guard.sh` — the same script the card
runs again at first boot. The answer goes to `/etc/elspi/reflex-app-commissioning-guard`
for `11-manifest`, which declares it as `baked_app.commissioning_guard` and
`baked_app.started_on_first_boot`. A release without the guard is **not** a
build failure: the image is still a correct recovery image, and the hook simply
does not start that app (see `14-first-boot-ui/README.md`).

## What it does not change

The checkout. It gates, after the install, that `HEAD` has not moved, every
ref is as 10a left it (so 10a's scrub still holds), no tracked file is
modified, and `ui/pyproject.toml`'s mtime is unchanged. The venv and the
checkout are then handed back to the service user with the same ownership gate
`08-venv` uses, because the in-app updater syncs into this venv as that user.

## Where it cannot be exercised

Like `08-venv` and `10a-app-checkout`, the interesting half runs through
`on_chroot` (an armhf `uv` against the image's venv), so `tests/dry-run-stages.sh`
cannot run it. The gate *is* the build: a CI image build that gets past this
substage has proven the offline re-sync on the real venv and the real release.
