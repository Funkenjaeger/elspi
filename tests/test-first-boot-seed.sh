#!/bin/bash
# Run the REAL first-boot seed script against a synthetic rootfs.
#
#   tests/test-first-boot-seed.sh
#
# stage-elspi/12-first-boot-seed/files/elspi-first-boot-seed.sh is the only
# thing that puts an SSH key on an elspi card: the image is KEYLESS
# (2026-09-23), so the keys typed into Raspberry Pi Imager's customisation page
# are the whole of SSH-by-key, and the password typed there is the whole of
# SSH-by-password. verify-image.sh can only say the unit is installed and
# wired. This says what the script DOES, case by case, against user-data in
# the shape Imager 2.x writes.
#
# THE SHAPE, and where it comes from: rpi-imager's
# src/customization_generator.cpp, generateCloudInitUserData(), read
# 2026-09-23. A SINGULAR `user:` mapping (not a `users:` list -- the source's
# own comment cites rpi-imager issue #1601), `lock_passwd: false` plus a
# double-quoted `passwd:` hash when a password is set, `lock_passwd: true`
# when only keys are, `ssh_authorized_keys:` as a list with one double-quoted
# key per item, and a top-level `ssh_pwauth: true|false` for the SSH choice.
#
# HOW IT RUNS WITHOUT ROOT OR A PI:
#   * ELSPI_SEED_TEST_ROOT prefixes every path the script touches.
#   * chpasswd and usermod are SHIMS that edit the synthetic /etc/shadow, so
#     the password path is exercised end to end rather than skipped.
#     rfkill/nmcli/iw/raspi-config are shims that only record they were
#     called (no Wi-Fi profile is seeded, so they should not be).
#   * The synthetic passwd maps `default` to THIS uid/gid. An unprivileged
#     chown can only name its own uid, so ownership is asserted -- and is
#     real -- but it proves the uid/gid lookup and the chown, not a chown
#     ACROSS uids. That half needs root, and a real card.
#   * Keys are generated per run with ssh-keygen into a temp dir. The
#     private halves are deleted as soon as they exist and are never
#     printed; nothing here is anybody's key.
#
# Needs: bash, python3 WITH PyYAML (the seed script parses user-data with it,
# as the image does -- cloud-init depends on it), ssh-keygen, coreutils.
# Missing any of those is reported and exits 2: NOT a pass.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SEED="${ELSPI_SEED_SCRIPT:-${REPO}/stage-elspi/12-first-boot-seed/files/elspi-first-boot-seed.sh}"
UPSTREAM_UD="${REPO}/stage2/04-cloud-init/files/user-data"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
chk() { # chk <description> <command...>
	local d="$1"; shift
	if "$@" >/dev/null 2>&1; then ok "${d}"; else bad "${d}"; fi
}
nchk() { # nchk <description> <command...>  -- passes when the command FAILS
	local d="$1"; shift
	if "$@" >/dev/null 2>&1; then bad "${d}"; else ok "${d}"; fi
}

# --- prerequisites: could we measure at all? --------------------------------
missing=""
command -v python3 >/dev/null 2>&1 || missing="${missing} python3"
python3 -c 'import yaml' >/dev/null 2>&1 || missing="${missing} python3-yaml"
command -v ssh-keygen >/dev/null 2>&1 || missing="${missing} ssh-keygen"
[ -f "${SEED}" ] || missing="${missing} ${SEED}"
if [ -n "${missing}" ]; then
	echo "CANNOT RUN: missing${missing}"
	echo "NOT reporting success -- the seed script was not exercised."
	exit 2
fi

# --- throwaway keys ---------------------------------------------------------
KEYS="${WORK}/keys"
mkdir -p "${KEYS}"
ssh-keygen -q -t ed25519 -N '' -C 'elspi-test-key-A' -f "${KEYS}/a" </dev/null >/dev/null 2>&1
ssh-keygen -q -t ecdsa -b 256 -N '' -C 'elspi-test-key-B' -f "${KEYS}/b" </dev/null >/dev/null 2>&1
rm -f "${KEYS}/a" "${KEYS}/b"       # private halves: never needed, never kept
if [ ! -s "${KEYS}/a.pub" ] || [ ! -s "${KEYS}/b.pub" ]; then
	echo "CANNOT RUN: ssh-keygen did not produce throwaway keys"
	exit 2
fi
PUB_A="$(cat "${KEYS}/a.pub")"
PUB_B="$(cat "${KEYS}/b.pub")"
BLOB_A="$(awk '{print $2}' "${KEYS}/a.pub")"
BLOB_B="$(awk '{print $2}' "${KEYS}/b.pub")"
FP_A="$(ssh-keygen -lf "${KEYS}/a.pub" | awk '{print $2}')"
FP_B="$(ssh-keygen -lf "${KEYS}/b.pub" | awk '{print $2}')"

# A crypt(3)-SHAPED value, not a hash of anything: the script checks the
# $id$ prefix and copies the field; it never verifies a password.
FAKE_HASH='$6$elspitest$'"$(printf 'A%.0s' $(seq 1 86))"

MY_UID="$(id -u)"
MY_GID="$(id -g)"

# --- shims ------------------------------------------------------------------
BIN="${WORK}/bin"
CALLS="${WORK}/calls.log"
mkdir -p "${BIN}"
: > "${CALLS}"

cat > "${BIN}/chpasswd" <<'SHIM'
#!/bin/bash
# Test shim: `chpasswd -e` against the SYNTHETIC shadow only.
echo "chpasswd $*" >> "${ELSPI_TEST_CALLS}"
[ -n "${ELSPI_SEED_TEST_ROOT:-}" ] || exit 1
IFS= read -r line || exit 1
u="${line%%:*}"
h="${line#*:}"
f="${ELSPI_SEED_TEST_ROOT}/etc/shadow"
awk -F: -v OFS=: -v u="${u}" -v h="${h}" '$1==u {$2=h} {print}' "${f}" > "${f}.new" && mv "${f}.new" "${f}"
SHIM
cat > "${BIN}/usermod" <<'SHIM'
#!/bin/bash
# Test shim: `usermod -p <field> <user>` against the SYNTHETIC shadow only.
echo "usermod $*" >> "${ELSPI_TEST_CALLS}"
[ -n "${ELSPI_SEED_TEST_ROOT:-}" ] || exit 1
[ "$1" = "-p" ] || exit 1
h="$2"
u="$3"
f="${ELSPI_SEED_TEST_ROOT}/etc/shadow"
awk -F: -v OFS=: -v u="${u}" -v h="${h}" '$1==u {$2=h} {print}' "${f}" > "${f}.new" && mv "${f}.new" "${f}"
SHIM
for c in rfkill nmcli iw raspi-config; do
	printf '#!/bin/bash\necho "%s $*" >> "${ELSPI_TEST_CALLS}"\nexit 0\n' "${c}" > "${BIN}/${c}"
done
chmod 0755 "${BIN}"/*

# --- a synthetic rootfs, shaped like the image AFTER cloud-init ran ---------
# What stage-elspi/05-service-user ships in default's password field: a BARE
# '!' (usermod -p '!'), not passwd -l's '!<hash>'. Section 0 below checks the
# stage still says so. The second value is the shape cloud-init leaves behind
# after it unlocks an image built BEFORE 2026-09-23: the throwaway's hash,
# live.
SHIPPED_FIELD='!'
LEGACY_UNLOCKED='$6$throwaway$BUILDTIME'

make_root() { # make_root <dir> [default's shadow password field]
	local r="$1" field="${2-${SHIPPED_FIELD}}"
	rm -rf "${r}"
	mkdir -p "${r}/boot/firmware" "${r}/etc/ssh/sshd_config.d" \
		"${r}/var/lib/cloud/instance" "${r}/home/default"
	: > "${r}/var/lib/cloud/instance/boot-finished"
	printf 'root:x:0:0:root:/root:/bin/bash\ndefault:x:%s:%s::/home/default:/bin/bash\n' \
		"${MY_UID}" "${MY_GID}" > "${r}/etc/passwd"
	printf 'root:*:20000:0:99999:7:::\ndefault:%s:20000:0:99999:7:::\n' "${field}" \
		> "${r}/etc/shadow"
	cp "${r}/etc/shadow" "${r}/etc/shadow.start"
	printf '{"service_user": "default"}\n' > "${r}/etc/elspi-image.json"
	printf 'dsmode: local\ninstance-id: rpi-imager-1758600000\n' > "${r}/boot/firmware/meta-data"
	printf 'network: {version: 2}\n' > "${r}/boot/firmware/network-config"
	printf 'Include /etc/ssh/sshd_config.d/*.conf\n#PasswordAuthentication yes\nKbdInteractiveAuthentication no\nUsePAM yes\n' \
		> "${r}/etc/ssh/sshd_config"
}

# user-data in Imager 2.x's shape. keys are passed as whole lines.
imager_ud() { # imager_ud <file> <password: yes|no> <ssh_pwauth: true|false|none> [key...]
	local f="$1" pw="$2" pwauth="$3" k
	shift 3
	{
		echo '#cloud-config'
		echo 'hostname: elspi'
		echo 'manage_etc_hosts: true'
		echo
		echo 'user:'
		echo '  name: default'
		echo '  shell: /bin/bash'
		if [ "${pw}" = yes ]; then
			echo '  lock_passwd: false'
			printf '  passwd: "%s"\n' "${FAKE_HASH}"
		elif [ "$#" -gt 0 ]; then
			echo '  lock_passwd: true'
		fi
		if [ "$#" -gt 0 ]; then
			echo '  ssh_authorized_keys:'
			for k in "$@"; do printf '    - "%s"\n' "${k}"; done
		fi
		echo '  sudo: ALL=(ALL) NOPASSWD:ALL'
		echo
		[ "${pwauth}" = none ] || echo "ssh_pwauth: ${pwauth}"
	} > "${f}"
}

# What cloud-init 25.2 writes for ssh_pwauth (ssh_util.update_ssh_config ->
# sshd_config.d/50-cloud-init.conf, because sshd_config Includes the dir).
cloudinit_pwauth() { # cloudinit_pwauth <root> <yes|no>
	printf 'PasswordAuthentication %s\n' "$2" > "$1/etc/ssh/sshd_config.d/50-cloud-init.conf"
}

run_seed() { # run_seed <root>  -> log at <root>.log, exit status in RC
	PATH="${BIN}:${PATH}" ELSPI_SEED_TEST_ROOT="$1" ELSPI_TEST_CALLS="${CALLS}" \
		bash "${SEED}" > "$1.log" 2>&1
	RC=$?
}

AK_OF() { echo "$1/home/default/.ssh/authorized_keys"; }
count_blob() { # count_blob <authorized_keys> <blob>
	[ -f "$1" ] || { echo 0; return; }
	awk -v b="$2" '{ for (i = 1; i < NF; i++) if ($(i + 1) == b) n++ } END { print n + 0 }' "$1"
}
shadow_field() { awk -F: '$1=="default" {print $2}' "$1/etc/shadow"; }
mode_owner() { stat -c '%a %u:%g' "$1" 2>/dev/null; }
logged() { grep -qF -- "$2" "$1.log"; }

# EVERY LOG, EVERY CASE: the key text never reaches the journal, only its
# fingerprint; the password hash never does either.
no_secret_in_log() { # no_secret_in_log <root>
	! grep -qF -e "${BLOB_A}" -e "${BLOB_B}" -e "${FAKE_HASH}" "$1.log"
}

common_asserts() { # common_asserts <root> <label>
	chk "[$2] exits 0 (never fails the boot)" test "${RC}" -eq 0
	chk "[$2] the verdict line is written" logged "$1" "verdict=OK"
	chk "[$2] no key text and no hash in the log (fingerprints only)" no_secret_in_log "$1"
	chk "[$2] user-data neutralised afterwards" test "$(cat "$1/boot/firmware/user-data")" = '#cloud-config'
}

echo "== seed script: ${SEED#"${REPO}/"} =="

# ---------------------------------------------------------------------------
echo
echo "-- 0. the locked field the image ships, as cloud-init will read it --"
# stage-elspi/05-service-user cannot run here (it needs the chroot), so its
# CODE FORM is asserted: it must write a bare '!' and must not use passwd -l,
# whose '!<hash>' is what cloud-init used to unlock. Its own post-write gate
# FATALs on anything but '^<user>:!:'.
SVC_STAGE="${REPO}/stage-elspi/05-service-user/00-run.sh"
chk "[0] 05-service-user locks with usermod -p '!'" grep -qE "^[[:blank:]]*usermod -p '!' " "${SVC_STAGE}"
nchk "[0] 05-service-user does not run passwd -l" grep -qE '^[[:blank:]]*passwd -l' "${SVC_STAGE}"
chk "[0] 05-service-user's post-write gate demands a bare '!'" grep -qF ':!:" "${ROOTFS_DIR}/etc/shadow"' "${SVC_STAGE}"

# cloud-init 25.2's own test, distros/__init__.py:139 and :809-841: a user
# whose line matches one of these has NO existing password, and with
# lock_passwd:false and no hashed_/plain_text_passwd cloud-init then declines
# to unlock (:941-953). The patterns are copied verbatim.
ci_sees_no_password() { # ci_sees_no_password <shadow field>
	python3 - "$1" <<'PY'
import re, sys
line = "default:%s:20000:0:99999:7:::" % sys.argv[1]
pats = ["^{username}::", "^{username}:!:"]
rx = "|".join(p.format(username="default") for p in pats)
sys.exit(0 if re.findall(rx, line, re.MULTILINE) else 1)
PY
}
chk "[0] cloud-init reads the shipped bare '!' as NO password (so it will not unlock)" ci_sees_no_password "${SHIPPED_FIELD}"
nchk "[0] control: cloud-init reads passwd -l's '!<hash>' as a password (the old unlock hole)" ci_sees_no_password '!$6$throwaway$BUILDTIME'

# ---------------------------------------------------------------------------
echo
echo "-- 1. one key, public-key-only SSH (Imager: key, no password) --"
R1="${WORK}/r1"; make_root "${R1}"
imager_ud "${R1}/boot/firmware/user-data" no false "${PUB_A}"
cloudinit_pwauth "${R1}" no
run_seed "${R1}"
common_asserts "${R1}" 1
AK1="$(AK_OF "${R1}")"
chk "[1] authorized_keys created" test -f "${AK1}"
chk "[1] key A present exactly once" test "$(count_blob "${AK1}" "${BLOB_A}")" -eq 1
chk "[1] authorized_keys holds exactly one line" test "$(grep -c . "${AK1}" 2>/dev/null)" -eq 1
chk "[1] ~/.ssh is 700 and owned by default's uid:gid" test "$(mode_owner "$(dirname "${AK1}")")" = "700 ${MY_UID}:${MY_GID}"
chk "[1] authorized_keys is 600 and owned by default's uid:gid" test "$(mode_owner "${AK1}")" = "600 ${MY_UID}:${MY_GID}"
chk "[1] key A's fingerprint is logged" logged "${R1}" "${FP_A}"
chk "[1] the key-only choice is reported, not changed" logged "${R1}" "Imager chose public-key-only SSH"
chk "[1] 50-cloud-init.conf left as cloud-init wrote it" test "$(cat "${R1}/etc/ssh/sshd_config.d/50-cloud-init.conf")" = "PasswordAuthentication no"
nchk "[1] no NO-SSH-WAY-IN warning" logged "${R1}" "NO SSH WAY IN"
chk "[1] password left locked (no password in the seed)" test "$(shadow_field "${R1}")" = "${SHIPPED_FIELD}"

# Idempotence: the same seed again (a re-flash of the same card, or a
# resumed first boot) must not append the key a second time.
imager_ud "${R1}/boot/firmware/user-data" no false "${PUB_A}"
run_seed "${R1}"
chk "[1b] second run with the same seed: exit 0" test "${RC}" -eq 0
chk "[1b] second run: key A still present exactly once" test "$(count_blob "${AK1}" "${BLOB_A}")" -eq 1
chk "[1b] second run: reported as already present" logged "${R1}" "already present"

# Later boots: the seed is gone, and that is not a missing credential.
run_seed "${R1}"
chk "[1c] neutralised seed: exit 0" test "${RC}" -eq 0
nchk "[1c] neutralised seed: no NO-SSH-WAY-IN warning" logged "${R1}" "NO SSH WAY IN"
chk "[1c] neutralised seed: key A still present exactly once" test "$(count_blob "${AK1}" "${BLOB_A}")" -eq 1

# ---------------------------------------------------------------------------
echo
echo "-- 2. two keys --"
R2="${WORK}/r2"; make_root "${R2}"
imager_ud "${R2}/boot/firmware/user-data" no false "${PUB_A}" "${PUB_B}"
cloudinit_pwauth "${R2}" no
run_seed "${R2}"
common_asserts "${R2}" 2
AK2="$(AK_OF "${R2}")"
chk "[2] key A present exactly once" test "$(count_blob "${AK2}" "${BLOB_A}")" -eq 1
chk "[2] key B present exactly once" test "$(count_blob "${AK2}" "${BLOB_B}")" -eq 1
chk "[2] authorized_keys holds exactly two lines" test "$(grep -c . "${AK2}" 2>/dev/null)" -eq 2
chk "[2] both fingerprints logged" eval 'logged "${R2}" "${FP_A}" && logged "${R2}" "${FP_B}"'
chk "[2] authorized_keys is 600, owned by default" test "$(mode_owner "${AK2}")" = "600 ${MY_UID}:${MY_GID}"

# ---------------------------------------------------------------------------
echo
echo "-- 3. a key cloud-init already installed (no duplicate) --"
# cloud-init 25.2 imports ssh_authorized_keys for a pre-existing user, so on a
# real card key A may already be there -- with whatever comment it carried.
R3="${WORK}/r3"; make_root "${R3}"
mkdir -p "${R3}/home/default/.ssh"
printf 'ssh-ed25519 %s written-by-cloud-init\n' "${BLOB_A}" > "$(AK_OF "${R3}")"
chmod 0600 "$(AK_OF "${R3}")"
imager_ud "${R3}/boot/firmware/user-data" no false "${PUB_A}" "${PUB_B}" "${PUB_A}"
cloudinit_pwauth "${R3}" no
run_seed "${R3}"
common_asserts "${R3}" 3
AK3="$(AK_OF "${R3}")"
chk "[3] key A still present exactly once (not re-added, not added twice from the seed)" test "$(count_blob "${AK3}" "${BLOB_A}")" -eq 1
chk "[3] cloud-init's own line for key A is untouched" grep -qxF "ssh-ed25519 ${BLOB_A} written-by-cloud-init" "${AK3}"
chk "[3] key B added exactly once" test "$(count_blob "${AK3}" "${BLOB_B}")" -eq 1
chk "[3] authorized_keys holds exactly two lines" test "$(grep -c . "${AK3}" 2>/dev/null)" -eq 2
chk "[3] the duplicate is reported as already present" logged "${R3}" "already present, not duplicated: 256 ${FP_A}"

# ---------------------------------------------------------------------------
echo
echo "-- 4. password only, password SSH (Imager: password, no key) --"
R4="${WORK}/r4"; make_root "${R4}"
imager_ud "${R4}/boot/firmware/user-data" yes true
cloudinit_pwauth "${R4}" yes
run_seed "${R4}"
common_asserts "${R4}" 4
chk "[4] the synthetic rootfs started from the shipped bare '!'" grep -qx "default:${SHIPPED_FIELD}:20000:0:99999:7:::" "${R4}/etc/shadow.start"
chk "[4] the typed password's hash is now default's shadow field (password SSH can work)" test "$(shadow_field "${R4}")" = "${FAKE_HASH}"
chk "[4] chpasswd -e was the mechanism" grep -qx "chpasswd -e" "${CALLS}"
nchk "[4] no authorized_keys created (no key in the seed)" test -e "$(AK_OF "${R4}")"
nchk "[4] no NO-SSH-WAY-IN warning (a password IS a way in)" logged "${R4}" "NO SSH WAY IN"
chk "[4] the password-SSH choice is reported, not changed" logged "${R4}" "Imager allowed password SSH"
chk "[4] 50-cloud-init.conf left as cloud-init wrote it" test "$(cat "${R4}/etc/ssh/sshd_config.d/50-cloud-init.conf")" = "PasswordAuthentication yes"

# ---------------------------------------------------------------------------
echo
echo "-- 5. password AND key --"
R5="${WORK}/r5"; make_root "${R5}"
imager_ud "${R5}/boot/firmware/user-data" yes true "${PUB_B}"
cloudinit_pwauth "${R5}" yes
run_seed "${R5}"
common_asserts "${R5}" 5
chk "[5] password applied" test "$(shadow_field "${R5}")" = "${FAKE_HASH}"
chk "[5] key B present exactly once" test "$(count_blob "$(AK_OF "${R5}")" "${BLOB_B}")" -eq 1
nchk "[5] no NO-SSH-WAY-IN warning" logged "${R5}" "NO SSH WAY IN"

# ---------------------------------------------------------------------------
echo
echo "-- 6. neither password nor key --"
R6="${WORK}/r6"; make_root "${R6}"
printf '#cloud-config\nhostname: elspi\nmanage_etc_hosts: true\n' > "${R6}/boot/firmware/user-data"
run_seed "${R6}"
common_asserts "${R6}" 6
chk "[6] the NO-SSH-WAY-IN warning fires" logged "${R6}" "WARNING: NO SSH WAY IN"
chk "[6] and says the touchscreen is the only way in" logged "${R6}" "reachable ONLY FROM THE TOUCHSCREEN"
nchk "[6] no authorized_keys created" test -e "$(AK_OF "${R6}")"
chk "[6] password left locked" test "$(shadow_field "${R6}")" = "${SHIPPED_FIELD}"

# The unseeded card, exactly: upstream's own template, all comments. This is
# what a "Use custom" flash leaves on the FAT partition.
R6B="${WORK}/r6b"; make_root "${R6B}"
cp "${UPSTREAM_UD}" "${R6B}/boot/firmware/user-data"
run_seed "${R6B}"
chk "[6b] upstream's template (a 'Use custom' flash): exit 0" test "${RC}" -eq 0
chk "[6b] upstream's template: the NO-SSH-WAY-IN warning fires" logged "${R6B}" "WARNING: NO SSH WAY IN"
nchk "[6b] upstream's template: no authorized_keys created" test -e "$(AK_OF "${R6B}")"

# ---------------------------------------------------------------------------
echo
echo "-- 7. malformed user-data --"
R7="${WORK}/r7"; make_root "${R7}"
printf '#cloud-config\nuser:\n  name: default\n  ssh_authorized_keys: [ "%s"\n    - : : :\n' "${PUB_A}" \
	> "${R7}/boot/firmware/user-data"
run_seed "${R7}"
chk "[7] exits 0" test "${RC}" -eq 0
chk "[7] the verdict line is written" logged "${R7}" "verdict=OK"
chk "[7] the malformed seed is reported" logged "${R7}" "is not valid YAML"
nchk "[7] nothing installed" test -e "$(AK_OF "${R7}")"
chk "[7] no key text in the log" no_secret_in_log "${R7}"
chk "[7] the NO-SSH-WAY-IN warning fires (nothing usable came through)" logged "${R7}" "NO SSH WAY IN"

# ---------------------------------------------------------------------------
echo
echo "-- 8. the seed names another account --"
R8="${WORK}/r8"; make_root "${R8}"
imager_ud "${R8}/boot/firmware/user-data" no false "${PUB_A}"
sed -i 's/^  name: default$/  name: pi/' "${R8}/boot/firmware/user-data"
run_seed "${R8}"
chk "[8] exits 0" test "${RC}" -eq 0
chk "[8] warns that the account is not 'default'" logged "${R8}" "the seed's account is 'pi', not 'default'"
nchk "[8] no key installed for default" test -e "$(AK_OF "${R8}")"

# ---------------------------------------------------------------------------
echo
echo "-- 9. an sshd drop-in that would override Imager's choice --"
R9="${WORK}/r9"; make_root "${R9}"
imager_ud "${R9}/boot/firmware/user-data" yes true
cloudinit_pwauth "${R9}" yes
printf 'PasswordAuthentication no\n' > "${R9}/etc/ssh/sshd_config.d/10-override.conf"
run_seed "${R9}"
chk "[9] exits 0" test "${RC}" -eq 0
chk "[9] the overriding drop-in is named in a WARNING" logged "${R9}" "10-override.conf sets an SSH authentication option"
chk "[9] and left alone (reported, never changed)" test "$(cat "${R9}/etc/ssh/sshd_config.d/10-override.conf")" = "PasswordAuthentication no"

# ---------------------------------------------------------------------------
# 10-12: a seed that asks for an UNLOCKED account without a password this
# image can apply. Imager never writes this (a password always comes with its
# own `passwd:`), but cloud-init honours a hand-written one, and what it does
# depends on the field the image shipped. See item 2 at the top of the script.
# The calls log is shared by every case (the last check reads all of it), so a
# case marks where its own calls start instead of truncating it.
CALLS_MARK=0
mark_calls() { CALLS_MARK="$(wc -l < "${CALLS}")"; }
new_calls_match() { tail -n +"$((CALLS_MARK + 1))" "${CALLS}" | grep -qE -- "$1"; }

unlock_ud() { # unlock_ud <file> [extra user-block line]
	{
		echo '#cloud-config'
		echo 'user:'
		echo '  name: default'
		echo '  lock_passwd: false'
		[ -z "${2:-}" ] || echo "  $2"
		echo "  ssh_authorized_keys:"
		printf '    - "%s"\n' "${PUB_A}"
	} > "$1"
}

echo
echo "-- 10. lock_passwd:false, no password, on this image's bare '!' --"
# cloud-init declined to unlock (its empty-locked pattern matches '!'), so
# the field is still the shipped '!' and there is nothing to revoke.
R10="${WORK}/r10"; make_root "${R10}"
unlock_ud "${R10}/boot/firmware/user-data"
mark_calls
run_seed "${R10}"
common_asserts "${R10}" 10
chk "[10] the declared locked state is recognised" logged "${R10}" "declared locked state holds"
chk "[10] default's field is still the bare '!'" test "$(shadow_field "${R10}")" = "${SHIPPED_FIELD}"
nchk "[10] usermod was not called (nothing to revoke)" new_calls_match '^usermod '
nchk "[10] no revocation warning" logged "${R10}" "Revoking it"

echo
echo "-- 11. an EMPTY field: cloud-init's passwd -d fallback after passwd -u refused '!' --"
# The seed carries an EMPTY hashed_passwd with lock_passwd:false. cloud-init
# calls unlock_passwd(); `passwd -u` refuses a bare '!' (exit 3, accepted), and
# cloud-init falls back to `passwd -d`: default's field is now EMPTY. That is
# a blank password, not "no password", and must be re-locked.
R11="${WORK}/r11"; make_root "${R11}" ''
unlock_ud "${R11}/boot/firmware/user-data" 'hashed_passwd: ""'
mark_calls
run_seed "${R11}"
common_asserts "${R11}" 11
chk "[11] the EMPTY field is named in a WARNING" logged "${R11}" "WARNING: the password field of default is EMPTY"
chk "[11] usermod -p ! was the mechanism" new_calls_match '^usermod -p ! default$'
chk "[11] default's field is back to the bare '!'" test "$(shadow_field "${R11}")" = "${SHIPPED_FIELD}"
chk "[11] the revocation is logged" logged "${R11}" "revoked: default now has no usable password"
nchk "[11] NOT reported as a declared locked state" logged "${R11}" "declared locked state holds"

echo
echo "-- 12. an image built before 2026-09-23: cloud-init unlocked the throwaway --"
# passwd -l's '!<hash>' did not match cloud-init's pattern, so it unlocked the
# field into the throwaway's live hash. Still revoked on such a card.
R12="${WORK}/r12"; make_root "${R12}" "${LEGACY_UNLOCKED}"
unlock_ud "${R12}/boot/firmware/user-data"
mark_calls
run_seed "${R12}"
common_asserts "${R12}" 12
chk "[12] the unlocked throwaway is named in a WARNING" logged "${R12}" "unlocked the BUILD-TIME THROWAWAY"
chk "[12] default's field is back to the bare '!'" test "$(shadow_field "${R12}")" = "${SHIPPED_FIELD}"

# ---------------------------------------------------------------------------
echo
nchk "no radio/regdom command ran (no Wi-Fi profile was seeded in any case)" \
	grep -qE '^(rfkill|nmcli|iw|raspi-config) ' "${CALLS}"

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
