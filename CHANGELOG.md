# ThugNet changelog

Newest first. The Settings > Updates tab reads this file, showing the
sections newer than the version a node currently runs.

## v2.2.0

- **Feature Requests from the panel** — Settings > Updates > Feature Request
  opens a composer that files your request straight into the public inbox
  the build agent watches. A Sent Requests page shows what each request's
  status is (waiting, in progress, shipped, and so on).
- Sending needs a GitHub token set once per node (Set Token... on the page);
  checking statuses works without one.

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
