#!/bin/bash
#
# elspi-first-boot-seed -- make Raspberry Pi Imager 2.x's OS-customisation page
# actually work on this image, then take the credentials off the SD card.
#
# Installed by stage-elspi/12-first-boot-seed. Runs on EVERY boot from
# elspi-first-boot-seed.service, ordered after cloud-final.service.
#
# ---------------------------------------------------------------------------
# CONTRACT
# ---------------------------------------------------------------------------
#   * IT NEVER FAILS THE BOOT. elspi has no terminal and no serial console;
#     a non-zero exit here would cost a lathe power cycle. Hence no `set -e`,
#     every step contained, and `exit 0` by construction.
#   * IT NEVER PRINTS A SECRET. The password hash and the Wi-Fi PSK pass
#     through this script. They are referred to by KIND and by the FILE they
#     came from, never by value. There is no `set -x` and there must never be.
#   * IT IS IDEMPOTENT. Every step is a no-op on the second and later boots.
#   * EVERY STEP GATES ON A SIGNAL THAT COULD HAVE COME OUT DIFFERENTLY, and
#     says so. Printing a value is not gating on it.
#
# ---------------------------------------------------------------------------
# WHY EACH STEP EXISTS -- measured against cloud-init 25.2, not assumed
# ---------------------------------------------------------------------------
# 1. THE RADIO. netplan's `regulatory-domain` key is rendered only by the
#    networkd backend; this image uses NetworkManager. And with WPA_COUNTRY
#    unset at build time, upstream stage2/02-net-tweaks writes
#    /var/lib/NetworkManager/NetworkManager.state with WirelessEnabled=false
#    and leaves the wlan rfkill soft-blocked. Nothing in cloud-init or netplan
#    undoes either. So a correctly rendered Wi-Fi keyfile never associates.
#
# 2. THE PASSWORD. cloud-init 25.2 distros/__init__.py:894-907: for a
#    PRE-EXISTING user, the `passwd` key in user-data is IGNORED -- only
#    `plain_text_passwd` and `hashed_passwd` are honoured. Imager writes
#    `passwd`. The `default` account already exists (stage-elspi/05-service-user
#    creates it and locks it), so the password the operator typed into Imager
#    is silently discarded. This script applies it instead (step 4).
#
#    THE UNLOCK HOLE, AND WHY THE IMAGE NO LONGER HAS IT. Until 2026-09-23
#    05-service-user locked the account with `passwd -l`, which prefixes '!' to
#    the existing hash -- shadow(5): "The remaining characters on the line
#    represent the password field before the password was locked" -- so the
#    field was `!<build throwaway hash>`. cloud-init's empty-locked patterns
#    (distros/__init__.py:139) are `^{username}::` and `^{username}:!:`, and
#    neither matched: has_existing_password became True (line 912),
#    `lock_passwd: false` took the branch at line 927, and line 940 called
#    unlock_passwd() -- making the random FIRST_USER_PASS throwaway a LIVE
#    password that nobody knows.
#
#    05-service-user now writes a BARE '!' (`usermod -p '!'`). `^default:!:`
#    matches, has_existing_password is False, and with Imager's ignored
#    `passwd` there is no ud_password_specified either -- so cloud-init takes
#    the "Not unlocking blank password for existing user" branch (lines
#    941-953) and never calls unlock_passwd(). Had it called it, `passwd -u`
#    would have refused anyway: shadow 4.17.4 src/passwd.c:522-528 exits
#    E_FAILURE with "unlocking the password would result in a passwordless
#    account" when the field is exactly '!'.
#
#    ONE PATH STILL ENDS IN AN EMPTY FIELD, and it is not Imager's. A
#    hand-written seed carrying an EMPTY `hashed_passwd`/`plain_text_passwd`
#    with `lock_passwd: false` is ud_password_specified, so cloud-init DOES call
#    unlock_passwd(); `passwd -u` refuses the bare '!' with exit 3, which
#    cloud-init accepts (rcs=[0, 3], line 1055), and because stderr is not
#    empty it falls back to `passwd -d` (lines 1059-1064) -- a BLANK password.
#    Step 4 treats an empty field as the hole it is and re-locks it.
#
#    This script therefore: applies the operator's hash when the seed carries
#    one; and otherwise, if the seed asked for an unlock, makes sure the field
#    is back to the image's declared bare '!' -- whether cloud-init left it
#    empty, or (on an image built before 2026-09-23) unlocked a throwaway.
#
# 3. THE SSH KEYS. The image is KEYLESS (2026-09-23): no public key is baked
#    in at build time, because this repo and its release images are public and
#    nobody's personal key belongs in them. The keys the operator typed into
#    Imager's customisation page are the ONLY keys a fresh card carries.
#    cloud-init 25.2 does import `ssh_authorized_keys` for a pre-existing user
#    (distros/__init__.py create_user, after add_user returns early) -- but
#    this image already learned once that "cloud-init handles it" was wrong
#    for this very account (item 2), so this script installs the seed's keys
#    ITSELF, before the seed is wiped, and deduplicates against whatever
#    cloud-init already wrote. Keys are OPTIONAL: a password alone is a way in.
#    A seed carrying NEITHER is reported loudly, because that card is
#    reachable only from the touchscreen.
#
#    SSH AUTHENTICATION POLICY IS THE OPERATOR'S, NOT THIS IMAGE'S. Imager's
#    "public-key only" choice becomes `ssh_pwauth: false`, which cloud-init
#    writes as PasswordAuthentication no in sshd_config.d/50-cloud-init.conf;
#    its password choice becomes `yes` there. This script REPORTS which, and
#    warns if any other file could override it. It never changes it.
#
# 4. THE SEED. user-data carries a password hash and network-config carries a
#    derived 64-hex PSK, on an unencrypted FAT partition readable by any
#    machine with a card slot. Once cloud-init has consumed them they are pure
#    liability.
#
# ---------------------------------------------------------------------------
# WHY OVERWRITE THE SEED RATHER THAN DELETE IT
# ---------------------------------------------------------------------------
# Overwriting is both safer and more honest here:
#
#   * ON FAT, UNLINKING DOES NOT REMOVE THE BYTES. Deleting user-data frees its
#     clusters and leaves the hash sitting in unallocated sectors for anyone
#     with a card reader. Writing a shorter file over it replaces the first
#     cluster's contents in place. Neither is a secure erase, but only one of
#     them actually overwrites the secret.
#   * THE FILES ARE EXPECTED TO EXIST. stage2/04-cloud-init/README.txt records
#     that network-config and user-data must be present or "imager would fail
#     to create the correct filesystem entry". A missing user-data also makes
#     the NoCloud datasource behave differently from an empty one.
#   * IT IS AUDITABLE. An operator who pulls the card can see a neutralised
#     seed and know this ran. An absent file is indistinguishable from a seed
#     that was never written -- exactly the ambiguity you do not want when
#     asking "did my credentials come off this card?".
#
# meta-data is deliberately LEFT ALONE: it carries the instance-id, and
# cloud-init compares that against its cached copy to decide whether this is a
# new instance. Blanking it would make every boot look like a first boot and
# re-run per-instance modules against an already-provisioned lathe.

# NO `set -e`: an early abort would skip the neutralisation step and leave the
# PSK on the card. NO `set -u` either -- an unbound variable must not be able
# to do that. Everything below is explicitly initialised instead.
# NO `set -x`, ever: this script handles a password hash.

# ELSPI_SEED_TEST_ROOT is FOR tests/test-first-boot-seed.sh ONLY. It prefixes
# every path this script reads or writes, so the offline harness can run the
# REAL script against a synthetic rootfs instead of a copy of its logic. The
# unit never sets it, so on the machine every path below is the real one.
R="${ELSPI_SEED_TEST_ROOT:-}"

BOOTDIR="${R}/boot/firmware"
UD="${BOOTDIR}/user-data"
NC="${BOOTDIR}/network-config"
MD="${BOOTDIR}/meta-data"
SHADOW="${R}/etc/shadow"
PASSWD_DB="${R}/etc/passwd"
MANIFEST="${R}/etc/elspi-image.json"
SSHD_CONFIG="${R}/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="${R}/etc/ssh/sshd_config.d"
CLOUD_DONE="${R}/var/lib/cloud/instance/boot-finished"
NM_STATE="${R}/var/lib/NetworkManager/NetworkManager.state"

# What a neutralised user-data holds (step 7). Named once, because step 5 has
# to recognise it too: a seed that already came off the card is a different
# answer from a seed that carried no credential.
UD_NEUTRAL='#cloud-config'

# Verdict accumulators. Printed as one line at the end so the journal has a
# single greppable summary as well as the step-by-step detail.
STEPS_DONE=""
WARN_COUNT=0

log()  { printf 'elspi-seed: %s\n' "$*"; }
warn() { printf 'elspi-seed: WARNING: %s\n' "$*"; WARN_COUNT=$((WARN_COUNT + 1)); }
did()  { STEPS_DONE="${STEPS_DONE} $1"; }

log "starting (pid $$)"

# ===========================================================================
# GATE 0: has cloud-init actually finished?
# ===========================================================================
# This is the gate that makes everything below safe. If cloud-init has not run,
# the seed has not been consumed, and neutralising it would destroy the
# operator's hostname, key, password and Wi-Fi before anything used them -- on
# a machine with no terminal to notice.
#
# /var/lib/cloud/instance/boot-finished is cloud-init's own end-of-run marker.
# Its absence is a real, different outcome: DEFER and change nothing.
if [ ! -e "${CLOUD_DONE}" ]; then
	log "cloud-init end marker ${CLOUD_DONE} is ABSENT."
	log "The seed has not been consumed yet, so nothing here is safe to do."
	log "verdict=DEFERRED steps_done=none"
	exit 0
fi
log "gate ok: cloud-init reports boot-finished"

# ===========================================================================
# STEP 1: is there a Wi-Fi connection profile at all?
# ===========================================================================
# netplan's NetworkManager backend renders keyfiles into /run/... on this
# distro, while a hand-written or nmcli-created profile lands in /etc/...
# Both are checked: looking only where the design document said would report
# "no wifi seeded" on a machine that has one, and then skip turning the radio
# on -- a check that fails in the direction of doing nothing.
#
# The keyfiles contain the PSK. They are searched with grep -l/-q ONLY; no
# content from them is ever printed.
WIFI_KEYFILE_DIR=""
for d in "${R}/etc/NetworkManager/system-connections" \
         "${R}/run/NetworkManager/system-connections"; do
	[ -d "${d}" ] || continue
	if grep -rlq '^type=wifi' "${d}" 2>/dev/null; then
		WIFI_KEYFILE_DIR="${d}"
		break
	fi
done

if [ -n "${WIFI_KEYFILE_DIR}" ]; then
	log "wifi profile present in ${WIFI_KEYFILE_DIR} (contents not logged)"
else
	log "no wifi profile found in /etc or /run NetworkManager/system-connections"
fi

# ===========================================================================
# STEP 2: unblock and enable the radio -- only if there is a profile to use
# ===========================================================================
if [ -n "${WIFI_KEYFILE_DIR}" ]; then

	# --- rfkill ---------------------------------------------------------
	# GATE: count the blocked wlan lines before and after. `rfkill unblock`
	# exits 0 whether or not it changed anything, so its exit status is not
	# evidence. The count is.
	rf_before="$(rfkill list wlan 2>/dev/null | grep -ci 'blocked: yes')"
	rfkill unblock wlan >/dev/null 2>&1
	rf_after="$(rfkill list wlan 2>/dev/null | grep -ci 'blocked: yes')"
	log "rfkill wlan blocked-lines: ${rf_before:-unknown} -> ${rf_after:-unknown}"
	if [ "${rf_after:-1}" -eq 0 ] 2>/dev/null; then
		did rfkill-clear
	else
		warn "rfkill still reports a blocked wlan. A HARD block is a physical switch or a missing regulatory domain; this script cannot clear it."
	fi

	# --- NetworkManager radio -------------------------------------------
	# `nmcli radio wifi on` is the persistent form: it flips the runtime
	# state AND rewrites /var/lib/NetworkManager/NetworkManager.state, which
	# is the file stage2/02-net-tweaks set to WirelessEnabled=false.
	#
	# GATE: nmcli's own report of the state, before and after.
	nm_before="$(nmcli radio wifi 2>/dev/null)"
	nmcli radio wifi on >/dev/null 2>&1
	nm_after="$(nmcli radio wifi 2>/dev/null)"
	log "nmcli radio wifi: ${nm_before:-unknown} -> ${nm_after:-unknown}"
	if [ "${nm_after}" = "enabled" ]; then
		did radio-on
	else
		warn "nmcli does not report the wifi radio as enabled. Is NetworkManager running?"
	fi

	# Belt and braces on persistence: assert the state file agrees. If NM
	# reported enabled but the file still says false, the next boot silently
	# comes up with no radio -- which is the original defect all over again.
	# (NM_STATE is set at the top, with the other paths.)
	if [ -f "${NM_STATE}" ]; then
		if grep -qi '^WirelessEnabled=true' "${NM_STATE}"; then
			log "persisted: ${NM_STATE} says WirelessEnabled=true"
			did radio-persisted
		else
			warn "${NM_STATE} does not say WirelessEnabled=true, so the radio may not survive a reboot."
		fi
	fi
else
	log "skipping radio enable: no wifi profile to enable it for"
fi

# ===========================================================================
# STEP 3: regulatory domain, read out of the seed
# ===========================================================================
# The `regulatory-domain` key under wifis.<iface> in network-config is what
# Imager writes when the operator picks a country. netplan's NM backend
# ignores it, so it has to be applied here.
#
# The parse prints ONLY the two-letter country code. python3 and PyYAML are
# both in the image (11-manifest's own post-write check uses python3).
CC=""
if [ -f "${NC}" ] && command -v python3 >/dev/null 2>&1; then
	CC="$(python3 - "${NC}" <<'PY' 2>/dev/null
import sys

try:
    import yaml
except Exception:
    sys.exit(1)

# Print ONLY the regulatory-domain value. This file also contains the PSK;
# nothing else in it may ever reach stdout.
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        doc = yaml.safe_load(fh)
except Exception:
    sys.exit(1)

if not isinstance(doc, dict):
    sys.exit(1)

# Accept both a top-level "network:" mapping and a bare one.
net = doc.get("network", doc)
if not isinstance(net, dict):
    sys.exit(1)

wifis = net.get("wifis") or {}
if not isinstance(wifis, dict):
    sys.exit(1)

for _iface, conf in wifis.items():
    if isinstance(conf, dict):
        cc = conf.get("regulatory-domain")
        if cc:
            print(str(cc).strip().upper())
            sys.exit(0)
sys.exit(1)
PY
)"
fi

# VALIDATE BEFORE USE. This value is about to be handed to a command. Two
# ASCII letters or it is not a country code and does not get used.
if [ -n "${CC}" ] && ! printf '%s' "${CC}" | grep -qE '^[A-Z][A-Z]$'; then
	warn "regulatory-domain in network-config is not a two-letter code; refusing to apply it."
	CC=""
fi

if [ -n "${CC}" ]; then
	reg_before="$(iw reg get 2>/dev/null | grep -m1 -o 'country [A-Z][A-Z]')"

	# raspi-config's do_wifi_country is the mechanism upstream
	# stage2/02-net-tweaks would have used had WPA_COUNTRY been set at build
	# time, so it is the mechanism that matches the rest of the image.
	if command -v raspi-config >/dev/null 2>&1; then
		SUDO_USER="${SUDO_USER:-default}" \
			raspi-config nonint do_wifi_country "${CC}" >/dev/null 2>&1
	fi
	# Whether or not raspi-config exists, set the live domain directly too.
	iw reg set "${CC}" >/dev/null 2>&1

	# GATE: the kernel's own view, before and after.
	reg_after="$(iw reg get 2>/dev/null | grep -m1 -o 'country [A-Z][A-Z]')"
	log "regulatory domain: ${reg_before:-unknown} -> ${reg_after:-unknown} (seed asked for ${CC})"
	if [ "${reg_after}" = "country ${CC}" ]; then
		did "regdom-${CC}"
	else
		warn "the kernel does not report country ${CC} after setting it. 5GHz channels and some rfkill hard-blocks depend on this."
	fi
else
	log "no regulatory-domain in the seed (or already neutralised); leaving the domain alone"
fi

# ===========================================================================
# STEP 4: the password cloud-init threw away
# ===========================================================================
# See the long comment at the top. Two distinct defects, and which one applies
# is decided from the seed itself, not guessed.
#
# The descriptor below is SECRET-FREE and is logged. The hash is fetched by a
# SECOND, separate parse whose output is never logged.
SEED_USER=""
SEED_LOCK=""
SEED_KIND=""

if [ -f "${UD}" ] && command -v python3 >/dev/null 2>&1; then
	DESC="$(python3 - "${UD}" <<'PY' 2>/dev/null
import sys

try:
    import yaml
except Exception:
    sys.exit(1)

# SECRET-FREE BY CONSTRUCTION: this prints the user NAME, whether lock_passwd
# was requested, and WHICH KIND of password key was present. Never a value.
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        doc = yaml.safe_load(fh)
except Exception:
    sys.exit(1)

if not isinstance(doc, dict):
    sys.exit(1)

# cloud-init honours both the singular "user:" mapping (ug_util.py:173) and a
# "users:" list. Imager writes the singular form.
cand = None
u = doc.get("user")
if isinstance(u, dict):
    cand = u
elif isinstance(u, str):
    cand = {"name": u}
else:
    users = doc.get("users")
    if isinstance(users, list):
        for entry in users:
            if isinstance(entry, dict) and entry.get("name"):
                cand = entry
                break

if not isinstance(cand, dict):
    sys.exit(1)

name = cand.get("name")
if not name:
    sys.exit(1)

kind = "none"
for key in ("hashed_passwd", "plain_text_passwd", "passwd"):
    if cand.get(key):
        kind = key
        break

lock = cand.get("lock_passwd", "absent")
if lock is True:
    lock = "true"
elif lock is False:
    lock = "false"
else:
    lock = "absent"

print("user=%s" % str(name).strip())
print("lock=%s" % lock)
print("kind=%s" % kind)
PY
)"
	if [ -n "${DESC}" ]; then
		SEED_USER="$(printf '%s\n' "${DESC}" | sed -n 's/^user=//p')"
		SEED_LOCK="$(printf '%s\n' "${DESC}" | sed -n 's/^lock=//p')"
		SEED_KIND="$(printf '%s\n' "${DESC}" | sed -n 's/^kind=//p')"
	fi
fi

if [ -z "${SEED_USER}" ]; then
	log "no user block in ${UD} (or already neutralised); leaving credentials alone"
elif ! grep -qE "^${SEED_USER}:" "${SHADOW}" 2>/dev/null; then
	log "seed names user '${SEED_USER}', which is not in ${SHADOW}; nothing to do"
else
	log "seed user='${SEED_USER}' lock_passwd=${SEED_LOCK} password_key=${SEED_KIND}"

	# The current shadow password field for that user. Captured, compared,
	# NEVER logged.
	CUR_FIELD="$(awk -F: -v u="${SEED_USER}" '$1==u {print $2}' "${SHADOW}" 2>/dev/null)"

	case "${SEED_KIND}" in
	passwd)
		# THE LIVE CASE. cloud-init ignored this key because the account
		# pre-existed. Apply it here.
		SEED_HASH="$(python3 - "${UD}" "${SEED_USER}" <<'PY' 2>/dev/null
import sys

try:
    import yaml
except Exception:
    sys.exit(1)

# This is the ONE place a secret is read. Its output is captured into a shell
# variable and never logged, printed or passed as an argv element.
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        doc = yaml.safe_load(fh)
except Exception:
    sys.exit(1)

want = sys.argv[2]
cand = None
u = doc.get("user") if isinstance(doc, dict) else None
if isinstance(u, dict) and str(u.get("name", "")).strip() == want:
    cand = u
else:
    users = doc.get("users") if isinstance(doc, dict) else None
    if isinstance(users, list):
        for entry in users:
            if isinstance(entry, dict) and str(entry.get("name", "")).strip() == want:
                cand = entry
                break

if not isinstance(cand, dict):
    sys.exit(1)
val = cand.get("passwd")
if not val:
    sys.exit(1)
sys.stdout.write(str(val))
PY
)"
		if [ -z "${SEED_HASH}" ]; then
			warn "could not read the 'passwd' value for ${SEED_USER} out of the seed."
		elif ! printf '%s' "${SEED_HASH}" | grep -qE '^\$[0-9a-zA-Z]+\$'; then
			# cloud-init documents `passwd` as a HASH. A plaintext value
			# here would be written to shadow verbatim and lock the
			# operator out; refuse rather than guess.
			warn "the 'passwd' value for ${SEED_USER} is not a crypt(3) hash (no \$id\$ prefix). Refusing to install it. Set the password from the interactive provision phase instead."
		elif [ "${CUR_FIELD}" = "${SEED_HASH}" ]; then
			# GATE: already current. This is what makes the step a no-op
			# on the second and later boots.
			log "password for ${SEED_USER} already matches the seed; no change"
			did passwd-already-current
		else
			# printf is a bash BUILTIN, so the hash never appears in argv
			# and never shows up in ps.
			if printf '%s:%s\n' "${SEED_USER}" "${SEED_HASH}" | chpasswd -e 2>/dev/null; then
				NEW_FIELD="$(awk -F: -v u="${SEED_USER}" '$1==u {print $2}' "${SHADOW}" 2>/dev/null)"
				# GATE: compare, do not assume. chpasswd can exit 0
				# and change nothing if the account is not writable.
				if [ "${NEW_FIELD}" = "${SEED_HASH}" ]; then
					log "installed the seeded password for ${SEED_USER} (hash not logged) over the image's locked field"
					did passwd-applied
				else
					warn "chpasswd exited 0 but ${SHADOW} did not change for ${SEED_USER}."
				fi
			else
				warn "chpasswd failed for ${SEED_USER}."
			fi
		fi
		unset SEED_HASH
		;;
	hashed_passwd|plain_text_passwd)
		# cloud-init 25.2 distros/__init__.py:876-892 applies both of
		# these to pre-existing users. Nothing to do -- and saying so is
		# better than a silent skip.
		log "cloud-init handles '${SEED_KIND}' for pre-existing users itself (distros/__init__.py:876-892); no action"
		did passwd-handled-by-cloud-init
		;;
	none)
		if [ "${SEED_LOCK}" = "false" ]; then
			# The seed asked for an unlocked account and supplied no
			# password this image can apply. What cloud-init did with that
			# depends on what the image shipped (see item 2 at the top):
			#
			#   '!' or '*'  -- the declared state; cloud-init declined to
			#                  unlock (this image, since 2026-09-23).
			#   ''          -- EMPTY: cloud-init's passwd -d fallback after
			#                  `passwd -u` refused a bare '!'. A blank
			#                  password is a hole, NOT "no password".
			#   '!<hash>'   -- still locked.
			#   '<hash>'    -- an image built before 2026-09-23: cloud-init
			#                  unlocked the BUILD-TIME THROWAWAY.
			#
			# GATE: act only on the two unlocked shapes, and read the field
			# back afterwards.
			REVOKE_WHY=""
			case "${CUR_FIELD}" in
			'!'|'*')
				log "${SEED_USER} has no usable password already; declared locked state holds"
				did passwd-already-revoked
				;;
			'')
				REVOKE_WHY="the password field of ${SEED_USER} is EMPTY (cloud-init's passwd -d fallback: the seed asked for lock_passwd:false with a blank password key). A blank password is a way in with no credential. Re-locking it."
				;;
			'!'*)
				log "${SEED_USER} is still locked; cloud-init did not unlock it"
				did passwd-still-locked
				;;
			*)
				REVOKE_WHY="seed asked for lock_passwd:false with no applicable password, so cloud-init unlocked the BUILD-TIME THROWAWAY for ${SEED_USER} (an image built before 2026-09-23). Revoking it."
				;;
			esac
			if [ -n "${REVOKE_WHY}" ]; then
				warn "${REVOKE_WHY}"
				if usermod -p '!' "${SEED_USER}" >/dev/null 2>&1; then
					REV_FIELD="$(awk -F: -v u="${SEED_USER}" '$1==u {print $2}' "${SHADOW}" 2>/dev/null)"
					if [ "${REV_FIELD}" = "!" ]; then
						log "revoked: ${SEED_USER} now has no usable password. Set one from the interactive provision phase."
						did passwd-revoked
					else
						warn "usermod exited 0 but ${SEED_USER}'s password field is not '!'."
					fi
				else
					warn "usermod -p '!' failed for ${SEED_USER}; an unlocked password field is still live."
				fi
			fi
			unset REVOKE_WHY
		else
			log "seed supplied no password and did not ask for an unlock; nothing to do"
		fi
		;;
	esac
	unset CUR_FIELD
fi

# ===========================================================================
# STEP 5: install the SSH keys typed into Imager
# ===========================================================================
# THE IMAGE IS KEYLESS (2026-09-23). No public key is baked in at build time,
# so the keys on Imager's customisation page are the only SSH keys a fresh card
# has. This step reads them out of user-data and makes sure each is in the
# account's authorized_keys EXACTLY ONCE. It MUST run before step 7 wipes the
# seed -- tests/test-first-boot-seed.sh proves a key read after the wipe finds
# nothing.
#
# Idempotent and duplicate-free by KEY MATERIAL, the same rule cloud-init's own
# ssh_util.update_authorized_keys uses (it matches on the base64 blob). So a key
# cloud-init already wrote, or one this step wrote on an earlier boot, is left
# alone rather than appended a second time; a comment that differs does not
# make it a different key.
#
# Keys are public, but they are still logged by FINGERPRINT ONLY
# (ssh-keygen -lf): the journal says which key went in without becoming a copy
# of authorized_keys.
#
# The parse needs PyYAML, which cloud-init itself depends on -- a card that ran
# cloud-init has it. If it is somehow missing, that is reported and nothing is
# guessed: a hand-rolled YAML reader that got a key wrong would install it.

# The account the image ships. Read from the image's own declaration, the
# same file the verification harness reads, rather than typed in again here.
KEY_TARGET=""
if [ -f "${MANIFEST}" ] && command -v python3 >/dev/null 2>&1; then
	KEY_TARGET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("service_user",""))' "${MANIFEST}" 2>/dev/null)"
fi
KEY_TARGET="${KEY_TARGET:-default}"

SEED_STATE=absent
if [ -f "${UD}" ]; then
	if [ "$(cat "${UD}" 2>/dev/null)" = "${UD_NEUTRAL}" ]; then
		SEED_STATE=neutralised
	else
		SEED_STATE=live
	fi
fi

KEY_STATUS=""
KEY_SEED_USER=""
KEY_COUNT=0
KEY_BAD=0
KEY_TMP="$(mktemp -d 2>/dev/null)"

if [ "${SEED_STATE}" = live ] && [ -n "${KEY_TMP}" ] && command -v python3 >/dev/null 2>&1; then
	KDESC="$(python3 - "${UD}" "${KEY_TARGET}" "${KEY_TMP}/keys" <<'PY' 2>/dev/null
import re
import sys

# Prints a SECRET-FREE descriptor; the keys themselves go to the file in
# argv[3], never to stdout. The shape read here is what Raspberry Pi Imager 2.x
# writes (src/customization_generator.cpp, generateCloudInitUserData): a
# SINGULAR `user:` mapping, whose `ssh_authorized_keys:` is a list with one
# double-quoted key per item. The plural `users:` list and a top-level
# `ssh_authorized_keys` are read too, because cloud-init honours both.
try:
    import yaml
except Exception:
    print("status=noyaml")
    sys.exit(0)

path, want, out = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        doc = yaml.safe_load(fh)
except Exception:
    print("status=malformed")
    sys.exit(0)

if doc is None:
    # A file of comments only: upstream's own template, i.e. an unseeded card.
    print("status=empty")
    sys.exit(0)
if not isinstance(doc, dict):
    print("status=malformed")
    sys.exit(0)

cand = None
singular = False
u = doc.get("user")
if isinstance(u, dict):
    cand, singular = u, True
elif isinstance(u, str):
    cand, singular = {"name": u}, True
else:
    users = doc.get("users")
    if isinstance(users, list):
        named = [e for e in users if isinstance(e, dict) and e.get("name")]
        for e in named:
            if str(e.get("name")).strip() == want:
                cand = e
                break
        if cand is None and named:
            cand = named[0]

if cand is None:
    print("status=nouser")
    sys.exit(0)

name = str(cand.get("name", "")).strip()
print("user=%s" % re.sub(r"[^A-Za-z0-9._-]", "?", name))
if name != want:
    print("status=otheruser")
    sys.exit(0)

raw = []
bad = 0


def take(v):
    global bad
    if v is None:
        return
    if isinstance(v, str):
        raw.append(v)
    elif isinstance(v, (list, tuple, set)):
        for x in v:
            if isinstance(x, str):
                raw.append(x)
            else:
                bad += 1
    elif isinstance(v, dict):
        raw.extend(str(x) for x in v.values())
    else:
        bad += 1


take(cand.get("ssh_authorized_keys"))
# A top-level list belongs to cloud-init's DEFAULT user, which a singular
# `user:` mapping IS (it is merged over the distro default).
if singular:
    take(doc.get("ssh_authorized_keys"))

# One key per line, no options prefix: the only shape Imager emits. Anything
# else is counted and skipped, never "repaired" into something installable.
key_re = re.compile(
    r"^(ssh-[a-z0-9-]+|ecdsa-sha2-[a-z0-9-]+|sk-[A-Za-z0-9@._-]+)"
    r" [A-Za-z0-9+/]+={0,3}( [^\r\n]*)?$"
)
good = []
for r in raw:
    for line in r.splitlines():
        line = line.strip()
        if not line:
            continue
        if key_re.match(line):
            good.append(line)
        else:
            bad += 1

with open(out, "w", encoding="utf-8") as fh:
    for g in good:
        fh.write(g + "\n")

print("status=ok")
print("keys=%d" % len(good))
print("bad=%d" % bad)
PY
)"
	KEY_STATUS="$(printf '%s\n' "${KDESC}" | sed -n 's/^status=//p')"
	KEY_SEED_USER="$(printf '%s\n' "${KDESC}" | sed -n 's/^user=//p')"
	KEY_COUNT="$(printf '%s\n' "${KDESC}" | sed -n 's/^keys=//p')"
	KEY_BAD="$(printf '%s\n' "${KDESC}" | sed -n 's/^bad=//p')"
	KEY_COUNT="${KEY_COUNT:-0}"
	KEY_BAD="${KEY_BAD:-0}"
fi

# Does this authorized_keys already carry the key whose base64 blob is $2?
# Matches the blob in the token AFTER the key type, so a line with an options
# prefix or a different comment is still recognised as the same key.
ak_has_blob() { # ak_has_blob <authorized_keys> <blob>
	[ -f "$1" ] || return 1
	awk -v b="$2" '
		{ for (i = 1; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/ && $(i + 1) == b) { found = 1; exit } }
		END { exit !found }
	' "$1" 2>/dev/null
}

KEYS_ADDED=0
KEYS_PRESENT=0
install_keys() { # install_keys <file of key lines> <user>
	local kf="$1" u="$2" uid gid home sshdir ak fpfile line blob fp

	# Owner and home out of the image's OWN passwd -- by number, so the same
	# code is right on the machine and against the test harness's rootfs.
	uid="$(awk -F: -v u="${u}" '$1==u {print $3; exit}' "${PASSWD_DB}" 2>/dev/null)"
	gid="$(awk -F: -v u="${u}" '$1==u {print $4; exit}' "${PASSWD_DB}" 2>/dev/null)"
	home="$(awk -F: -v u="${u}" '$1==u {print $6; exit}' "${PASSWD_DB}" 2>/dev/null)"
	if [ -z "${uid}" ] || [ -z "${gid}" ] || [ -z "${home}" ]; then
		warn "no passwd entry for '${u}' in ${PASSWD_DB}; the seeded SSH keys were NOT installed."
		return 1
	fi
	if [ ! -d "${R}${home}" ]; then
		warn "home ${home} of '${u}' does not exist; the seeded SSH keys were NOT installed."
		return 1
	fi

	sshdir="${R}${home}/.ssh"
	ak="${sshdir}/authorized_keys"
	# Never write through a symlink as root into a user's home.
	if [ -L "${sshdir}" ] || [ -L "${ak}" ]; then
		warn "${sshdir} or its authorized_keys is a symlink; refusing to write through it. The seeded SSH keys were NOT installed."
		return 1
	fi

	if ! mkdir -p "${sshdir}" 2>/dev/null || ! ( umask 077 && : >> "${ak}" ) 2>/dev/null; then
		warn "could not create ${ak}; the seeded SSH keys were NOT installed."
		return 1
	fi
	chmod 0700 "${sshdir}" 2>/dev/null
	chmod 0600 "${ak}" 2>/dev/null
	chown "${uid}:${gid}" "${sshdir}" "${ak}" 2>/dev/null

	fpfile="$(mktemp "${KEY_TMP}/fp.XXXXXX" 2>/dev/null)"
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		fp=""
		if command -v ssh-keygen >/dev/null 2>&1 && [ -n "${fpfile}" ]; then
			printf '%s\n' "${line}" > "${fpfile}"
			fp="$(ssh-keygen -lf "${fpfile}" 2>/dev/null | awk '{print $1, $2, $NF}')"
			if [ -z "${fp}" ]; then
				# ssh-keygen doubles as the validator: a line it cannot read
				# is not a key sshd could use either.
				warn "a seeded SSH key is not one ssh-keygen can read; skipped (its text is not logged)."
				continue
			fi
		else
			fp="(ssh-keygen unavailable: no fingerprint)"
		fi
		blob="$(printf '%s\n' "${line}" | awk '{print $2}')"

		# THE DEDUPE. Checked against the file as it is NOW, so a key the
		# seed lists twice is added once, and one cloud-init already wrote
		# is not added at all.
		if ak_has_blob "${ak}" "${blob}"; then
			log "ssh key already present, not duplicated: ${fp}"
			KEYS_PRESENT=$((KEYS_PRESENT + 1))
			continue
		fi
		if ! printf '%s\n' "${line}" >> "${ak}" 2>/dev/null; then
			warn "could not append to ${ak}: key ${fp} NOT installed."
			continue
		fi
		# GATE: read it back rather than trusting the redirection.
		if ak_has_blob "${ak}" "${blob}"; then
			log "installed ssh key for ${u}: ${fp}"
			KEYS_ADDED=$((KEYS_ADDED + 1))
		else
			warn "appended key ${fp} to ${ak} but it is not there on re-read."
		fi
	done < "${kf}"

	# GATE: sshd's StrictModes refuses keys in a directory or file that is
	# group/world-writable or owned by someone else, and says so only in its
	# own log. Measured, not assumed.
	local want_owner="${uid}:${gid}" got
	got="$(stat -c '%a %u:%g' "${sshdir}" 2>/dev/null)"
	[ "${got}" = "700 ${want_owner}" ] || warn "${sshdir} is '${got}', expected '700 ${want_owner}'; sshd may refuse these keys."
	got="$(stat -c '%a %u:%g' "${ak}" 2>/dev/null)"
	[ "${got}" = "600 ${want_owner}" ] || warn "${ak} is '${got}', expected '600 ${want_owner}'; sshd may refuse these keys."
	return 0
}

case "${SEED_STATE}:${KEY_STATUS}" in
	absent:*)
		log "no ${UD}; no SSH keys to install" ;;
	neutralised:*)
		log "seed already neutralised; no SSH keys to read (earlier boots installed whatever it carried)" ;;
	live:)
		warn "could not read ${UD} for SSH keys (python3 missing or the parse died); NO KEYS INSTALLED." ;;
	live:noyaml)
		warn "python3 has no PyYAML here, so the SSH keys in ${UD} could not be read. NO KEYS INSTALLED." ;;
	live:malformed)
		warn "${UD} is not valid YAML (cloud-init could not have read it either). NO KEYS INSTALLED." ;;
	live:otheruser)
		warn "the seed's account is '${KEY_SEED_USER}', not '${KEY_TARGET}'. cloud-init creates that as a NEW account with its own keys; '${KEY_TARGET}' -- the account this image runs as -- gets none. See docs/flashing.md: the username must be '${KEY_TARGET}'." ;;
	live:ok)
		if [ "${KEY_BAD}" -gt 0 ] 2>/dev/null; then
			warn "${KEY_BAD} entry(ies) under ssh_authorized_keys are not a single-line public key; skipped (not logged)."
		fi
		if [ "${KEY_COUNT}" -gt 0 ] 2>/dev/null; then
			if install_keys "${KEY_TMP}/keys" "${KEY_TARGET}"; then
				log "ssh keys for ${KEY_TARGET}: ${KEYS_ADDED} installed, ${KEYS_PRESENT} already present"
				did "ssh-keys-${KEYS_ADDED}-added-${KEYS_PRESENT}-present"
			fi
		else
			log "the seed carries no SSH key for ${KEY_TARGET}"
		fi ;;
	live:*)
		log "the seed carries no user block (${KEY_STATUS}); no SSH keys to install" ;;
esac

# --- NO SSH WAY IN ----------------------------------------------------------
# The one case worth shouting about: a live seed that carries NEITHER a
# password NOR a key for the image's account. Password-only is fine (and is
# the easier path for many operators); key-only is fine. Neither means the
# account stays locked with nothing in authorized_keys, and the touchscreen is
# the only way in -- which is exactly the thing in question when the UI fails.
SEED_HAS_PW=0
if [ "${SEED_USER}" = "${KEY_TARGET}" ]; then
	case "${SEED_KIND}" in
		passwd|hashed_passwd|plain_text_passwd) SEED_HAS_PW=1 ;;
	esac
fi
if [ "${SEED_STATE}" = live ]; then
	case "${KEY_STATUS}" in
		ok|empty|nouser|malformed)
			if [ "${SEED_HAS_PW}" -eq 0 ] && [ "${KEY_COUNT}" -eq 0 ] 2>/dev/null; then
				warn "NO SSH WAY IN. The Imager seed carried neither a password nor an SSH key for '${KEY_TARGET}'."
				log "#####################################################################"
				log "# This machine is reachable ONLY FROM THE TOUCHSCREEN: the account is"
				log "# locked and the seed gave it no key. Re-flash with Imager 2.x from"
				log "# its --repo entry and, on the customisation page, set a password"
				log "# and/or paste an SSH public key for user '${KEY_TARGET}'."
				log "# (Imager's 'Use custom' local file skips that page entirely.)"
				log "#####################################################################"
			fi ;;
	esac
fi
[ -n "${KEY_TMP}" ] && rm -rf "${KEY_TMP}"

# ===========================================================================
# STEP 6: report -- never change -- the SSH authentication choice
# ===========================================================================
# SSH AUTH POLICY IS THE OPERATOR'S (2026-09-23). The image enables sshd and
# leaves RPi OS's default in place: it sets no PasswordAuthentication anywhere
# (elspi.conf has PUBKEY_ONLY_SSH=0). Imager's page then decides per card:
#
#   "public-key only"  -> ssh_pwauth: false -> PasswordAuthentication no
#   password SSH       -> ssh_pwauth: true  -> PasswordAuthentication yes
#
# cloud-init 25.2 (ssh_util.update_ssh_config) writes that into
# /etc/ssh/sshd_config.d/50-cloud-init.conf whenever sshd_config Includes
# sshd_config.d/*.conf, which Debian's does, at the top. sshd takes the FIRST
# value it reads, so cloud-init's file wins over sshd_config's own body, and
# LOSES to any drop-in that sorts ahead of "50-". This image ships no drop-in
# that sets an authentication option (tests/verify-image.sh asserts it), and
# this step is the runtime tripwire for one appearing.
CI_SSHD="${SSHD_DROPIN_DIR}/50-cloud-init.conf"
if [ -f "${CI_SSHD}" ]; then
	ci_pw="$(awk 'tolower($1) == "passwordauthentication" { print tolower($2); exit }' "${CI_SSHD}" 2>/dev/null)"
	case "${ci_pw}" in
		no)  log "Imager chose public-key-only SSH: ${CI_SSHD} says PasswordAuthentication no. Left as chosen." ;;
		yes) log "Imager allowed password SSH: ${CI_SSHD} says PasswordAuthentication yes. Left as chosen." ;;
		*)   log "${CI_SSHD} is present but sets no PasswordAuthentication; sshd keeps the image default." ;;
	esac
else
	log "no SSH choice from Imager (no ${CI_SSHD}); sshd keeps the image default (RPi OS: password authentication allowed)."
fi

for f in "${SSHD_DROPIN_DIR}"/*.conf; do
	[ -f "${f}" ] || continue
	[ "${f}" = "${CI_SSHD}" ] && continue
	if grep -qiE '^[[:blank:]]*(PasswordAuthentication|AuthenticationMethods)[[:blank:]]' "${f}" 2>/dev/null; then
		warn "${f} sets an SSH authentication option. sshd uses the FIRST value it reads, so this file overrides (or stands in for) the choice made on Imager's page. This image ships no such file; something added it."
	fi
done
if [ -f "${SSHD_CONFIG}" ] && grep -qiE '^[[:blank:]]*(PasswordAuthentication|AuthenticationMethods)[[:blank:]]' "${SSHD_CONFIG}" 2>/dev/null; then
	warn "${SSHD_CONFIG} itself sets an SSH authentication option. When Imager made no choice, that line decides instead of RPi OS's default. This image ships none."
fi

# ===========================================================================
# STEP 7: take the credentials off the card
# ===========================================================================
# Reached only because GATE 0 passed, i.e. cloud-init has finished with them.
neutralise() { # neutralise <path> <desired single-line content> <label>
	local f="$1" want="$2" label="$3" cur=""

	if [ ! -f "${f}" ]; then
		log "${label}: ${f} is absent; nothing to neutralise"
		return 0
	fi

	cur="$(cat "${f}" 2>/dev/null)"
	if [ "${cur}" = "${want}" ]; then
		# GATE: already neutralised. The idempotence of this whole script.
		log "${label}: already neutralised"
		return 0
	fi

	if ! printf '%s\n' "${want}" > "${f}" 2>/dev/null; then
		warn "${label}: could not write ${f}. The seed is STILL ON THE CARD."
		return 1
	fi
	sync

	# GATE: read it back. A FAT partition remounted read-only, or a full
	# filesystem, both let the redirection above look like it worked.
	cur="$(cat "${f}" 2>/dev/null)"
	if [ "${cur}" = "${want}" ]; then
		log "${label}: neutralised ${f}"
		did "neutralised-${label}"
		return 0
	fi
	warn "${label}: ${f} did not change after writing it. The seed is STILL ON THE CARD."
	return 1
}

# A bare '#cloud-config' is a VALID, EMPTY cloud-config -- not a malformed
# file. cloud-init parses it, finds no modules to run, and logs nothing
# alarming. An empty or absent file does not have that property.
neutralise "${UD}" "${UD_NEUTRAL}" user-data

# The minimal valid netplan document. Same reasoning: `network: {version: 2}`
# declares "no interfaces configured here" rather than "this file is broken".
neutralise "${NC}" 'network: {version: 2}' network-config

# meta-data is deliberately untouched -- it carries the instance-id.
if [ -f "${MD}" ]; then
	log "meta-data left intact by design ($(grep -cE '^instance-id:' "${MD}" 2>/dev/null) instance-id line(s)); it holds no credential"
fi

# ===========================================================================
# ONE greppable summary line. `warnings=` is a count, not a rating: a run with
# warnings still did everything it could, and the detail is in the lines above.
log "verdict=OK steps_done=[${STEPS_DONE# }] warnings=${WARN_COUNT}"

# ALWAYS. See the contract at the top.
exit 0
