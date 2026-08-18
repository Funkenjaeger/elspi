# Verifying the image

Nothing here is built yet. This is the plan and, more importantly, the honest
boundary of what each tier can prove. Researched 2026-08-17.

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

So the build half needs no invention. Note this is *why* ospi's `build-docker.sh`
binfmt fix is on our cherry-pick list — skipping manual binfmt registration when
`setup-qemu-action` already did it is precisely what makes the build work on a
hosted runner.

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
