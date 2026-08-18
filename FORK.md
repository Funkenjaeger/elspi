# This is not pi-gen

This repository builds the SD-card image for **elspi**, the Raspberry Pi that runs
the `reflex-ui` electronic-leadscrew control application on the lathe. It is a
**soft fork of [RPi-Distro/pi-gen](https://github.com/RPi-Distro/pi-gen)**: we
intend to keep merging upstream indefinitely, not to diverge from it.

Everything except this file and our own stage is upstream's code. `README.md`
still opens with "# pi-gen" because it is upstream's file, unmodified on purpose
— see [Keep the merge surface small](#keep-the-merge-surface-small).

## Syncing with upstream

```sh
git fetch upstream
git merge upstream/master        # on master (armhf)
git merge upstream/arm64         # on arm64
```

`upstream` is fetch-only; its push URL is deliberately set to an invalid string so
that a stray `git push upstream` fails loudly instead of erroring out somewhere
less obvious.

**Do this on a schedule, not when something breaks.** The whole reason this repo
exists rather than being based on an existing derivative is that the obvious
candidate (`bartei/ospi`) stopped merging upstream in May 2025 and thereafter
updated itself by hand-copying upstream files. That silently dropped the
`rpifwcrypto` package from stage2 and the Pi 5 `dtoverlay=nospi10` block from
stage1's `config.txt` — the latter on a board that is exactly what elspi is. A
soft fork that is not actually merged is a hard fork that has not admitted it yet.

## The branch is the architecture

Upstream encodes the target architecture in the *branch*, not in a variable —
`build.sh` contains a bare `export ARCH=armhf` with no override. Setting `ARCH`
in a config file does nothing. We mirror upstream's structure:

| Branch | ARCH | Status |
|---|---|---|
| `master` | `armhf` | **Current.** Matches elspi as it runs today. |
| `arm64` | `arm64` | Planned migration target. Currently pristine upstream. |

elspi today is a Raspberry Pi 5 running a 64-bit kernel with a **32-bit userland**
(`uname -m` = `aarch64`, `dpkg --print-architecture` = `armhf`) — the standard
Raspberry Pi OS 32-bit-on-Pi-5 arrangement, not a misconfiguration. `master` is
therefore the like-for-like rebuild, and the one to get working first: the point
of this repo is a recovery path, and a recovery path that changes the ABI at the
same time is proving two things at once.

Moving to `arm64` is a real ABI change. Every Python wheel with a compiled
extension (Kivy and its SDL2/GL bindings above all) needs an `aarch64` build, and
the `gcc-arm-none-eabi` cross-toolchain used to build STM32 firmware on the Pi
needs its 64-bit package — though the firmware it emits is unaffected, since the
target is a Cortex-M either way.

## Both release lines are trixie

Upstream `master` and `arm64` are both on Debian 13:
`build.sh` has `export RELEASE=${RELEASE:-trixie}`, and `stage0/prerun.sh` carries
a matching guard. elspi already runs trixie, so there is no OS upgrade step
anywhere in the provisioning path — by design.

## Keep the merge surface small

Every upstream file we edit is a merge conflict on every future sync, forever.
Every file we *add* is free. So:

- **Prefer new files** — our own stage directory, our own build config.
- Confine edits to upstream files to cases where there is genuinely no
  alternative, and note each one here when it happens.
- Never edit `README.md`, `build.sh`, or anything under `stage0`–`stage5` to
  express our configuration. Stage selection belongs in our build config's
  `STAGE_LIST`.

Upstream files edited so far: **none.**

## This is a copy, not a GitHub fork

Deliberately. GitHub's docs are explicit that
["You cannot change the visibility of a fork by itself"](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/about-permissions-and-visibility-of-forks)
and that "Public repository forks are public, and private repository forks are
private." pi-gen is public, so a Fork-button fork of it could never be private,
and this repo needs to be private for now.

It was therefore created with GitHub's
[duplicating a repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/duplicating-a-repository)
recipe — `git clone --bare` followed by `git push --mirror` — which preserves
full history. Nothing load-bearing was lost: `git merge upstream/master` neither
knows nor cares about repository names or fork relationships. What we gave up is
GitHub interface convenience only — the "forked from" banner, the Sync fork
button, and the ability to open a pull request against upstream, which we will
never do.

Upstream's EOL release branches (`bookworm`, `bullseye`, `buster`, `jessie` and
their `-arm64` variants) were deleted from this repo so that its branch list means
"our lines." They remain available at any time as `upstream/<name>` after a
`git fetch upstream`.

## Remotes

`origin` fetches from GitHub and pushes to **both** GitHub and dserver, matching
how the `reflex` monorepo is configured:

```
origin    git@github.com:Funkenjaeger/elspi.git   (fetch)
origin    git@github.com:Funkenjaeger/elspi.git   (push)
origin    dserver:/mnt/git/elspi.git              (push)
upstream  https://github.com/RPi-Distro/pi-gen.git (fetch; push disabled)
```

A single `git push origin <branch>` reaches both. The dserver copy lives on an
NFS mount from the NAS whose UIDs do not match dserver's, so every bare repo
there needs a one-time registration on dserver before it will accept a push:

```sh
git config --global --add safe.directory /mnt/git/elspi.git
```

This is already done for this repo. It is recorded because the failure it
produces — `fatal: Could not read from remote repository` on push — points at
credentials rather than at ownership, and there are 29 prior repos on that mount
carrying the same registration.

## What is deliberately *not* here

The image cannot regenerate `/var/lib/reflex-config`. That directory holds
**commissioned machine data** measured off the physical lathe — axis geometry,
servo polarity, backlash calibration, Z scale counts/mm. It can only be
*restored* from a backup, never generated, and provisioning must fail loudly
rather than fall back to defaults if no backup is present.
