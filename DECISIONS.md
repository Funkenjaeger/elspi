# Decisions

Smaller calls that are not obvious from the code. The larger one, what goes in
the image and what is left to provisioning, is
[docs/design/seam.md](docs/design/seam.md).

## Releases are promoted test builds, not rebuilds

A release is a test build that passed the bench, published byte-for-byte and
tagged at the commit it was built from. A rebuild on tag could differ from what
was tested (a dependency resolving differently, a newer reflex baked in), and
nothing would catch it. The procedure is in
[flashing.md](docs/flashing.md#releasing-a-tested-build).

## Release tags are made at home, then pushed out

Work is pushed to a home git server and CI runs there; GitHub gets deliberate
pushes of tested `main` and of release tags, never a push mirror. So
`promote-release.ps1` creates the release tag in the checkout — annotated, on
the promoted commit — pushes it to the home remote first, pushes it to GitHub
only then, and creates the GitHub release from that existing tag. A release once
existed on GitHub and nowhere else, because `gh release create` had made the tag
there; that release had to be fetched home afterwards to exist at all. Each push
is read back and the two remotes must carry the same annotated tag object.

## The home remote is a local setting, not something this repo knows

Which remote is the home one cannot be read off a remote NAME — `origin` is the
home remote in one checkout and GitHub in another. It cannot be read off a URL
either, and that is the stronger reason: elspi is public, so a host name or a
repository path written into the source, the tests or the docs is one operator's
setup shipped to everybody, and wrong for everybody else. So the answer is
asked for once per checkout and read with `git config`: `elspi.homeRemote` names
the remote. It lives in `.git/config`, which is never committed.

That setting is the whole rule. There is no URL matching, no built-in default
and no guess — unset, or naming a remote the checkout does not have, is a
refusal that prints the `git config` command to run. A wrong guess pushes a
release tag, or fetches a commit, from the wrong place, and the cost of the
refusal is one command typed once per clone.

The same resolver serves `flash-test-build.ps1`, which has to fetch a build's
commit when the checkout does not have it yet. That fetch used to name `origin`,
which is the wrong remote in exactly the checkouts where the commit is missing:
the build ran at home, and the commit may not be on GitHub at all.

## 64-bit is the main line; armhf is retired

`main` is the 64-bit (arm64) line and gets all new work. The 32-bit armhf line
is retired to the tag `armhf-final`; it can still be built from that tag, and
nothing is lost, since its last commit is part of `main`'s history. The payoff is Kivy: PyPI has a prebuilt aarch64 wheel, so nothing is compiled
from source, and its SDL2 drives the display without X. That has been seen on
one Pi 5; other hardware may differ.

## A fresh card boots into the UI, but not onto defaults

The image carries the newest full reflex release, and a one-shot first-boot
hook starts it with no network needed. It starts the app only if that release
has reflex's commissioning guard, which brings an unrestored machine up as
UNCOMMISSIONED rather than quietly running, and saving, default geometry. The
hook runs once and never overrules a service someone has already configured.

Because the app may already be running when provisioning restores a backup,
`provision.sh` stops it first; otherwise its next save could write defaults
over the geometry just restored.

## Smaller calls behind the home-first release tag

**The tag is annotated, messaged `elspi <tag>`, and not signed.** An annotated
tag is one object with one sha, so "both remotes carry the same tag" is a single
comparison instead of a guess about what a lightweight ref means. A tag that
turns out to point straight at the commit is refused.

**`gh release create` gets `--verify-tag` and no `--target`.** `--target` is how
the tag came to be created on GitHub in the first place, and GitHub ignores it
once the tag exists. `--verify-tag` makes `gh` fail rather than invent a tag, so
the only way a release exists is from a tag that already went home.

**Only the home remote refuses on none-or-many.** The GitHub push prefers a
remote of the checkout whose URL names the repo, so an existing ssh remote and
its key keep working; with none, or several, it pushes to the https URL every
read in the script already uses. Home has no such fallback — there is nothing
safe to guess.

**The tag name must be free in all three places it is about to exist:** the
checkout, the home remote, and GitHub. The automatic pick skips a day taken in
any of them, so `v2026.09.26.1` is chosen when the bare name exists only at
home. A name left in the checkout by a run that stopped half-way is reported as
such, with how to remove it.

**The release read-back expects an annotated tag object on GitHub.** The ref has
to be the object that was pushed, dereferenced to the promoted commit; a ref
pointing straight at a commit means something else made the tag, and is refused.

**`docs/flashing.md` said the release line was the branch `arm64`.** It is
`main` — the release procedure was the last place still naming the retired
branch, and the code it describes already checked `main`.

## Smaller calls behind the local home-remote setting

### One key, and no URL matching at all

An earlier round of this had a second key that matched remote URLs, plus a
built-in rule for the shape of the author's own remote. Both were dropped. A URL
rule shipped in a public repo is a guess about everybody's setup extrapolated
from one person's; it has to carry an example of that setup — a host name or a
path — to be written down at all; and it can be wrong silently, which is the one
failure this whole decision exists to prevent. One key that is either set or
refused has no wrong answer available to it.

What it costs is one `git config` line per clone, once, printed verbatim by the
refusal that demands it. That is a fair price for a rule that cannot be wrong
and a repo that says nothing about where anybody's server is.

### The resolver lives in `flash-test-build.ps1`, and is shared

`promote-release.ps1` already dot-sources `flash-test-build.ps1` for the
functions they share, so the resolver went in the same place rather than being
written twice. Two copies of "which remote is home" is exactly the kind of pair
that drifts, and they would then disagree about a release.

### `flash-test-build.ps1` resolves it only when it actually needs to

The fetch happens only when the build's commit is missing from the checkout, so
the resolver is called there and not in preflight: a normal flash of a commit you
already have never needs the setting, and never refuses for the want of it.
`promote-release.ps1` is the other way round — it resolves in preflight, before a
gigabyte is hashed, because it always has to push the tag home.

### A refusal prints the command that fixes it

Every way the home remote can fail to resolve ends in the same
`git config elspi.homeRemote <remote-name>` line, with the checkout's remotes
listed beside it. A refusal that only says "cannot tell" costs a search through
the source; this one is a copy-and-paste.

### The tests' URLs are placeholders, and are never read

Every remote URL in the tests is a reserved-example placeholder — `example.com`,
`/srv/example.git`. Nothing resolves them and nothing matches them: they are
there so a fixture looks like a checkout. A test fixture is the easiest place
for a real address to end up published by accident, and here there is not even a
rule that would give one a reason to exist.

## One config key, and no URL rule at all

Neither a URL-pattern key nor a built-in path rule survives: `elspi.homeRemote`
is the only input, and unset is a refusal that names it. The key keeps the name
an earlier round gave it, so a checkout already configured needs no change. The
cost is one `git config` line per clone; the gain is that nothing in a public
repo has to describe anybody's machine.

## Placeholder fixtures, and the one URL match left

Test fixtures are reserved example names — `example.com`, `/srv/example.git` —
and nothing reads them, so a real address has no reason to appear in a test.
`Resolve-GitHubPushTarget` still matches `github.com/<repo>` against remote
URLs; that is this repo's own published address, it picks only which remote a
public tag is pushed through, and it falls back rather than refusing.
