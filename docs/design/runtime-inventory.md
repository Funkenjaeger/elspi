# Runtime requirements

What `reflex-ui` needs from the OS. Measured on one machine, a Raspberry Pi 5
with a USB touchscreen; other hardware may differ. The package lists are in
`stage-elspi-pkgs/`, and `tests/verify-image.sh` checks them.

- **Beyond pi-gen Lite:** the SDL2 and GL/EGL runtime for Kivy, the V3D Mesa
  driver, `libmtdev` for the touchscreen, and `network-manager` (the UI shells
  out to `nmcli`).
- **No display server.** SDL2 drives the screen through KMS/DRM only because
  there is no X server or Wayland compositor to find. Installing one would
  silently change the backend, so the image check treats it as a failure. The
  X11/Wayland client libraries stay; SDL2 links against them.
- **The UI runs as `default`, not root.** It gets the display by being the first
  process to open it after the boot splash exits. If that ever fails,
  `elspi-drm-mode cap-sys-admin` switches to a capability grant without a
  reflash. Only real hardware can confirm the display works.
