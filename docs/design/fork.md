# This is not pi-gen

This repository builds the SD-card image for a Raspberry Pi that runs the
`reflex-ui` lathe controller. It is a **soft fork** of
[RPi-Distro/pi-gen](https://github.com/RPi-Distro/pi-gen): it is meant to keep
merging upstream indefinitely. A fork that stops merging and starts
hand-copying upstream files becomes a hard fork without anyone deciding it.
One existing pi-gen derivative did that, and it lost upstream's Pi 5
`dtoverlay=nospi10` block without noticing.

## The branch is the architecture

Upstream sets the architecture on the branch (`build.sh` has a bare
`export ARCH=`), not through a variable. Setting `ARCH` in a config file does
nothing, so this repository follows the same scheme:

| Branch or tag | ARCH | Status |
|---|---|---|
| `main` | `arm64` | the main line and default branch; syncs with `upstream/arm64` |
| tag `armhf-final` | `armhf` | retired; still buildable from the tag |

To sync with upstream, run `git fetch upstream && git checkout main && git merge upstream/arm64`.
Upstream merges its own `master` into `arm64`, so this brings in both. Sync
on a schedule, not only when something breaks. The `upstream` remote is
fetch-only.

## Keep the merge surface small

Every upstream file edited here is a merge conflict on every sync. Every file
added is free. So:

- Put configuration in our own files (`elspi.conf`, `ci.conf`,
  `ci-test.conf`) and our own stages (`stage-elspi-pkgs/`, `stage-elspi/`),
  never in `build.sh` or `stage0`–`stage5`.
- **Edit upstream's output, not its input.** Upstream's cloud-init template
  misspells `instance-id`. We did not fix the template. `12-first-boot-seed`
  rewrites the installed file during the build. It stops the build if the
  template no longer matches what it expects, but a template that already
  uses the correct key passes through unchanged.
- Use upstream's own mechanisms where they exist. `stage2/SKIP_IMAGES` is
  created at build time by `elspi.conf`, not committed, because upstream's
  `.gitignore` already treats it as a local marker.

**Upstream files edited: one.** `Dockerfile` adds `gpgv` to its apt line.
Without it, debootstrap falls back to Sequoia's `sqv`, whose policy rejects
the Raspbian archive key (SHA-1 self-signature). `build-docker.sh` has no hook
for this, so a one-word edit is the smallest fix.

**Upstream files renamed: one.** `README.md` became `README.pi-gen.md`,
otherwise unchanged, so the front page can describe this project. When
upstream changes its README, the merge shows a rename/modify conflict. Resolve
it by applying upstream's change to `README.pi-gen.md`. On `main` that file
is still the armhf copy (one line differs), so the first upstream merge will
fix that.

## A copy, not a GitHub fork

The repository was created by mirroring pi-gen's history, not with GitHub's
Fork button, because a fork of a public repository cannot be private and this
one started private. It is public now. Nothing depends on the fork
relationship: `git merge upstream/arm64` works the same either way.
