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
cannot fetch the backup itself: it would have to know where dserver is.

`--app` is passed to phase 1 *and* phase 3. Phase 1 requires it and writes to
it; phase 3 only **reads** it, to report whether the firmware sources are there.
Run alone, phase 3 falls back to the `paths.app_root` the image manifest
declares, and says so — it never guesses a path.

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

- **First commissioning.** `provision.sh` requires `--config-backup` and a
  brand-new machine has none. The refusal is correct; the missing path is a real
  gap, and a `--fresh` flag is not the fix. See the warning at the top of
  `docs/provisioning.md`.
- **Item 19**, the OT state-pull key. Phase 3 prompts for it, but the
  `authorized_keys` line must be written against the forced-command defect
  narrowed 2026-08-14 — never as a bare key line.
- Verification by **diffing a freshly-provisioned Pi against the live elspi**
  (item 12). That needs the hardware.
