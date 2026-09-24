# Example site layer

A skeleton to copy into your own private site layer, not a hooks directory to
point `--site-hooks` at directly — see `docs/site-layer.md` for the contract
this follows. `build/site.conf.example` is a starting point for
`ELSPI_SITE_CONF`; `hooks/` is a starting point for `--site-hooks`, including
one placeholder hook (`hooks/10-example-extra-key.sh`) and a `site.env.example`
for the settings `provision.sh` loads before phase 1. Every `*.example` file
here has placeholder values only — rename it (dropping `.example`) and edit it
in your own copy, never in this repo.
