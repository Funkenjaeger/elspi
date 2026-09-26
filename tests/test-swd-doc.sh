#!/bin/bash
# Prove docs/swd-first-load.md stays honest against what this image actually
# bakes, and that it can go red.
#
#   tests/test-swd-doc.sh
#
# The doc's whole premise is "derive the package list from
# stage-elspi/02-firmware-dev/00-packages, never retype it from the reflex
# page" and "no apt step, because it's already installed". Both of those
# claims rot silently: 00-packages can gain or lose a package with nobody
# touching this doc, and a future edit could reintroduce an `apt install`
# line by copying from the reflex page again. This test reads 00-packages as
# the source of truth and checks the doc against it, not the other way round.
#
# It also gates the placeholder contract: the physical half must stay a named
# placeholder with no pin numbers, connector names, or board-rev claims in it
# -- those are Evan's, from the bench, not something to guess into a doc.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
cd "${REPO}" || exit 2

PKG_FILE="stage-elspi/02-firmware-dev/00-packages"
DOC="docs/swd-first-load.md"
MKDOCS="mkdocs.yml"

PASS=0
FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -r "${PKG_FILE}" ] || { echo "UNKNOWN: ${PKG_FILE} missing. NOT a pass."; exit 2; }
[ -r "${DOC}" ]      || { echo "UNKNOWN: ${DOC} missing. NOT a pass."; exit 2; }
[ -r "${MKDOCS}" ]   || { echo "UNKNOWN: ${MKDOCS} missing. NOT a pass."; exit 2; }

# The packages this image actually bakes in (strip comments and blank lines).
mapfile -t PACKAGES < <(grep -vE '^\s*#' "${PKG_FILE}" | grep -vE '^\s*$')
if [ "${#PACKAGES[@]}" -eq 0 ]; then
	echo "UNKNOWN: parsed zero packages out of ${PKG_FILE}. NOT a pass."
	exit 2
fi

in_packages() { # in_packages <name>
	local n="$1" p
	for p in "${PACKAGES[@]}"; do [ "${p}" = "${n}" ] && return 0; done
	return 1
}

# ---------------------------------------------------------------------------
# (a) every toolchain package the doc names is in 00-packages.
#
# The doc is required to name its packages as their own bullet line, exactly
# `- \`pkgname\`` -- anchored so this cannot accidentally match a filename or
# a command mentioned elsewhere in the prose (provision.sh, modbus-flash.py,
# etc). That is the doc's own convention (see docs/swd-first-load.md), not a
# general markdown-parsing exercise.
# ---------------------------------------------------------------------------
echo "== (a) every toolchain package the doc names is in ${PKG_FILE} =="
mapfile -t DOC_NAMED < <(grep -oE '^- `[a-zA-Z0-9+.-]+`$' "${DOC}" | sed -E 's/^- `(.*)`$/\1/')
if [ "${#DOC_NAMED[@]}" -eq 0 ]; then
	bad "doc names zero packages via the '- \`pkg\`' convention -- nothing to check"
else
	A_OK=1
	for name in "${DOC_NAMED[@]}"; do
		if in_packages "${name}"; then
			ok "doc names '${name}', present in ${PKG_FILE}"
		else
			bad "doc names '${name}', which ${PKG_FILE} does NOT list"
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
