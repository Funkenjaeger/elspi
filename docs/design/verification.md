# Verifying the image

| Tier | Proves | Runs |
|---|---|---|
| 1. Scripts and contracts | build and provisioning logic | CI, every push |
| 2. The built image matches its declaration | packages, users, units, files | a build host (`tests/verify-built-image.sh`) |
| 3. It runs the lathe | display, touchscreen, controller link | real hardware only |

A clean Tier 2 says the userland is what was declared, not that the machine
works. What only hardware can prove is listed in the image's own manifest, and
the harness reports those items as UNKNOWN, never as passes. Tier 2's in-image
checks currently run only on armhf.

The harness also tests itself: `tests/self-test.sh` breaks each declared
property in turn and requires Tier 2 to fail, so a check that cannot fail is
caught.
