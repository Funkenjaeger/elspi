# The hardware session (booked 2026-09-13/14)

Checklist item 17: *"PROVE IT ON HARDWARE: build a second SD card from scratch
and boot it on the real Pi."*

Written 2026-09-07 from the desk, with the stage built and the image not yet
built. It exists so the session is spent on the machine rather than on
decisions that could have been made at a desk.

---

## READ THIS FIRST — the session cannot fully succeed yet

**The delta layer does not exist.** `SEAM.md` splits the work in two: the
IMAGE (built, this repo) and the DELTAS (app deploy, `reflex-ui.service`,
`start.sh`, the sudoers rule, the restore of `/var/lib/reflex-config`, the
interactive phase). Checklist items 13 and 14 cover the deltas and **neither is
started**.

A perfect image on its own boots to a console with a venv and no application.
That is still a worthwhile hardware test — see *What this session CAN prove* —
but do not go in expecting a working lathe on the new card.

**And the prerequisite that predates everything: `/var/lib/reflex-config` is
still not backed up.** Checklist item 0, verified 2026-08-16: elspi is in no
backup job anywhere. That directory is commissioned machine data measured off
the physical lathe — `els_backlash_steps 435`,
`els_cal_last_measured_steps 363`, `els_cal_motion_thresh_counts 2`, ceiling
1008 — and **no provisioning system can regenerate it.** The new image ships
that directory *empty and owned*, deliberately, because item 14 requires
provisioning to restore it and to fail loudly rather than invent defaults.

So: get that data off the machine before the session, not during it.

---

## Before the session (desk work, no lathe)

1. **Back up `/var/lib/reflex-config`** off the live elspi. Item 0. Do this
   even if nothing else on this list happens.
2. **Build the image.** Needs one `sudo` on dserver first — see *Building* below.
3. **Run the harness** against the built rootfs:
   ```sh
   tests/verify-image.sh work/elspi/stage-elspi/rootfs
   sudo tests/verify-image.sh work/elspi/stage-elspi/rootfs --boot
   ```
   Both must be green before an SD card is written. A red harness on the desk
   is free; the same fault found at the lathe costs a power cycle.
4. **Keep the original SD card.** It is the rollback, and until item 0 is done
   it is also the only copy of the commissioned data. Flash a *second* card.

---

## What this session CAN prove

Everything on the Tier 3 list that the harness structurally cannot see:

| Question | Why only hardware answers it |
|---|---|
| **Does a non-root process take DRM master?** | no GPU in the harness. This is the headline item |
| Does the display come up at all (KMS/DRM, V3D) | no GPU |
| Does the touchscreen enumerate on the MTD path | no touchscreen |
| Is `/dev/ttyAMA0` free of a getty, and does SPI/I²C exist | firmware-level; `config.txt` is only asserted *textually* |
| Does `usb_max_current_enable=1` stop the brownouts | needs the real panel |
| Does audio play on card 0 | needs the real HDMI sink |

## What it cannot prove yet

The lathe working end to end. That needs the delta layer.

---

## The DRM question, and how to spend attempts cheaply

This is the one genuinely open decision, and the session is where it closes.

The image ships **three** mechanisms and a switcher, precisely so that a wrong
guess costs an SSH command instead of a reflash:

```sh
elspi-drm-mode                     # what is it now?
elspi-drm-mode first-opener        # image default
elspi-drm-mode logind-seat         # autologin tty1 + user unit
elspi-drm-mode cap-sys-admin       # last resort
```

**Ladder, in order. Stop at the first that works.**

1. `first-opener` — already active. If the UI takes the display, done: the
   appliance runs non-root with no privilege and no seat machinery.
2. If it fails, **check Plymouth first, before changing mode.** Plymouth's DRM
   renderer is itself a master, and the likeliest failure is that it has not
   released the display. `systemctl status plymouth-quit-wait.service`, and
   try stopping Plymouth by hand and restarting the app. If that fixes it, the
   fault is ordering, not mechanism — a much better answer than escalating.
3. `logind-seat` — needs a **reboot**, not a restart, because the seat session
   is created at login.
4. `cap-sys-admin` — takes the display regardless of seats. If the machine ends
   up resting here, write it up; it is a floor, not a destination.

**Record which rung worked and why.** The image manifest carries
`"verified_on_hardware": false` and that flips only on evidence.

---

## The recovery path — read before flashing

`elspi.conf` sets `ENABLE_SSH=1` with `PUBKEY_ONLY_SSH=1`, and **the build
refuses to produce an image without `ELSPI_PUBKEY`**. This is the difference
between an experiment and a power cycle: the service account's password is
locked by design, so if no key is baked in, a card whose UI does not start is
reachable only from the touchscreen.

So, before writing the card, confirm:

- the image was built with `ELSPI_PUBKEY` set to a key you hold;
- you can reach the new card over SSH *before* touching anything else.

If SSH is up, a failed UI is a five-second fix. If it is not, everything below
is a power cycle each.

---

## Building

Needs `qemu-user-static` on the build host, which needs root. **On dserver, in
bash:**

```bash
sudo apt-get update && sudo apt-get install -y qemu-user-static qemu-user-binfmt binfmt-support
```

Then, still on dserver, in the repo:

```bash
ELSPI_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" ./build-docker.sh -c elspi.conf
```

Expect it to be slow, and expect it to fail in `08-venv` if it fails at all:
compiling Kivy from sdist inside an emulated armhf chroot is the riskiest step
in the build, and `SEAM.md` says to prove that one step before trusting the
rest. Nobody has a duration for it yet — ospi never pays this cost, because on
its Python version its app pulls a prebuilt wheel. **Measure the first build**;
`VERIFICATION.md`'s runner choice depends on that number and on nothing else.

Output lands in `deploy/`.

---

## After the session

- Flip `verified_on_hardware` only if DRM was actually verified.
- Record the working DRM rung in `RUNTIME-INVENTORY.md`, replacing the
  hypothesis with a measurement.
- If `first-opener` worked, say so plainly — it means the seat machinery in
  `logind-seat` can eventually be deleted rather than maintained.
