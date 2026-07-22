# ThugNet changelog

Newest first. The Settings > Updates tab reads this file, showing the
sections newer than the version a node currently runs.

## v2.1.0

- **Easy Updater** — nodes now update themselves from GitHub. Settings >
  Updates shows the installed and available version, with a one-click
  update that stages, verifies, and swaps atomically.
- **Settings page** — node rename, roles, automation authority, and reboot,
  all in one place instead of scattered across pages and the setup wizard.
- Updates never touch your configs: every runtime `.json` is left alone.

## v2.0.1

- Sensor Quick Setup: auto-discovers reachable blocks and highlights only
  the sensor kinds each block can actually back.
- Unreadable sensors now show as `ERR` in Monitoring instead of vanishing.
