# The delta layer

Everything the image deliberately does **not** contain. `SEAM.md` decides what
lives on which side; this is the other side of that line.

The image is `flash → boot`. This is `restore → run`.

## Three phases, three different failure contracts

`SEAM.md` is explicit that this is the point, and that collapsing them loses
it:

> The three delta phases have deliberately different failure contracts:
> converge is idempotent and retryable, restore refuses to invent data, and
> interactive blocks on a human. Collapsing them into one "ansible run" loses
> that, and the restore contract is the one that must not be softened.

| Phase | Contract | Re-runnable? |
|---|---|---|
| `01-converge.sh` | idempotent — run it as many times as you like | yes, always |
| `02-restore.sh` | **refuses to invent data**; hard-fails when the backup is absent | yes, but never silently |
| `03-interactive.sh` | blocks on a human; asks, never assumes | yes; skips what is already set |

They are separate files rather than three functions because the boundary is
the product. `provision.sh` runs them in order for convenience — it does not
merge them, and a failure in one does not let the next run.

## Why there is nothing machine-specific in this directory

Checklist item 13, Evan's hard requirement: *"Nothing machine-specific
hard-coded in the repo."* `SEAM.md` call 2 adds: no credential enters this
repo, because it is going public.

So: no IP addresses, no hostnames of other machines, no keys, no passwords, no
WiFi SSIDs. Anything that names the world outside this Pi arrives at run time —
as an argument, or from the human in phase 3. The restore source is a path you
hand it, not a server it knows how to reach.

That is also why `02-restore.sh` cannot fetch the backup itself. It would have
to know where dserver is.

## What phase 1 owns, and what it deliberately does not

Converge installs the application and its wiring. It does **not** own:

- **The unit file.** `reflex-ui.service` belongs to the reflex repo and is
  installed *from the checkout*, never copied into this repo. A copy would
  drift, and the app is the thing that knows how it wants to be started.
- **The DRM mechanism.** The image ships three options and
  `/usr/local/sbin/elspi-drm-mode`. Converge calls the switcher; it does not
  write `User=` itself.

Those two facts combine into the one piece of wiring worth understanding
before reading the code: **the app's stock unit says `User=root`, and the image
runs non-root.** The drop-in written by `elspi-drm-mode` overrides `User=` and
`Group=`, because systemd drop-ins override single-value settings from the
main unit. So the app repo keeps a unit that works on the old root-running
machine, the image keeps the privilege decision, and neither has to know about
the other. Nothing edits the app's unit file.

## The venv bridge

`SEAM.md` call 1 puts the dependency set in the image at `/opt/reflex-venv`,
without the `reflex` package itself. But `deploy/start.sh` in the app repo
activates `$UI_DIR/.venv` — the checkout's own venv.

Converge reconciles that by symlinking the checkout's `.venv` at the image
venv, then running `uv sync --no-dev` with `UV_PROJECT_ENVIRONMENT` pointed at
the same place. Stock `start.sh` then works unmodified, and the sync completes
in seconds because every dependency is already present.

This is why converge **hard-fails if `/opt/reflex-venv` is missing**: this
delta targets the pi-gen image, and on a machine without it the sync would
silently start compiling Kivy from source — the exact hours-long, network-
dependent step the image exists to remove.

## Running it

On the Pi, after a flash:

```sh
sudo ./provision.sh --app /home/default/projects/reflex \
                    --config-backup /path/to/elspi-reflex-config-YYYY-MM-DD
```

Each phase can be run alone. `--dry-run` is available on all three and changes
nothing.

`--app` goes to phase 1 *and* phase 3, and `provision.sh` passes it to both.
Phase 1 requires it and writes to it; phase 3 only **reads** it, to report
whether the firmware sources are there. Run alone, phase 3 falls back to the
`paths.app_root` the image manifest declares, and says so — it never guesses a
path:

```sh
sudo ./03-interactive.sh --app /home/default/projects/reflex
```

## What phase 3 no longer asks

The **dev-role question is retired.** `SEAM.md` call 3 bakes the firmware
toolchain bytes into the image unconditionally and left phase 3 asking whether
to *enable* the role — which meant cloning `reflex-fw` and asking for its URL.
The firmware moved **into the reflex monorepo** at the 2026-08-17 weld, so it
now arrives at `<app>/fw` inside the very checkout phase 1 already converges.
There is no second repository to clone and nothing for a "no" to withhold, so
phase 3 reports instead of asking: the toolchain bytes are present or not, and
`<app>/fw` is present or not.

The decision `SEAM.md` call 3 protects — toolchain bytes baked in, never
fetched at provision time — is unchanged. It was the *mechanism* of enabling
the role that the weld overtook.

## What is NOT here yet

- **Item 19**, the OT state-pull key. Phase 3 prompts for it, but the
  `authorized_keys` line must be written against the forced-command defect
  narrowed 2026-08-14 — never as a bare key line.
- Verification by **diffing a freshly-provisioned Pi against the live elspi**
  (item 12). That needs the hardware, and reading the result is the point of
  the flash session.
