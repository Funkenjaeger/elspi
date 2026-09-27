#!/bin/bash
# Prove docs/swd-first-load.md stays honest against what this image actually
# bakes, and that it can go red.
#
#   tests/test-swd-doc.sh
#
# The doc's whole premise is "derive the package list from the firmware-dev
# substage (stage-elspi-pkgs/02-firmware-dev), never retype it from the reflex
# page" and "no apt step, because it's already installed". Both of those
# claims rot silently: the substage's lists can gain or lose a package with
# nobody touching this doc, and a future edit could reintroduce an `apt install`
# line by copying from the reflex page again. This test reads the substage's
# lists as the source of truth and checks the doc against them, not the other
# way round.
#
# THE LISTS ARE READ THE WAY PI-GEN READS THEM (build.sh:8-37): every
# NN-packages-nr and NN-packages file in the substage, each through
# scripts/remove-comments.sed (which also drops trailing comments and joins
# lines), split into words. Until 2026-09-27 this test read 00-packages alone,
# line by line, and went red when c2f1902 (2026-09-26) moved gcc-arm-none-eabi
# into 00-packages-nr for --no-install-recommends, though the image still
# installs it.
#
# It also gates the placeholder contract: the physical half must stay a named
# placeholder with no pin numbers, connector names, or board-rev claims in it
# -- those are the operator's, from the bench, not something to guess into a doc.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
cd "${REPO}" || exit 2

PKG_DIR="${PKG_DIR:-stage-elspi-pkgs/02-firmware-dev}"
SED="scripts/remove-comments.sed"
DOC="docs/swd-first-load.md"
MKDOCS="mkdocs.yml"

PASS=0
FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -d "${PKG_DIR}" ]  || { echo "UNKNOWN: ${PKG_DIR} missing. NOT a pass."; exit 2; }
[ -r "${SED}" ]      || { echo "UNKNOWN: ${SED} missing. NOT a pass."; exit 2; }
[ -r "${DOC}" ]      || { echo "UNKNOWN: ${DOC} missing. NOT a pass."; exit 2; }
[ -r "${MKDOCS}" ]   || { echo "UNKNOWN: ${MKDOCS} missing. NOT a pass."; exit 2; }

# The packages this image actually bakes in: every list pi-gen installs from the
# substage, read as pi-gen reads it (see the header).
mapfile -t PKG_FILES < <(find "${PKG_DIR}" -maxdepth 1 -type f -regex '.*/[0-9][0-9]-packages\(-nr\)?' | LC_ALL=C sort)
if [ "${#PKG_FILES[@]}" -eq 0 ]; then
	echo "UNKNOWN: no NN-packages or NN-packages-nr file in ${PKG_DIR}. NOT a pass."
	exit 2
fi
PKG_LISTS="${PKG_DIR}/{$(printf '%s,' "${PKG_FILES[@]##*/}" | sed 's/,$//')}"
PACKAGES=()
for f in "${PKG_FILES[@]}"; do
	read -r -a words <<< "$(sed -f "${SED}" < "${f}")"
	PACKAGES+=("${words[@]}")
done
if [ "${#PACKAGES[@]}" -eq 0 ]; then
	echo "UNKNOWN: parsed zero packages out of ${PKG_LISTS}. NOT a pass."
	exit 2
fi

in_packages() { # in_packages <name>
	local n="$1" p
	for p in "${PACKAGES[@]}"; do [ "${p}" = "${n}" ] && return 0; done
	return 1
}

# ---------------------------------------------------------------------------
# (a) every toolchain package the doc names is in the substage's lists.
#
# The doc is required to name its packages as their own bullet line, exactly
# `- \`pkgname\`` -- anchored so this cannot accidentally match a filename or
# a command mentioned elsewhere in the prose (provision.sh, modbus-flash.py,
# etc). That is the doc's own convention (see docs/swd-first-load.md), not a
# general markdown-parsing exercise.
# ---------------------------------------------------------------------------
echo "== (a) every toolchain package the doc names is in ${PKG_LISTS} =="
mapfile -t DOC_NAMED < <(grep -oE '^- `[a-zA-Z0-9+.-]+`$' "${DOC}" | sed -E 's/^- `(.*)`$/\1/')
if [ "${#DOC_NAMED[@]}" -eq 0 ]; then
	bad "doc names zero packages via the '- \`pkg\`' convention -- nothing to check"
else
	A_OK=1
	for name in "${DOC_NAMED[@]}"; do
		if in_packages "${name}"; then
			ok "doc names '${name}', present in ${PKG_LISTS}"
		else
			bad "doc names '${name}', which ${PKG_LISTS} do NOT list"
			A_OK=0
		fi
	done
	[ "${A_OK}" -eq 1 ] || true
fi

# ---------------------------------------------------------------------------
# (b) the doc contains no apt install / apt-get install line.
# ---------------------------------------------------------------------------
echo "== (b) no apt install / apt-get install line in the doc =="
if grep -qiE 'apt(-get)?[[:space:]]+install' "${DOC}"; then
	bad "doc contains an apt install / apt-get install line"
	grep -niE 'apt(-get)?[[:space:]]+install' "${DOC}" | sed 's/^/        /'
else
	ok "no apt install / apt-get install line found"
fi

# ---------------------------------------------------------------------------
# (c) mkdocs.yml nav names swd-first-load.md.
# ---------------------------------------------------------------------------
echo "== (c) mkdocs.yml nav names swd-first-load.md =="
if grep -qE 'swd-first-load\.md' "${MKDOCS}"; then
	ok "mkdocs.yml references swd-first-load.md"
else
	bad "mkdocs.yml nav does not mention swd-first-load.md"
fi

# ---------------------------------------------------------------------------
# (d) the placeholder heading is present, and no pin-number-shaped string.
# ---------------------------------------------------------------------------
echo "== (d) placeholder heading present, no pin-number pattern =="
if grep -qF '## Wiring the ST-Link (to be written at the bench)' "${DOC}"; then
	ok "placeholder heading present"
else
	bad "placeholder heading '## Wiring the ST-Link (to be written at the bench)' not found"
fi

if grep -qE '\bP[A-D][0-9]+\b' "${DOC}"; then
	bad "doc contains a pin-number-shaped string (PA/PB/PC/PD + digits)"
	grep -nE '\bP[A-D][0-9]+\b' "${DOC}" | sed 's/^/        /'
else
	ok "no pin-number-shaped string (PA/PB/PC/PD + digits) found"
fi

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
