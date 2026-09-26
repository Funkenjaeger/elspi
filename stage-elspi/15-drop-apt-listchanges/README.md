# 15-drop-apt-listchanges

Purges `apt-listchanges`, which upstream's stage2 installs.

**What it is:** a changelog viewer for interactive `apt upgrade` runs. elspi is
an appliance: nothing on the image depends on it (checked 2026-09-26 with
`apt-cache rdepends --installed`), and its timer ends up disabled anyway.

**Why it goes:** upstream's `export-image/05-finalise/01-run.sh:13-15` runs
`python3 -m apt_listchanges.populate_database` in the chroot whenever the
package's service file exists. On a runner that emulates arm64 through qemu,
that step alone took most of an 11-minute finalise (Forgejo runner, reuse
build of 74e2208). On a native arm64 runner it costs seconds, so GitHub builds
barely change.

**Why here, not upstream's files:** editing `stage2/01-sys-tweaks/00-packages`
or the finalise script would be a merge conflict on every upstream sync
(`docs/design/fork.md`). This is the last sub-stage, so no later install can
bring it back. Its dependencies (`python3-apt`, `python3-debconf`,
`sensible-utils`, `ucf`) are left installed: no autoremove, so the package list
changes by exactly one package.

The step fails the build if the service file finalise tests for is still
present.
