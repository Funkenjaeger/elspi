#!/bin/bash
# Shared helpers for the delta phases. Sourced, never executed.
#
# The bias throughout: a step that claims an effect must GATE on a signal that
# could have come out differently, and anything unmeasurable must say so rather
# than pass quietly.

# shellcheck shell=bash

DRY_RUN="${DRY_RUN:-0}"

_c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_ylw=$'\033[33m'; _c_off=$'\033[0m'

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  %sok%s    %s\n' "${_c_grn}" "${_c_off}" "$*"; }
warn() { printf '  %swarn%s  %s\n' "${_c_ylw}" "${_c_off}" "$*"; }
die()  { printf '  %sFATAL%s %s\n' "${_c_red}" "${_c_off}" "$*" >&2; exit 1; }

phase() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# Every mutating action goes through this, so --dry-run is honest by
# construction rather than by remembering to check a flag at each call site.
run() {
	if [ "${DRY_RUN}" = "1" ]; then
		printf '  would: %s\n' "$*"
		return 0
	fi
	"$@"
}

need_root() {
	[ "$(id -u)" -eq 0 ] || die "must run as root (it installs units and writes /var/lib)"
}

# GATE: assert a condition after acting on it, and fail loudly naming the check.
# Skipped under --dry-run, because nothing was written to assert about -- and
# a post-check that "passes" against an action that never happened is worse
# than no check.
assert() { # assert <description> <command...>
	local desc="$1"; shift
	if [ "${DRY_RUN}" = "1" ]; then
		printf '  (skipped check: %s)\n' "${desc}"
		return 0
	fi
	if "$@" >/dev/null 2>&1; then
		ok "${desc}"
	else
		die "post-write check FAILED: ${desc}"
	fi
}

# A site's SETTINGS for the phases, as opposed to its hooks: <hooks dir>/site.env,
# loaded by provision.sh BEFORE phase 1 (hooks run last, which is too late to
# change how restore judges a capture). DATA, not code: every non-blank,
# non-comment line must be ELSPI_<NAME>=<value>, the value drawn from
# [A-Za-z0-9._/-]; anything else is refused by line number, and the file is
# never sourced. Each accepted name is exported, and named on the terminal.
# Absent file: nothing to load, said so. (deltas/README.md has the contract.)
load_site_env() { # load_site_env <site hooks dir>
	local f="$1/site.env" line n=0 name
	if [ ! -e "${f}" ]; then
		say "no site.env in $1 -- the phases use their public defaults"
		return 0
	fi
	[ -f "${f}" ] && [ -r "${f}" ] || die "${f} exists but is not a readable file"
	while IFS= read -r line || [ -n "${line}" ]; do
		n=$((n + 1))
		case "${line}" in ''|'#'*) continue ;; esac
		if ! printf '%s\n' "${line}" | grep -qE '^ELSPI_[A-Z0-9_]+=[A-Za-z0-9._/-]*$'; then
			die "${f}:${n} is not an ELSPI_<NAME>=<value> line (value: letters, digits, . _ / - only).
  site.env is data, never sourced; fix or remove that line."
		fi
		name="${line%%=*}"
		export "${name}=${line#*=}"
		ok "site.env: ${name}=${line#*=}"
	done < "${f}"
}

# The service user. Read from the image's own manifest when present so the
# delta cannot disagree with the image about who runs the app; falls back to
# the pi-gen default, and says which it used.
IMAGE_MANIFEST=/etc/elspi-image.json

manifest_get() { # manifest_get <python-index-expression>
	[ -r "${IMAGE_MANIFEST}" ] || return 1
	python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
cur=d
for k in sys.argv[2].split("."):
    cur=cur[k]
print(cur)' "${IMAGE_MANIFEST}" "$1" 2>/dev/null
}

resolve_service_user() {
	local u
	if u="$(manifest_get service_user)" && [ -n "${u}" ]; then
		SERVICE_USER="${u}"
		SERVICE_USER_SRC="the image manifest"
	else
		SERVICE_USER=default
		SERVICE_USER_SRC="the built-in default (no ${IMAGE_MANIFEST})"
	fi
	id "${SERVICE_USER}" >/dev/null 2>&1 \
		|| die "service user '${SERVICE_USER}' (per ${SERVICE_USER_SRC}) does not exist"
}

resolve_paths() {
	VENV="$(manifest_get paths.venv 2>/dev/null || true)"
	[ -n "${VENV}" ] || VENV=/opt/reflex-venv
	CONFIG_DIR="$(manifest_get paths.config_dir 2>/dev/null || true)"
	[ -n "${CONFIG_DIR}" ] || CONFIG_DIR=/var/lib/reflex-config
	LOG_DIR="$(manifest_get paths.log_dir 2>/dev/null || true)"
	[ -n "${LOG_DIR}" ] || LOG_DIR=/var/log/reflex
	# The app checkout AS THE IMAGE DECLARES IT. Deliberately NOT defaulted:
	# the image creates paths.app_parent, the delta creates the checkout under
	# it, and a phase that wants to report on the checkout should say "not
	# declared" rather than guess a path and report on nothing. Phase 1 takes
	# it as --app; phase 3 uses this as the fallback when run standalone.
	APP_ROOT="$(manifest_get paths.app_root 2>/dev/null || true)"
}

# The app checkout. NOT defaulted to a guess: on the live machine it is
# /home/default/projects/reflex (monorepo layout since the 2026-08-17 weld;
# the old /reflex-ui standalone checkout was deleted 2026-08-25), but a
# provisioning script that guesses a path and finds nothing there should say
# so, not invent one.
require_app_dir() { # require_app_dir <path>
	local d="$1"
	[ -n "${d}" ] || die "--app is required (the reflex monorepo checkout)"
	[ -d "${d}" ] || die "--app ${d} does not exist"
	[ -f "${d}/ui/deploy/start.sh" ] \
		|| die "--app ${d} does not look like the reflex monorepo: ui/deploy/start.sh missing"
	[ -f "${d}/ui/deploy/reflex-ui.service" ] \
		|| die "--app ${d} has no ui/deploy/reflex-ui.service to install"
	APP_DIR="$(cd "${d}" && pwd)"
	UI_DIR="${APP_DIR}/ui"
}
