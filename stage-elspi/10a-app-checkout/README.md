# 10a-app-checkout — the application, baked at the latest full release

`docs/design/seam.md`, **amendment 2026-09-21, ratified by Evan**: the image
ships the app pinned to the **latest FULL release** — never a development
`rc.*`, never a branch tip. Full releases are infrequent and in-app updating
closes the gap cheaply, so the image only has to be *a* good starting point
rather than *the current* one.

## What it does

Clones the reflex monorepo into `/home/<service user>/projects/reflex` as a
**real git checkout with full tag history**, detached at the selected release
tag, owned by the service user.

It does **not** start anything. The start gate is order 2026-09-21#1;
`stage-elspi/14-first-boot-ui` remains exactly the scaffold order 2026-09-20#5
shipped.

## Why a checkout and not a tarball

`ui/reflex/utils/updater.py` reads the target release's protocol version with
`git show <tag>:ui/reflex/utils/els_stop_map.py` and then checks that tag out
in place. Its `resolve_checkout()` refuses outright when `<root>/.git`,
`<root>/ui/pyproject.toml`, `<root>/fw/scripts/modbus-flash.py` or
`<root>/fw/scripts/reflex_image.py` is missing — "an installed wheel, a copied
tree, a directory with no `fw/`". An export would make every in-app update
fail on a freshly flashed card, which is the one thing the amendment leans on.

## Parameters (see `elspi.conf`)

| variable | meaning |
| --- | --- |
| `REFLEX_SOURCE` | where to clone from. **No default in the stage** — a hardcoded URL is what would stop the build being reproducible from a local mirror. Takes a path, a bare repo, or a URL. |
| `REFLEX_RELEASE` | optional pin. Still goes through the same full-release check; a pinned `rc.*` is refused by name, not silently accepted. |
| `REFLEX_ORIGIN_URL` | the remote the **shipped image** carries. Anonymous HTTPS, matching `updater.py`'s own `GITHUB_FETCH_URL`. The build source is never shipped as `origin`. |

Nothing here runs at provision or first boot, so the provision path gains no
network fetch.

## The selection rule lives in `files/select-release.sh`

A full release is exactly `v<major>.<minor>.<patch>`. That is read out of
reflex's own `.github/workflows/release.yml`, which tags `v$V` and treats *any*
version carrying a hyphen as a pre-release. `ui-*` and `fw-*` tags name one
half of the lockstep pair and are refused for that reason, not for their shape.

**There is no fallback.** When nothing resolves, the build stops and says what
it saw. It never reaches for `HEAD`, `main`, `dev`, or the newest pre-release.

Split out as a standalone script for the same reason as
`../11-manifest/files/render-release.sh`: the decision is testable without a
2–3 hour pi-gen build. `tests/test-release-selection.sh` drives it directly.

## Known limitation at the time of writing (2026-09-22), measured not assumed

The newest full release in the reflex mirror is **`v1.1.0` (2026-08-31,
`752da5c`)**. The in-app updater landed *after* it: at `v1.1.0` there is no
`ui/reflex/utils/updater.py`, no `ui/reflex/utils/els_stop_map.py`, and no
`fw/scripts/modbus-flash.py` or `fw/scripts/reflex_image.py`. Those first
appear at `v1.2.0-rc.4` (2026-09-19), which is a pre-release and therefore
refused.

So an image built today bakes a release **that cannot update itself**. The
stage says so by name rather than passing quietly, and records the verdict in
the manifest as `baked_app.updater_ready` and
`baked_app.protocol_version_readable`, so the image declares its own
limitation. It is **not** a build failure: which files a release contains is a
property of the release, and the amendment is ratified. It resolves itself the
day `v1.2.0` ships from `main`.

## Why the directory is called `10a`

It must run after `05-service-user` (which creates and owns the app parent) and
before `11-manifest` (which records what was baked). `build.sh:112` iterates
`"${STAGE_DIR}"/*`, i.e. glob order, and `10a-app-checkout` sorts after
`10-splash` and before `11-manifest` under both C and `en_US` collation.
Renumbering `11`–`14` to open a clean slot would rename directories that docs,
tests, README files and the manifest's own strings name by number.
