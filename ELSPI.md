# elspi — user-facing notes

This file exists because `README.md` is upstream pi-gen's, unmodified on
purpose — see [FORK.md, "Keep the merge surface small"](FORK.md#keep-the-merge-surface-small).
Anything a *user* of a built elspi image needs (as opposed to a contributor
building or merging this repo) goes here instead of editing that file.

## Flashing

Once a release is published on GitHub, flashing a card needs Raspberry Pi
Imager and one command — no checkout, nothing downloaded by hand.

**Windows**, from Win+R, cmd or PowerShell alike:

    cmd /c start rpi-imager --repo https://github.com/Funkenjaeger/elspi/releases/latest/download/os_list.json

**Linux**:

    rpi-imager --repo https://github.com/Funkenjaeger/elspi/releases/latest/download/os_list.json

Raspberry Pi Imager 2.x from raspberrypi.com is required — distro packages
ship 1.x, which seeds a card via `firstrun.sh`, and this image ignores that
file entirely. Imager downloads and verifies the image itself; nothing is
downloaded by hand. Take the one OS entry it offers, then fill in the
customisation page (user `default`, public-key SSH only, Wi-Fi, country US)
— see [FLASH-SESSION.md](FLASH-SESSION.md#flashing-the-card) for what each
field means and why.

`releases/latest/download/<asset>` is GitHub's stable redirect to the newest
release's asset, not a fixed URL — it always resolves to whatever was tagged
most recently. Imager follows redirects on both fetches this needs: the
`--repo` list and, from the URL that list contains, the image itself
(measured in the rpi-imager source 2026-09-13: `CURLOPT_FOLLOWLOCATION` is set
for the image download, and the OS-list fetcher tracks an `effectiveUrl`
through its own redirect chain).

A specific release's page carries the same two commands pinned to its own
tag instead of `latest` — see `tools/release-notes.sh`, which generates that
block.
