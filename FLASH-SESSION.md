# The hardware session (booked 2026-09-13/14)

Checklist item 17: *"PROVE IT ON HARDWARE: build a second SD card from scratch
and boot it on the real Pi."*

Rewritten 2026-09-07 (evening), after the image was built and the delta layer
written. The earlier version of this file said the delta layer did not exist —
it does now, so the session can attempt a working lathe rather than only a
boot.

---

## What is ready

| | state |
|---|---|
| Image | `deploy/image_2026-09-08-elspi.img.xz`, 1.3 GB, built 46m26s |
| Baked SSH key | Evan's desktop `id_ed25519` — verified byte-identical, `PasswordAuthentication no` |
| Tier 2 | **90 passed, 0 failed, 3 unknown** against that exact rootfs |
| Delta layer | `deltas/` — converge, restore, interactive |
| Commissioned config | captured 2026-09-07, verified 19/19 against a live hash pull |

The three UNKNOWNs are honest and permanent-ish: DRM master (no GPU in any
harness), the booted tier (`nspawn --boot` does not work in this nesting), and
Pillow (`SEAM.md` ratified promoting it in the reflex repo; not landed).

## What this session can and cannot settle

**CAN:** everything invisible to a VM — whether the display comes up at all
(KMS/DRM, V3D), the touchscreen, SPI/I²C and the UART link to the STM32,
whether `usb_max_current_enable=1` stops the brownouts, audio on card 0. And
the headline: **does a non-root process take DRM master.**

**CANNOT:** prove the image is a complete recovery path. The delta layer has
never run against real hardware — only its refusal paths, exercised inside the
built rootfs. Expect to debug it.

---

## Before you go out there

1. **Re-capture the commissioned config if you have used the lathe since
   2026-09-07.** The current capture is
   `dserver:~/backups/elspi/elspi-reflex-config-2026-09-07`. It drifted 13 of
   19 files in the 16 days before it, so a week of bench work is enough to
   matter. Restoring a stale capture puts old geometry on the machine and
   nothing downstream notices.
2. **Bring the capture to the Pi.** `02-restore.sh` cannot fetch it — it would
   have to know where dserver is, and nothing machine-specific lives in this
   repo.
3. **Keep the original SD card.** It is the rollback and it is the running
   machine. Flash a *second* card.

---

## The DRM question — the actual point of the session

The image ships **three** mechanisms and a switcher, so a wrong guess costs an
SSH command instead of a reflash:

```sh
elspi-drm-mode                  # what is it now?
elspi-drm-mode first-opener     # image default
elspi-drm-mode logind-seat      # autologin tty1 + user unit
elspi-drm-mode cap-sys-admin    # last resort
```

**The ladder. Stop at the first that works.**

1. **`first-opener`** is already active. If the UI takes the display, done —
   the appliance runs non-root with no privilege and no seat machinery.
2. **If it fails, check Plymouth BEFORE changing mode.** Plymouth's DRM
   renderer is itself a master, and the likeliest failure is that it has not
   released the display. `systemctl status plymouth-quit-wait.service`; try
   stopping Plymouth by hand and restarting the app. **If that fixes it the
   fault is ordering, not mechanism** — a much better answer than escalating
   privilege, and one that changes what we ship.
3. **`logind-seat`** — needs a **reboot**, not a restart: the seat session is
   created at login.
4. **`cap-sys-admin`** — takes the display regardless of seats. If the machine
   ends up resting here, write it up. It is a floor, not a destination.

Record which rung worked. `/etc/elspi-image.json` carries
`"verified_on_hardware": false` and that flips only on evidence.

---

## Recovery — read before flashing

The account ships **locked**, so the baked key is the only way in. Confirm SSH
works *before* touching anything else:

```sh
ssh default@<the pi>
```

With SSH up, a failed UI is a five-second fix. Without it, every experiment
above is a power cycle.

---

## Running it

**On dserver (bash)** — only if you need to rebuild:

```bash
cd ~/projects/elspi && ./build-elspi.sh ~/elspi-flash-key.pub
```

**On the Pi (bash)**, after flashing and confirming SSH:

```bash
sudo ./provision.sh --app /home/default/projects/reflex \
                    --config-backup /path/to/elspi-reflex-config-YYYY-MM-DD
```

The app checkout has to get onto the Pi somehow — clone it, or copy it from the
old card. `provision.sh` will not invent it.

Phases run in order and stop on failure. Each is also runnable alone, and all
three take `--dry-run`.

**Nothing starts the application.** That is deliberate: phase 2 prints the
commissioned values it restored, and starting before a human has looked at them
means coming up on whatever happened to be in the file. When you are satisfied:

```bash
systemctl start reflex-ui
journalctl -u reflex-ui -f
```

---

## Things that will probably bite

- **The app's stock unit says `User=root`.** The image runs non-root, and the
  `elspi-drm-mode` drop-in overrides `User=`/`Group=`. Converge gates on
  systemd's *resolved* `User=` and refuses to continue if it still says root.
  If that gate fires, the drop-in did not take.
- **Sudoers.** The image reproduces the live pair exactly: `reflex-restart`
  (restart) and `reflex-stopstart` (**stop only** — the name lies, verified on
  the live machine 2026-09-07). Converge asserts the grant does *not* extend to
  other units.
- **The venv is at `/opt/reflex-venv`**, not in the checkout. Converge symlinks
  the checkout's `.venv` at it so stock `start.sh` works unmodified, and hard
  fails if the image venv is missing — on a non-image machine `uv` would
  silently start compiling Kivy from source.
- **`/dev/ttyAMA0` carries Modbus.** The image takes the serial console off the
  kernel cmdline *and* masks `serial-getty@ttyAMA0`. If Modbus frames are
  garbled, check both.

---

## After the session

- Flip `verified_on_hardware` only if DRM was actually verified, and record
  which rung.
- If `first-opener` worked, say so plainly — the `logind-seat` machinery can
  then be deleted rather than maintained.
- Item 12: diff the provisioned Pi against the live elspi. That is the check
  that says whether the delta layer is complete, and it can only be done here.
