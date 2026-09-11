#!/bin/bash
# Prove the field-scoped commissioned-config hash in ot-state does what
# build/2026-09-10#3 asked for, and nothing more:
#   - changing ONLY offsets[0] (any axis) leaves the file's hash UNCHANGED
#   - changing ONLY the SPINDLE axis's syncRatioNum/Den leaves it UNCHANGED
#   - the same fields on a NON-spindle axis are NOT exempt -- still DRIFT
#   - els_backlash_steps, and other commissioned geometry, still moves it
#   - the emitted line is still `<file>  sha=<16 hex>  mtime=...`
#   - a malformed or unreadable yaml fails loud, never a silently stable hash
#
#   deltas/tests/test-config-hash-contract.sh
#
# Runs anywhere with bash + python3; needs no image, no Pi, no root, and never
# touches /var/lib/reflex-config -- OT_CONFIG_DIR (a test seam ot-state itself
# defines, same pattern and same INERT-over-the-confined-key reasoning as
# OT_FLIGHT_STATUS) points the whole emitter at a tempdir fixture instead.
# Fixtures are built here, not copied from any live or mirrored machine.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OT_STATE="${HERE}/../files/ot-state"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0

# --- helpers -----------------------------------------------------------------

# Full real run of ot-state against a fixture dir, commissioned-config block
# only, one data line per *.yaml file.
config_lines() { # config_lines <fixture-dir>
	OT_CONFIG_DIR="$1" "${OT_STATE}" ot-state-v1 2>&1 \
		| sed -n '/^## commissioned config/,/^files:/p' \
		| grep -E '\.yaml  sha='
}

# The sha column for one file, out of a config_lines() capture.
sha_of() { # sha_of <config_lines output> <basename.yaml>
	printf '%s\n' "$1" | grep "^$2  " | sed -E 's/^[^ ]+  sha=([^ ]+).*/\1/'
}

expect_same() { # expect_same <desc> <a> <b>
	if [ "$2" = "$3" ]; then
		printf '  ok    %s (both %s)\n' "$1" "$2"
		PASS=$((PASS+1))
	else
		printf '  FAIL  %s\n        expected unchanged, got %s -> %s\n' "$1" "$2" "$3"
		FAIL=$((FAIL+1))
	fi
}

expect_diff() { # expect_diff <desc> <a> <b>
	if [ "$2" != "$3" ]; then
		printf '  ok    %s (%s -> %s)\n' "$1" "$2" "$3"
		PASS=$((PASS+1))
	else
		printf '  FAIL  %s\n        expected a change, hash stayed %s\n' "$1" "$2"
		FAIL=$((FAIL+1))
	fi
}

# A well-formed emitted hash: exactly 16 lowercase hex chars. The sentinels
# (UNREADABLE/NO_PYTHON3/MALFORMED) must NOT match this -- that mismatch is
# the "loud failure" property itself.
is_hex16() { printf '%s' "$1" | grep -qE '^[0-9a-f]{16}$'; }

# --- fixture: a well-formed capture, built here, not read from any mirror ---
good() { # good <dir>
	mkdir -p "$1"
	cat > "$1/Axis-0.yaml" <<'EOF'
abs_offset: 0
axis_index: 0
axis_name: X
diameter_mode: true
id_override: '0'
offsets:
- 15.456
- 0
- 0
spindleMode: false
syncRatioDen: 100
syncRatioNum: 360
transform_config:
  contributions:
  - 2
  transform_type: identity
EOF
	cat > "$1/Axis-1.yaml" <<'EOF'
abs_offset: 0
axis_index: 1
axis_name: Z
diameter_mode: false
id_override: '1'
offsets:
- 0.335
- 0
- 0
spindleMode: false
syncRatioDen: 100
syncRatioNum: 360
transform_config:
  contributions:
  - 1
  transform_type: identity
EOF
	cat > "$1/Axis-2.yaml" <<'EOF'
abs_offset: 0
axis_index: 2
axis_name: S
diameter_mode: false
id_override: '2'
offsets:
- 0
- 0
- 0
spindleMode: true
syncRatioDen: 90
syncRatioNum: 127
transform_config:
  contributions:
  - 0
  transform_type: identity
EOF
	cat > "$1/Els-0.yaml" <<'EOF'
els_backlash_steps: 484
els_cal_last_measured_steps: 404
id_override: '0'
spindle_axis_index: 2
x_axis_index: 0
z_axis_index: 1
EOF
}

echo "== fixture sanity: baseline hashes are real 16-hex digests =="
good "${WORK}/good"
BASE="$(config_lines "${WORK}/good")"
for f in Axis-0.yaml Axis-1.yaml Axis-2.yaml Els-0.yaml; do
	h="$(sha_of "${BASE}" "$f")"
	if is_hex16 "$h"; then
		printf '  ok    %s baseline hash is 16 hex (%s)\n' "$f" "$h"
		PASS=$((PASS+1))
	else
		printf '  FAIL  %s baseline hash is not 16 hex: %q\n' "$f" "$h"
		FAIL=$((FAIL+1))
	fi
done
B_AXIS0="$(sha_of "${BASE}" Axis-0.yaml)"
B_AXIS1="$(sha_of "${BASE}" Axis-1.yaml)"
B_AXIS2="$(sha_of "${BASE}" Axis-2.yaml)"
B_ELS0="$(sha_of "${BASE}" Els-0.yaml)"

echo
echo "== (a) offsets[0] is excluded, on a NON-spindle axis =="
good "${WORK}/mut-offset"
sed -i '0,/^- 15.456$/s//- 99.999/' "${WORK}/mut-offset/Axis-0.yaml"
M="$(config_lines "${WORK}/mut-offset")"
expect_same "Axis-0.yaml hash after offsets[0] 15.456 -> 99.999 (only field touched)" \
	"${B_AXIS0}" "$(sha_of "${M}" Axis-0.yaml)"

echo
echo "== (b) syncRatioNum/Den excluded ONLY on the file with spindleMode: true =="
good "${WORK}/mut-sync-spindle"
sed -i 's/^syncRatioDen: 90$/syncRatioDen: 45/' "${WORK}/mut-sync-spindle/Axis-2.yaml"
M="$(config_lines "${WORK}/mut-sync-spindle")"
expect_same "Axis-2.yaml (spindleMode: true) hash after syncRatioDen 90 -> 45" \
	"${B_AXIS2}" "$(sha_of "${M}" Axis-2.yaml)"

echo
echo "== negative control: the SAME field on a non-spindle axis is NOT exempt =="
good "${WORK}/mut-sync-nonspindle"
sed -i 's/^syncRatioDen: 100$/syncRatioDen: 45/' "${WORK}/mut-sync-nonspindle/Axis-0.yaml"
M="$(config_lines "${WORK}/mut-sync-nonspindle")"
expect_diff "Axis-0.yaml (spindleMode: false) hash after syncRatioDen 100 -> 45" \
	"${B_AXIS0}" "$(sha_of "${M}" Axis-0.yaml)"

echo
echo "== (c) els_backlash_steps is commissioned -- must still DRIFT =="
good "${WORK}/mut-backlash"
sed -i 's/^els_backlash_steps: 484$/els_backlash_steps: 999/' "${WORK}/mut-backlash/Els-0.yaml"
M="$(config_lines "${WORK}/mut-backlash")"
expect_diff "Els-0.yaml hash after els_backlash_steps 484 -> 999" \
	"${B_ELS0}" "$(sha_of "${M}" Els-0.yaml)"

echo
echo "== (d) other commissioned geometry (axis abs_offset) still DRIFTs =="
good "${WORK}/mut-geom"
sed -i 's/^abs_offset: 0$/abs_offset: 5/' "${WORK}/mut-geom/Axis-1.yaml"
M="$(config_lines "${WORK}/mut-geom")"
expect_diff "Axis-1.yaml hash after abs_offset 0 -> 5" \
	"${B_AXIS1}" "$(sha_of "${M}" Axis-1.yaml)"

echo
echo "== (e) line format is still <file>  sha=<16 hex>  mtime=... =="
# check-ot.sh itself cannot be read here (ol-control is denied); this proves
# parseability against the CONTRACT AS STATED in the build order, with an
# independently-written grep/sed pair, not against check-ot.sh's own code.
LINE="$(printf '%s\n' "${BASE}" | grep '^Els-0.yaml  ')"
EXTRACTED_FILE="$(printf '%s' "${LINE}" | sed -E 's/^([^ ]+)  sha=.*/\1/')"
EXTRACTED_SHA="$(printf '%s' "${LINE}" | sed -E 's/^[^ ]+  sha=([0-9a-f]{16})  mtime=.*/\1/')"
if [ "${EXTRACTED_FILE}" = "Els-0.yaml" ] && [ "${EXTRACTED_SHA}" = "${B_ELS0}" ]; then
	printf '  ok    grep/sed pair recovers file=%s sha=%s from: %s\n' \
		"${EXTRACTED_FILE}" "${EXTRACTED_SHA}" "${LINE}"
	PASS=$((PASS+1))
else
	printf '  FAIL  grep/sed pair could not parse the emitted line: %s\n' "${LINE}"
	FAIL=$((FAIL+1))
fi

echo
echo "== (f) malformed or unreadable yaml fails LOUD, never a silently stable hash =="
mkdir -p "${WORK}/bad"
printf 'not a yaml key line at all ???\njust garbage, no colon\n' > "${WORK}/bad/Bad-0.yaml"
printf '\xff\xfe binary garbage \x00\x01 not utf-8\n' > "${WORK}/bad/Bad-1.yaml"
touch "${WORK}/bad/Unreadable-0.yaml"
if [ "$(id -u)" -eq 0 ]; then
	printf '  --    skipping the UNREADABLE case: running as root, chmod 000 is not honoured\n'
else
	chmod 000 "${WORK}/bad/Unreadable-0.yaml"
fi
M="$(config_lines "${WORK}/bad")"

sha_bad0="$(sha_of "${M}" Bad-0.yaml)"
if [ "${sha_bad0}" = "MALFORMED" ] && ! is_hex16 "${sha_bad0}"; then
	printf '  ok    Bad-0.yaml (no top-level key) sha=%s -- loud, not hex\n' "${sha_bad0}"
	PASS=$((PASS+1))
else
	printf '  FAIL  Bad-0.yaml sha=%q -- expected MALFORMED\n' "${sha_bad0}"
	FAIL=$((FAIL+1))
fi

sha_bad1="$(sha_of "${M}" Bad-1.yaml)"
if [ "${sha_bad1}" = "MALFORMED" ] && ! is_hex16 "${sha_bad1}"; then
	printf '  ok    Bad-1.yaml (not valid utf-8) sha=%s -- loud, not hex\n' "${sha_bad1}"
	PASS=$((PASS+1))
else
	printf '  FAIL  Bad-1.yaml sha=%q -- expected MALFORMED\n' "${sha_bad1}"
	FAIL=$((FAIL+1))
fi

if [ "$(id -u)" -ne 0 ]; then
	sha_unread="$(sha_of "${M}" Unreadable-0.yaml)"
	if [ "${sha_unread}" = "UNREADABLE" ] && ! is_hex16 "${sha_unread}"; then
		printf '  ok    Unreadable-0.yaml (mode 000) sha=%s -- loud, not hex\n' "${sha_unread}"
		PASS=$((PASS+1))
	else
		printf '  FAIL  Unreadable-0.yaml sha=%q -- expected UNREADABLE\n' "${sha_unread}"
		FAIL=$((FAIL+1))
	fi
	chmod 644 "${WORK}/bad/Unreadable-0.yaml"
fi

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
