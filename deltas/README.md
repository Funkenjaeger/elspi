# The delta layer

Everything the image deliberately does **not** contain. The image is
`flash → boot`; this is `restore → run`.

**How to run it, what each phase prints, and the DRM ladder when the screen
stays black: [docs/provisioning.md](../docs/provisioning.md).** That page is the
operator's, and it is the one to keep current. What follows is contributor
detail that does not belong in it.

`docs/design/seam.md` decides what lives on which side of the line.

## Three files, not three functions

| Phase | Contract | Re-runnable? |
|---|---|---|
| `01-converge.sh` | idempotent — run it as many times as you like | yes, always |
| `02-restore.sh` | **refuses to invent data**; hard-fails when the backup is absent | yes, but never silently |
| `03-interactive.sh` | blocks on a human; asks, never assumes | yes; skips what is already set |

`02-restore.sh` (and `provision.sh` above it) also accepts `--fresh` in place
of `--config-backup`, for first commissioning — see "What is NOT here yet"
below for what it does and does not do.

`docs/design/seam.md` is explicit that the differing failure contracts are the
point, and that collapsing them loses it:

> The three delta phases have deliberately different failure contracts: converge
> is idempotent and retryable, restore refuses to invent data, and interactive
> blocks on a human. Collapsing them into one "ansible run" loses that, and the
> restore contract is the one that must not be softened.

They are separate files rather than three functions because **the boundary is
the product**. `provision.sh` runs them in order for convenience — it does not
merge them, and a failure in one does not let the next run.

Shared helpers live in `lib.sh`, which is sourced and never executed. Every
mutating action goes through its `run` wrapper so `--dry-run` is honest by
construction rather than by remembering to check a flag at each call site, and
`assert` exists so that a step claiming an effect gates on a signal that could
have come out differently.

## Nothing machine-specific lives in this directory

Evan's hard requirement (checklist item 13), and `docs/design/seam.md` call 2
adds: no credential enters this repo, because it is going public.

So: no IP addresses, no hostnames of other machines, no keys, no passwords, no
Wi-Fi SSIDs. Anything that names the world outside this Pi arrives at run time —
as an argument, or from the human in phase 3. The restore source is a path you
hand it, not a server it knows how to reach. That is also why `02-restore.sh`
cannot fetch the backup itself: it would have to know where the backup host is.

`--app` is passed to phase 1 *and* phase 3. Phase 1 requires it and writes to
it; phase 3 only **reads** it, to report whether the firmware sources are there.
Run alone, phase 3 falls back to the `paths.app_root` the image manifest
declares, and says so — it never guesses a path.

## Site hooks — the seam for what cannot be here

A step that is true of **one estate** rather than of the image cannot be a
phase. It still has to run in the same order, with the same helpers, right
after the phases. So it runs as a **hook**, out of a directory that lives
outside this repo:

    sudo ./provision.sh --app <checkout> --config-backup <dir> \
        --site-hooks /path/to/site/hooks

**A hook is an executable `*.sh` directly in that directory.** Every one of
them runs, in sorted filename order, as root, after phase 3 — and after phase 2
when `--skip-interactive` skipped phase 3, because skipping the interactive
phase is about not blocking on a human, not about skipping site steps. The
directory must exist: `provision.sh` refuses a path that does not, during
argument parsing, *before* phase 1 changes anything.

**The environment a hook gets**, and the only environment it may assume:

| Variable | Meaning |
|---|---|
| `DELTAS_DIR` | this directory — `. "${DELTAS_DIR}/lib.sh"` for `say`/`ok`/`warn`/`die`/`run`/`assert` |
| `SERVICE_USER` | the account the app runs as, resolved the same way the phases resolve it |
| `HOME_DIR` | that account's home directory |
| `APP_DIR` | the reflex monorepo checkout, as `--app` gave it |
| `CONFIG_DIR` | the commissioned-config directory |
| `DRY_RUN` | `1` when provisioning was asked to change nothing |

`DELTAS_DIR` exists so a hook can look like a phase rather than reinventing
one. `DRY_RUN` is **passed through, not enforced** — a hook is responsible for
honouring it, and sourcing `lib.sh` and putting every mutating action through
its `run` wrapper is how to get that for free. `provision.sh` names each hook
it would run either way.

**A hook that exits non-zero stops provisioning, named.** Hooks run last for
that reason: a site step that fails must not be able to leave a half-converged
machine behind it. A hooks directory that matched no executable `*.sh` is
reported as a warning rather than passed over — a lost executable bit looks
exactly like a hook with nothing to do.

**`site.env` — settings, not steps.** Hooks run last, which is too late to
change how a phase judges its input. So the hooks directory may also hold a
`site.env`, which `provision.sh` loads *before phase 1* (`lib.sh`
`load_site_env`). It is **data, never sourced**: every non-blank,
non-comment line must be `ELSPI_<NAME>=<value>` with the value drawn from
`[A-Za-z0-9._/-]`; anything else stops provisioning, naming the line, before
root is asked for anything. Each accepted variable is exported to every phase
and printed. The one a phase reads today:

| Variable | Read by | Meaning |
|---|---|---|
| `ELSPI_RESTORE_MIN_YAML` | `02-restore.sh` | the minimum number of `*.yaml` files a capture must hold. The public minimum is 1 (`Els-0.yaml`, which must also be non-empty); a site may raise it, never lower it — `0` or a non-number is refused |

**This repo ships no hooks and no hooks directory.** That is the point: the
hooks are where the IP addresses, collector names and backup hosts live, and
they live somewhere else.

## What phase 1 deliberately does not own

- **The unit file.** `reflex-ui.service` belongs to the reflex repo and is
  installed *from the checkout*, never copied into this repo. A copy would
  drift, and the app is the thing that knows how it wants to be started.
- **The DRM mechanism.** The image ships the two mechanisms and the switcher;
  converge calls the switcher and never writes `User=` itself. `--drm-mode` is
  passed through **without a mode list here on purpose**: the switcher owns the
  list, so it is the only thing that can reject a name.

Those combine into the one piece of wiring worth understanding before reading
the code: **the app's stock unit says `User=root`, and the image runs
non-root.** The drop-in written by `elspi-drm-mode` overrides `User=` and
`Group=`, because systemd drop-ins override single-value settings from the main
unit. So the app repo keeps a unit that works on the old root-running machine,
the image keeps the privilege decision, and neither has to know about the other.
Nothing edits the app's unit file.

## What is NOT here yet

- **First commissioning, from this tooling's point of view, is `--fresh`.**
  `provision.sh` and `02-restore.sh` accept `--fresh` in place of
  `--config-backup`: it is mutually exclusive with `--config-backup`, it skips
  the restore phase entirely (nothing is written into `CONFIG_DIR`, nothing is
  generated — the application's own defaults apply), and it refuses if
  `CONFIG_DIR` already holds anything, so a fresh provision can never mask
  existing commissioned data. It prints an UNCOMMISSIONED banner at the start
  of phase 2 and again in its final summary: axis geometry, servo polarity,
  backlash calibration and Z scale counts/mm are commissioned machine data
  that nothing here can generate, and every one of them must still be measured
  off the physical lathe before the machine is trusted. With neither flag,
  provisioning refuses exactly as it always has — `--fresh` is a deliberate
  choice, never a default. See `docs/provisioning.md` for the operator-facing
  version, including where to point a first-commissioning user who *does* have
  commissioned values to bring onto the machine (the USB import on the reflex
  Setup screen, not this flag).
- **Monitoring enrolment.** Phase 3 used to have a fifth step that installed a
  purpose-scoped forced-command SSH key for one estate's collector. It named a
  particular network, so it is a **site hook** now (see above) and lives
  outside this repo. Nothing here replaces it, and nothing here needs to.
- Verification by **diffing a freshly-provisioned Pi against the live elspi**
  (item 12). That needs the hardware.
