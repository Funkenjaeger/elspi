# The site layer

Nothing that is true of **one installation** and not of the image belongs in
this repository — no IP addresses, no hostnames of other machines, no keys,
no passwords, no Wi-Fi SSIDs (`deltas/README.md`, "Nothing machine-specific
lives in this directory"). Anywhere a build or a provisioning run needs one
owner's specifics, this repo defines a seam and stops: what crosses it is
your choice, kept in a **site layer** that lives outside this repo entirely —
a private repository or just a local directory. **elspi builds and provisions
correctly with no site layer at all**; every seam below is optional, and the
public defaults are what ship when you don't use it.

There are two seams, one per phase of elspi's life: a build-time file and a
provisioning-time directory. Neither is read from, or written into, this repo.

## Build time: `ELSPI_SITE_CONF`

```sh
ELSPI_SITE_CONF=/path/to/site.conf ./build-elspi.sh
```

`elspi.conf` sources this file **last**, after every public default, so it can
override any of them — `TIMEZONE_DEFAULT`, `LOCALE_DEFAULT`, `KEYBOARD_*`,
`TARGET_HOSTNAME`, `REFLEX_*` — and set the one board knob the public image
leaves off, `ELSPI_USB_MAX_CURRENT=1` (`elspi.conf:183-206`). `build-elspi.sh`
resolves the path, refuses one containing whitespace or `:` (both are unsafe
across `PIGEN_DOCKER_OPTS`), bind-mounts it read-only into the build
container at its own absolute path, and forwards the variable
(`build-elspi.sh:126-147`). A name that is set but does not point at a
readable file is **FATAL**, both on the host and inside the container
(`build-elspi.sh:135-136`, `elspi.conf:196-201`) — a site config that silently
failed to apply would build an image that looks right and is not.

The image records only **whether** a site config was applied, never its path
or contents: `build_defaults.site_build_config_applied` and
`boot_config.usb_max_current_enable` in `/etc/elspi-image.json`
(`stage-elspi/11-manifest/00-run.sh:95-99,219,223`), sourced from
`ELSPI_SITE_CONF_APPLIED`, which `elspi.conf` sets and exports
(`elspi.conf:195,204,221`). `ci.conf` sources `elspi.conf` for everything, so
the same seam applies to CI-built images (`ci.conf:19-26`).

## Provisioning time: `--site-hooks`

```sh
sudo ./deltas/provision.sh --app <checkout> --config-backup <dir> \
    --site-hooks /path/to/site/hooks
```

`--site-hooks` names a directory that must already exist — checked during
argument parsing, before phase 1 changes anything on the machine
(`deltas/provision.sh:85-88`). Two things may live in it:

**Hooks.** Every executable `DIR/*.sh`, found non-recursively and run in
`LC_ALL=C` sorted filename order, as root, after phase 3 — and still after
phase 2 if `--skip-interactive` skipped phase 3, because that flag is about
not blocking on a human, not about skipping site steps
(`deltas/provision.sh:165-178,203-213`). A directory that matched no
executable `*.sh` is a **warning**, not silence, because a lost executable bit
looks identical to a hook with nothing to do
(`deltas/provision.sh:182-189`). A hook that exits non-zero stops
provisioning, named — hooks run last precisely so a failing site step cannot
leave a half-converged machine behind it (`deltas/provision.sh:203-213`).

Each hook gets exactly this environment, resolved once and exported before
the first one runs (`deltas/provision.sh:194-201`):

| Variable | Meaning |
|---|---|
| `DELTAS_DIR` | this directory, so a hook can `. "${DELTAS_DIR}/lib.sh"` and get `say`/`ok`/`warn`/`die`/`run`/`assert` |
| `SERVICE_USER` | the account the app runs as (`lib.sh` `resolve_service_user`, `lib.sh:94-105`) |
| `HOME_DIR` | that account's home directory |
| `APP_DIR` | the reflex checkout, as `--app` gave it |
| `CONFIG_DIR` | the commissioned-config directory (`lib.sh` `resolve_paths`, `lib.sh:107-120`) |
| `DRY_RUN` | `1` when provisioning was asked to change nothing |

`DRY_RUN` is **passed through, not enforced**: nothing stops a hook from
writing anyway. Routing every mutating line through `lib.sh`'s `run` wrapper
(no-ops and prints `would: ...` when `DRY_RUN=1`) and gating claimed effects
with `assert` (skipped under `--dry-run`, since there is nothing yet to
check) is how a hook gets the same honesty the phases have
(`deltas/lib.sh:23-29,39-50`). A redirection (`>>`, `>`) cannot go through
`run`; write those behind an explicit `if [ "${DRY_RUN}" = "1" ]` instead, the
way `deltas/03-interactive.sh`'s own `authorized_keys` step does.

**`site.env`** — settings for the *phases themselves*, as opposed to steps
that run after them. `provision.sh` loads it before phase 1, before
`need_root`, so a malformed line is refused before anything is asked of root
(`deltas/provision.sh:96-102`). It is **parsed as data, never sourced**: every
non-blank, non-`#` line must match `ELSPI_[A-Z0-9_]+=[A-Za-z0-9._/-]*`
exactly, or the whole run is refused, by line number, naming the file
(`deltas/lib.sh:59-77`). An absent `site.env` is not an error — the phases
just use their public defaults (`deltas/lib.sh:61-64`). One variable is read
today:

| Variable | Read by | Meaning |
|---|---|---|
| `ELSPI_RESTORE_MIN_YAML` | `02-restore.sh` | the minimum number of `*.yaml` files a capture must hold. The public minimum is 1 (`Els-0.yaml`, non-empty); a site **may only raise it, never lower it** — `0` or anything that isn't a whole number is refused (`deltas/02-restore.sh:140-154`) |

## Keep it private

A site layer is exactly the material that must never reach this public repo:
extra `authorized_keys` lines, backup-host names, a stricter restore bar,
anything that says which network this Pi lives on. Put it in a private
repository, or just a directory that never gets `git add`ed here — either
way, outside this checkout.

If a hook's job is to grant SSH access for some other purpose (a collector, a
backup pull, a monitor), prefer a **forced-command** `authorized_keys` line
over a bare key:

```
restrict,command="/usr/local/bin/whatever-that-purpose-needs" ssh-ed25519 AAAA...
```

`restrict` (OpenSSH ≥ 7.2) turns off port/agent/X11 forwarding and PTY
allocation in one word; `command=` pins the session to one script regardless
of what the client asks to run (`sshd(8)`, `AUTHORIZED_KEYS FILE FORMAT`). A
bare key grants a full interactive shell to `SERVICE_USER`, which is rarely
what a single-purpose hook actually needs.

`examples/site/` in this repo is a skeleton to copy into your own site layer
and adapt — see its `README.md`. The full contract, if you're writing a hook
from scratch: `deltas/README.md`.
