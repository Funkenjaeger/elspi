#!/bin/bash
# Prove tools/make-os-list.sh both works and can go red.
#
#   tests/test-os-list.sh
#
# The numbers this script checks are the ones Imager verifies the card against
# while it writes. If `extract_sha256` is wrong the flash fails at the end of a
# 7.5 GB write with a checksum error and no clue which side is wrong; if
# `init_format` is wrong Imager silently skips every customisation page and you
# get an unseeded card. Neither failure names its own cause, so both get a test.
#
# Two halves, and only the pair means anything:
#
#   GREEN  run the generator on a small synthetic .xz and check every measured
#          field against a value computed INDEPENDENTLY here -- a second
#          sha256sum and a stat, not the generator's own output re-read.
#   RED    mutate one thing at a time and require a failure. A generator whose
#          validator cannot reject a corrupted hash is not validating anything.
#
# Runs on any Linux box in seconds. No pi-gen build, no Docker, no image.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
GEN="${REPO}/tools/make-os-list.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

# The commit this build order's premise was verified against: master before
# the OS_LIST_URL / file:// NOTE-guard-widening fix. Used below to prove the
# guard-widening and --url-plumbing cases are actually RED beforehand, not
# merely GREEN now by coincidence.
BASE_SHA="3de42c792cacf0106b7f2f0b25cbecd1678cca2e"

PY=""
for c in python3 python; do
	if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "${PY}" ]; then
	echo "UNKNOWN: no python3 -- cannot read the JSON back. NOT a pass."
	exit 2
fi
[ -x "${GEN}" ] || { echo "UNKNOWN: ${GEN} is missing or not executable. NOT a pass."; exit 2; }

# jget <file> <dotted.path> -- prints the value, or exits 1 with nothing
jget() {
	"${PY}" - "$1" "$2" <<-'PY'
		import json, sys
		doc = json.load(open(sys.argv[1], encoding="utf-8"))
		cur = doc
		for part in sys.argv[2].split("."):
		    cur = cur[int(part)] if part.isdigit() else cur[part]
		print(json.dumps(cur) if isinstance(cur, (list, dict)) else cur)
	PY
}

ok()  { echo "  OK    $1"; PASSED=$((PASSED+1)); }
bad() { echo "  FAIL  $1"; FAILED=$((FAILED+1)); }

eq() { # eq <label> <expected> <actual>
	if [ "$2" = "$3" ]; then ok "$1 = $2"; else bad "$1: expected [$2], got [$3]"; fi
}

# expect_red <label> <shell...> -- the command MUST fail
expect_red() {
	local label="$1"; shift
	if ( "$@" ) >"${WORK}/red.out" 2>&1; then
		echo "  MISS  stayed GREEN: ${label}"
		echo "        ^ this property is NOT actually enforced."
		sed 's/^/           /' "${WORK}/red.out"
		FAILED=$((FAILED+1))
	else
		ok "went red: ${label}"
		sed -n '$p' "${WORK}/red.out" | sed 's/^/           /'
	fi
}

# ---------------------------------------------------------------------------
# the fixture: a small, cheap stand-in for a 1.3 GB / 7.5 GB pair
# ---------------------------------------------------------------------------
FIX="${WORK}/fixture"
mkdir -p "${FIX}"
RAW="${WORK}/raw.bin"
IMG="${FIX}/image_2026-09-13-elspi.img.xz"
INFO="${FIX}/2026-09-13-elspi.info"

head -c 4M /dev/urandom > "${RAW}"
xz -0 -T0 -c "${RAW}" > "${IMG}"
# The two lines scripts/common's update_issue() writes into /etc/rpi-issue,
# which export-image/05-finalise/01-run.sh copies to <img>.info.
{
	echo "Raspberry Pi reference 2026-09-13"
	echo "Generated using pi-gen, https://github.com/RPi-Distro/pi-gen, 0f1e2d3c4b5a69788796a5b4c3d2e1f009182736, stage-elspi"
} > "${INFO}"

# computed here, independently of the generator
EXP_RAW_SIZE="$(stat -c %s "${RAW}")"
EXP_RAW_SHA="$(sha256sum < "${RAW}" | cut -d' ' -f1)"
EXP_XZ_SIZE="$(stat -c %s "${IMG}")"
EXP_XZ_SHA="$(sha256sum < "${IMG}" | cut -d' ' -f1)"

echo "== green: the generator on a synthetic .xz =="
OUT="${WORK}/os_list.json"
if ! "${GEN}" "${IMG}" --out "${OUT}" >"${WORK}/gen.out" 2>&1; then
	echo "  BROKEN the generator FAILED on the fixture, so no mutation below"
	echo "         proves anything. Output:"
	sed 's/^/           /' "${WORK}/gen.out"
	exit 1
fi
ok "generator exited 0 and wrote ${OUT##*/}"

eq "image_download_size"   "${EXP_XZ_SIZE}"  "$(jget "${OUT}" os_list.0.image_download_size)"
eq "image_download_sha256" "${EXP_XZ_SHA}"   "$(jget "${OUT}" os_list.0.image_download_sha256)"
eq "extract_size"          "${EXP_RAW_SIZE}" "$(jget "${OUT}" os_list.0.extract_size)"
eq "extract_sha256"        "${EXP_RAW_SHA}"  "$(jget "${OUT}" os_list.0.extract_sha256)"

# The key the whole --repo path exists for.
eq "init_format" "cloudinit-rpi" "$(jget "${OUT}" os_list.0.init_format)"
# armhf: 32-bit tags only, or Imager offers the image for a kernel it cannot run.
eq "devices" '["pi5-32bit", "pi4-32bit", "pi3-32bit", "pi2-32bit", "pi1-32bit"]' \
             "$(jget "${OUT}" os_list.0.devices)"
eq "release_date" "2026-09-13" "$(jget "${OUT}" os_list.0.release_date)"
# Default url is the image where it sits, as a file:// URL.
eq "url" "file://${IMG}" "$(jget "${OUT}" os_list.0.url)"
# The build sha comes out of line 2, field 3, of the sibling .info.
eq "name" "elspi 2026-09-13 (0f1e2d3)" "$(jget "${OUT}" os_list.0.name)"
# Without this the Device step comes up empty and no entry can match.
if [ "$(jget "${OUT}" imager.devices | tr -cd '{' | wc -c)" -gt 0 ]; then
	ok "imager block carries devices"
else
	bad "imager block has no devices -- Imager's Device step would be empty"
fi

echo
echo "== green: --url overrides for a published release =="
OUT2="${WORK}/os_list.published.json"
if "${GEN}" "${IMG}" --url "https://example.invalid/elspi/image.img.xz" --out "${OUT2}" >/dev/null 2>&1; then
	eq "url (--url)" "https://example.invalid/elspi/image.img.xz" "$(jget "${OUT2}" os_list.0.url)"
	eq "hashes unchanged by --url" "${EXP_RAW_SHA}" "$(jget "${OUT2}" os_list.0.extract_sha256)"
else
	bad "--url run failed"
fi

echo
echo "== green: --url is written verbatim (build order's literal case) =="
OUT2B="${WORK}/os_list.explicit-url.json"
if "${GEN}" "${IMG}" --url "https://example.invalid/os_list.json" --out "${OUT2B}" >/dev/null 2>&1; then
	eq "url (--url, verbatim)" "https://example.invalid/os_list.json" "$(jget "${OUT2B}" os_list.0.url)"
else
	bad "--url https://example.invalid/os_list.json run failed"
fi

# ---------------------------------------------------------------------------
echo
echo "== red: each of these MUST fail =="

# 1. the validator itself. Corrupt a hash in the written file and re-run the
#    same comparison the green half made: it has to reject it.
cp "${OUT}" "${WORK}/mutated.json"
"${PY}" - "${WORK}/mutated.json" <<-'PY'
	import json, sys
	p = sys.argv[1]
	doc = json.load(open(p, encoding="utf-8"))
	h = doc["os_list"][0]["extract_sha256"]
	# flip one hex digit -- the smallest corruption that still parses
	doc["os_list"][0]["extract_sha256"] = ("1" if h[0] != "1" else "2") + h[1:]
	open(p, "w", encoding="utf-8", newline="\n").write(json.dumps(doc, indent=2) + "\n")
PY
check_extract_sha() { # the green half's assertion, as a runnable check
	[ "$(jget "$1" os_list.0.extract_sha256)" = "${EXP_RAW_SHA}" ]
}
expect_red "extract_sha256 corrupted by one hex digit" check_extract_sha "${WORK}/mutated.json"
# and prove the same check is GREEN on the unmutated file, or it proves nothing
if check_extract_sha "${OUT}"; then
	ok "the same check passes the unmutated file"
else
	bad "the check fails the unmutated file too -- it is not measuring the mutation"
fi

# 2. a missing image
expect_red "missing image file" "${GEN}" "${WORK}/does-not-exist.img.xz" --out "${WORK}/never.json"
[ -e "${WORK}/never.json" ] && bad "it wrote a JSON anyway" || ok "no JSON written for a missing image"

# 3. an unreadable image
UNREAD="${WORK}/unreadable.img.xz"
cp "${IMG}" "${UNREAD}"
chmod 000 "${UNREAD}"
if [ -r "${UNREAD}" ]; then
	echo "  UNKNOWN chmod 000 still readable (running as root?) -- unreadable case not tested"
else
	expect_red "unreadable image" "${GEN}" "${UNREAD}" --out "${WORK}/never2.json"
fi
chmod 644 "${UNREAD}"

# 4. something that is not an .img.xz
NOTXZ="${WORK}/image_2026-09-13-elspi.img"
head -c 1024 /dev/urandom > "${NOTXZ}"
expect_red "not an .img.xz" "${GEN}" "${NOTXZ}" --out "${WORK}/never3.json"

# 5. a truncated .xz -- must not produce a confident half-image hash
TRUNC="${WORK}/image_2026-09-13-trunc.img.xz"
head -c "$(( EXP_XZ_SIZE / 2 ))" "${IMG}" > "${TRUNC}"
expect_red "truncated .xz stream" "${GEN}" "${TRUNC}" --out "${WORK}/never4.json"

# 6. an imager block with no devices. Run a COPY of the generator beside a
#    broken block so the repo's own block is never touched.
SANDBOX="${WORK}/sandbox"
mkdir -p "${SANDBOX}"
cp "${GEN}" "${SANDBOX}/make-os-list.sh"
echo '{"latest_version": "2.0.11.1", "url": "https://www.raspberrypi.com/software/", "devices": []}' \
	> "${SANDBOX}/os_list.imager-block.json"
expect_red "imager block with an empty devices list" \
	"${SANDBOX}/make-os-list.sh" "${IMG}" --out "${WORK}/never5.json"

# 7. a bad --url scheme
expect_red "--url with an unsupported scheme" \
	"${GEN}" "${IMG}" --url "ftp://example.invalid/x.img.xz" --out "${WORK}/never6.json"

echo
echo "== seen-red: the file:// NOTE guard must fire for ANY default URL, not just /mnt =="
# A build-host-shaped absolute path: under \$WORK, itself under \$TMPDIR (/tmp
# or /home -- never /mnt). The OLD guard (base :146, /mnt/[a-z]/* only) would
# have matched nothing here; that is the defect this build fixes.
DSERVER_DIR="${WORK}/buildhost-shaped/home/builder"
mkdir -p "${DSERVER_DIR}"
case "${DSERVER_DIR}" in
	/mnt/*) echo "  UNKNOWN fixture landed under /mnt -- TMPDIR is Windows-mounted here"; exit 2 ;;
esac
DSERVER_IMG="${DSERVER_DIR}/image_2026-09-13-elspi.img.xz"
cp "${IMG}" "${DSERVER_IMG}"

NOTE_OUT="${WORK}/note.out"
"${GEN}" "${DSERVER_IMG}" --out "${WORK}/note.json" >"${NOTE_OUT}" 2>&1
if grep -q "^NOTE:" "${NOTE_OUT}"; then
	ok "current make-os-list.sh prints a NOTE for a default file:// URL on a non-/mnt path"
else
	bad "current make-os-list.sh stayed silent for ${DSERVER_IMG} -- the guard did not widen"
	sed 's/^/           /' "${NOTE_OUT}"
fi

# Prove RED: the identical case against the BASE SHA's generator must print
# nothing at all, since base :146 only matches /mnt/[a-z]/*.
if git -C "${REPO}" cat-file -e "${BASE_SHA}" 2>/dev/null; then
	BASE_GEN="${WORK}/base-make-os-list.sh"
	git -C "${REPO}" show "${BASE_SHA}:tools/make-os-list.sh" > "${BASE_GEN}"
	chmod +x "${BASE_GEN}"
	cp "${REPO}/tools/os_list.imager-block.json" "${WORK}/os_list.imager-block.json"
	BASE_NOTE_OUT="${WORK}/base-note.out"
	"${BASE_GEN}" "${DSERVER_IMG}" --out "${WORK}/base-note.json" >"${BASE_NOTE_OUT}" 2>&1
	if grep -q "^NOTE:" "${BASE_NOTE_OUT}"; then
		bad "RED PROOF FAILED: base SHA ${BASE_SHA} ALSO printed a NOTE for a non-/mnt path -- the premise (guard only matches /mnt/[a-z]/*) does not hold here"
		sed 's/^/           /' "${BASE_NOTE_OUT}"
	else
		ok "RED proven: base SHA ${BASE_SHA}'s make-os-list.sh prints NOTHING for the same non-/mnt case"
	fi
else
	echo "  UNKNOWN base SHA ${BASE_SHA} not reachable from this clone -- skipping RED proof"
fi

echo
echo "== static: build-elspi.sh's make-os-list.sh invocation carries --url plumbing =="
# check_url_plumbing <path-to-build-elspi.sh> -- a static grep, not an
# execution: build-elspi.sh needs docker and a real pi-gen build to run, which
# is out of bounds for this test.
check_url_plumbing() {
	awk '
		/make-os-list\.sh/ { found_call=1 }
		found_call && /--url/ { found_url=1 }
		END { exit(found_url ? 0 : 1) }
	' "$1"
}
if check_url_plumbing "${REPO}/build-elspi.sh"; then
	ok "current build-elspi.sh: make-os-list.sh invocation carries --url plumbing"
else
	bad "current build-elspi.sh has no --url plumbing to make-os-list.sh"
fi
if git -C "${REPO}" cat-file -e "${BASE_SHA}" 2>/dev/null; then
	BASE_BUILD="${WORK}/base-build-elspi.sh"
	git -C "${REPO}" show "${BASE_SHA}:build-elspi.sh" > "${BASE_BUILD}"
	expect_red "base SHA build-elspi.sh has no --url plumbing (static grep)" \
		check_url_plumbing "${BASE_BUILD}"
else
	echo "  UNKNOWN base SHA ${BASE_SHA} not reachable from this clone -- skipping RED proof"
fi

echo
echo "RESULT: ${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ] || exit 1
