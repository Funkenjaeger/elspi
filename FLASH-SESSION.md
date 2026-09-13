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
| Image | `deploy/image_2026-09-13-elspi.img.xz`, 1.3 GB, built 2026-09-12 22:20-23:04 from `9fd9291` (this branch), sha256 `58f4846b…3bb4a7`; a copy sits on the desktop at `C:\Users\evand\elspi-image\` |
| Baked SSH key | Evan's desktop `id_ed25519` — verified byte-identical, `PasswordAuthentication no` |
| Tier 2 | **102 passed, 0 failed, 4 unknown** against that exact rootfs, measured 2026-09-13 with `tests/verify-built-image.sh --chroot`. Includes the twelve first-boot-seed checks (meta-data `instance-id`, unit, script, enablement, ordering, manifest). The fourth UNKNOWN is the seed's runtime behaviour, a Tier 3 item |
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

## Flashing the card

**From a published release (a user with no checkout): one line, no script.**
The release carries `os_list.json` beside the image, and Imager fetches the image
itself from that URL, verifying it against the published hashes. Nothing is
downloaded by hand.

- **Windows:** press **Win+R**, paste, Enter (the installer registers
  `rpi-imager.exe` in App Paths, which the Run dialog resolves; a PowerShell
  prompt does not, there use `cmd /c start rpi-imager --repo <url>`):

      rpi-imager --repo https://github.com/Funkenjaeger/elspi/releases/download/<tag>/os_list.json

- **Linux** (packaged `rpi-imager` on PATH, 2.x from raspberrypi.com, not the
  distro's 1.x):

      rpi-imager --repo https://github.com/Funkenjaeger/elspi/releases/download/<tag>/os_list.json

Imager opens on **one OS entry**, then Device, Storage, and the customisation
page described below. The rest of this section is the same flow **from a
checkout**, where the launchers add the version check and find the JSON the
build wrote. Measured 2026-09-13 against a LAN host standing in for the release
URL: the entry, the download and the customisation page all behaved.

**From a checkout: run the launcher. Do not open Imager and pick the image yourself.**

**On Windows (PowerShell):**

```powershell
cd C:\projects\elspi
.\tools\flash-elspi.ps1
```

**On Linux (bash):**

```bash
cd ~/projects/elspi
./tools/flash-elspi.sh                       # packaged rpi-imager on PATH
./tools/flash-elspi.sh ./rpi-imager_*.AppImage   # or an AppImage
```

Either one finds Imager, refuses anything older than 2.0, and starts it as
`rpi-imager --repo deploy/os_list.json`. Imager then opens on **one OS entry**
— this image — followed by the normal Device and Storage steps and then the
customisation page. Take the OS entry, pick the Pi, pick the card, and fill the
page as below. Windows shows a UAC prompt: Imager writes raw disks and asks for
administrator rights itself.

### Why not just "Use custom" and pick the .img.xz

**Because Imager 2.x never offers the customisation page for a local file, and
does not say so.** `src/wizard/OSSelectionStep.qml` calls `setSrc(fileUrl)`
with the default `initFormat` of `""` (`src/imagewriter.h`), so
`imageSupportsCustomization()` is false and `WizardContainer.qml` skips every
customisation step. You get a flash that succeeds and a card with **no
password, no key, no Wi-Fi and no country** — and
`stage-elspi/12-first-boot-seed`, which exists to consume that seed, has
nothing to consume. The only difference you would notice is a wizard with two
fewer pages.

The page appears only for an entry in an **OS-list repository** that declares
`init_format` `"cloudinit-rpi"`, and Imager takes a custom repository on the
command line (`--repo`, `src/main.cpp`). So `deploy/os_list.json` — written by
the build, one entry, `file://` URL pointing at the image beside it — is what
makes the documented seed work at all. `tools/make-os-list.sh` writes it; the
build fails if it cannot.

**And Imager 1.x is refused, not merely discouraged.** 1.x accepts `--repo`, so
it looks like it worked — but its customisation page seeds a card through
`firstrun.sh`/`userconf.txt`, which this image never reads. Both launchers
check the version and stop, pointing at <https://www.raspberrypi.com/software/>.

If the JSON is missing (you have an image but not the build that made it):

```bash
tools/make-os-list.sh path/to/image_2026-09-13-elspi.img.xz
# writes os_list.json beside the image; --out puts it elsewhere,
# --url https://... is for a published release
```

It streams the 7.5 GB decompressed image past `sha256sum` and `wc -c` in one
pass without writing it anywhere, so it takes a couple of minutes and no disk.

Now fill the customisation page:

| Field | Value | Why it matters |
|---|---|---|
| Hostname | `elspi` | matches `TARGET_HOSTNAME` |
| Username | **`default` — exactly** | see below |
| Password | pick one, and write it down | this becomes the `sudo` password |
| SSH | **enable**, and choose **"Allow public-key authentication only"** | see below |
| Public key | the desktop's `id_ed25519.pub` | the recovery path |
| Wi-Fi SSID / password | the shop network | |
| Wireless LAN country | **`US`** | nothing else turns the radio on |

**The username must be `default`.** That is the image's service user — the
account `stage-elspi/05-service-user` creates, that owns
`/var/lib/reflex-config`, `/var/log/reflex` and `~/projects`, and that
`reflex-ui.service` and the `elspi-drm-mode` drop-in name. Type anything else
and Imager creates a *second*, unrelated account: the lathe's own account stays
locked, the new one owns nothing the app needs, and every path in the delta
layer points at the wrong home directory.

**Tick "Allow public-key authentication only", not password SSH.** Imager
writes `ssh_pwauth: true` for the password option, and cloud-init 25.2
(`cc_set_passwords.py:60-90`) turns that into `PasswordAuthentication yes` in
`/etc/ssh/sshd_config` — **the same file `stage2/01-sys-tweaks/01-run.sh` set
to `no`** because `elspi.conf` sets `PUBKEY_ONLY_SSH=1`. So that one checkbox
silently reverses the image's SSH posture. The first-boot unit **warns about
this in the journal and does not revert it**: it was your explicit choice at
flash time, and an image that quietly undoes what the operator asked for is
worse than one that tells them. If you tick it anyway, know that the lathe is
then reachable by password over SSH.

**Country `US` is not cosmetic.** netplan's `regulatory-domain` key is rendered
only by the *networkd* backend and this image uses NetworkManager, so nothing
in cloud-init applies it. The first-boot unit reads it back out of
`/boot/firmware/network-config` and applies it itself — but only if you set it.

### The non-Imager route, if you ever need it

**Not implemented, and not needed while the launcher works — written down so
nobody has to rediscover it.** The seed is three plain files on the image's FAT
partition, so it can be injected into the `.img` *before* flashing instead of
by Imager: decompress the image, find the first partition's byte offset
(`fdisk -l`, or `partx`/`kpartx`), and copy `user-data`, `network-config` and
`meta-data` in with mtools, which needs no loop device and no root —
`mcopy -i image.img@@<offset> user-data ::user-data`, once per file. Then flash
the `.img` with anything at all: Imager's "Use custom", `dd`, `bmaptool`. The
first boot is identical, because cloud-init reads the card, not Imager. The
catch is that you are then authoring a cloud-config and a netplan document by
hand — with the password hash and the PSK in a file on your disk — which is
exactly the work the customisation page does for you, and exactly the exposure
`12-first-boot-seed` cleans up on the card but not on your desktop.

### What happens on the first boot

`elspi-first-boot-seed.service` runs once cloud-init has finished
(`After=cloud-final.service`) and does the four things cloud-init cannot do on
this image:

1. **Turns the radio on.** `stage2/02-net-tweaks` ships
   `NetworkManager.state` with `WirelessEnabled=false` and the wlan rfkill
   soft-blocked, because `WPA_COUNTRY` is unset at build time. Without this
   step a perfectly rendered Wi-Fi keyfile never associates.
2. **Applies the regulatory domain** from the seed.
3. **Installs the password you typed.** cloud-init *ignores* Imager's `passwd`
   key for an account that already exists
   (`distros/__init__.py:894-907`) — and then unlocks the account anyway,
   exposing the random build-time throwaway from `elspi.conf`. The unit applies
   your hash instead, which also overwrites that throwaway. If you left the
   password blank, it re-locks the account instead.
4. **Takes the credentials off the card.** `user-data` is overwritten with a
   bare `#cloud-config` and `network-config` with `network: {version: 2}`;
   `meta-data` is left intact because it carries the instance-id. The FAT
   partition is unencrypted and readable by any machine with a card slot, so
   the password hash and the 64-hex PSK do not stay there.

**Check it ran**, before trusting any of the above:

```sh
journalctl -u elspi-first-boot-seed --no-pager
```

Look for the single summary line — `verdict=OK steps_done=[...] warnings=N` —
and read the `WARNING:` lines if `warnings` is not `0`. A `verdict=DEFERRED`
means cloud-init had not finished and **nothing** was done, including the
credential wipe.

**None of this has ever run on hardware.** It is derived from cloud-init 25.2
source and verified only by the offline harness. Expect to debug it, and check
`/boot/firmware/user-data` by hand afterwards to confirm the seed really is
gone.

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

The account ships **locked**, and there are now **two** ways in: the key baked
at build time from `ELSPI_PUBKEY`, and the key you pasted into Imager's
customisation page. Either is enough; both is better, and they are independent
— a typo on the customisation page does not cost you the card. Confirm SSH
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
