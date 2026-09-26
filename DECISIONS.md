# Decisions

## 2026-09-26 order 2026-09-25#1: resolve_service_user stays paired with need_root, not moved ahead of it

Order's words: "Pure validation = ... anything that only READS." `resolve_service_user`
(lib.sh:94-105) only reads (the image manifest, then `id <user>`) so it technically
qualifies. Choice: left it immediately AFTER `need_root` in both 01-converge.sh and
03-interactive.sh, rather than grouping it with the other pure-read validation ahead of
the gate. Alternative: move it before `need_root` too, since it never writes.
Why: 02-restore.sh only calls it at its own write boundary (:243, right after its
`need_root` at :242), never earlier — the established shape pairs it with the write
phase, not the argument gates. It can also fail for reasons that have nothing to do with
the caller's arguments (no `/etc/elspi-image.json`, no matching account on this
machine), which is a different kind of refusal than "this input is bad" and moving it
ahead would let an unrelated environment gap mask a validation message the same way
`need_root` used to.

## 2026-09-26 order 2026-09-25#1: resolve_paths runs before require_app_dir in 01-converge.sh

Order pins where `need_root` moves to in each file but not the internal order among the
pure-validation reads now ahead of it. Choice: kept `resolve_paths` before
`require_app_dir "${APP_ARG}"` (their original relative order). Alternative: reverse
them, since require_app_dir does not read anything resolve_paths sets.
Why: matches 02-restore.sh's own comment (:115-116): "CONFIG_DIR is needed by both paths
below and resolving it needs neither root nor a service user to exist yet, so it happens
unconditionally, up front." Neither function can fail on the other's account, so the
order carries no correctness weight — this just avoids gratuitously reshuffling beyond
what moving `need_root` required.

## 2026-09-26 order 2026-09-25#1: 03-interactive.sh's tty check counted as pure validation

The order's definition of pure validation ("argument parsing, required-flag and
mutual-exclusivity checks, checkout/path existence, site.env parsing and validation, and
any 'what would run' summary") does not name a tty check by name. Choice: treated
`[ ! -t 0 ] || die "stdin is not a terminal..."` (03-interactive.sh) as pure validation
and moved it ahead of `need_root` along with the other reads. Alternative: leave it
paired with `need_root` on the theory that it is an environment precondition like
`resolve_service_user`, not an argument check.
Why: it only reads stdin's own state (no write, no dependency on the local machine's
image manifest or accounts) and is exactly the kind of "what would run" gate the order
describes — an unattended, non-interactive caller should be told THAT reason, not
refused for being non-root, which is the whole point of the reorder.

## 2026-09-26 order 2026-09-25#1: no live-tty "control" case in test-interactive-contract.sh

test-restore-contract.sh's style includes a "control" case proving a well-formed input
gets past the gates under test, and test-converge-contract.sh has one (a well-formed
--app reaching need_root). Choice: 03-interactive.sh's contract test has no equivalent —
only the tty-refusal cases and an unrelated arg-parsing regression case.
Alternative: fake a controlling tty (a pty via `script` or Python's `pty.fork`, both
confirmed working in this sandbox) and feed scripted answers past every `ask_yn` prompt
so the run reaches `need_root`.
Why: doing that safely needs answers for every prompt in phase 3 (password, SSH key,
network) or it can block on a `read`, and a test that can hang is worse than one that
is merely incomplete (assert-on-code-form / never-test-by-detonating spirit). The
RED-then-GREEN transition on the tty message itself is the property this order asked
to prove; a control case here would exercise phase 3's prompt flow, not the gate order.

## 2026-09-26 order 2026-09-25#1: no validation step was found to write

Checked each step now sitting ahead of `need_root` in all three files —
`resolve_paths`, `require_app_dir` (01-converge.sh); `resolve_paths`, the APP_DIR
fallback logic, the tty check (03-interactive.sh); the `--app`/mutual-exclusivity/
`--config-backup` checks (provision.sh) — against lib.sh's own definitions. None calls
`run`, `install`, `mkdir`, `mv`, `cp`, `chown`, or any other write. None needed to stay
behind `need_root` on those grounds, so this entry records the check rather than a
change: the bound's "list it in the report instead of moving it" clause did not fire.

## 2026-09-26 first-boot-ui

Branch `feat/first-boot-ui`: "a fresh elspi card boots straight into the UI", items 1-4
of the 2026-09-13 decision.

### The vendored reflex dependency set is bumped to v1.2.0 (the branch's first commit)

`stage-elspi/08-venv/files/{REFLEX_COMMIT,pyproject.toml,uv.lock}` pinned
`v1.2.0-rc.3` (`43ac7c5`). Now `REFLEX_COMMIT` is `f776eae0a1782ede3e7a3882ce7ad85742ebff20`
(tag `v1.2.0`, released 2026-09-25) and both files are reflex's `ui/pyproject.toml` and
`ui/uv.lock` at that tag, byte-identical (same git blob ids). The only dependency change
is `segno` (added in reflex 2026-09-17 for the device-flow QR). Why: Evan's gate of
2026-09-22 was "cut v1.2.0 from main BEFORE the first image bake", so the image the
first card is baked from pairs its venv with v1.2.0 — the same release `10a-app-checkout`
selects as the newest full release — rather than with a pre-release two weeks older.
`tests/test-lockfile-drift.sh` against a checkout of reflex at `v1.2.0`: `RESULT: in sync`.
