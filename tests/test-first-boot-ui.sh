#!/bin/bash
# Run the REAL first-boot UI hook against a synthetic rootfs, branch by branch.
#
#   tests/test-first-boot-ui.sh
#
# stage-elspi/14-first-boot-ui/files/elspi-first-boot-ui.sh is what makes a
# fresh card boot straight into the UI: it converges the baked checkout and
# starts reflex-ui.service, once, and only when the baked release carries
# reflex's commissioning guard. verify-image.sh can say the hook is installed
# and wired. This says what it DOES, in every branch, including the ones that
# must start nothing.
#
# HOW IT RUNS WITHOUT ROOT, SYSTEMD OR A PI:
#   * ELSPI_FBUI_TEST_ROOT prefixes every file path the hook touches.
#   * `systemctl` is a SHIM on PATH that keeps unit state in files and logs
#     every call, so "was it started", "was it disabled again" are observed,
#     not inferred.
#   * converge is a FAKE at the path the image installs it
#     (/usr/local/lib/elspi/deltas/01-converge.sh) that records its arguments
#     and whether UV_OFFLINE=1 reached it, and then behaves as told: succeed
#     and enable the unit, fail after enabling it, or succeed without
#     enabling it. The real converge is exercised by deltas/tests and, on a
#     card, by the first boot itself.
#   * the commissioning-guard check is the REAL script, run against
#     synthetic checkouts with and without the guard's three files.
#
# NOT COVERED, stated rather than implied: real systemd ordering at boot
# (Plymouth, the seed), the real converge on a card, and what the application
# shows. Those need hardware; the image manifest declares the blind spot.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
HOOK="${ELSPI_FBUI_SCRIPT:-${REPO}/stage-elspi/14-first-boot-ui/files/elspi-first-boot-ui.sh}"
GUARD_SRC="${REPO}/stage-elspi/14-first-boot-ui/files/commissioning-guard.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

if ! command -v python3 >/dev/null 2>&1 || [ ! -f "${HOOK}" ] || [ ! -f "${GUARD_SRC}" ]; then
	echo "CANNOT RUN: need python3, ${HOOK} and ${GUARD_SRC}"
	echo "NOT reporting success -- the hook was not exercised."
	exit 2
fi

# --- the systemctl shim -------------------------------------------------------
SHIMS="${WORK}/shims"
mkdir -p "${SHIMS}"
cat > "${SHIMS}/systemctl" <<'SHIM'
#!/bin/bash
# State: ${SHIM_STATE}/<unit>.enabled and <unit>.active exist or do not.
echo "systemctl $*" >> "${SHIM_STATE}/calls"
q=0; args=()
for a in "$@"; do
	case "$a" in --quiet) q=1 ;; --no-block) ;; *) args+=("$a") ;; esac
done
verb="${args[0]:-}"; unit="${args[1]:-}"
case "${verb}" in
	is-enabled) if [ -e "${SHIM_STATE}/${unit}.enabled" ]; then [ $q = 1 ] || echo enabled; exit 0; else [ $q = 1 ] || echo disabled; exit 1; fi ;;
	is-active)  if [ -e "${SHIM_STATE}/${unit}.active" ];  then [ $q = 1 ] || echo active;  exit 0; else [ $q = 1 ] || echo inactive; exit 3; fi ;;
	enable)     touch "${SHIM_STATE}/${unit}.enabled" ;;
	disable)    rm -f "${SHIM_STATE}/${unit}.enabled" ;;
	start)      [ -e "${SHIM_STATE}/refuse-start" ] && exit 1; touch "${SHIM_STATE}/${unit}.active" ;;
	*)          exit 0 ;;
esac
SHIM
chmod +x "${SHIMS}/systemctl"

# --- one synthetic card per case ---------------------------------------------
# mkcard <name> <guard: yes|no|none>  -> sets R and SHIM_STATE
mkcard() {
	R="${WORK}/$1"
	SHIM_STATE="${R}.state"
	mkdir -p "${R}/etc/elspi" "${R}/run" "${R}/var/lib/reflex-config" \
	         "${R}/usr/local/lib/elspi/deltas" "${SHIM_STATE}"
	: > "${SHIM_STATE}/calls"
	cat > "${R}/etc/elspi-image.json" <<'JSON'
{"paths": {"app_root": "/home/default/projects/reflex", "config_dir": "/var/lib/reflex-config"}}
JSON
	install -m 0755 "${GUARD_SRC}" "${R}/usr/local/lib/elspi/commissioning-guard"
	# The FAKE converge. FAKE_CONVERGE: ok | fail-after-enable | ok-no-enable
	cat > "${R}/usr/local/lib/elspi/deltas/01-converge.sh" <<'FAKE'
#!/bin/bash
printf 'args=%s UV_OFFLINE=%s\n' "$*" "${UV_OFFLINE:-unset}" >> "${SHIM_STATE}/converge"
echo "fake converge running"
case "${FAKE_CONVERGE:-ok}" in
	ok)                systemctl enable reflex-ui.service; exit 0 ;;
	fail-after-enable) systemctl enable reflex-ui.service; exit 3 ;;
	ok-no-enable)      exit 0 ;;
esac
FAKE
	chmod +x "${R}/usr/local/lib/elspi/deltas/01-converge.sh"
	local app="${R}/home/default/projects/reflex/ui/reflex"
	case "$2" in
		none) ;;
		no)
			mkdir -p "${app}"
			printf 'class MainApp:\n    pass\n' > "${app}/app.py" ;;
		yes)
			mkdir -p "${app}/utils" "${app}/components/home"
			printf 'def latch():\n    return False\n' > "${app}/utils/commissioning_state.py"
			printf 'from reflex.utils import commissioning_state\nclass MainApp:\n    def latch_commissioning_state(self):\n        return commissioning_state.latch()\n    def build(self):\n        self.latch_commissioning_state()\n' > "${app}/app.py"
			printf '<UncommissionedBanner>:\n' > "${app}/components/home/uncommissioned_banner.kv" ;;
	esac
}

# run_hook [VAR=value ...] -> OUT, RC
run_hook() {
	OUT="$(env PATH="${SHIMS}:${PATH}" SHIM_STATE="${SHIM_STATE}" ELSPI_FBUI_TEST_ROOT="${R}" \
		ELSPI_FBUI_START_WAIT=2 ELSPI_FBUI_CONVERGE_TIMEOUT=30 "$@" bash "${HOOK}" 2>&1)"; RC=$?
}
verdict_is() { # verdict_is <VERDICT> <description>
	local v; v="$(cat "${R}/etc/elspi/first-boot-ui-verdict" 2>/dev/null)"
	if [ "${RC}" -ne 0 ]; then bad "$2 -- the hook exited ${RC}; it must always exit 0"; return; fi
	if [ "${v}" = "$1" ] && printf '%s' "${OUT}" | grep -q "verdict=$1 "; then ok "$2"
	else bad "$2 -- expected verdict=$1, recorded '${v}'; output:"; printf '%s\n' "${OUT}" | sed 's/^/          /'; fi
}
called()     { grep -qE "$1" "${SHIM_STATE}/calls"; }
converged()  { [ -s "${SHIM_STATE}/converge" ]; }
started()    { called '^systemctl start'; }

echo "== branches that must start nothing =="

mkcard no-manifest yes; rm -f "${R}/etc/elspi-image.json"
run_hook
verdict_is UNKNOWN "no manifest -> UNKNOWN"
converged && bad "no manifest: converge ran anyway" || ok "no manifest: converge not run"

mkcard no-checkout none
run_hook
verdict_is NOOP "no baked checkout (an image from before 2026-09-21) -> NOOP"
{ converged || started; } && bad "no checkout: converge or start happened" || ok "no checkout: nothing converged or started"

mkcard no-guard no
run_hook
verdict_is REFUSED_NO_GUARD "a release WITHOUT the commissioning guard -> REFUSED_NO_GUARD"
converged && bad "no guard: converge ran -- it must not even be converged" || ok "no guard: converge NOT run"
started && bad "no guard: reflex-ui was STARTED on silent defaults" || ok "no guard: reflex-ui NOT started"
[ -e "${R}/etc/elspi/first-boot-ui-done" ] && bad "no guard: DONE marker written" || ok "no guard: no DONE marker (re-evaluated next boot)"

mkcard provisioned yes; touch "${SHIM_STATE}/reflex-ui.service.enabled"
run_hook
verdict_is ALREADY_PROVISIONED "reflex-ui already enabled (someone provisioned this card) -> ALREADY_PROVISIONED"
{ converged || started; } && bad "already provisioned: the hook converged or started anyway" || ok "already provisioned: left alone (no converge, no start)"
[ -e "${R}/etc/elspi/first-boot-ui-done" ] && ok "already provisioned: DONE marker written" || bad "already provisioned: no DONE marker"

mkcard converge-fails yes
run_hook FAKE_CONVERGE=fail-after-enable
verdict_is CONVERGE_FAILED "converge fails after enabling the unit -> CONVERGE_FAILED"
[ -e "${SHIM_STATE}/reflex-ui.service.enabled" ] && bad "converge failed: reflex-ui left ENABLED (the next boot would start it half-wired)" \
	|| ok "converge failed: reflex-ui disabled again"
started && bad "converge failed: reflex-ui was started" || ok "converge failed: reflex-ui NOT started"
[ -e "${R}/etc/elspi/first-boot-ui-done" ] && bad "converge failed: DONE marker written (no retry)" || ok "converge failed: no DONE marker (retried next boot)"

mkcard converge-no-enable yes
run_hook FAKE_CONVERGE=ok-no-enable
verdict_is CONVERGE_FAILED "converge exits 0 but the unit is not enabled -> CONVERGE_FAILED (systemd's answer, not the exit code)"
started && bad "converge-no-enable: reflex-ui was started" || ok "converge-no-enable: reflex-ui NOT started"

echo
echo "== the branch that starts the UI =="

mkcard fresh yes
run_hook FAKE_CONVERGE=ok
verdict_is STARTED "fresh card, guard present -> converge, start, STARTED"
if grep -qx 'args=--app /home/default/projects/reflex UV_OFFLINE=1' "${SHIM_STATE}/converge" 2>/dev/null; then
	ok "converge got --app <manifest app_root> and UV_OFFLINE=1"
else
	bad "converge was not run as '--app /home/default/projects/reflex' with UV_OFFLINE=1: $(cat "${SHIM_STATE}/converge" 2>/dev/null)"
fi
called '^systemctl start --no-block reflex-ui.service$' && ok "reflex-ui started with --no-block (no boot-time job wait)" \
	|| bad "reflex-ui not started with 'systemctl start --no-block reflex-ui.service': $(grep start "${SHIM_STATE}/calls")"
[ -e "${R}/etc/elspi/first-boot-ui-done" ] && ok "DONE marker written" || bad "no DONE marker after a successful start"
printf '%s' "${OUT}" | grep -q 'UNCOMMISSIONED' && ok "the journal says the UI will come up UNCOMMISSIONED (empty config dir)" \
	|| bad "the journal does not say UNCOMMISSIONED for an empty config dir"
[ -z "$(ls -A "${R}/var/lib/reflex-config")" ] && ok "nothing written to /var/lib/reflex-config (never restores, never generates)" \
	|| bad "the hook wrote into /var/lib/reflex-config: $(ls -A "${R}/var/lib/reflex-config")"
ls "${R}/run" | grep -q . && bad "the private uv cache under /run was left behind" || ok "the private uv cache was removed"

# Second boot: the hook must do NOTHING -- not converge again, not start, and
# not overrule a human who stopped or disabled the UI since.
rm -f "${SHIM_STATE}/reflex-ui.service.active" "${SHIM_STATE}/reflex-ui.service.enabled"
: > "${SHIM_STATE}/converge"; : > "${SHIM_STATE}/calls"
run_hook FAKE_CONVERGE=ok
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -q 'verdict=DONE_EARLIER'; then ok "second boot -> DONE_EARLIER"; else bad "second boot did not report DONE_EARLIER: ${OUT}"; fi
{ converged || started || called 'enable'; } && bad "second boot: converged, enabled or started again (a human's stop/disable was overruled)" \
	|| ok "second boot: nothing converged, enabled or started"
[ "$(cat "${R}/etc/elspi/first-boot-ui-verdict")" = STARTED ] && ok "second boot: the first boot's verdict (STARTED) is kept" \
	|| bad "second boot overwrote the first boot's verdict"

mkcard start-refused yes; touch "${SHIM_STATE}/refuse-start"
run_hook FAKE_CONVERGE=ok
verdict_is START_FAILED "systemctl refuses the start -> START_FAILED"

mkcard start-slow yes
# A unit that never reports active within the wait: the shim's start is made
# to succeed without marking it active.
sed -i 's|start)      \[ -e "${SHIM_STATE}/refuse-start" \] && exit 1; touch "${SHIM_STATE}/${unit}.active" ;;|start) exit 0 ;;|' "${SHIMS}/systemctl"
run_hook FAKE_CONVERGE=ok
verdict_is START_UNCONFIRMED "started but never reported active -> START_UNCONFIRMED (not STARTED)"

echo
echo "== the contract =="
if grep -qE '^\s*read\b' "${HOOK}"; then bad "the hook has an interactive 'read' step"; else ok "the hook has no interactive 'read' step"; fi
grep -qE '^[[:space:]]*exit [1-9]' "${HOOK}" && bad "the hook has a non-zero exit path" || ok "the hook has no non-zero exit path"

echo
echo "== result: ${PASS} ok, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ] || exit 1
