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
