# Flashing a card

Start to finish: a blank SD card, one command, and a Pi that boots straight
into the lathe UI. No checkout, nothing downloaded by hand, no SSH needed.

This page is honest about where it stops. A freshly flashed card comes up
**UNCOMMISSIONED**: the application is running on its own defaults, says so on
the home screen, and saves nothing until this lathe's commissioned settings are
restored or measured. [After first boot](#after-first-boot) says how to get
from there to a machine you can trust.

## Requirements

**Raspberry Pi Imager 2.x, from
[raspberrypi.com/software](https://www.raspberrypi.com/software/).** Not your
distribution's package.

!!! warning "Imager 1.x looks like it works and does not"
    1.x accepts `--repo`, so nothing complains — but its customisation page
    seeds a card through `firstrun.sh` / `userconf.txt`, and **this image never
    reads those files**. You would get a card with no password, no key, no
    Wi-Fi and no country, and no error to tell you. If you flash from a
    checkout the launchers (`tools/flash-elspi.ps1`, `tools/flash-elspi.sh`)
    refuse anything older than 2.0 outright; flashing straight from a release
    URL, as below, has nothing to check the version for you. Verify it:
    Imager's window title, or `rpi-imager --version`.

**A 16 GB or larger SD card.** The decompressed image is about 7.5 GB; 16 GB is
the smallest sensible card and leaves room for the application, the venv and
logs.

**The target machine:** a Raspberry Pi 5 with the touchscreen attached. The
image is `armhf` userland on a 64-bit kernel, with `config.txt` written for that
board — including upstream's `[pi5] dtoverlay=nospi10`. The public image leaves
`usb_max_current_enable` off; a Pi 5 powering a USB touchscreen may need it, and
a [site build config](provisioning.md#a-site-build-config) turns it on.

**Keep the card that is currently in the machine.** It is the rollback and it is
the running lathe. Flash a *second* card.

## Flash

**Windows**, from Win+R, or a cmd or PowerShell prompt — the same line works in
all three:

```
cmd /c start rpi-imager --repo https://github.com/Funkenjaeger/elspi/releases/latest/download/os_list.json
```

**Linux**:

```
rpi-imager --repo https://github.com/Funkenjaeger/elspi/releases/latest/download/os_list.json
```

??? info "Why `cmd /c start`, and why `latest/download`"
    The Windows installer registers `rpi-imager.exe` under App Paths, which
    `start` and the Run dialog resolve; a cmd or PowerShell prompt looks up
    bare commands on `PATH` only. The `cmd /c start` prefix is what makes one
    line work everywhere.

    `releases/latest/download/<asset>` is GitHub's stable redirect to the
    newest release's asset — it is not a fixed URL, and it moves when a new
    release is tagged. Imager follows redirects on both fetches this needs: the
    `--repo` list, and the image URL that list contains. (Measured in the
    rpi-imager source 2026-09-13: `CURLOPT_FOLLOWLOCATION` is set for the image
    download, and the OS-list fetcher tracks an `effectiveUrl` through its own
    redirect chain.) A specific release's page carries the same two commands
    pinned to its own tag instead of `latest`, which is what you want if you
    are reproducing a known-good pair.

!!! info "Publishing a build: `OS_LIST_URL`"
    `os_list.json` carries a `url` field pointing at the image, and
    `build-elspi.sh` has no way to know in advance where a given build will end
    up being served from — so by default it writes a `file://` URL for the
    image's path on the machine that built it. That is fine for a `--repo`
    flash from that same machine, and useless anywhere else: `rpi-imager` on
    another machine cannot open a `file://` path from a box it isn't running
    on, and fails with something like "not found: /the/build/machine/path".

    Before publishing a release, re-run the build with `OS_LIST_URL` set to the
    URL the JSON's `url` field should actually contain — the shape GitHub gives
    a release asset:

    ```
    OS_LIST_URL=https://github.com/Funkenjaeger/elspi/releases/download/<tag>/image_<date>-elspi.img.xz ./build-elspi.sh
    ```

    (Note: that is the image's own URL -- the one Imager downloads once it
    reads the `url` field inside `os_list.json` -- not `os_list.json`'s own
    address, which is what `--repo` above points at.) Leave it unset for
    a local-only build-and-flash — `build-elspi.sh` prints a WARNING naming the
    `file://` URL it wrote and which machine it is only good on, so a build
    headed for a release does not get published by accident with the wrong
    `url` field.

### What Imager shows

1. **One OS entry** — this image, from the repository you passed. There is no
   list to scroll and no Raspberry Pi OS menu; if you see the normal Imager
   catalogue, the `--repo` argument did not take.
2. **Device** and **Storage** — pick the Pi 5 and pick the card. On Windows
   Imager raises a UAC prompt here: it writes raw disks and asks for
   administrator rights itself.
3. **The OS customisation page.** This is the part that matters, and it is the
   *only* supported way to seed this image.

!!! danger "Do not use Imager's “Use custom” to pick a downloaded `.img.xz`"
    Imager 2.x never offers the customisation page for a local file and does not
    say so — `imageSupportsCustomization()` is false for a file URL, so the
    wizard silently skips every customisation step. The flash succeeds and you
    get a card with **no password, no key, no Wi-Fi and no country** — and
    because the image carries no SSH key of its own, **no SSH way in at all**:
    the touchscreen is the only access to that card. The only
    visible difference is a wizard with two fewer pages. The page appears only
    for an entry in an OS-list repository declaring
    `init_format: cloudinit-rpi`, which is what `os_list.json` is for.

### Fill in the customisation page

Every field below becomes something specific on the machine. Imager writes them
to the card's FAT partition as cloud-init NoCloud files; cloud-init consumes
them on first boot; and the image's own seed unit then finishes the job and
overwrites the files.

| Field | Value | What it becomes |
|---|---|---|
| Hostname | `elspi`, or a name of your own | the machine's hostname. The image's built-in `elspi` (`TARGET_HOSTNAME`) is only a default: whatever you type here replaces it on first boot, and `ssh default@<that name>` then works on a network with mDNS |
| Time zone / keyboard layout | yours | cloud-init sets both on first boot. An unseeded card keeps the image defaults: `Etc/UTC` and a US layout |
| Username | **`default` — exactly** | nothing: the account already exists in the image. See below |
| Password | pick one and write it down | the `default` account's password, and therefore the `sudo` password — and, with password SSH, your SSH login. The account ships **locked**; this is what unlocks it |
| SSH | **enable**; then allow password authentication, *or* paste a key and optionally choose **“Allow public-key authentication only”** | how `sshd` authenticates on this card. The image sets nothing here itself. See below |
| Public key | *optional:* your workstation's `id_ed25519.pub` | `~default/.ssh/authorized_keys`, installed by the image's seed unit. The image ships **no key of its own** |
| Wi-Fi SSID / password | the shop network | a NetworkManager keyfile |
| Wireless LAN country | **yours** (`US`, `GB`, `DE`, …) | the regulatory domain. Without it the radio stays off — see below |

Imager has no field for the system **locale**: its cloud-init output carries
no `locale:` key, so every card keeps the image's `en_US.UTF-8`. The
application formats nothing through the locale; it affects only shell tools
over SSH. A build of your own can set `LOCALE_DEFAULT` (see
[the site build config](provisioning.md#a-site-build-config)).

**The username must be `default`.** That is the image's service user: the
account that owns `/var/lib/reflex-config`, `/var/log/reflex` and `~/projects`,
and the account `reflex-ui.service` and the DRM drop-in name. Type anything else
and Imager creates a *second*, unrelated account — the lathe's own account stays
locked, the new one owns nothing the application needs, and every path in the
delta layer points at the wrong home directory.

**Set a password, a public key, or both — not neither.** The image is
*keyless*: it is built from a public repository into public release images, so
no SSH key is baked into it, and the `default` account ships locked. Whatever
you type on this page is therefore the only way in over SSH:

- **A password** is enough on its own. Leave password authentication allowed
  and `ssh default@elspi` asks for it. This is the easy path if you do not
  already use SSH keys.
- **A public key** is enough on its own too, and you may then choose
  **“Allow public-key authentication only”** so the card refuses passwords over
  SSH. The password, if you set one, still works at the console and for `sudo`.
- **Neither** leaves a card reachable **only from the touchscreen**. The seed
  unit says so in the journal (`NO SSH WAY IN`), but by then you are standing
  at the machine: re-flash instead.

**The SSH choice is yours, per card, and the image does not second-guess it.**
Imager writes it as `ssh_pwauth: true` or `false`; cloud-init turns that into
`PasswordAuthentication yes` or `no` in `/etc/ssh/sshd_config.d/50-cloud-init.conf`.
The image sets no authentication option anywhere that could override it, and
the seed unit only *reports* which one you picked.

**The country is not cosmetic.** netplan's `regulatory-domain` key is rendered
only by the *networkd* backend and this image uses NetworkManager, so nothing in
cloud-init applies it. The seed unit reads it back out of the card and applies it
itself — but only if you set it.

Write the card. When Imager reports success, eject it.

**Verify before you walk to the machine:** the card should mount as a `bootfs`
FAT partition containing `user-data`, `network-config` and `meta-data`. If
`user-data` is missing or does not mention your username, the customisation page
did not run and the first boot will seed nothing.

## First boot

Put the card in the Pi and power it. Allow about **3 minutes**, and up to 5
before worrying — cloud-init does real work on a first boot, the seed unit runs
after it, and the first-boot UI unit runs after that.

During that time the image's oneshot unit
(`elspi-first-boot-seed.service`, ordered after `cloud-final.service` and
enabled in `cloud-init.target`) does the five things cloud-init cannot do here
(or cannot be trusted to):

1. **Turns the Wi-Fi radio on.** The base image ships
   `NetworkManager.state` with `WirelessEnabled=false` and the wlan rfkill
   soft-blocked, so a perfectly rendered Wi-Fi keyfile would never associate.
2. **Applies the regulatory domain** you typed as the country.
3. **Installs the password you typed.** cloud-init ignores Imager's `passwd`
   key for an account that already exists, so the unit installs your hash
   itself. The account ships locked with a bare `!` — no password hash of any
   kind is in the image — so if you left the password blank it simply stays
   locked. (Images built before 2026-09-23 locked it differently, and
   cloud-init unlocked a random build-time throwaway; the unit still revokes
   that on such a card.)
4. **Installs your SSH keys**, each exactly once, into
   `~default/.ssh/authorized_keys`, and logs their fingerprints. If the page
   carried neither a password nor a key it logs `NO SSH WAY IN` instead.
5. **Takes the credentials off the card.** `user-data` is overwritten with a
   bare `#cloud-config` and `network-config` with `network: {version: 2}`.
   `meta-data` is left intact: it carries the instance-id, and blanking it would
   make every subsequent boot look like a first boot. The FAT partition is
   unencrypted and readable by any machine with a card slot, so the password
   hash and the Wi-Fi PSK do not stay there.

Then the image's second first-boot unit, `elspi-first-boot-ui.service`
(ordered after the seed unit and after Plymouth has let go of the display),
does the rest **once**:

1. **Checks the baked application for its commissioning guard** — the
   UNCOMMISSIONED state described below. A release without it is never started
   unattended.
2. **Runs phase 1 of the [delta layer](provisioning.md), converge,** against the
   reflex checkout baked into the image, from the image's own copy of the
   scripts at `/usr/local/lib/elspi/deltas`. **Offline**: the image build
   already installed the application and proved that no download is needed, so
   a card with no Wi-Fi boots into the UI exactly like one with it.
3. **Starts `reflex-ui`.** Converge enabled it, so every later boot starts it
   too, without this unit doing anything.

It never restores anything and never writes the machine's settings.

### What the touchscreen shows

In order:

1. **The Plymouth splash** while the system boots.
2. **A black screen, for up to about a minute,** while converge runs. Normal on
   the first boot only.
3. **The lathe UI, with an amber UNCOMMISSIONED strip across the top of the
   home screen:** *UNCOMMISSIONED — defaults, not this machine — settings are
   not saved*, and *Tap for options* at its right-hand end. That strip is the
   correct end state of a first boot. It is the application saying that
   `/var/lib/reflex-config` holds nothing measured off this lathe, that every
   number on screen is a built-in default, and that it is **saving nothing**
   until a backup is restored or you deliberately dismiss the warning to
   commission by hand. **Do not cut with the machine in this state.**

Every later boot is the splash and then the UI, with the strip for as long as
the machine stays uncommissioned.

**Nothing on the screen after 5 minutes** is not the expected result any more
— see [Troubleshooting](#troubleshooting).

### Confirm it is up

The UI on the screen is the test. SSH is optional now, and still worth doing
once — from the workstation whose public key you gave Imager, or with the
password you set there:

```sh
ssh default@elspi
```

That succeeding is the whole test of this page: the hostname resolved, the
network came up, the account exists and your key or password was installed.
Then confirm the
seed unit actually ran:

```sh
journalctl -u elspi-first-boot-seed --no-pager
```

Look for the single summary line — `verdict=OK steps_done=[...] warnings=N` —
and read the `WARNING:` lines if `warnings` is not `0`. A `verdict=DEFERRED`
means cloud-init had not finished and **nothing** was done, including the
credential wipe. While you are there, confirm the seed really is gone:

```sh
sudo head -1 /boot/firmware/user-data     # expect: #cloud-config
```

And the first-boot UI unit's own summary line:

```sh
journalctl -u elspi-first-boot-ui --no-pager | grep verdict=
```

`verdict=STARTED` is the good answer. Every other verdict names why the UI was
not started; they are listed under [Troubleshooting](#troubleshooting).

## After first boot

The card is a working appliance running the lathe UI on **defaults**. The
application, the runtime and your credentials are in place. What it does not
have is anything measured off *this* lathe: axis geometry, servo polarity,
backlash calibration, Z scale counts/mm. Until it does, the UNCOMMISSIONED strip
stays and nothing is saved.

**Pick one of these — they are alternatives, not steps:**

- **You have a backup of this lathe's settings** (a USB export or a gist from
  the reflex Setup screen). Restore it from the touchscreen: **Setup → Backup →
  Import from USB** (or *Restore from gist*), then **restart the machine** — the
  restored settings are read at startup, and the strip does not come back. No
  SSH, no command line. This is the route for recovering a lathe whose old card
  died. (*Tap for options* on the strip says the same.)
- **You have a capture on a workstation and prefer the command line.** Carry it
  to the Pi and run phase 2 from the delta layer the image carries:

    ```sh
    sudo /usr/local/lib/elspi/deltas/provision.sh \
        --app /home/default/projects/reflex \
        --config-backup /path/to/reflex-config-capture
    ```

    It stops the running UI before it restores, prints the values it put in
    place, and leaves the UI stopped so you can check them before
    `sudo systemctl start reflex-ui`. Full detail on
    [Provisioning](provisioning.md).
- **This lathe has never been commissioned.** *Tap for options* on the strip,
  then **Dismiss** — deliberately: from that moment everything you save is
  recorded as this machine's baseline — and measure and enter everything in the
  order the reflex Setup screen gives. Until you dismiss, nothing you change is
  saved. (`provision.sh --fresh` names this same choice from the command line;
  on a card that booted into the UI it has nothing left to do and says so.)

**Independently of which you picked:**

- **A brand-new controller board** has OEM firmware and no field bootloader. It
  needs one session with an ST-Link before the UI can talk to it — see
  [First load (SWD)](swd-first-load.md). The toolchain is already on the card.
- **The optional interactive phase** (the dev-role question, and any credential
  you did not give Imager) is phase 3 of the delta layer and needs a terminal:
  `sudo /usr/local/lib/elspi/deltas/03-interactive.sh --app /home/default/projects/reflex`.
- **Site hooks** (one estate's own steps, kept outside this repository) run
  from `provision.sh --site-hooks` — see [Provisioning](provisioning.md#site-hooks).

## Troubleshooting

**Imager says “Source file not found”, or shows its normal OS catalogue instead
of one entry.** The `--repo` URL is wrong, or the release it points at has no
`os_list.json` asset. Open the URL in a browser: it must return JSON, not a
GitHub 404 page. Check the release you are aiming at actually carries
`os_list.json` beside the image.

**Imager flashes successfully but never showed a customisation page.** Either
you are on 1.x, or you picked the image with “Use custom”. Both produce a card
with no seed at all. Re-flash using the `--repo` command above with Imager 2.x.

**`ssh default@elspi` says the host key changed**, with
`REMOTE HOST IDENTIFICATION HAS CHANGED`. Expected after a card swap: the new
card generated new host keys. Drop the old entry and reconnect:

```sh
ssh-keygen -R elspi
ssh default@elspi
```

**`ssh: Could not resolve hostname elspi`.** mDNS is not resolving. Find the
address on your router or with `nmap -sn`, and connect by IP:
`ssh default@<address>`. The hostname itself is set — this is a name-resolution
problem on the workstation's side, not a problem with the card.

**SSH refuses your key and asks for a password.** The public key did not reach
the card. The image has no key of its own to fall back on. If you also set a
password and left password authentication allowed, log in with it and read
`journalctl -u elspi-first-boot-seed` for the key lines; otherwise re-flash —
there is no way to fix `authorized_keys` from outside.

**SSH says `Permission denied (publickey)` and never asks for a password.**
You chose “Allow public-key authentication only” on Imager's page, so the card
refuses SSH passwords by design. Use the key you pasted there, or re-flash and
allow password authentication.

**The screen stays black after 5 minutes, but SSH answers.** The first-boot UI
unit says why in one line:
`journalctl -u elspi-first-boot-ui --no-pager | grep verdict=`

| verdict | meaning | what to do |
|---|---|---|
| `STARTED` or `START_UNCONFIRMED` | the UI was started; the display is the problem | the [DRM ladder](provisioning.md#if-the-screen-stays-black-the-drm-ladder), Plymouth first; `journalctl -u reflex-ui -b` |
| `CONVERGE_FAILED` | converge refused or failed; the `converge:` lines above the verdict say which check | fix what it names, then reboot — the unit retries on every boot until it succeeds |
| `REFUSED_NO_GUARD` | the baked release predates reflex's commissioning guard, so it was deliberately **not** started | an image from a build that baked an older release; provision by hand ([Provisioning](provisioning.md)) or use a newer image |
| `ALREADY_PROVISIONED` | `reflex-ui` was already enabled before first boot got to it | nothing: systemd starts it; read `journalctl -u reflex-ui -b` |
| `NOOP` / `UNKNOWN` | an image built before the app was baked in, or one missing a piece | provision by hand |

**The screen stays black and SSH does not answer either.** That is a boot
failure rather than the expected black screen. Attach a keyboard and check the
console; the serial console is deliberately *off* on `/dev/ttyAMA0`, because
that UART carries Modbus to the motion controller.
