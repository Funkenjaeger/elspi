# `12-first-boot-seed` — Imager's customisation page as the supported seed

**Design (a), ratified by Evan 2026-09-12.** Raspberry Pi Imager 2.x's
OS-customisation page is the supported way to seed this image at flash time,
and this substage ships what the fork needs for that to actually work.

Nothing here puts a credential in the repo or in the image. The operator types
the password, the public key and the Wi-Fi SSID/PSK into Imager; Imager writes
them to the FAT partition; cloud-init consumes them on first boot; this
substage's unit then takes them off the card. See `SEAM.md` and
`FLASH-SESSION.md`.

## Why it is numbered 12

`11-manifest` **does not inventory substages.** It writes a hand-authored
static `/etc/elspi-image.json` and never enumerates anything — there is no loop
over unit files or over `stage-elspi/*`, so no numbering choice makes it "pick
this up". Its post-write check greps for a fixed list of required keys. The
number is therefore free, and 12 was chosen so that:

- nothing needs renumbering (`tests/dry-run-stages.sh` calls `run_stage
  11-manifest` by name), and
- this substage stays the last thing the image does, which matches what it
  touches: the FAT boot partition and one unit, not the userland that the
  manifest describes.

The manifest *does* now **declare** this unit, under the `first_boot_seed` key,
and `tests/verify-image.sh` reads the paths out of that declaration rather than
hardcoding them — the same arrangement already used for `drm.switcher`, which
`06-seat` creates. The manifest has never created what it declares.

## What the build-time half does

`00-run.sh` is **chroot-free** — it touches only `${ROOTFS_DIR}` — which is why
`tests/dry-run-stages.sh` can exercise it in seconds on any Linux box instead
of only inside a three-hour emulated build. It:

1. **Rewrites `instance_id:` to `instance-id:` in
   `/boot/firmware/meta-data`.** Upstream's `stage2/04-cloud-init` template
   carries the key with an **underscore**; cloud-init 25.2's NoCloud datasource
   reads the **hyphen** form and otherwise falls back to the literal
   `"nocloud"`. The fix is applied here, at image-build time, **rather than by
   editing upstream's template** — that would add a second file to the merge
   surface forever (`FORK.md`). The anchor is asserted before the `sed` and
   re-grepped after, in both directions: the hyphen must be present *and* the
   underscore must be gone, because a file carrying both keys is ambiguous.

2. **Installs and enables the oneshot unit.** Enablement is a direct
   `multi-user.target.wants` symlink — exactly what `systemctl enable` produces
   for a unit declaring `WantedBy=multi-user.target` — which is what keeps the
   substage chroot-free. The symlink is then checked for existence *and for
   resolving*, since a dangling enablement symlink looks enabled to `ls` and is
   silently ignored by systemd.

## What the runtime half does

`files/elspi-first-boot-seed.sh`, run by
`files/elspi-first-boot-seed.service` after `cloud-final.service` and
`NetworkManager.service`, on **every** boot.

Its contract, in full, is at the top of the script: it never fails the boot, it
never prints a secret, it is idempotent, and every step gates on a signal that
could have come out differently. The steps:

| # | Step | Gate |
|---|---|---|
| 0 | Refuse to do anything unless cloud-init has finished | `/var/lib/cloud/instance/boot-finished` exists |
| 1 | Find a Wi-Fi profile | `grep -l '^type=wifi'` in `/etc` **and** `/run` `NetworkManager/system-connections` |
| 2 | `rfkill unblock wlan`, `nmcli radio wifi on` | blocked-line count before/after; `nmcli radio wifi` before/after; `NetworkManager.state` says `WirelessEnabled=true` |
| 3 | Set the regulatory domain from the seed | `iw reg get` before/after |
| 4 | Apply the password cloud-init discarded | the `/etc/shadow` field before/after |
| 5 | Report Imager's `ssh_pwauth` effect on sshd | `PasswordAuthentication yes` present or not |
| 6 | Neutralise `user-data` and `network-config` | content read back after writing |

### Why steps 2 and 3 are needed at all

Nothing in cloud-init or netplan's NetworkManager backend turns the radio on:

- netplan's `regulatory-domain` key is rendered **only by the networkd
  backend**, and this image uses NetworkManager;
- with `WPA_COUNTRY` unset at build time, upstream `stage2/02-net-tweaks`
  writes `NetworkManager.state` with `WirelessEnabled=false` and leaves the
  wlan rfkill soft-blocked.

So a perfectly rendered Wi-Fi keyfile never associates. That is the defect
design (a) has to close, and it can only be closed on the machine.

### Why step 4 is needed — the part that is not obvious

cloud-init 25.2, `distros/__init__.py:894-907`: for a **pre-existing** user the
`passwd` key in user-data is **ignored**; only `plain_text_passwd` and
`hashed_passwd` are honoured. Imager writes `passwd`. `default` already exists
(`stage-elspi/05-service-user`), so the password the operator typed is silently
discarded.

And then the same function **unlocks the account anyway**. `passwd -l` prefixes
`!` to the *existing* hash and leaves the rest — `shadow(5)`: "The remaining
characters on the line represent the password field before the password was
locked" — so `default`'s field is `!<build throwaway hash>`, not `!`.
cloud-init's empty-locked patterns (`distros/__init__.py:139`) are
`^{username}::` and `^{username}:!:`, and neither matches. So
`has_existing_password` is True at line 912, `lock_passwd: false` takes the
branch at line 927, and line 940 calls `unlock_passwd()` — making the random
`FIRST_USER_PASS` throwaway from `elspi.conf` a **live password that nobody
knows**.

Step 4 closes both halves, deciding which applies from the seed itself:

- `passwd` present → install it with `chpasswd -e` (this also overwrites the
  throwaway), after checking it is a `crypt(3)` hash and that it differs from
  what is already there;
- `hashed_passwd`/`plain_text_passwd` present → cloud-init already did it
  (`distros/__init__.py:876-892`); say so and do nothing;
- neither, but `lock_passwd: false` → revoke the unlocked throwaway with
  `usermod -p '!'`, restoring the image's declared locked state.

### Why the seed is overwritten and not deleted

Three reasons, in order of weight:

1. **On FAT, unlinking does not remove the bytes.** Deleting `user-data` frees
   its clusters and leaves the hash in unallocated sectors for anyone with a
   card reader. Writing a shorter file over it replaces the first cluster's
   contents in place. Neither is a secure erase — but only one of them actually
   overwrites the secret.
2. **The files are expected to exist.** `stage2/04-cloud-init/README.txt`
   records that `network-config` and `user-data` must be present or "imager
   would fail to create the correct filesystem entry", and an absent
   `user-data` makes the NoCloud datasource behave differently from an empty
   one.
3. **It is auditable.** A neutralised seed tells an operator who pulls the card
   that this ran. An absent file is indistinguishable from a seed that was
   never written — exactly the ambiguity you do not want when the question is
   "did my credentials come off this card?".

`meta-data` is left **intact**: it carries the instance-id, and cloud-init
compares that against its cached copy to decide whether this is a new instance.
Blanking it would make every boot look like a first boot and re-run
per-instance modules against an already-provisioned lathe.

The replacement contents are valid documents, not empty files — `#cloud-config`
is a well-formed empty cloud-config, and `network: {version: 2}` is the minimal
valid netplan document. Both say "nothing configured here" rather than "this
file is broken".

## What this substage does *not* do

- It does not revert `PasswordAuthentication yes` if the operator ticked
  Imager's password-SSH option. That was an explicit choice on the
  customisation page; the unit **warns** in the journal and leaves it.
  `FLASH-SESSION.md` says which box to tick.
- It does not set the hostname, create users, install keys, or configure
  Wi-Fi. cloud-init does all of that from the seed. This substage only fixes
  what cloud-init cannot do on this image and then cleans up.
- It has **never run on real hardware.** Everything above is derived from
  cloud-init 25.2 source and upstream's stage scripts, and verified only by the
  offline harness. See `VERIFICATION.md`'s tiers — this is a Tier 3 item until
  a card boots.
