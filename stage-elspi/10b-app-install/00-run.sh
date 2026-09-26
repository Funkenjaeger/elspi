#!/bin/bash -e

# 10b-app-install -- install the BAKED app into the image venv at BUILD time,
# so first boot needs no network. README.md in this directory has the whole
# argument; the short form:
#
# The first-boot hook (stage-elspi/14-first-boot-ui) runs the delta layer's
# converge phase, and converge runs `uv sync --no-dev --frozen` against the
# checkout. On a card straight out of 10a-app-checkout that sync has real work
# to do, and every bit of it needs PyPI:
#
#   * the reflex package itself is installed EDITABLE, which means BUILDING it,
#     which means fetching its build backend (hatchling) -- 08-venv installs
#     everything EXCEPT the project and deletes its uv cache afterwards;
#   * the baked release's lock need not be the venv's lock. 08-venv builds
#     from the lock VENDORED at files/REFLEX_COMMIT; 10a bakes the newest FULL
#     release. They agree today (both v1.2.0, re-vendored 2026-09-26), but a
#     full release cut before the next re-vendor would add whatever it adds
#     (v1.2.0 added segno over rc.3), and converge would fetch it.
#
# docs/design/seam.md test 2: "Every step that needs PyPI, a package mirror, or
# the network at recovery time is a step that can fail on the day you need
# it. Bake those in." First commissioning is the same day as recovery for a
# card nobody has provisioned. So this substage runs that SAME sync, with the
# same environment converge uses, here -- where the build already has the
# network (08-venv fetched Kivy's sdist the same way) -- and then PROVES the
# card will not need it: a second sync with an EMPTY cache and UV_OFFLINE=1
# must succeed. That second sync is byte-for-byte the command the first-boot
# hook runs, so a build that passes this gate is a card whose first boot is
# hermetic. uv decides "already installed" for the editable project from
# pyproject.toml's mtime, and pi-gen's export preserves mtimes, so what is
# proven here holds on the card (measured with uv, 2026-09-26: unchanged
# mtime -> "Audited", offline, exit 0; touched pyproject -> rebuild ->
# offline failure).
#
# It also measures, once, whether the baked release carries reflex's
# COMMISSIONING GUARD (../14-first-boot-ui/files/commissioning-guard.sh), and
# records the answer for 11-manifest. The first-boot hook asks the same
# script again on the card and starts nothing without a `yes`.
#
# WHAT THIS DOES NOT DO: change the checkout. Nothing is written under the app
# root (gated below), no ref moves, no file is added to what git tracks. The
# venv is the only thing that changes, and it is handed back to the service
# user exactly as 08-venv leaves it.
#
# WHY "10b": after 10a-app-checkout (the checkout must exist) and before
# 11-manifest (which records what this measured). "10b-app-install" sorts
# after "10a-app-checkout" and before "11-manifest" under C and en_US
# collation, the same argument 10a's README makes for its own name.

VENV=/opt/reflex-venv
SERVICE_USER="${FIRST_USER_NAME}"
APP_ROOT="/home/${SERVICE_USER}/projects/reflex"
DEST="${ROOTFS_DIR}${APP_ROOT}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HERE}/../14-first-boot-ui/files/commissioning-guard.sh"

fatal() { echo "FATAL: $*"; exit 1; }

# --- premises, asserted rather than assumed -----------------------------------
[ -n "${ROOTFS_DIR}" ] || fatal "ROOTFS_DIR is empty"
[ -d "${DEST}/.git" ] || fatal "${APP_ROOT} is not a checkout -- 10a-app-checkout must run first"
[ -f "${DEST}/ui/pyproject.toml" ] || fatal "${APP_ROOT}/ui/pyproject.toml is missing"
[ -f "${DEST}/ui/uv.lock" ] || fatal "${APP_ROOT}/ui/uv.lock is missing -- converge syncs --frozen against it"
[ -d "${ROOTFS_DIR}${VENV}" ] || fatal "${VENV} does not exist -- 08-venv must run first"
[ -f "${GUARD}" ] || fatal "${GUARD} is missing"

SVC_UID="$(awk -F: -v u="${SERVICE_USER}" '$1==u{print $3}' "${ROOTFS_DIR}/etc/passwd")"
[ -n "${SVC_UID}" ] || fatal "no uid for '${SERVICE_USER}' in ${ROOTFS_DIR}/etc/passwd"

# The checkout as git sees it BEFORE anything here runs. safe.directory: the
# checkout is owned by the service user's uid and this runs as the build's
# root, which git otherwise refuses as "dubious ownership".
G() { git -c safe.directory='*' -C "${DEST}" "$@"; }
HEAD_BEFORE="$(G rev-parse HEAD)" || fatal "cannot read HEAD of ${APP_ROOT}"
REFS_BEFORE="$(G for-each-ref --format='%(refname) %(objectname)' | sort)"
PYPROJECT_MTIME_BEFORE="$(stat -c %Y "${DEST}/ui/pyproject.toml")"

# --- the commissioning guard, measured once ------------------------------------
GUARD_ANSWER="$(bash "${GUARD}" "${DEST}")" || fatal "commissioning-guard could not judge ${APP_ROOT}"
case "${GUARD_ANSWER}" in
	yes) echo "  commissioning guard: PRESENT in the baked release -- first boot will start the UI, UNCOMMISSIONED" ;;
	no)  echo "  commissioning guard: ABSENT in the baked release."
	     echo "           The first-boot hook will NOT start this app: without the guard a"
	     echo "           fresh card would run on silent defaults (docs/design/seam.md,"
	     echo "           amendment 2026-09-21). NOT a build failure -- the image is still a"
	     echo "           recovery image, provisioned by hand -- and the manifest says so." ;;
	*)   fatal "commissioning-guard answered '${GUARD_ANSWER}', expected yes or no" ;;
esac

# --- the install, and the proof it will not need the network again ------------
# The same environment 01-converge.sh gives its own `uv sync`, plus a scratch
# cache and a scratch KIVY_HOME (08-venv's note: building or importing Kivy as
# root otherwise creates /root/.kivy). Two syncs:
#   1. networked, fresh cache: does the work -- the reflex package (editable,
#      so hatchling is fetched and used once, here) and any lock delta;
#   2. EMPTY cache, UV_OFFLINE=1: must find nothing to do. This is the
#      first-boot hook's exact invocation, and it is the gate.
on_chroot << EOF
set -e
cd ${APP_ROOT}/ui
export UV_PROJECT_ENVIRONMENT=${VENV}
export UV_PYTHON_DOWNLOADS=never
export UV_LINK_MODE=copy
export KIVY_HOME=/tmp/kivy-app-install-home

echo "  sync 1 of 2 (network allowed): install the baked app into ${VENV}"
UV_CACHE_DIR=/tmp/uv-cache-app-install uv sync --no-dev --frozen

echo "  sync 2 of 2 (EMPTY cache, UV_OFFLINE=1): what the first-boot hook will run"
rm -rf /tmp/uv-cache-app-install-offline
UV_CACHE_DIR=/tmp/uv-cache-app-install-offline UV_OFFLINE=1 uv sync --no-dev --frozen

rm -rf /tmp/uv-cache-app-install /tmp/uv-cache-app-install-offline /tmp/kivy-app-install-home
EOF
echo "  ok: an offline re-sync against an empty cache succeeds -- first boot needs no network"

# The editable install must point INTO the checkout, or converge's
# `import reflex` would be importing something other than the baked release.
EDITABLE_HIT="$(grep -rlsF "${APP_ROOT}/ui" "${ROOTFS_DIR}${VENV}/lib"/python3*/site-packages/*.pth 2>/dev/null | head -n1 || true)"
[ -n "${EDITABLE_HIT}" ] \
	|| fatal "no .pth in ${VENV} points at ${APP_ROOT}/ui -- the reflex package is not installed editable from the baked checkout"
echo "  ok: reflex installed editable from ${APP_ROOT}/ui ($(basename "${EDITABLE_HIT}"))"

# --- the checkout is exactly as 10a left it ------------------------------------
[ "$(G rev-parse HEAD)" = "${HEAD_BEFORE}" ] || fatal "HEAD of ${APP_ROOT} moved during the install"
[ "$(G for-each-ref --format='%(refname) %(objectname)' | sort)" = "${REFS_BEFORE}" ] \
	|| fatal "the refs of ${APP_ROOT} changed during the install -- 10a's scrub no longer holds"
DIRTY="$(G status --porcelain --untracked-files=no)"
[ -z "${DIRTY}" ] || fatal "the install modified tracked files in ${APP_ROOT}:
${DIRTY}"
# uv keys "is the editable install current" on pyproject.toml's mtime; if
# anything here moved it, the offline proof above is about a different file.
[ "$(stat -c %Y "${DEST}/ui/pyproject.toml")" = "${PYPROJECT_MTIME_BEFORE}" ] \
	|| fatal "${APP_ROOT}/ui/pyproject.toml's mtime moved during the install"
UNTRACKED="$(G status --porcelain --untracked-files=all | grep '^??' || true)"
if [ -n "${UNTRACKED}" ]; then
	echo "  note: untracked (not ignored) paths now in ${APP_ROOT}:"
	printf '%s\n' "${UNTRACKED}" | sed 's/^/        /'
fi
echo "  ok: ${APP_ROOT} unchanged -- same HEAD, same refs, no tracked file modified"

# --- ownership: the venv goes back to the service user ------------------------
# Same rule and same gate as 08-venv: the in-app updater runs `uv sync` into
# this venv AS THE SERVICE USER, and a root-owned file in it turns every
# update into a preflight refusal.
on_chroot << EOF
set -e
id ${SERVICE_USER} >/dev/null
chown -R -h ${SERVICE_USER}:${SERVICE_USER} ${VENV}
chown -R -h ${SERVICE_USER}:${SERVICE_USER} ${APP_ROOT}
EOF
NOT_OURS="$(find "${ROOTFS_DIR}${VENV}" "${DEST}" ! -uid "${SVC_UID}" -print -quit)"
[ -z "${NOT_OURS}" ] || fatal "not wholly owned by ${SERVICE_USER} (uid ${SVC_UID}) after chown; first offender: ${NOT_OURS#"${ROOTFS_DIR}"}"
[ -e "${ROOTFS_DIR}/root/.kivy" ] && fatal "/root/.kivy exists after the app install (KIVY_HOME was set; something else imported kivy as root)"
[ "$(stat -c %Y "${DEST}/ui/pyproject.toml")" = "${PYPROJECT_MTIME_BEFORE}" ] \
	|| fatal "${APP_ROOT}/ui/pyproject.toml's mtime moved during the chown"

# --- record what was measured, for 11-manifest ---------------------------------
install -d -m 0755 "${ROOTFS_DIR}/etc/elspi"
printf '%s\n' "${GUARD_ANSWER}" > "${ROOTFS_DIR}/etc/elspi/reflex-app-commissioning-guard"
printf '%s\n' "yes"             > "${ROOTFS_DIR}/etc/elspi/reflex-app-installed-offline-ok"

echo "  installed the baked app into ${VENV}; offline re-sync proven; commissioning guard: ${GUARD_ANSWER}"
