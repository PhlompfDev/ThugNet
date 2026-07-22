# ThugNet v2

A CC:Tweaked multi-computer home/base automation system: touchscreen control
panels backed by a rednet DNS/server/client network, a persistent shared-state
bus, telemetry with rates, scenes, automation rules, monitor zoning, a runtime
visual editor, and bundled-redstone control of real in-world mechanisms.

- **Version:** see [`thugnet/version.lua`](thugnet/version.lua) — the single
  source, shown on every front panel and in the boot log.
- **Wire protocol:** `thugnet2` (protocol v2). A separate axis from the app
  version: v1 and v2 nodes coexist harmlessly but cannot see each other.
- **Design spec:** `docs/superpowers/specs/2026-07-21-thugnet-rewrite-design.md`
  is normative; per-phase plans live in `docs/superpowers/plans/`.
- **UI toolkit:** `graphics/` is vendored from
  [cc-mek-scada](https://github.com/MikaylaFischler/cc-mek-scada) (with local
  fixes); `scada-common/` carries its support modules.

## Deploying a node

**This `deployable/` tree is the shipping artifact.** It holds exactly what a
computer runs (`startup.lua`, `setup.lua`, `thugnet/`, `graphics/`,
`scada-common/`, this README) and nothing dev-only — `docs/` and `tests/` live
one level up, outside it. Every computer in the fleet runs the same tree; nodes
differ only by their `config.json`, which is authored on the computer itself —
never copied in.

1. Copy the **contents of `deployable/`** onto the computer's root (so
   `startup.lua` sits at the computer's top level). Nothing to pick out — the
   folder is already the exact ship set.
2. Reboot (or run `startup`). An unprovisioned node launches the **setup
   wizard** automatically: label, roles, and the hosted domain for servers.
   The wizard loops until a valid configuration is saved — a fresh computer
   is never a silent blank terminal.
3. Done. Runtime state (`state.json`, `events.json`, `scenes.json`, …) is
   created as needed and **must start absent** on a fresh node.

Run `setup` at the shell to re-provision a node deliberately. A `config.json`
that is missing *or* invalid (typo'd role, server without a domain) routes
back into the wizard on the next boot, with the problems printed.

**Updating an existing node:** copy the tree over the old one. JSONs are
untouched; `thugnet/migrate.lua` converts any v1 leftovers on boot (originals
kept as `.v1.bak`).

### Roles

| Role | What it does | Typical nodes |
|---|---|---|
| `dns` | Hosts the name server: domain registry, command routing, liveness watchdog, diagnostics. One per network. | C4 |
| `server` | Hosts a domain: executes commands (redstone faces + step sequences), polls sensors, publishes telemetry. | 5–10 |
| `ui` | The full control panel on terminal + monitors (starts a client internally). | C4, pocket |
| `client` | Headless client cache without a panel. Rarely needed alone. | — |

A server node's `config.json` carries `server_domain` as a **provisioning
seed**: it names the domain only until `server_config2.json` exists; after
that the live file owns the name (Rename on the Server page edits it, and a
reboot never reverts it).

Headless nodes (no `ui` role) render a **front panel** on their terminal:
STATUS, a HEARTBEAT LED that toggles every second (a frozen node is visually
obvious), one LED per role, the DNS link state, the hosted domain, the last
warning, and a hardware line (`FW` version / `NET thugnet2` / `SN` serial).

## Architecture

```
startup.lua        boot: wizard gate -> migrate -> role services -> kernel.run()
setup.lua          re-run the provisioning wizard, then chain into startup
thugnet/
  kernel.lua       the single event loop: timers (after/every), event handlers
  config.lua       config.json load/save, defaults, validate (actionable messages)
  setup.lua        first-boot wizard (plain-terminal prompts, injectable io)
  version.lua      the version string (single source)
  migrate.lua      idempotent v1 -> v2 file conversion (configs, editor pages)
  core/
    store.lua      JSON persistence; corrupt files quarantined, never clobbered
    bus.lua        shared state: set/get/watch, opts.persist, debounced saves
    events.lua     unified log + alerts: ring buffer, severity, hooks
    rsio.lua       redstone faces: static/pulse, bundled masks
    steps.lua      the step engine: net/wait steps, retry, abort
    telemetry.lua  sensor pollers, rate derivation (per MINUTE), panel cache
    scenes.lua     named step-engine macros with live progress
    automation.lua rules: time + sensor-condition triggers (hysteresis, sustain)
    custom_pages.lua / editor_store.lua   user pages + their placed widgets
  net/
    protocol.lua   thugnet2 message types + validator
    transport.lua  rednet send/broadcast/request with fids
    dns.lua        registry, routing (routed=true), watchdog, diagnostics
    server.lua     domain host: commands, sequences, sensors, telemetry publish
    client.lua     panel-side cache: domains, state, telemetry, liveness
  ui/
    theme.lua      the palette; sole owner of colors (semantic tokens)
    app.lua        surface lifecycle: terminal + zoned monitors, overlays,
                   sidebar (ListBox; page drawer under 30 cols), rebuilds
    nav.lua        page registry with role/monitor gating and hidden pages
    panel.lua      the headless front panel
    menus.lua      every context menu's content (spec §8 map)
    widgets.lua    section/chip/kv/tile/page_container (honest too-small)
    pages/         dashboard, monitoring, domains, events, dns,
                   server, server_config, scenes, automation, displays, custom
    editor/        the runtime visual editor: factory, wizard, props, colors
graphics/          vendored cc-mek-scada toolkit (fixed: varargs set_value,
                   IndicatorLight redraw/enable, left-click handlers)
scada-common/      toolkit support (log, util, tcd, types, constants)
```

Everything runs on **one kernel event loop** — services register handlers and
timers; nothing blocks. UI pages own their watchers through `ui_ctx.own`, and
every rebuild tears down handles + flasher state (leak-free by test).

## config.json

Authored by the wizard; hand-editable. Validated on every boot — an invalid
file routes to the wizard with the problems named.

| Field | Default | Meaning |
|---|---|---|
| `label` | `node-<id>` | computer label, shown everywhere |
| `roles` | — (wizard) | `{ dns, server, client, ui }` booleans, ≥ 1 required |
| `server_domain` | — | server nodes: the hosted domain (provisioning seed) |
| `theme` | `"dark"` | UI palette |
| `text_scale` | `1.0` | monitor text scale |
| `automation` | `false` | arm the automation engine on this node (one per fleet) |

All other JSONs are runtime state created on the node. None ship with the
repo; `.gitignore` keeps them out (`/*.json`).

## Tests

```
node tests/run.js
```

Offline harness: fengari (Lua-in-JS) + full CC stubs (term/window, rednet,
timers, JSON) — the entire UI renders headless. Rules proven by past defects:

- **Test the fresh-node path**: delete the JSONs your test touches in its
  header. A test that passes because of dev-machine leftovers is the local
  bug class ("works on my machine" = leftover state).
- Leak tests must count the watcher registry (`bus.watcher_count`,
  `telemetry.cache().watcher_count`, `flasher.registered`), not probe hits —
  a leaked watcher can't affect a probe's own count.
- A regression test must **fail without its fix** — verify by sabotage.

## Gotchas (hard-won)

- **Every parallel coroutine's timer branch must call `flasher.step(p1)`** or
  all LED blinking freezes. Same pattern for any future timer chain.
- **`util.strwrap() limit not greater than 0`** means "a child was laid out
  past its parent's right edge" — fix the caller's x/width math, don't chase
  it into util. Clamp widths to `parent_w - x + 1`; monitor zoning makes real
  widths far smaller than the monitor suggests.
- **`bus.set(key, value, opts)` is 3-arg** and `opts.persist = true` is
  required for reboot survival — `bus.init` only auto-marks keys already in
  `state.json`, which hides the omission on a dev node.
- **Anything reading screen content back (`getLine`) must target a window**,
  never a bare terminal redirect — real CC has `getLine` on windows only.
  Overlays anchor on `display.window()` for this reason.
- **LED and IndicatorLight are near-twins that drift** — when fixing either,
  check the other (redraw-discards-value and double-flash were IndicatorLight
  regressions LED had already fixed).
- **`PushButton.set_value(v)` simulates a press** (fires the callback);
  mirroring state without firing needs `set_value(v, true)`.
- **Multi-prompt chains must collect into a local and apply once at the end**
  — applying mid-chain triggers the debounced rebuild whose teardown closes
  the next prompt.
- **`telemetry.derive_rate` is per-minute** (`/m`); check units against the
  producing module, not the consuming plan.
