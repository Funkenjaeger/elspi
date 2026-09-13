# Verifying the image

This is the plan and, more importantly, the honest boundary of what each tier
can prove. Researched 2026-08-17.

**Updated 2026-09-07: the Tier 2 harness now exists and parts of it have been
run.** The line that used to open this document — "Nothing here is built yet" —
is no longer true. See *Built 2026-09-07* at the bottom for what has actually
been executed as opposed to designed; the two are kept apart on purpose.

## Three tiers, and only the third proves the appliance works

| Tier | Proves | Where |
|---|---|---|
| 1. It builds | the stage scripts run to completion and produce an image | CI |
| 2. It boots and matches the declaration | the userland is what we said it would be | CI |
| 3. It runs the lathe | everything that makes this an appliance | **real hardware only** |

## Tier 1 — building in CI is a solved problem

`bartei/ospi` already does exactly this in `.github/workflows/release.yml`, on a
stock `ubuntu-latest` hosted runner:

1. free disk space — `rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc`
   (the runner is tight for a 2–3 GB image)
2. `docker/setup-qemu-action@v3`
3. `./build-docker.sh -c ci.conf`
4. publish `deploy/*.zip`

So the build half needs no invention. This paragraph used to add that ospi's
`build-docker.sh` binfmt fix was on our cherry-pick list for exactly this
reason. **CORRECTED 2026-09-07: upstream already has it.** At our pin
`314262c`, `build-docker.sh` guards the registration with
`if ! grep -q "^interpreter ${qemu_arm}" /proc/sys/fs/binfmt_misc/qemu-arm*`,
so skipping-when-already-registered is upstream behavior and there is nothing
to port. Corrected rather than deleted, so the record shows the claim was
checked instead of quietly losing it. See `FORK.md`.

What ospi does **not** do is verify anything. It builds and releases; there is no
boot test and no assertions, and its `todo.md` still lists "test full build
end-to-end" unchecked. Tier 2 is ours to design.

## Tier 2 — boot the rootfs, assert on it

**Emulating the real board is out.** QEMU ships `raspi3b` and `raspi4b` machine
models; there is no `raspi5`, and elspi is a Pi 5. Do not spend time here.

Boot the *root filesystem* instead, which needs no Pi emulation:

- **Preferred: `systemd-nspawn --boot`** into the built rootfs under
  `qemu-user-static` binfmt. This really starts systemd, so unit enablement and
  ordering, users and groups, sudoers, installed packages, the venv, and
  `python -c "import kivy"` are all assertable, and it is fast enough to run on
  every push.
- **Fallback: `qemu-system-aarch64 -M virt`** with a generic kernel over the
  rootfs — a more faithful init, still not the Pi firmware path.

Worth asserting: expected packages present and unexpected ones absent (no X
server, no compositor — see `RUNTIME-INVENTORY.md`), `reflex-ui.service` enabled
and its unit valid, the `default` user with its full group list, the single
sudoers rule, the venv resolving to the versions in `uv.lock`, timezone correct,
and `config.txt`/`cmdline.txt` containing the expected lines.

## What Tier 2 cannot see, and must say so

A green CI run means **"the image built, and its userland is what we declared."**
It does not mean the appliance works. Invisible to any VM:

- KMS/DRM and the V3D driver — there is no GPU
- the touchscreen
- SPI, I²C, and the UART link to the STM32
- anything `config.txt` or a `dtoverlay` actually *does* — firmware level, not
  emulated. These can only be asserted **textually**, that the expected lines are
  present.
- the `usb_max_current_enable=1` brownout workaround

The harness must print this list rather than leave it implicit. A check that
cannot fail on the thing you care about reports a confident clean over exactly
the state it could not see — so Tier 3 stays mandatory no matter how green CI is.

## Runner choice — GitHub-hosted, unless the build turns out to be very long

Decided 2026-08-17: default to **GitHub-hosted**. The free allowance on a private
repo is 2000 minutes/month, which is roomy at this cadence, and the metering
disappears entirely once the repo goes public — which is the intent as soon as it
is moderately mature.

The number nobody has yet is *our* build's duration, and there is a specific
reason to expect it to exceed ospi's: **we compile Kivy from source under
QEMU-emulated armhf**, which ospi never pays for (see `RUNTIME-INVENTORY.md`).
Emulated Cython compilation is slow. Measure the first manual build before
assuming the allowance is generous — though even at two hours a build, 2000
minutes is roughly 16 builds a month, and GitHub's 6-hour job ceiling is not
close.

Revisit a self-hosted runner on dserver only if that measured number comes back
bad. Persisting pi-gen's `work/` directory between runs would make iteration much
faster there, but note that cuts against the point of this harness: a verification
build should start clean, or it stops proving the image is reproducible from
scratch.

## Built 2026-09-07 — what exists now, and what it has actually proven

The plan above was written 2026-08-17 with nothing built. The harness now
exists. This section records what it is and, more usefully, the exact boundary
of what has been *run* versus what is still only designed.

| Script | What it does | Run? |
|---|---|---|
| `tests/self-test.sh` | mutates a synthetic rootfs 31 ways and asserts the harness goes red for each | **yes — baseline green, 31/31 red** |
| `tests/dry-run-stages.sh` | runs the chroot-free substages against the REAL upstream stage1 templates, twice (idempotence), plus two negative controls | **yes — 9/9** |
| `tests/test-lockfile-drift.sh` | vendored `pyproject.toml`/`uv.lock` vs the reflex repo | **yes — in sync at reflex `dc5da79`** |
| `tests/test-run-scripts-executable.sh` | every `*-run.sh`/`prerun.sh` is mode 100755 **in the git index** | **yes — 43/43** |
| `tests/test-drm-mode-switcher.sh` | runs the real `elspi-drm-mode` and asserts its refusal paths — added 2026-09-13 with the deletion of the `logind-seat` rung, since `verify-image.sh` only ever sees a fixture *stub* of the switcher and so can check what it says, never what it does | **yes — 17/17** |
| `tests/verify-image.sh` | Tier 2 offline assertions against a built rootfs | not yet — no image exists |
| `tests/verify-image.sh --boot` | Tier 2 booted assertions under `systemd-nspawn` | not yet — needs the image and `qemu-user-static` |

### Why there is a mutation test at all

Tier 2 is a pile of `grep`s. A pile of `grep`s that has never been shown to
fail is indistinguishable from a pile of `grep`s with a typo in every pattern,
and both report a confident clean. `self-test.sh` builds a synthetic rootfs
that satisfies the contract, then breaks one declared property at a time —
root unlocked, SPI switched off, a Wayland compositor installed, Kivy stripped
of its `.so`s, `asound.conf` back on card 1, the tty1 autologin shipped active
— and requires a red result for each. It runs in seconds on any Linux box with
no build, no Docker and no qemu, because a mutation test that is expensive is a
mutation test that gets skipped.

### The silent-skip trap, found while writing the stage

`build.sh:68` is `if [ -x ${i}-run.sh ]; then`, and `build.sh:107` is the same
for `prerun.sh`. **A run script without its executable bit is silently
skipped** — no warning, exit 0, "successful" build, substage simply not
performed. Lose the bit on `03-boot-config` and the image ships with SPI off
and a getty on the Modbus UART, and nothing says so.

This repo is edited from Windows, where the working-tree mode is not
authoritative, so `tests/test-run-scripts-executable.sh` checks **the git
index**, not the filesystem. Checking the filesystem there would be a check
that cannot fail.

### The blind spots are not in the harness

`verify-image.sh` prints them by reading
`cannot_be_verified_without_hardware` out of the image's own
`/etc/elspi-image.json`. One declaration, shipped with the artifact. A harness
holding a private copy of that list will eventually disagree with the image and
be believed anyway.

The list gained a member on 2026-09-01 and it is the important one: **DRM
master acquisition**. It is reported as `UNKN`, printed as loudly as a failure,
because "could not measure" and "measured and fine" are different answers.
