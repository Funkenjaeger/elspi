# `14-first-boot-ui` — a fresh card boots straight into the UI

*A fresh elspi card boots straight into the UI: no SSH, no mandatory backup.*
Decided by Evan 2026-09-13; this substage was a trigger-only scaffold from
2026-09-20 until 2026-09-26, when the converge/start branch was written.
`DECISIONS.md`, "2026-09-26 first-boot-ui", has every choice below and its
alternative.

## What it installs

| path on the card | what it is |
|---|---|
| `/etc/systemd/system/elspi-first-boot-ui.service` | a oneshot, enabled in `cloud-init.target`, ordered after the seed and after Plymouth |
| `/usr/local/sbin/elspi-first-boot-ui` | `files/elspi-first-boot-ui.sh`, the hook |
| `/usr/local/lib/elspi/commissioning-guard` | `files/commissioning-guard.sh`: does a checkout carry reflex's commissioning guard? `yes`/`no` |
| `/usr/local/lib/elspi/deltas/` | this repository's `deltas/`, minus `tests/`, plus `SOURCE_COMMIT` |

## What the hook does, once

1. Reads `.paths.app_root` from `/etc/elspi-image.json` and finds the checkout
   `10a-app-checkout` baked there.
2. **Asks the guard check.** reflex's commissioning guard (first shipped in
   `v1.2.0-rc.5`) is what makes an unrestored card safe to start: the app
   latches "uncommissioned" once at startup, shows the UNCOMMISSIONED strip,
   and refuses every settings write until a restore or a deliberate dismissal.
   `docs/design/seam.md`'s 2026-09-21 amendment makes that state the condition
   for starting at first boot ("silent defaults are the one outcome this
   amendment forbids"). No guard: `verdict=REFUSED_NO_GUARD`, nothing runs.
3. **Leaves a provisioned card alone.** If `reflex-ui.service` is already
   enabled, somebody provisioned it: `verdict=ALREADY_PROVISIONED`.
4. **Runs converge** — `/usr/local/lib/elspi/deltas/01-converge.sh --app
   <app_root>` — with `UV_OFFLINE=1` and a private cache on `/run`.
   `10b-app-install` did the one networked step (installing the app into the
   venv) at build time and proved an offline re-sync succeeds, so first boot
   is as hermetic as recovery (`seam.md` test 2). If converge fails after
   enabling the unit, the hook disables it again, so the next boot cannot
   start a half-converged app: `verdict=CONVERGE_FAILED`, retried next boot.
5. **Starts** `reflex-ui.service` with `--no-block` (a oneshot waiting on
   another unit's job from inside its own ExecStart is the shape of a
   boot-time deadlock), watches for `active` for 60 s, and writes
   `/etc/elspi/first-boot-ui-done`: `verdict=STARTED` (or `START_UNCONFIRMED`).

Every later boot: the marker exists, the hook logs `verdict=DONE_EARLIER` and
does nothing. systemd starts the enabled unit by itself, and a human who
stopped or disabled it since is not overruled.

**It never restores and never writes `/var/lib/reflex-config`.** Phase 2
(restore) is an action a human takes with a capture in hand; phase 3 needs a
terminal. `deltas/provision.sh` still does both, and since this change it
stops a running `reflex-ui` before phase 2.

The verdict is one journal line (`journalctl -u elspi-first-boot-ui | grep
verdict=`) and the file `/etc/elspi/first-boot-ui-verdict`.
`docs/flashing.md` → Troubleshooting has the operator's table.

## Why the ordering matters

`After=plymouth-quit-wait.service`: Plymouth's DRM renderer is itself a DRM
master, and anything that opens card0 before Plymouth releases it loses the
race the `first-opener` DRM mode depends on winning (`stage-elspi/06-seat`).
The hook starts `reflex-ui`, so this is load-bearing now, not
future-proofing.

`After=elspi-first-boot-seed.service`: converging before the seed has finished
would converge a machine whose network, password and regulatory domain are not
settled.

**Not** `After=network-online.target`, on purpose: first boot is offline by
design, and a card with no Wi-Fi seeded still boots into the UI.

## Why `cloud-init.target`, not `multi-user.target`

The exact trap `stage-elspi/12-first-boot-seed/README.md` documents at length:
this unit's `After=` chain reaches `cloud-final.service` (via the seed unit),
and `cloud-final.service` is itself `After=multi-user.target`. Pulling this unit
in from `multi-user.target.wants` would recreate the ordering cycle that made
systemd delete the seed unit's job on 2026-09-13. `00-run.sh` and
`tests/verify-image.sh` both assert it is not.

## How it is tested

- `tests/test-first-boot-ui.sh` runs the **real** hook against a synthetic
  rootfs, with a `systemctl` shim and a fake converge, through every branch
  (and goes red against the old scaffold).
- `tests/dry-run-stages.sh` runs this substage and checks the payload landed,
  byte-identical to the repository.
- `tests/verify-image.sh` (and `self-test.sh`'s mutations) check the payload on
  a rootfs and that the manifest's `started_on_first_boot` agrees with the
  guard check run against the checkout that shipped.
- `10b-app-install`'s offline-sync gate runs in every real build.

## The blind spot

Whether the whole chain works on a real card — seed, Plymouth, converge on the
real venv, the unit starting, the application drawing its UNCOMMISSIONED strip
— was closed 2026-09-26: a CI image (run 36244494844, tip 5ef03b0) flashed onto
a spare card and booted on the lathe's Pi 5 came up UNCOMMISSIONED, with SSH
confirming `verdict=STARTED` and `baked_app.started_on_first_boot: true` in
`/etc/elspi-image.json`. `first_boot_ui.verified_on_hardware` is now `true` in
the manifest this stage writes. The automated harness still cannot reproduce
this itself — no GPU or real card in CI — so `cannot_be_verified_without_hardware`
keeps declaring the hook as a standing limit of the offline harness, not as a
claim that it is unverified.
