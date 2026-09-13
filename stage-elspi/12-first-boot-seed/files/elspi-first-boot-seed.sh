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
#    creates it and runs `passwd -l`), so the password the operator typed into
#    Imager is silently discarded.
#
#    Worse, the same function then UNLOCKS the account anyway. `passwd -l`
#    prefixes '!' to the existing hash and leaves the rest -- shadow(5): "The
#    remaining characters on the line represent the password field before the
#    password was locked" -- so the field is `!<build throwaway hash>`, not
#    `!`. cloud-init's empty-locked patterns (distros/__init__.py:139) are
#    `^{username}::` and `^{username}:!:`, neither of which matches. So
#    has_existing_password becomes True (line 912), `lock_passwd: false` takes
#    the branch at line 927, and line 940 calls unlock_passwd() -- making the
#    random FIRST_USER_PASS throwaway from elspi.conf a LIVE password that
#    nobody knows.
#
#    This script closes both halves: it applies the operator's hash itself, or,
#    if the seed asked for an unlock without supplying a password this image
#    can apply, it revokes the throwaway and restores the declared locked
#    state.
#
# 3. THE SEED. user-data carries a password hash and network-config carries a
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

BOOTDIR=/boot/firmware
UD="${BOOTDIR}/user-data"
NC="${BOOTDIR}/network-config"
MD="${BOOTDIR}/meta-data"
SHADOW=/etc/shadow
SSHD_CONFIG=/etc/ssh/sshd_config

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
if [ ! -e /var/lib/cloud/instance/boot-finished ]; then
	log "cloud-init end marker /var/lib/cloud/instance/boot-finished is ABSENT."
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
for d in /etc/NetworkManager/system-connections \
         /run/NetworkManager/system-connections; do
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
	NM_STATE=/var/lib/NetworkManager/NetworkManager.state
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
					log "installed the seeded password for ${SEED_USER} (hash not logged) and cleared the build-time throwaway"
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
			# THE UNLOCK HOLE. The seed asked for an unlocked account and
			# supplied no password this image can apply, so cloud-init
			# unlocked whatever was already there -- the random
			# FIRST_USER_PASS throwaway from elspi.conf, which nobody
			# knows and which is now a live credential.
			#
			# GATE: only act if the field is actually unlocked AND
			# non-empty. If it is already '!' or empty, the image's
			# declared state holds and there is nothing to revoke.
			if [ -z "${CUR_FIELD}" ] || [ "${CUR_FIELD}" = "!" ] || [ "${CUR_FIELD}" = "*" ]; then
				log "${SEED_USER} has no usable password already; declared locked state holds"
				did passwd-already-revoked
			else
				case "${CUR_FIELD}" in
				'!'*)
					log "${SEED_USER} is still locked; cloud-init did not unlock it"
					did passwd-still-locked
					;;
				*)
					warn "seed asked for lock_passwd:false with no applicable password, so cloud-init unlocked the BUILD-TIME THROWAWAY for ${SEED_USER}. Revoking it."
					if usermod -p '!' "${SEED_USER}" >/dev/null 2>&1; then
						REV_FIELD="$(awk -F: -v u="${SEED_USER}" '$1==u {print $2}' "${SHADOW}" 2>/dev/null)"
						if [ "${REV_FIELD}" = "!" ]; then
							log "revoked: ${SEED_USER} now has no usable password. Set one from the interactive provision phase."
							did passwd-throwaway-revoked
						else
							warn "usermod exited 0 but ${SEED_USER}'s password field is not '!'."
						fi
					else
						warn "usermod -p '!' failed for ${SEED_USER}; a password nobody knows is still live."
					fi
					;;
				esac
			fi
		else
			log "seed supplied no password and did not ask for an unlock; nothing to do"
		fi
		;;
	esac
	unset CUR_FIELD
fi

# ===========================================================================
# STEP 5: report -- do not silently fight -- Imager's ssh_pwauth checkbox
# ===========================================================================
# cloud-init 25.2 cc_set_passwords.py:60-90 turns `ssh_pwauth: true` into
# PasswordAuthentication yes in /etc/ssh/sshd_config -- the same file
# stage2/01-sys-tweaks/01-run.sh set to `no` because elspi.conf sets
# PUBKEY_ONLY_SSH=1.
#
# This is REPORTED and not reverted on purpose. The checkbox is an explicit
# operator choice made at flash time, and an image that silently undoes what
# the operator asked for is worse than one that tells them. FLASH-SESSION.md
# tells them which box to tick.
if [ -f "${SSHD_CONFIG}" ]; then
	if grep -qiE '^[[:blank:]]*PasswordAuthentication[[:blank:]]+yes' "${SSHD_CONFIG}"; then
		warn "${SSHD_CONFIG} has PasswordAuthentication yes -- the Imager seed's 'ssh_pwauth: true' overrode this image's PUBKEY_ONLY_SSH=1. Not reverted: it was an explicit choice on the customisation page."
	else
		log "sshd still pubkey-only (PasswordAuthentication is not 'yes')"
	fi
fi

# ===========================================================================
# STEP 6: take the credentials off the card
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
neutralise "${UD}" '#cloud-config' user-data

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
