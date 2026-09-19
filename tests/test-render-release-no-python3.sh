#!/bin/bash
# render-release.sh must work on a BUILD HOST WITH NO python3.
#
#   tests/test-render-release-no-python3.sh [path/to/render-release.sh]
#
# THE BUILD THIS TEST EXISTS FOR. The 2026-09-17 image build died here, three
# hours in, at stage-elspi/11-manifest:
#
#   [03:22:19] Begin /pi-gen/stage-elspi/11-manifest/00-run.sh
#     wrote /etc/elspi-image.json (reflex lock 43ac7c5...)
#   /pi-gen/stage-elspi/11-manifest/files/render-release.sh: line 48: python3: command not found
#   FATAL: manifest has no image_release
#   FATAL: render-release.sh generate failed
#
# render-release.sh's jget() shelled out to `python3 -c`, and it ran on the
# BUILD HOST -- the pi-gen container -- not in the chroot. The container is
# built from `debian:bullseye` plus the apt list in ./Dockerfile, and that
# list carries neither python3 nor jq. The image's OWN rootfs has python3;
# the thing assembling it does not. 00-run.sh already knew that (it guards
# its own JSON check with `command -v python3`); render-release.sh did not.
#
# HOW THIS TEST MAKES THAT FAILURE REPRODUCIBLE ON ANY DEV BOX, which all
# have python3: it runs render-release.sh under a PATH containing NOTHING but
# a tmpdir of symlinks to a hand-picked set of coreutils and text tools --
# and no python3, no python, no jq. That is a fair stand-in for the
# container: the ordinary shell tools ARE there, the interpreter is NOT. A
# test that emptied PATH entirely would pass for the wrong reason (the script
# could not find `grep` either).
#
# AND WHAT IT PINS: byte-identity. /etc/elspi-release is consumed on the
# device by the UI and by order 2026-09-14#6's reflex updater, both of which
# `.` the file. Making it render without python3 is only half the job; the
# bytes have to be the SAME bytes. EXPECTED below is literally the output of
# the PRE-CHANGE, python3-based render-release.sh run WITH python3 on the
# fixture manifest below. Reproduce it at the commit before this test landed:
#
#   git show 86e1e481:stage-elspi/11-manifest/files/render-release.sh > /tmp/old.sh
#   mkdir -p /tmp/fx/etc && <the MANIFEST heredoc below> > /tmp/fx/etc/elspi-image.json
#   bash /tmp/old.sh generate /tmp/fx && cat /tmp/fx/etc/elspi-release
#
# The fixture manifest is NOT tests/make-fixture.sh's. make-fixture.sh calls
# render-release.sh itself (deliberately -- see its own note), so using it
# here would compare the code under test against itself. This one is written
# out by hand, in the shape 11-manifest/00-run.sh actually emits, and it
# carries the shapes a JSON reader has to survive even though no flat key
# maps to them: nested objects, arrays of strings, a bare `true`, an
# unquoted integer, and string values containing spaces, dots and
# parentheses.
#
# It also carries a DECOY top-level key literally named
# "runtime_versions.python". A reader that flattens nested paths by joining
# them with "." cannot tell that apart from runtime_versions -> python, and
# the decoy wins -- a wrong ELSPI_PYTHON, written silently. `python3 -c` with
# d['runtime_versions']['python'] could never be fooled that way, so the
# replacement must not be either.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${1:-${HERE}/../stage-elspi/11-manifest/files/render-release.sh}"

if [ ! -f "${SCRIPT}" ]; then
	echo "UNKNOWN: no render-release.sh at ${SCRIPT}. NOT a pass."
	exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ok    $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# --- the fixture manifest ---------------------------------------------------
mkfixture() { # mkfixture <rootfs-dir>
	mkdir -p "$1/etc"
	cat > "$1/etc/elspi-image.json" <<'JSON'
{
  "image": "elspi",
  "arch": "armhf",
  "release": "trixie",
  "built_utc": "2026-09-17T03:22:19Z",
  "pi_gen_upstream_pin": "314262c",
  "reflex_lock_commit": "43ac7c5e1b2d4f6a8c0e9d7b3a5f1c2e4d6b8a09",
  "image_build_sha": "86e1e481d2d4a41b93e3e06f686dd67c35a9049e",
  "image_release": 1,

  "runtime_versions": {
    "python": "Python 3.13.5",
    "kivy": "2.3.1",
    "uv": "uv 0.4.18 (a1b2c3d4 2026-09-01)"
  },

  "runtime_versions.python": "DECOY-MUST-NOT-WIN",

  "service_user": "default",
  "runs_as_root": false,

  "paths": {
    "venv": "/opt/reflex-venv",
    "app_parent": "/home/default/projects",
    "app_root": "/home/default/projects/reflex",
    "config_dir": "/var/lib/reflex-config",
    "log_dir": "/var/log/reflex"
  },

  "drm": {
    "default_mode": "first-opener",
    "modes": ["first-opener", "cap-sys-admin"],
    "switcher": "/usr/local/sbin/elspi-drm-mode",
    "verified_on_hardware": true
  },

  "cannot_be_verified_without_hardware": [
    "DRM master acquisition (no GPU in the harness)",
    "the touchscreen"
  ]
}
JSON
}

# --- the golden bytes -------------------------------------------------------
# ELSPI_IMAGE_RELEASE is UNQUOTED and every other value is double-quoted;
# that asymmetry is the contract (render-release.sh's own header says why),
# so it is part of what is byte-compared here rather than something a
# tolerant comparison could sand off.
cat > "${WORK}/expected" <<'EXPECTED'
ELSPI_IMAGE_RELEASE=1
ELSPI_IMAGE_BUILD="86e1e481d2d4a41b93e3e06f686dd67c35a9049e"
ELSPI_IMAGE_DATE="2026-09-17T03:22:19Z"
ELSPI_REFLEX_COMMIT="43ac7c5e1b2d4f6a8c0e9d7b3a5f1c2e4d6b8a09"
ELSPI_PYTHON="Python 3.13.5"
ELSPI_KIVY="2.3.1"
ELSPI_UV="uv 0.4.18 (a1b2c3d4 2026-09-01)"
EXPECTED

# --- a PATH with the shell tools but NO interpreter -------------------------
# Symlinks, not copies, and resolved through `command -v` so this works on a
# box that puts them in /usr/bin, /bin or anywhere else on the real PATH.
#
# The list is deliberately GENEROUS. The point being proved is "does not need
# python3", not "does not shell out at all" -- an implementation built on sed
# or awk is a legitimate answer to the same problem and must be able to pass.
STUB="${WORK}/bin"
mkdir -p "${STUB}"
MISSING=""
for c in bash sh cat printf echo sed grep awk tr cut head tail sort wc \
         mkdir rmdir rm cp mv ln chmod ls test env dirname basename \
         id date mktemp find stat od; do
	p="$(command -v "${c}" 2>/dev/null)" || { MISSING="${MISSING} ${c}"; continue; }
	ln -sf "${p}" "${STUB}/${c}"
done
if [ -n "${MISSING}" ]; then
	echo "  note  not on this box, so not in the stub PATH:${MISSING}"
fi

# The test is worthless if the restricted PATH still reaches an interpreter.
# Assert that, rather than assume it.
for interp in python3 python python2 jq; do
	if PATH="${STUB}" command -v "${interp}" >/dev/null 2>&1; then
		echo "UNKNOWN: ${interp} is still reachable on the restricted PATH."
		echo "         This test cannot prove anything. NOT a pass."
		exit 2
	fi
done
ok "the restricted PATH reaches no python3, python, python2 or jq"

# `env -i` as well as the PATH override: a stray PYTHONHOME/BASH_ENV in the
# caller's environment must not be able to change what the script under test
# does, and neither must a PATH re-export from a startup file.
run_restricted() { # run_restricted <mode> <rootfs>
	/usr/bin/env -i PATH="${STUB}" HOME="${WORK}" \
		/bin/bash "${SCRIPT}" "$1" "$2"
}

# --- 1. generate, with python3 on PATH, must match the golden ---------------
# This half is what makes the golden falsifiable: if a future edit changes the
# rendering for everyone, this goes red too, not just the no-python3 half.
R1="${WORK}/r1"
mkfixture "${R1}"
if bash "${SCRIPT}" generate "${R1}" >"${WORK}/gen1.log" 2>&1; then
	if cmp -s "${R1}/etc/elspi-release" "${WORK}/expected"; then
		ok "generate WITH python3 on PATH produces the expected bytes"
	else
		bad "generate WITH python3 on PATH produced different bytes:"
		diff -u "${WORK}/expected" "${R1}/etc/elspi-release" | sed 's/^/        /'
	fi
else
	bad "generate WITH python3 on PATH exited non-zero:"
	sed 's/^/        /' "${WORK}/gen1.log"
fi

# --- 2. generate, with NO python3 anywhere on PATH --------------------------
# THE REGRESSION TEST. Before the fix this is the 2026-09-17 build failure,
# reproduced in a second instead of three hours.
R2="${WORK}/r2"
mkfixture "${R2}"
if run_restricted generate "${R2}" >"${WORK}/gen2.log" 2>&1; then
	ok "generate exits 0 with no python3 on PATH"
	if [ -f "${R2}/etc/elspi-release" ]; then
		if cmp -s "${R2}/etc/elspi-release" "${WORK}/expected"; then
			ok "generate with no python3 produces BYTE-IDENTICAL output"
		else
			bad "generate with no python3 produced different bytes:"
			diff -u "${WORK}/expected" "${R2}/etc/elspi-release" | sed 's/^/        /'
		fi
	else
		bad "generate with no python3 wrote no ${R2}/etc/elspi-release"
	fi
else
	bad "generate exited non-zero with no python3 on PATH:"
	sed 's/^/        /' "${WORK}/gen2.log"
	bad "generate with no python3 produces BYTE-IDENTICAL output (did not run)"
fi

# Nothing the script printed may mention a missing interpreter, even on a
# path that happened to exit 0 -- that string in a build log is the bug.
if grep -qE 'python3?: (command )?not found' "${WORK}/gen2.log"; then
	bad "the no-python3 run still printed a 'python3: command not found':"
	grep -nE 'python3?: (command )?not found' "${WORK}/gen2.log" | sed 's/^/        /'
else
	ok "the no-python3 run printed no 'python3: command not found'"
fi

# --- 3. validate must share the extraction, so it must work too -------------
# validate is the half tests/self-test.sh and the booted harness lean on. It
# reads the SAME manifest through the SAME mapping; if the fix only covered
# generate, the two would drift and this catches it.
if run_restricted validate "${R2}" >"${WORK}/val.log" 2>&1; then
	ok "validate passes on that output with no python3 on PATH"
else
	bad "validate failed with no python3 on PATH:"
	sed 's/^/        /' "${WORK}/val.log"
fi

# validate must still be able to go RED without python3 -- a check that can
# only pass is not a check. Break the flat file's agreement with the manifest.
R3="${WORK}/r3"
mkfixture "${R3}"
run_restricted generate "${R3}" >/dev/null 2>&1
if [ ! -f "${R3}/etc/elspi-release" ]; then
	# Guarded, because "validate went red" is worthless evidence when the
	# thing it went red about is a file generate never managed to write.
	bad "cannot exercise the disagreement mutation: generate wrote nothing"
elif ! sed -i 's|^ELSPI_REFLEX_COMMIT=.*|ELSPI_REFLEX_COMMIT="deadbeef"|' \
		"${R3}/etc/elspi-release"; then
	bad "cannot exercise the disagreement mutation: sed failed"
elif run_restricted validate "${R3}" >"${WORK}/val2.log" 2>&1; then
	bad "validate stayed GREEN with no python3 on a flat file that disagrees"
	bad "      with the manifest -- it is not reading the manifest at all"
else
	ok "validate goes red with no python3 when the flat file disagrees"
fi

# --- 4. the missing-manifest path must still be the loud one ----------------
# Not "python3 not found", and not a silently empty release file.
R4="${WORK}/r4"
mkdir -p "${R4}/etc"
if run_restricted generate "${R4}" >"${WORK}/gen4.log" 2>&1; then
	bad "generate exited 0 with no manifest at all"
else
	if grep -q "missing -- write the manifest first" "${WORK}/gen4.log" &&
	   ! grep -qE 'python3?: (command )?not found' "${WORK}/gen4.log"; then
		ok "generate refuses a missing manifest with its own message"
	else
		bad "generate refused a missing manifest, but not with its own message:"
		sed 's/^/        /' "${WORK}/gen4.log"
	fi
fi

# --- 5. a manifest missing a MAPPED key must be a named FATAL ---------------
# This is the shape the 2026-09-17 log showed ("FATAL: manifest has no
# image_release") arriving for the WRONG reason. It must still arrive for the
# right one, and it must name the key.
R5="${WORK}/r5"
mkfixture "${R5}"
sed -i 's/^  "image_release": 1,$/  "image_release_TYPO": 1,/' "${R5}/etc/elspi-image.json"
if run_restricted generate "${R5}" >"${WORK}/gen5.log" 2>&1; then
	bad "generate exited 0 on a manifest with no image_release"
else
	# The `! grep python3` half is load-bearing: against the PRE-CHANGE
	# script this message appeared for entirely the wrong reason -- jget
	# failed because the interpreter was absent, not because the key was.
	if grep -q "FATAL: manifest has no image_release" "${WORK}/gen5.log" &&
	   ! grep -qE 'python3?: (command )?not found' "${WORK}/gen5.log"; then
		ok "generate names the missing key (FATAL: manifest has no image_release)"
	else
		bad "generate failed but did not name the missing key:"
		sed 's/^/        /' "${WORK}/gen5.log"
	fi
fi

# --- 6. every mapped key is actually rendered -------------------------------
# The mutation this exists for: drop one key from the extraction and the
# byte-compare above catches it -- but only if the byte-compare is reached.
# This asserts the key SET independently so a change that shortens the file
# is named, not just diffed.
for k in ELSPI_IMAGE_RELEASE ELSPI_IMAGE_BUILD ELSPI_IMAGE_DATE \
         ELSPI_REFLEX_COMMIT ELSPI_PYTHON ELSPI_KIVY ELSPI_UV; do
	if grep -q "^${k}=" "${R2}/etc/elspi-release" 2>/dev/null; then
		ok "${k} is present in the no-python3 rendering"
	else
		bad "${k} is MISSING from the no-python3 rendering"
	fi
done

# --- 7. the string decoder -------------------------------------------------
# The mapped values in the fixture above are all plain ASCII, so nothing so
# far would notice if the replacement stopped decoding JSON's backslash
# escapes and shipped the raw two-character source instead. `python3 -c
# print(json.load(...))` decoded them; whatever replaced it has to decode
# them the same, to the same BYTES -- é is two bytes of UTF-8 in the
# file the device reads, not six characters of source.
#
# Generate-only on purpose: a decoded tab and a decoded double quote put this
# rendering outside the KEY=VALUE shape `validate` enforces. That is not a
# bug in either one -- it is a manifest nobody would write -- but it is
# exactly the input that pins the decoder, so it is checked for the bytes it
# produces and not for whether it validates.
DEC="${WORK}/dec"
mkdir -p "${DEC}/etc"
cat > "${DEC}/etc/elspi-image.json" <<'JSON'
{
  "built_utc": "quote:\" backslash:\\ slash:\/ tab:\tend",
  "reflex_lock_commit": "Aéz",
  "image_build_sha": "plain",
  "image_release": 0,
  "runtime_versions.python": "DECOY-MUST-NOT-WIN",
  "runtime_versions": {
    "python": "Python 3.13.5 (main)",
    "kivy": "2.3.1",
    "uv": "uv 0.4.18"
  }
}
JSON

# Built with printf and $'...' rather than a heredoc so the tab and the
# e-acute are visible as what they are instead of being an invisible byte
# somebody's editor will helpfully clean up.
{
	printf '%s\n' 'ELSPI_IMAGE_RELEASE=0'
	printf '%s\n' 'ELSPI_IMAGE_BUILD="plain"'
	printf '%s\n' 'ELSPI_IMAGE_DATE="quote:" backslash:\ slash:/ tab:'$'\t''end"'
	printf '%s\n' 'ELSPI_REFLEX_COMMIT="A'$'é''z"'
	printf '%s\n' 'ELSPI_PYTHON="Python 3.13.5 (main)"'
	printf '%s\n' 'ELSPI_KIVY="2.3.1"'
	printf '%s\n' 'ELSPI_UV="uv 0.4.18"'
} > "${WORK}/dec-expected"

if run_restricted generate "${DEC}" >"${WORK}/dec.log" 2>&1; then
	if cmp -s "${DEC}/etc/elspi-release" "${WORK}/dec-expected"; then
		ok "backslash and \\uXXXX escapes decode to the same bytes as before"
	else
		bad "escape decoding drifted. expected vs got, as bytes:"
		diff -u <(od -c "${WORK}/dec-expected") <(od -c "${DEC}/etc/elspi-release") \
			| sed 's/^/        /'
	fi
else
	bad "generate failed on the escape-decoding fixture:"
	sed 's/^/        /' "${WORK}/dec.log"
fi

# Named separately from the byte-compare so a regression here reads as what
# it is rather than as "some bytes moved".
#
# Matched as a LINE, not by sourcing the file: this fixture's
# ELSPI_IMAGE_DATE carries a decoded double quote, so `. ` on it is a syntax
# error and every variable would come back empty -- which would make this
# assertion fail for a reason that has nothing to do with the decoy.
DEC_PY="$(grep -c '^ELSPI_PYTHON="Python 3\.13\.5 (main)"$' "${DEC}/etc/elspi-release" 2>/dev/null || true)"
if [ "${DEC_PY}" = "1" ]; then
	ok "the literal 'runtime_versions.python' decoy did not win the lookup"
else
	bad "ELSPI_PYTHON is not the nested runtime_versions.python value:"
	grep -n '^ELSPI_PYTHON=' "${DEC}/etc/elspi-release" 2>/dev/null | sed 's/^/        /'
	bad "      a top-level key named 'runtime_versions.python' aliased it"
fi

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
