# `14-first-boot-ui` — the hook for task 6aa73b01, not the feature

**This substage ships a trigger, not the feature task 6aa73b01 asks for.**
Read this before changing it, and before assuming it does more than it does.

## What task 6aa73b01 actually asks

Title: *"Make a fresh elspi card boot straight into the UI: no SSH, no
mandatory backup, SWD chapter documented."* Item 1 of that task says:

> FIRST BOOT LANDS IN THE UI. The image already vendors reflex's lock at a
> pinned commit (`stage-elspi/08-venv/files/REFLEX_COMMIT`); bake the reflex
> checkout at that same commit into the image and run converge as part of
> first boot, right after the seed (`stage-elspi/12-first-boot-seed`). A fresh
> card boots into the UI on defaults, visibly uncommissioned, with no SSH
> needed.

That is a change to **which side of the image-vs-deltas seam the application
checkout lives on**. Today it is deltas-owned:
`stage-elspi/11-manifest/00-run.sh` writes
`"delta_layer_owns": ["reflex monorepo checkout at
/home/default/projects/reflex", "reflex-ui.service", ...]` into every image's
own manifest, and `docs/design/seam.md`'s call 1 (ratified 2026-08-22) is
explicit that the venv goes in the image and the application does not.

The order that produced this substage said, in so many words: *the seam is
ratified, land on the correct side of it, do not re-litigate it.* Baking the
checkout in and auto-running converge would be exactly that re-litigation.
**So this substage does not do it.**

## What this substage does instead

It ships the part of item 1 that is genuinely image-side and does not move
anything across the seam: a systemd unit, enabled, ordered correctly against
both the existing first-boot seed and Plymouth's hold on DRM master. Its
installed script (`files/elspi-first-boot-ui.sh`) looks for a checkout at the
path the manifest already declares (`.paths.app_root`) and, finding none —
true of every image this repo has ever built — logs `verdict=NOOP` and exits
0. Nothing starts. Nothing is visibly different on the console. That is
correct: `docs/flashing.md` already documents a black screen after Plymouth
as the expected result of a first boot with no application installed, and
this substage does not change that.

If a future build DOES bake a checkout in (a decision, not a bug fix), the
script will log `verdict=UNIMPLEMENTED` rather than silently doing nothing —
so the day that decision is made, whoever makes it gets a loud pointer back
to this file instead of a boot that mysteriously still shows a black screen.
Writing the actual converge-and-start branch is future work, gated on that
decision.

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

- It does not touch `deltas/` or `provision.sh`. Item 2 of task 6aa73b01 (a
  `--fresh` flag making `--config-backup` optional) is a provisioning-safety
  change — `docs/provisioning.md` currently makes starting the application a
  deliberate, human-reviewed step specifically so a lathe never comes up on
  unreviewed commissioned data — and that is out of this substage's bound.
- It does not touch `stage-elspi/06-seat` or the DRM default. Two modes ship
  (`first-opener`, `cap-sys-admin`); `first-opener` is the default and was
  **measured** on real hardware 2026-09-13
  (`docs/design/runtime-inventory.md`, "SETTLED 2026-09-13 on hardware").
  Neither fact changes here.
- It does not write an SWD chapter (item 3) or an ELSPI.md "after first boot"
  section (item 4) — `docs/swd-first-load.md` already exists and is one of
  this order's required reads, but authoring/expanding it was not this
  substage's bound.

## The blind spot this substage adds

`/etc/elspi-image.json`'s `cannot_be_verified_without_hardware` list gains one
member: whether the converge/start branch above would actually work is
untested, because it has never run — no image has ever had a checkout to run
it against. That is a genuinely new limitation (not one of the existing
GPU/touchscreen/UART hardware blind spots) and it is declared rather than
left implicit, per this repo's own rule that a harness holding a private copy
of what it cannot see will eventually disagree with the image and be believed
anyway.
