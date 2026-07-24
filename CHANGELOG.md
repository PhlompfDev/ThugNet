# ThugNet changelog

Newest first. The Settings > Updates tab reads this file, showing the
sections newer than the version a node currently runs.

## v2.2.15

- The setup wizard's theme choice now previews instantly as you click Dark or Light, instead of only changing after you finish the wizard.
- Tidied the Status page: removed the cluttered signal bars and gave the DNS and Server status lights more breathing room so they no longer crowd the section dividers.

## v2.2.14

- **New Status page.** A dedicated diagnostics screen (in the sidebar under the home area) shows your node at a glance: name/ID/version/uptime, live DNS and Server heartbeat LEDs with a signal bar, and a roster of every domain on the network -- each pulsing green when alive, solid red when down -- plus a firmware/network/serial line, styled like an industrial network panel.

## v2.2.13

- Fresh coat of paint, with a new industrial "network panel" look inspired by cc-mek-scada.
- **Light theme.** Settings now has a Visual tab where you can switch between the dark and a new light theme -- it applies instantly and is saved per computer. You can also pick your theme right in the setup wizard.
- **Redesigned setup wizard.** The first-boot wizard is now a guided flow: a welcome screen, one step at a time with progress dots, a "can't continue until it's filled in" Next button, a theme choice, and a review screen before anything is saved -- no more cramped buttons on small screens.
- **Live status in the header.** Every screen's top-right corner now shows DNS and Server heartbeat LEDs plus a signal bar, so link health is always visible at a glance.

## v2.2.12

- One-line install for a fresh computer: run `wget run https://raw.githubusercontent.com/PhlompfDev/ThugNet/main/install.lua` in the terminal and it downloads the whole system (verifying every file) and reboots into the setup wizard -- no more copying the folder in by hand.
- Re-running the installer on an existing computer is a safe repair: it only rewrites program files and never touches your config or saved state.

## v2.2.11

- The Updates screen no longer shows an empty gray bar when nothing is downloading -- the progress bar now appears only while an update is actually in flight, and there's a bit more breathing room above the Check Now button.

## v2.2.10

- The update screen now shows live progress: the file currently downloading, a fill bar, and how far along the download is -- instead of sitting at 0/x until it finishes.
- If a file stalls, the screen now shows the retry (e.g. "retry 2/3") as it happens, so a slow update no longer looks frozen.

## v2.2.9

- Home page DNS and Server dots now show live status: they pulse green while the service is up and turn solid red when it is down (stopping the server now turns its dot red instead of staying green).
- Monitoring page updates an inventory sensor's breakdown live -- no manual refresh needed.
- Switching pages no longer flickers monitors.
- The What's New changelog now wraps long lines instead of cutting them off, and is cached so it is only fetched once per version.
- Added breathing room above the New Rule / New Scene / event filter buttons.

## v2.2.8

- Updates are more resilient: a file that briefly stalls while downloading is now retried instead of failing the whole update, and requests are paced to avoid rate-limit stalls.

## v2.2.7

- Monitoring page now removes sensors when they are deleted and stays in sync as sensors are added or changed. Offline sensors still appear (shown as down); a new right-click "Forget sensor" option clears a lingering one.

## v2.2.6

- more UI changes and performance changes

## v2.2.5

- Adds spacing on the Settings page between the header and tabs, around the Feature Request button, and between the role checkboxes.

## v2.2.4

- Makes the Settings update button's label readable while it is greyed out.

## v2.2.2

- Fixes sending a feature request crashing with "attempt to use a closed
  file". The update checker and the feature-request sender share the same
  network events, and each was closing responses that belonged to the
  other. Both now leave responses alone unless they asked for them.

## v2.2.1

- Fixes v2.2.0 failing to boot after install (`unexpected symbol near
  '\239'` — an invisible byte-order mark at the top of one file that CC's
  Lua loader rejects). If a node installed v2.2.0 and errored, just reboot
  it until it comes up (auto-rollback restores v2.1.0 by itself), then
  update again from Settings.

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
