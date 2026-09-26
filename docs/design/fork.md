# This is not pi-gen

This repository builds the SD-card image for **elspi**, the Raspberry Pi that runs
the `reflex-ui` electronic-leadscrew control application on the lathe. It is a
**soft fork of [RPi-Distro/pi-gen](https://github.com/RPi-Distro/pi-gen)**: we
intend to keep merging upstream indefinitely, not to diverge from it.

Everything except this file and our own stage is upstream's code. Upstream's
README is still here as `README.pi-gen.md`; it was moved aside rather than
edited so that the root `README.md` can describe elspi — see
[Keep the merge surface small](#keep-the-merge-surface-small). On `arm64`
today `README.pi-gen.md` is **not yet byte-identical** with
`upstream/arm64`'s README: it is still master's armhf copy, and differs at
one line (`qemu-arm-static` vs `qemu-aarch64-static`). The upstream sync
(below) resolves this as a rename/modify conflict and restores byte-identity.

## Syncing with upstream

`master` (frozen legacy armhf) takes no more upstream merges. `arm64` is the
line that syncs, and upstream's own pattern is master → arm64 (upstream merges
`master` into `arm64`, so `upstream/arm64` already contains
`upstream/master`):

```sh
git fetch upstream
git checkout arm64
git merge upstream/arm64         # brings upstream master's commits too
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
| `master` | `armhf` | Frozen legacy line. No more elspi work or upstream merges land here; it stays rebuildable on demand for as long as the armhf rollback card is in service. |
| `arm64` | `arm64` | **Current: the main line**, carrying default-branch and release status (decision D1, 2026-09-26), gated on the ordered migration plan's gate G. |

**Migrated 2026-09-26.** elspi was originally a Raspberry Pi 5 running a
64-bit kernel with a **32-bit userland** (`uname -m` = `aarch64`,
`dpkg --print-architecture` = `armhf`) — the standard Raspberry Pi OS
32-bit-on-Pi-5 arrangement, not a misconfiguration — and `master` was the
like-for-like rebuild target while the fork was proved out. That proof is
done: an arm64 build (workflow run `36253822753`, commit `a699073`) has
booted and run on the lathe's hardware. Evan decided the same day to make
`arm64` the main line (decision D1) and freeze `master` (decision D2) rather
than maintain both ABIs. GitHub's default-branch setting and the first
promoted arm64 release wait on gate G — one more build carrying a reflex UI
fix, then a full end-to-end flash-and-restore test — recorded in this
repository's migration plan.

Moving to `arm64` was a real ABI change, now proven out. Every Python wheel
with a compiled extension needed an `aarch64` build: Kivy 2.3.1 has one on
PyPI (running on SDL2 against the Pi 5's V3D driver), so the venv no longer
compiles Kivy from source under emulation. The `gcc-arm-none-eabi`
cross-toolchain used to build STM32 firmware on the Pi has its 64-bit
package too — the firmware it emits is unaffected either way, since the
target is a Cortex-M regardless of the Pi's own userland.

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
- Never edit `README.pi-gen.md`, `build.sh`, or anything under `stage0`–`stage5`
  to express our configuration. Stage selection belongs in our build config's
  `STAGE_LIST`.

Upstream files edited so far: **one — `Dockerfile`, one word.**
Upstream files **renamed**: one — `README.md` → `README.pi-gen.md`.

#### The README rename, and why it is not an edit (2026-09-13)

Upstream's README is 19 KB of pi-gen build documentation and it was the first
thing a reader of this repository saw. Before the repo went public it was moved
to `README.pi-gen.md`, **unmodified**, and a short elspi README written in its
place.

This is the one rename on the merge surface, and it is cheaper than an edit but
not free: a future `git merge upstream/master` that touches `README.md`
conflicts as rename/modify rather than merging into the moved file. Resolve it
by taking upstream's change into `README.pi-gen.md` and keeping ours at
`README.md`. Git's rename detection makes that a one-line resolution, and it
beats the alternatives — editing upstream's README (a content conflict on every
sync, forever) or leaving a public repository whose front page describes a
different project.

Everything else we add lives in new files: `stage-elspi/`, `elspi.conf`,
`ci.conf`, `ci-test.conf`, `elspi-base-reuse.sh`, `build-elspi.sh`, `tests/`,
`docs/`.

#### A case that would have made it two, and did not (2026-09-12)

`stage2/04-cloud-init/files/meta-data` carries `instance_id: rpios-image` — with
an **underscore**. cloud-init 25.2's NoCloud datasource reads `instance-id`,
with a **hyphen**, and falls back to the literal string `"nocloud"` when it is
absent. So upstream's seed template names an instance that nothing reads, and
the obvious fix is a one-character edit to that file.

We did not make it. `stage-elspi/12-first-boot-seed/00-run.sh` rewrites the key
in `${ROOTFS_DIR}/boot/firmware/meta-data` **at image-build time**, after
stage2 has installed the template — asserting the upstream text is present
first and re-grepping after, so the day upstream fixes its own typo the stage
says so loudly instead of silently no-opping.

Same result, and the merge surface stays at one file. This is the pattern to
copy for the next one: a stage of ours that edits upstream's *output* costs
nothing on a merge, while editing upstream's *input* costs a conflict on every
sync forever.

#### `Dockerfile` — added `gpgv` to the apt line (2026-09-07)

The first real build died in `stage0` debootstrap:

```
E: Invalid Release signature
Signing key on A0DA38D0D76E8B5D638872819165938D90FDDD2E is not bound:
  because: Policy rejected non-revocation signature (PositiveCertification)
  because: SHA1 is not considered secure since 2023-02-01
```

This is ospi's "gpgv in the Dockerfile" cherry-pick, which this document had
been carrying as *unconfirmed*. It is confirmed — and **the reason is not the
one the name suggests.**

Measured inside the container rather than inferred: `command -v gpgv sqv gpg`
returns only `/usr/bin/sqv` and `/usr/bin/gpg`. `gpgv` is absent, because the
Dockerfile installs `gpg` with `--no-install-recommends` and the `gpg` package
does not depend on `gpgv`. With no `gpgv` present, debootstrap falls back to
Sequoia's `sqv`, whose crypto policy rejects the Raspbian archive key because
that key's self-signature is SHA1.

So the fault is not "gpgv is missing" in the abstract. It is **"the wrong
verifier gets used, and its policy is stricter than the Raspbian archive key
can satisfy."** Upstream most likely never sees this because its own CI runs
`build.sh` on a runner that already has GnuPG; the *Docker* path is the broken
one, which is precisely why ospi — who builds through `build-docker.sh` — hit
it and patched it.

**Why the edit rather than a workaround.** `build-docker.sh` offers no
Dockerfile override hook, and the only edit-free alternative was to run an
`apt-get install gpgv` from inside `elspi.conf`, which hides a package
transaction in a configuration file. One added word in a package list is about
the mildest merge conflict available, and it is a real upstream deficiency
rather than our configuration. Verified fixed: debootstrap now completes.

One case came close and was resolved without an edit, recorded so nobody
re-litigates it. Exporting only *our* image means stage2 must not also export a
Lite one, and the mechanism for that is a `SKIP_IMAGES` marker in `stage2/`
(`build.sh:96`). Committing that file would have put a tracked file inside an
upstream stage directory. It turns out **upstream's own `.gitignore` already
lists `SKIP_IMAGES`**, i.e. upstream intends it as a local build-time marker,
so `elspi.conf` creates it at build time instead. Merge surface stays zero and
we are using the mechanism the way it was designed.

### Cherry-picks from ospi: one item is already obsolete

The cherry-pick list carries "build-docker.sh skipping manual binfmt
registration when `docker/setup-qemu-action` already did it". **Checked at our
pin 314262c on 2026-09-07: upstream already does this.** `build-docker.sh`
guards the registration with

```sh
if ! grep -q "^interpreter ${qemu_arm}" /proc/sys/fs/binfmt_misc/qemu-arm* ; then
```

so there is nothing to port. Drop it from the list rather than carrying a patch
that would re-apply an existing fix — that is how a soft fork starts diverging.

The other build-system item, `gpgv` in the `Dockerfile`, is **not yet
confirmed** either way: the Dockerfile installs `gpg` with
`--no-install-recommends`, and whether `debootstrap` then wants `gpgv`
separately is a question the first real build answers. Left open on purpose
rather than pre-emptively editing an upstream file on a guess.

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

### Before making this public

Both of these are **done**, 2026-09-13, in the pass that added `LICENSE-elspi`
and the CI workflows:

- The **Remotes** section below is generalized. Our own git hosting is not a
  fact about the fork, and a reader of a Pi image builder has no use for the
  name of a box on someone else's LAN.
- The tree was re-grepped for anything internal: LAN addresses, our own
  hostnames and usernames, Wi-Fi SSIDs. What came back was one line, in
  `README.pi-gen.md` — upstream's own `--add-host` example, in an upstream
  file this fork does not edit. Test fixtures were checked too; none embeds a
  real hostname.

The one thing that could not be generalized, because it is not a string, was
`deltas/03-interactive.sh`'s fifth step: it enrolled the machine with our own
monitoring. That moved to a private repo and left a `--site-hooks` seam
behind — see `deltas/README.md`.

Upstream's EOL release branches (`bookworm`, `bullseye`, `buster`, `jessie` and
their `-arm64` variants) were deleted from this repo so that its branch list means
"our lines." They remain available at any time as `upstream/<name>` after a
`git fetch upstream`.

## Remotes

`origin` fetches from GitHub and pushes to **two** places: GitHub, and a
private mirror on our own git host. The `reflex` monorepo is configured the
same way, with a second `pushurl` on the same remote, so one
`git push origin <branch>` reaches both:

```
origin    git@github.com:Funkenjaeger/elspi.git    (fetch)
origin    git@github.com:Funkenjaeger/elspi.git    (push)
origin    <internal-host>:<path>/elspi.git         (push)
upstream  https://github.com/RPi-Distro/pi-gen.git (fetch; push disabled)
```

The mirror's address is ours and is not interesting. The arrangement is, and so
is one failure it produces, because the error names the wrong cause: when the
bare repo sits on a **network mount whose UIDs do not match the git host's**,
git refuses the push with `fatal: Could not read from remote repository`, which
reads as a credentials or connectivity problem and is neither. It is
ownership. The fix is a one-time registration on the host that serves the
mount:

```sh
git config --global --add safe.directory <path-to-the-bare-repo>
```

## What is deliberately *not* here

The image cannot regenerate `/var/lib/reflex-config`. That directory holds
**commissioned machine data** measured off the physical lathe — axis geometry,
servo polarity, backlash calibration, Z scale counts/mm. It can only be
*restored* from a backup, never generated, and provisioning must fail loudly
rather than fall back to defaults if no backup is present.
