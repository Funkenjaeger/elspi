# `14-first-boot-ui` — the hook for first-boot-into-the-UI, not the feature

**This substage ships a trigger, not the feature.** Read this before changing
it, and before assuming it does more than it does.

## The goal it is a hook for

*A fresh elspi card boots straight into the UI: no SSH, no mandatory backup.*
The whole of that needs two things: the reflex checkout baked into the image,
and something that converges and starts it at first boot, right after the seed
(`stage-elspi/12-first-boot-seed`), so a fresh card comes up on defaults,
visibly uncommissioned.

**The first half exists now.** `docs/design/seam.md`'s amendment of
2026-09-21 moved the checkout into the image: `stage-elspi/10a-app-checkout`
bakes the latest full release at `/home/default/projects/reflex`, and
`11-manifest` declares it as `baked_app` (with
`"started_on_first_boot": false`). Until then the checkout was deltas-owned
and no image carried one.

**The second half does not.** Starting the application unattended is a
separate decision from baking it in: `docs/provisioning.md` makes starting
reflex-ui a deliberate, human-reviewed step, specifically so a lathe never
comes up on unreviewed commissioned data. This substage does not make that
decision.

## What this substage does

It ships the part that is genuinely image-side: a systemd unit, enabled,
ordered correctly against both the first-boot seed and Plymouth's hold on DRM
master. Its installed script (`files/elspi-first-boot-ui.sh`) looks for a
checkout at the path the manifest declares (`.paths.app_root`):

- **found** — true of every image built since 2026-09-21 — it logs
  `verdict=UNIMPLEMENTED`, naming the unwritten converge/start branch, and
  exits 0. Nothing starts;
- **absent** — an image built before 2026-09-21 — it logs `verdict=NOOP` and
  exits 0.

Either way nothing is visibly different on the console. `docs/flashing.md`
documents a black screen after Plymouth as the expected result of a first boot
before provisioning, and this substage does not change that. The loud
`UNIMPLEMENTED` verdict exists so that whoever writes the start branch gets a
pointer back to this file rather than a boot that mysteriously still shows a
black screen.

## Why the ordering matters even for a unit that (today) does nothing

`After=plymouth-quit-wait.service` is asserted at build time
(`00-run.sh`) and at verification time (`tests/verify-image.sh`) even though
the shipped script never touches DRM. The reasoning: whoever eventually
writes the converge/start branch inherits *correct* ordering for free, rather
than rediscovering the exact hazard `stage-elspi/06-seat`'s DRM-mode
fragments already exist to avoid — Plymouth's DRM renderer is itself a
master, and anything that opens card0 before Plymouth releases it loses the
race the `first-opener` DRM mode depends on winning.

`After=elspi-first-boot-seed.service` is there because a converge run before
the seed has finished would be converging a machine whose network, password
and regulatory domain are not yet settled.

## Why `cloud-init.target`, not `multi-user.target`

Verbatim the same trap `stage-elspi/12-first-boot-seed/README.md` documents
at length, so it is not repeated here in full: this unit's own `After=`
chain reaches `cloud-final.service` (via `elspi-first-boot-seed.service`),
and `cloud-final.service` is itself `After=multi-user.target`. Pulling this
unit in from `multi-user.target.wants` would recreate the exact ordering
cycle that made systemd delete the seed unit's job on 2026-09-13, silently.
`cloud-init.target` adds no ordering edge of its own and our real edges
already point the direction it points, so no cycle is possible.
`00-run.sh` and `tests/verify-image.sh` both assert the unit is **not**
also enabled in `multi-user.target.wants`, for the same reason
`12-first-boot-seed` does.

## What this substage does NOT do, and why that is not a shortcut

- It does not touch `deltas/` or `provision.sh`. Making `--config-backup`
  optional was a provisioning-safety change and landed there as `--fresh`, a
  deliberate, loud flag — not here.
- It does not touch `stage-elspi/06-seat` or the DRM default. Two modes ship
  (`first-opener`, `cap-sys-admin`); `first-opener` is the default and was
  **measured** on real hardware 2026-09-13
  (`docs/design/runtime-inventory.md`, "SETTLED 2026-09-13 on hardware").
  Neither fact changes here.
- It does not write documentation for the SWD first load; that is
  `docs/swd-first-load.md`.

## The blind spot this substage adds

`/etc/elspi-image.json`'s `cannot_be_verified_without_hardware` list carries
one member for it: whether a converge/start branch would actually work is
untested, because that branch does not exist and has never run. That is a
genuinely different limitation from the GPU/touchscreen/UART hardware blind
spots, and it is declared rather than left implicit, per this repo's own rule
that a harness holding a private copy of what it cannot see will eventually
disagree with the image and be believed anyway.
