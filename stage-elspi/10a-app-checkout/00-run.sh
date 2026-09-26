#!/bin/bash -e

# THE APPLICATION ITSELF -- a real git checkout of the reflex monorepo, at the
# latest FULL release, at the app root the app's own unit already hardcodes.
#
# docs/design/seam.md, AMENDMENT 2026-09-21, RATIFIED by Evan: call 1's second
# clause ("but not reflex-ui itself") is withdrawn. "The image now ships the
# app, pinned to the latest FULL release. Not a development `rc.*`, not a
# floating branch." Full releases are infrequent, and in-app updating closes
# the gap cheaply, so the image only has to be *a* good starting point rather
# than *the current* one.
#
# THE THREE THINGS THAT AMENDMENT SAYS THE STAGE MUST DO -- two already held
# before this substage existed, and are ASSERTED here rather than redone:
#
#   1. a real git checkout carrying tag history, at a path writable by the
#      service user                                     <- THIS SUBSTAGE
#   2. /opt/reflex-venv writable by the service user    <- 08-venv already
#      chowns it and FATALs if it is not wholly owned afterwards
#   3. /etc/elspi-release shipped                       <- 11-manifest's
#      files/render-release.sh already writes it
#
# WHY A CHECKOUT AND NOT A TARBALL. ui/reflex/utils/updater.py reads the
# TARGET release's protocol version with `git show <tag>:ui/reflex/utils/
# els_stop_map.py` and then checks that tag out in place. Its resolve_checkout()
# refuses outright -- "an installed wheel, a copied tree, a directory with no
# fw/" -- when <root>/.git, <root>/ui/pyproject.toml, <root>/fw/scripts/
# modbus-flash.py or <root>/fw/scripts/reflex_image.py is missing. A source
# export would therefore make EVERY in-app update fail on a freshly flashed
# card, which is the one thing the amendment leans on.
#
# WHERE THE SOURCE COMES FROM: REFLEX_SOURCE, a BUILD PARAMETER (see
# elspi.conf), never a URL hardcoded here. That is what keeps the build
# reproducible from the local mirror with no network. This is a BUILD-time
# clone on the build host; nothing here runs at provision or first boot, and
# the provision path gains no network fetch.
#
# NO CREDENTIAL, seam call 2: the clone is anonymous, the shipped remote is
# rewritten to the public URL, and the gates below refuse anything
# credential-shaped in .git/config rather than trusting that.
#
# THIS SUBSTAGE DOES NOT START ANYTHING. The start gate is order 2026-09-21#1
# and does not exist yet; stage-elspi/14-first-boot-ui stays exactly the
# scaffold order 2026-09-20#5 shipped. A checkout with nothing pointed at it
# is inert.
#
# WHY "10a" AND NOT A RENUMBER. It has to run after 05-service-user (which
# creates and owns the app parent) and BEFORE 11-manifest (which records what
# was baked). Renumbering 11-manifest..14-first-boot-ui to open a slot would
# rename directories that docs, tests, README files and the manifest's own
# strings name by number -- a large diff to buy a tidier integer. build.sh:112
# iterates `"${STAGE_DIR}"/*`, i.e. glob order, and "10a-app-checkout" sorts
# after "10-splash" and before "11-manifest" in both C and en_US collation.

SERVICE_USER="${FIRST_USER_NAME}"
APP_PARENT="/home/${SERVICE_USER}/projects"
APP_ROOT="${APP_PARENT}/reflex"
DEST="${ROOTFS_DIR}${APP_ROOT}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECT="${HERE}/files/select-release.sh"

# The remote the SHIPPED image carries. A parameter too, because the build
# source and the shipped remote are different questions: the build reads from
# a local mirror, the card in the machine shop fetches from the public repo.
# Anonymous HTTPS, matching updater.py's own GITHUB_FETCH_URL -- see its note
# on why the git half stopped using whatever remote the checkout happened to
# have: a developer's checkout may name an SSH host alias from THAT person's
# ~/.ssh/config, which the account the service runs as does not have.
REFLEX_ORIGIN_URL="${REFLEX_ORIGIN_URL:-https://github.com/Funkenjaeger/reflex.git}"

# --- Gate: the source is a parameter, and it is not optional ----------------
if [ -z "${REFLEX_SOURCE:-}" ]; then
	echo "FATAL: REFLEX_SOURCE is not set."
	echo "       The release source is a build parameter so this build stays"
	echo "       reproducible from a local mirror. Set it in elspi.conf, or:"
	echo "         REFLEX_SOURCE=/path/to/mirror/reflex.git ./build-elspi.sh"
	echo "       There is deliberately no default network URL in this stage."
	exit 1
fi

# --- Gate: 05-service-user must already have made the app parent ------------
# PREMISE, measured on the stage at d81d04c 2026-09-21 and asserted rather
# than repeated: stage-elspi/05-service-user/00-run.sh installs
# /home/<service user>/projects owned by the service user at mode 0755 (the
# path corrected 2026-09-07 away from an invented /opt/reflex to the monorepo
# path the app's own unit hardcodes). If that ever stops happening, the clone
# below would create the parent as root and the checkout would be unwritable
# by the user that has to update it -- so this is a hard gate, not a mkdir.
if [ ! -d "${ROOTFS_DIR}${APP_PARENT}" ]; then
	echo "FATAL: ${APP_PARENT} does not exist in the rootfs."
	echo "       stage-elspi/05-service-user is expected to have created it."
	echo "       This stage will not create it: an app parent made HERE would"
	echo "       be root-owned and the in-app updater could never write it."
	exit 1
fi

SVC_UID="$(awk -F: -v u="${SERVICE_USER}" '$1==u{print $3}' "${ROOTFS_DIR}/etc/passwd")"
SVC_GID="$(awk -F: -v u="${SERVICE_USER}" '$1==u{print $4}' "${ROOTFS_DIR}/etc/passwd")"
# The rootfs's OWN passwd, never the build host's -- same reason 08-venv and
# 13-usb-automount read it there: the host's uids are an accident of who ran
# the build.
if [ -z "${SVC_UID}" ] || [ -z "${SVC_GID}" ]; then
	echo "FATAL: no uid/gid for '${SERVICE_USER}' in ${ROOTFS_DIR}/etc/passwd"
	exit 1
fi

PARENT_UID="$(stat -c %u "${ROOTFS_DIR}${APP_PARENT}")"
if [ "${PARENT_UID}" != "${SVC_UID}" ]; then
	echo "FATAL: ${APP_PARENT} is owned by uid ${PARENT_UID}, not ${SERVICE_USER}"
	echo "       (uid ${SVC_UID}). 05-service-user installs it -o ${SERVICE_USER};"
	echo "       something has changed that."
	exit 1
fi
echo "  app parent ok: ${APP_PARENT} owned by ${SERVICE_USER} (uid ${SVC_UID})"

# --- Select the release -----------------------------------------------------
# The decision lives in files/select-release.sh so it is testable without a
# pi-gen build (tests/test-release-selection.sh drives it directly). This
# stage does not reimplement any part of it -- including the "is this a full
# release" question for an explicitly pinned REFLEX_RELEASE, which goes
# through the same `check` the selection filters with.
if [ -n "${REFLEX_RELEASE:-}" ]; then
	echo "  REFLEX_RELEASE pinned to '${REFLEX_RELEASE}' -- checking it is a full release"
	if ! RELEASE_TAG="$(bash "${SELECT}" check "${REFLEX_RELEASE}")"; then
		echo "FATAL: the pinned REFLEX_RELEASE was refused (message above)."
		echo "       Nothing is substituted for a refused tag."
		exit 1
	fi
	# A pinned tag still has to EXIST in the source. Refusing here is the
	# difference between "you asked for a release that is not a release" and
	# "you asked for a release this mirror has never heard of".
	if ! git ls-remote --tags --refs --exit-code "${REFLEX_SOURCE}" "refs/tags/${RELEASE_TAG}" >/dev/null 2>&1; then
		echo "FATAL: '${RELEASE_TAG}' is a well-formed full release tag but does"
		echo "       not exist in REFLEX_SOURCE=${REFLEX_SOURCE}."
		exit 1
	fi
else
	if ! RELEASE_TAG="$(bash "${SELECT}" latest "${REFLEX_SOURCE}")"; then
		echo "FATAL: no full release could be selected (message above)."
		echo "       The build stops rather than baking a pre-release or a"
		echo "       branch tip -- docs/design/seam.md amendment 2026-09-21."
		exit 1
	fi
fi
[ -n "${RELEASE_TAG}" ] || { echo "FATAL: selection produced an empty tag"; exit 1; }
echo "  baking reflex release ${RELEASE_TAG} from ${REFLEX_SOURCE}"

# --- The checkout -----------------------------------------------------------
# IDEMPOTENCE: pi-gen re-runs stages on a resumed build. The destination is
# removed and re-cloned rather than fetched into, so a half-written checkout
# from an interrupted build cannot survive as a plausible-looking tree. The
# rm is bounded to the one computed path under ${ROOTFS_DIR} and gated on
# both being non-empty, because an unset ROOTFS_DIR here would be `rm -rf
# /home/...` on the BUILD HOST.
if [ -z "${ROOTFS_DIR}" ] || [ -z "${APP_ROOT}" ]; then
	echo "FATAL: refusing to touch '${DEST}' with an empty ROOTFS_DIR or APP_ROOT"
	exit 1
fi
rm -rf "${DEST}"

# --no-hardlinks IS LOAD-BEARING when REFLEX_SOURCE is a local path. git's
# default for a local clone is to hardlink the object files, which would put
# the IMAGE's git objects and the build host's mirror on the same inodes --
# the image would then either carry links out of its own filesystem or, once
# the rootfs is packed, silently depend on a mirror that is not there.
#
# --branch <tag> lands HEAD detached AT THE TAG, which is the state the
# updater itself leaves behind after an update, and still fetches the whole
# history and every tag. NOT --single-branch and NOT --depth: tag history is
# the entire reason this is a checkout (gated on below).
echo "  cloning (full history, all tags) -> ${APP_ROOT}"
# THE STATUS READ IS git's, NOT sed's. `git clone ... | sed` under a plain
# `if !` tests the LAST element of the pipeline, so a clone that died would be
# reported as a success by the indenting filter -- the exact shape of a check
# that cannot fail. PIPESTATUS[0] is the clone.
git clone --no-hardlinks --branch "${RELEASE_TAG}" \
	"${REFLEX_SOURCE}" "${DEST}" 2>&1 | sed 's/^/    /'
CLONE_RC="${PIPESTATUS[0]}"
if [ "${CLONE_RC}" -ne 0 ]; then
	echo "FATAL: git clone of ${REFLEX_SOURCE} at ${RELEASE_TAG} failed (exit ${CLONE_RC})"
	exit 1
fi

# Defined here, ahead of its first use below, and used by every gate after it.
fatal() { echo "FATAL: $*"; exit 1; }

# The shipped remote, not the build host's path. Done before the gates so the
# gates judge what actually ships.
git -C "${DEST}" remote set-url origin "${REFLEX_ORIGIN_URL}"

# --- What the clone recorded about the BUILD, taken back out ----------------
# Rewriting origin is not enough. A clone also leaves behind, in .git:
#
#   * a REFLOG (.git/logs/) whose first line is "clone: from <REFLEX_SOURCE>",
#     stamped with the BUILDER's git identity -- a build-host path and a
#     person, in every image built from a local mirror;
#   * a REMOTE-TRACKING REF for every branch the source had. A mirror carries
#     branches that were never published (work-in-progress pushed from a
#     workstation), and each ref also keeps that branch's commits in the
#     object store.
#
# THE REF RULE: a remote-tracking ref ships only if it is KNOWN to be on the
# public origin, and the only way this stage knows that without a network is
# that it was read FROM the public origin -- REFLEX_SOURCE is literally
# REFLEX_ORIGIN_URL (the default build, and CI). From any other source every
# remote-tracking ref is deleted. The in-app updater does not need them: it
# fetches tags anonymously from the public URL and checks a tag out
# (ui/reflex/utils/updater.py, `git fetch --tags --force GITHUB_FETCH_URL`).
#
# Then the reflog is expired and logs/ removed, and a gc drops every object
# only a deleted ref could reach. Gate 7 below re-checks all of it.
if [ "${REFLEX_SOURCE}" = "${REFLEX_ORIGIN_URL}" ]; then
	echo "  remote-tracking refs kept: the source IS the public origin (${REFLEX_ORIGIN_URL})"
	PUBLIC_REFS_KNOWN=yes
else
	PUBLIC_REFS_KNOWN=no
	N_PRUNED="$(git -C "${DEST}" for-each-ref --format='%(refname)' refs/remotes | wc -l)"
	git -C "${DEST}" for-each-ref --format='delete %(refname)' refs/remotes \
		| git -C "${DEST}" update-ref --no-deref --stdin \
		|| fatal "could not delete the clone's remote-tracking refs"
	echo "  remote-tracking refs deleted: ${N_PRUNED} (the source is not the public origin, so none is known to be public)"
fi
git -C "${DEST}" reflog expire --expire=now --expire-unreachable=now --all \
	|| fatal "git reflog expire failed in the baked checkout"
rm -rf "${DEST}/.git/logs"
git -C "${DEST}" gc --quiet --prune=now \
	|| fatal "git gc --prune=now failed in the baked checkout"

# --- POST-WRITE GATES -------------------------------------------------------
# Each of these could come out differently. "A directory exists at the app
# root" proves nothing; the point of this stage is a REAL REPOSITORY, AT A
# FULL RELEASE, THAT THE SERVICE USER CAN UPDATE.

[ -d "${DEST}/.git" ] || fatal "${APP_ROOT}/.git is not a directory -- that is not a checkout"

# 1. A real repository, and not a shallow one. updater.py needs history for
#    tags it has not fetched yet; a shallow clone answers `git show` for the
#    tip and lies about everything else.
git -C "${DEST}" rev-parse --git-dir >/dev/null 2>&1 \
	|| fatal "${APP_ROOT} is not a git repository"
[ -e "${DEST}/.git/shallow" ] && fatal "${APP_ROOT} is a SHALLOW clone -- tag history is the point"

# 2. HEAD is the selected tag, by commit id rather than by name.
TAG_SHA="$(git -C "${DEST}" rev-parse --verify "refs/tags/${RELEASE_TAG}^{commit}" 2>/dev/null)" \
	|| fatal "tag ${RELEASE_TAG} does not resolve inside the baked checkout"
HEAD_SHA="$(git -C "${DEST}" rev-parse --verify HEAD 2>/dev/null)" \
	|| fatal "the baked checkout has no resolvable HEAD"
[ "${TAG_SHA}" = "${HEAD_SHA}" ] \
	|| fatal "HEAD (${HEAD_SHA}) is not ${RELEASE_TAG} (${TAG_SHA})"

# 3. TAG HISTORY, not one tag. A `git archive` export has none; a
#    --single-branch --depth 1 clone has one. The updater has to be able to
#    reach a tag that did not exist when the card was flashed, and it fetches
#    into THIS object store.
TAG_COUNT="$(git -C "${DEST}" tag | wc -l)"
[ "${TAG_COUNT}" -ge 2 ] \
	|| fatal "the baked checkout carries ${TAG_COUNT} tag(s) -- that is not tag history"

# 4. THE UPDATER'S OWN READ MECHANISM, exercised rather than assumed:
#    `git show <tag>:<path>` against a path the release definitely has.
git -C "${DEST}" show "${RELEASE_TAG}:ui/pyproject.toml" >/dev/null 2>&1 \
	|| fatal "git show ${RELEASE_TAG}:ui/pyproject.toml failed in the baked checkout"

# 5. resolve_checkout()'s four required paths, named one at a time.
#    .git and ui/pyproject.toml are FATAL -- without them nothing about this
#    stage worked. The two fw/scripts entries are reported LOUDLY BY NAME and
#    are NOT fatal, because whether they exist is a property of the RELEASE,
#    not of this build: they landed after v1.1.0. Making them fatal would
#    veto the ratified amendment from inside the build script. The manifest
#    records the verdict so the image declares its own limitation instead of
#    the build silently shrugging.
UPDATER_READY=yes
for p in ui/pyproject.toml fw/scripts/modbus-flash.py fw/scripts/reflex_image.py; do
	if [ -e "${DEST}/${p}" ]; then
		echo "  present: ${p}"
	else
		case "${p}" in
		ui/pyproject.toml)
			fatal "${APP_ROOT}/${p} is missing -- that is not a reflex monorepo tree"
			;;
		*)
			UPDATER_READY=no
			echo "  UNKNOWN: ${p} is ABSENT at ${RELEASE_TAG}."
			echo "           ui/reflex/utils/updater.py:resolve_checkout() lists this"
			echo "           file among the four it refuses without. The in-app"
			echo "           updater on this image will therefore REFUSE at"
			echo "           preflight until the app is updated by hand to a"
			echo "           release that carries it. NOT a build failure: which"
			echo "           files a release contains is the release's property,"
			echo "           and docs/design/seam.md's amendment is ratified."
			;;
		esac
	fi
done

# 6. THE EXACT READ THE AMENDMENT NAMES. Reported, never faked, never skipped.
if git -C "${DEST}" show "${RELEASE_TAG}:ui/reflex/utils/els_stop_map.py" >/dev/null 2>&1; then
	echo "  ok: git show ${RELEASE_TAG}:ui/reflex/utils/els_stop_map.py succeeds"
	PROTOCOL_READABLE=yes
else
	PROTOCOL_READABLE=no
	UPDATER_READY=no
	echo "  UNKNOWN: ui/reflex/utils/els_stop_map.py is ABSENT at ${RELEASE_TAG}."
	echo "           That is the file updater.py reads the TARGET release's"
	echo "           protocol version out of. Its absence AT THE BAKED TAG does"
	echo "           not break the mechanism -- the read is always against the"
	echo "           tag being updated TO, and this checkout can resolve any tag"
	echo "           it has fetched (gate 4 above proves the mechanism). It does"
	echo "           mean the baked release predates the in-app updater, so the"
	echo "           first update on a fresh card is a manual one."
fi

# 7. NO CREDENTIAL SHIPS. seam call 2, and this repo is public.
if grep -qE '://[^/[:space:]]+:[^@/[:space:]]+@' "${DEST}/.git/config" 2>/dev/null; then
	fatal "${APP_ROOT}/.git/config carries a URL with embedded credentials"
fi
for leak in .git/credentials .git-credentials .netrc .git/hooks/post-checkout; do
	[ -e "${DEST}/${leak}" ] && fatal "${APP_ROOT}/${leak} exists -- refusing to bake it"
done
SHIPPED_ORIGIN="$(git -C "${DEST}" remote get-url origin 2>/dev/null || true)"
[ "${SHIPPED_ORIGIN}" = "${REFLEX_ORIGIN_URL}" ] \
	|| fatal "origin is '${SHIPPED_ORIGIN}', expected '${REFLEX_ORIGIN_URL}' -- the build host's source path must not ship"
echo "  origin: ${SHIPPED_ORIGIN} (anonymous; the build source is not shipped)"

# 7b. NOTHING ABOUT THE BUILD SHIPS -- not its source path, not its builder,
#     not a branch the public origin does not have. Each check reads the
#     checkout as it now stands; the scrub above is not taken on trust.
[ -e "${DEST}/.git/logs" ] \
	&& fatal "${APP_ROOT}/.git/logs exists -- the reflog records the build source and the builder's identity"
[ -z "$(git -C "${DEST}" reflog show --all 2>/dev/null | head -n1)" ] \
	|| fatal "${APP_ROOT} still has reflog entries -- they record the build source and the builder's identity"
# Only tags ship, plus origin's remote-tracking refs when they were read from
# the public origin itself. Anything else -- a mirror's branch, a local
# branch, a stash, a note -- is refused BY NAME.
if [ "${PUBLIC_REFS_KNOWN}" = yes ]; then REFS_OK='^refs/(tags|remotes/origin)/'; else REFS_OK='^refs/tags/'; fi
STRAY_REF="$(git -C "${DEST}" for-each-ref --format='%(refname)' | grep -Ev "${REFS_OK}" | head -n1 || true)"
[ -z "${STRAY_REF}" ] \
	|| fatal "${APP_ROOT} carries ${STRAY_REF}, which is not known to be on the public origin (${REFLEX_ORIGIN_URL})"
# The build source's own path or URL, anywhere in .git outside the object
# store. Skipped only when the source IS the shipped origin, where finding it
# is the point.
if [ "${REFLEX_SOURCE}" != "${REFLEX_ORIGIN_URL}" ]; then
	LEAKED="$(grep -rIlF --exclude-dir=objects -- "${REFLEX_SOURCE}" "${DEST}/.git" 2>/dev/null | head -n1 || true)"
	[ -z "${LEAKED}" ] || fatal "${LEAKED#"${ROOTFS_DIR}"} names the build source ${REFLEX_SOURCE}"
fi
# The identity this build's git runs as, when git can say.
BUILDER_IDENT="$(git var GIT_COMMITTER_IDENT 2>/dev/null | sed -E 's/ [0-9]+ [-+][0-9]{4}$//' || true)"
if [ -n "${BUILDER_IDENT}" ]; then
	LEAKED="$(grep -rIlF --exclude-dir=objects -- "${BUILDER_IDENT}" "${DEST}/.git" 2>/dev/null | head -n1 || true)"
	[ -z "${LEAKED}" ] || fatal "${LEAKED#"${ROOTFS_DIR}"} records the builder's git identity"
fi
# No object that only a deleted ref could reach: every object in the store
# must be reachable from what ships.
N_ALL="$(git -C "${DEST}" cat-file --batch-all-objects --batch-check='%(objectname)' | wc -l)"
N_REACH="$(git -C "${DEST}" rev-list --objects --all | wc -l)"
[ "${N_ALL}" -eq "${N_REACH}" ] \
	|| fatal "${APP_ROOT}'s object store holds ${N_ALL} objects but only ${N_REACH} are reachable -- a pruned branch's commits would ship"
echo "  scrubbed: no reflog, no logs/, refs = tags$( [ "${PUBLIC_REFS_KNOWN}" = yes ] && echo ' + origin/*'), ${N_ALL} objects all reachable"

# --- Ownership --------------------------------------------------------------
# The in-app updater runs `git fetch`, `git checkout` and `uv sync` AS THE
# SERVICE USER. A root-owned checkout is refused by resolve_checkout()'s
# sibling preflight the same way a root-owned venv was (fixed in 08-venv
# 2026-09-17) -- and git additionally refuses a repository
# whose owner is not the caller ("detected dubious ownership"), which looks
# nothing like a permissions problem in a log.
#
# Through on_chroot, exactly as 08-venv does, so the names resolve against the
# IMAGE's passwd rather than the build host's. -h re-owns symlinks themselves.
on_chroot << EOF
set -e
id ${SERVICE_USER} >/dev/null
chown -R -h ${SERVICE_USER}:${SERVICE_USER} ${APP_ROOT}
EOF

# GATE, host-side against the rootfs's own uid. find -P (the default) judges
# symlinks themselves, matching the -h above.
NOT_OURS="$(find "${DEST}" ! -uid "${SVC_UID}" -print -quit)"
if [ -n "${NOT_OURS}" ]; then
	echo "FATAL: ${APP_ROOT} is not wholly owned by ${SERVICE_USER} (uid ${SVC_UID});"
	echo "       first offender: ${NOT_OURS#"${ROOTFS_DIR}"}"
	exit 1
fi
echo "  checkout owned by ${SERVICE_USER} (uid ${SVC_UID}), ${TAG_COUNT} tags carried"

# --- Record what was baked --------------------------------------------------
# Written as flat fact files for 11-manifest to READ, exactly the arrangement
# 08-venv/11-manifest already use for the reflex lock commit: one measurement
# of "what went in", not two that could disagree. 11-manifest FATALs if these
# are missing.
install -d -m 0755 "${ROOTFS_DIR}/etc/elspi"
printf '%s\n' "${RELEASE_TAG}"        > "${ROOTFS_DIR}/etc/elspi/reflex-app-release"
printf '%s\n' "${TAG_SHA}"            > "${ROOTFS_DIR}/etc/elspi/reflex-app-commit"
printf '%s\n' "${UPDATER_READY}"      > "${ROOTFS_DIR}/etc/elspi/reflex-app-updater-ready"
printf '%s\n' "${PROTOCOL_READABLE}"  > "${ROOTFS_DIR}/etc/elspi/reflex-app-protocol-readable"

echo "  baked ${RELEASE_TAG} (${TAG_SHA}) at ${APP_ROOT}; app NOT started (order 2026-09-21#1 owns the start gate)"
