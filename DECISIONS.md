# Decisions

## 2026-09-26 order 2026-09-25#1: resolve_service_user stays paired with need_root, not moved ahead of it

Order's words: "Pure validation = ... anything that only READS." `resolve_service_user`
(lib.sh:94-105) only reads (the image manifest, then `id <user>`) so it technically
qualifies. Choice: left it immediately AFTER `need_root` in both 01-converge.sh and
03-interactive.sh, rather than grouping it with the other pure-read validation ahead of
the gate. Alternative: move it before `need_root` too, since it never writes.
Why: 02-restore.sh only calls it at its own write boundary (:243, right after its
`need_root` at :242), never earlier — the established shape pairs it with the write
phase, not the argument gates. It can also fail for reasons that have nothing to do with
the caller's arguments (no `/etc/elspi-image.json`, no matching account on this
machine), which is a different kind of refusal than "this input is bad" and moving it
ahead would let an unrelated environment gap mask a validation message the same way
`need_root` used to.

## 2026-09-26 order 2026-09-25#1: resolve_paths runs before require_app_dir in 01-converge.sh

Order pins where `need_root` moves to in each file but not the internal order among the
pure-validation reads now ahead of it. Choice: kept `resolve_paths` before
`require_app_dir "${APP_ARG}"` (their original relative order). Alternative: reverse
them, since require_app_dir does not read anything resolve_paths sets.
Why: matches 02-restore.sh's own comment (:115-116): "CONFIG_DIR is needed by both paths
below and resolving it needs neither root nor a service user to exist yet, so it happens
unconditionally, up front." Neither function can fail on the other's account, so the
order carries no correctness weight — this just avoids gratuitously reshuffling beyond
what moving `need_root` required.

## 2026-09-26 order 2026-09-25#1: 03-interactive.sh's tty check counted as pure validation

The order's definition of pure validation ("argument parsing, required-flag and
mutual-exclusivity checks, checkout/path existence, site.env parsing and validation, and
any 'what would run' summary") does not name a tty check by name. Choice: treated
`[ ! -t 0 ] || die "stdin is not a terminal..."` (03-interactive.sh) as pure validation
and moved it ahead of `need_root` along with the other reads. Alternative: leave it
paired with `need_root` on the theory that it is an environment precondition like
`resolve_service_user`, not an argument check.
Why: it only reads stdin's own state (no write, no dependency on the local machine's
image manifest or accounts) and is exactly the kind of "what would run" gate the order
describes — an unattended, non-interactive caller should be told THAT reason, not
refused for being non-root, which is the whole point of the reorder.

## 2026-09-26 order 2026-09-25#1: no live-tty "control" case in test-interactive-contract.sh

test-restore-contract.sh's style includes a "control" case proving a well-formed input
gets past the gates under test, and test-converge-contract.sh has one (a well-formed
--app reaching need_root). Choice: 03-interactive.sh's contract test has no equivalent —
only the tty-refusal cases and an unrelated arg-parsing regression case.
Alternative: fake a controlling tty (a pty via `script` or Python's `pty.fork`, both
confirmed working in this sandbox) and feed scripted answers past every `ask_yn` prompt
so the run reaches `need_root`.
Why: doing that safely needs answers for every prompt in phase 3 (password, SSH key,
network) or it can block on a `read`, and a test that can hang is worse than one that
is merely incomplete (assert-on-code-form / never-test-by-detonating spirit). The
RED-then-GREEN transition on the tty message itself is the property this order asked
to prove; a control case here would exercise phase 3's prompt flow, not the gate order.

## 2026-09-26 order 2026-09-25#1: no validation step was found to write

Checked each step now sitting ahead of `need_root` in all three files —
`resolve_paths`, `require_app_dir` (01-converge.sh); `resolve_paths`, the APP_DIR
fallback logic, the tty check (03-interactive.sh); the `--app`/mutual-exclusivity/
`--config-backup` checks (provision.sh) — against lib.sh's own definitions. None calls
`run`, `install`, `mkdir`, `mv`, `cp`, `chown`, or any other write. None needed to stay
behind `need_root` on those grounds, so this entry records the check rather than a
change: the bound's "list it in the report instead of moving it" clause did not fire.

## 2026-09-26 arm64 migration

Evan decided 2026-09-26 to migrate elspi to a 64-bit userland. The branch is the
architecture (docs/design/fork.md): master stays armhf, and everything below lives on
`arm64` except where noted. Every entry says why it is arm64-specific.

**On master, not arm64: image.yml stages the qemu that build.sh's ARCH needs
(03a77ea).** The first arm64 dispatch (run 36243403960) died at build-docker.sh's host
precheck, `qemu-aarch64 not found (please install qemu-user-binfmt)`: the workflow only
ever staged `qemu-arm`. The shim step now reads the single `export ARCH=` line from the
checkout's build.sh (never the branch name) and stages `qemu-arm` -> qemu-arm-static
for armhf or `qemu-aarch64` -> qemu-aarch64-static for arm64. A missing, duplicated or
unmapped ARCH line fails the step. On master the effect is the same as before: same
package, same symlink, same static gate. It went on master because the workflow is
shared, and arm64 picked it up by merge.

**stage-elspi/07-uv picks the uv tarball by `${ARCH}`.** master pinned
`uv-armv7-unknown-linux-gnueabihf`, which on an arm64 rootfs has no armhf loader to run
under, so `uv --version` in 08-venv's chroot would fail. The file now carries both
pins in a `case "${ARCH}"`: armv7 (unchanged hash d10df2eb...) and
`uv-aarch64-unknown-linux-gnu` 0.11.23 (hash 1873a773..., checked against the
published `.sha256` and the GitHub release asset digest, which agree). The post-write
`file` check is tighter now: `ARM, EABI5` for armhf and `ARM aarch64` for arm64. The
old check was a bare `ARM`, which either ABI passes. An unset or unknown ARCH is
FATAL. The file is written so it reads correctly on both branches, which means it can
be merged to master as-is to remove this divergence. That is a master change, so it
stays Evan's call.

**tests/dry-run-stages.sh exports ARCH, read from build.sh.** It runs 07-uv outside
pi-gen, so it now has to export ARCH the way build.sh does. Otherwise the stage
refuses to run, as it should. Checked in WSL: 07-uv gets the aarch64 tarball on
arm64, the armv7 tarball with ARCH=armhf, and is FATAL with ARCH unset or `riscv64`.

**stage-elspi/11-manifest measures `arch` and no longer hard-codes it.**
`/etc/elspi-image.json` said `"arch": "armhf"` as a literal, so on this branch it would
have lied. The field now comes from `dpkg --print-architecture` inside the chroot,
in the same on_chroot block that already measures python and uv. The build is FATAL
if that disagrees with build.sh's ARCH. The dry-run fallback is "unmeasured", the same
as its neighbors. Only test fixtures read the field, so nothing downstream expected
the literal. This change is also branch-neutral and could go to master.

**tools/make-os-list.sh uses 64-bit Imager device tags on this branch.** master's
list is `pi5/4/3/2/1-32bit`, deliberately 32-bit-only. For an arm64 image the danger
is reversed: a 32bit tag offers it to a Pi 1/2/Zero whose CPU cannot run it. The
arm64 list is `pi5-64bit, pi4-64bit, pi3-64bit`, the same set Raspberry Pi OS
(64-bit) carries, and the description says arm64. tests/test-os-list.sh expects the
same. This is a real branch divergence: a master edit to those lines will conflict
on the next merge. Resolve it by keeping arm64's tags.

**Kivy: taken from PyPI's prebuilt aarch64 wheel. This is the migration's main
payoff, and it is NOT a Kivy build option we chose.** The vendored uv.lock already
lists `Kivy-2.3.1-cp313-cp313-manylinux_2_17_aarch64.manylinux2014_aarch64.whl`, and
`uv sync --frozen` takes it, so arm64 does not compile Kivy from sdist under emulation
the way armhf has to. The question is whether that wheel's bundled SDL2 can drive the
Pi's display with no X server. Checked in kivy/kivy at tag 2.3.1: the manylinux job's
`install_manylinux_build_deps` (.ci/ubuntu_ci.sh) installs `libdrm-devel` and
`mesa-libgbm-devel` before `tools/build_linux_dependencies.sh` builds SDL 2.30.7 with
default CMake options. SDL's CMake enables its KMSDRM video driver when those are
present. Kivy's own installation-rpi.rst says the same. So the wheel should carry
kmsdrm, but that is **UNVERIFIED on hardware**. It is the first thing the boot test
settles.
Consequence, not acted on: 01-toolchain's SDL2 `-dev` packages were there to compile
Kivy, and on this branch nothing needs them to. They stay, because removing them is a
judgment call. psutil still builds from sdist on both arches and needs the compiler.

**Not changed, and known to be armhf-only:** build-elspi.sh, the local build wrapper,
still stages only `qemu-arm`. tests/verify-image.sh and tests/verify-built-image.sh
gate on a `qemu-arm` binfmt handler. README.md and docs/flashing.md still describe an
armhf userland. None of these is on the CI image path. Changing any of them on this
branch adds merge surface for a local-build or docs path that has no arm64 user yet.

## 2026-09-26 image.yml: the runner follows build.sh's ARCH; arm64 builds natively

Evan asked for elspi's arm64 image to build on GitHub's native arm64 runners instead of
under qemu on x86. The change is in `.github/workflows/image.yml` only, on master, and
reaches arm64 by merge. No pi-gen file is touched, so the merge surface
(docs/design/fork.md) does not grow.

**The runner is picked from build.sh's ARCH, never the branch name.** A new `arch` job
does a sparse checkout of build.sh, reads its single `export ARCH=` line (missing,
duplicated or unknown fails in seconds), and outputs the runner label and the qemu name:
armhf -> `ubuntu-24.04` + `qemu-arm`; arm64 -> `ubuntu-24.04-arm` + `qemu-aarch64`. The
build job runs on `${{ needs.arch.outputs.runner }}`. Its first step re-reads build.sh
from the full checkout and must agree with the arch job, then measures `uname -m`. Only
aarch64 building arm64 counts as native. The qemu shim step and
`docker/setup-qemu-action` run only when that step says the host is emulating. Master's
armhf path is unchanged in effect: same x86 label, same shim, same binfmt registration,
same build command.

**Label, cost and Docker, from GitHub's own pages (checked 2026-09-26).** The hosted
runners reference lists `ubuntu-24.04-arm` for public repositories (4 CPU, 16 GB).
It also says standard runners are "free and unlimited on public repositories". The
2025-08-07 changelog made the arm64 runners generally available for public repos "at no
cost". The image is Arm's partner image (actions/partner-runner-images,
arm-ubuntu-24-image.md), whose software list includes Docker, Docker Compose and Docker
Buildx.

**pi-gen needs no qemu or binfmt_misc on an aarch64 host. Read on the arm64 branch at
f5d7a99:** build-docker.sh sets `binfmt_misc_required=0` for `uname -m` = aarch64/arm*,
which skips the `which qemu-aarch64` lookup, the binfmt_misc mount and the handler
registration. scripts/dependencies_check skips its binfmt_misc check on the same test.
build.sh's page-size check applies only to armhf, and `arch-test -n arm64` passes
natively. What does still run is inside the container and harmless: the Dockerfile
installs qemu-user-static, `depends` lists `qemu-arm:qemu-user-binfmt` (satisfied by
that package), and build-docker.sh's container command runs `dpkg-reconfigure
qemu-user-binfmt` and a `|| true` binfmt_misc mount. All of these are upstream's own
behavior on a native Pi build host, so no host-arch condition was needed and nothing
was added.

**armhf stays on x86 + qemu.** The arm64 runners are Azure Cobalt 100, a Neoverse N2
design. Arm's Neoverse N2 TRM (102099, issue 05) says the core "supports AArch32 at
EL0", so the silicon is not the proven blocker. Nothing from GitHub promises 32-bit
execution on these runners either. Third-party reports show 32-bit ARM binaries failing
with `Exec format error` on GitHub's aarch64 runners, sometimes only intermittently
(astral-sh/uv-dev#2055). So a native armhf build there is not reliable, and master
keeps the x86 label.
