# `12-first-boot-seed` — Imager's customisation page as the supported seed

**Design (a), ratified by Evan 2026-09-12.** Raspberry Pi Imager 2.x's
OS-customisation page is the supported way to seed this image at flash time,
and this substage ships what the fork needs for that to actually work.

Nothing here puts a credential in the repo or in the image. The operator types
the password, the public key and the Wi-Fi SSID/PSK into Imager; Imager writes
them to the FAT partition; cloud-init consumes them on first boot; this
substage's unit then takes them off the card. See `docs/design/seam.md` and
`FLASH-SESSION.md`.

**Imager only shows that page for an OS-list entry, never for a local file.**
2.x calls `setSrc(fileUrl)` with an empty `initFormat` for "Use custom"
(`src/wizard/OSSelectionStep.qml`, `src/imagewriter.h`), so
`imageSupportsCustomization()` is false and the wizard skips every
customisation step — silently. The page appears only for an entry declaring
`init_format: cloudinit-rpi` in a repository passed as `rpi-imager --repo`,
which is why `tools/make-os-list.sh` writes `deploy/os_list.json` as part of
the build and `tools/flash-elspi.ps1` / `tools/flash-elspi.sh` are the
documented way to start a flash. **Pick the image by hand and this whole
substage runs against an empty seed**: no password to install, no country to
apply, nothing to wipe. `FLASH-SESSION.md` has the procedure.

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
   surface forever (`docs/design/fork.md`). The anchor is asserted before the `sed` and
   re-grepped after, in both directions: the hyphen must be present *and* the
   underscore must be gone, because a file carrying both keys is ambiguous.

2. **Installs and enables the oneshot unit.** Enablement is a direct
   `cloud-init.target.wants` symlink — exactly what `systemctl enable` produces
   for a unit declaring `WantedBy=cloud-init.target` — which is what keeps the
   substage chroot-free. The symlink is then checked for existence *and for
   resolving*, since a dangling enablement symlink looks enabled to `ls` and is
   silently ignored by systemd. Two further gates assert the unit is **not**
   enabled in `multi-user.target.wants` and does **not** declare
   `WantedBy=multi-user.target`: that combination is an ordering cycle that
   stops the unit running at all. See the 2026-09-13 finding below.

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
- It has **never run on real hardware.** A card *has* now booted — 2026-09-13,
  `image_2026-09-13-elspi` — but the unit's job was deleted by systemd before
  it started, so not one of the six steps has ever executed. Everything above
  is still derived from cloud-init 25.2 source and upstream's stage scripts and
  verified only by the offline harness. See `docs/design/verification.md`'s tiers — this
  remains a Tier 3 item until a card boots *and the unit runs*.

## 2026-09-13 — first boot on hardware: the unit never started

**The seed did not run.** `image_2026-09-13-elspi`, first boot on the real Pi.
No failed unit, no error, nothing in the journal from our script, and
`ExecMainStartTimestamp` empty. systemd had deleted the job before it started:

```
cloud-final.service: Found ordering cycle on multi-user.target/start
Job elspi-first-boot-seed.service/start deleted to break ordering cycle
  starting with cloud-final.service/start
```

### Why

The unit shipped `[Install] WantedBy=multi-user.target` together with
`After=cloud-init.service cloud-config.service cloud-final.service`. On this
image:

| unit | ordering | pulled in by |
|---|---|---|
| `elspi-first-boot-seed.service` | `After=cloud-final.service` | `multi-user.target` |
| `cloud-final.service` | `After=multi-user.target` | `cloud-init.target` |
| `cloud-init.target` | `After=cloud-config.service multi-user.target cloud-final.service` | — |

So `multi-user.target` wanted us, we waited for `cloud-final.service`, and
`cloud-final.service` waited for `multi-user.target`. A cycle has no correct
resolution, and systemd's resolution is to **delete a job** — it deleted ours.

### What that cost, measured on the card afterwards

- The **radio was not turned on by us.** It came up anyway, because
  cloud-init's `runcmd` from Imager happened to bring it up. That is luck, not
  design, and it is exactly the kind of coincidence that makes a defect look
  like a working feature.
- The **regulatory domain came from the cmdline**, not from the seed.
- The **password step never ran** — so the `cc_users_groups` unlock described
  above stands, with the build throwaway live.
- The **seed was still on the card**: `user-data` still carrying `passwd:` and
  `network-config` still carrying `password:`, on the unencrypted FAT
  partition. Step 6 is the whole security argument of design (a) and it did not
  happen.

Every other offline check was green on this image. The unit was installed,
executable, `-` prefixed, `After=cloud-final.service`, and enabled by a symlink
that resolved. The harness was measuring an image that did nothing.

### Why `cloud-init.target` is the right anchor

Because it is the target that **means "cloud-init is done"**, and it is the
only one of the two that does not also mean "cloud-init has not started yet".
`cloud-final.service` is `WantedBy=cloud-init.target`, and the target is
ordered *after* `cloud-final.service`, so:

- being **wanted by** `cloud-init.target` is a pull with no ordering edge of
  its own, so it adds nothing that can cycle;
- our one remaining ordering edge, `After=cloud-final.service`, points the same
  direction the target already points.

A unit that must run after cloud-init has finished belongs in the target
cloud-init *completes*, not in the target cloud-init *waits for*. The redundant
`After=cloud-init.service cloud-config.service` was dropped at the same time:
`cloud-final.service` is already ordered after both, and every extra edge named
here is another constraint to satisfy against a target we are now pulled in
from — the same class of thing that caused this.

### The tests that now catch it

`tests/verify-image.sh` asserts `cloud-init.target` in both the symlink and the
`WantedBy=`, and adds two **negative** assertions: no symlink under
`multi-user.target.wants` for this unit, and no `WantedBy=multi-user.target` in
the unit (which a later `systemctl reenable` would act on). The general rule
they encode: *this unit must not be wanted by any target that
`cloud-final.service` is ordered `After=`.* `tests/self-test.sh` mutates both
halves of the shipped cycle back in, one at a time, so each assertion is proven
able to fail. `tests/dry-run-stages.sh` checks the same two things against the
tree the **real** substage writes, because the fixture and the harness could
otherwise agree with each other and both disagree with `00-run.sh`.
