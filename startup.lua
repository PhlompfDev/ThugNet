-- ThugNet v2 entry point (the sole startup; v1 startup.lua + demo/ retired).
local base = fs.getDir(shell.getRunningProgram())
package.path = package.path .. string.format(";%s/?.lua;%s/?/?.lua;%s/?/?/?.lua", base, base, base)

-- Rollback gate. Must run before EVERY other require, not just before
-- reading a file: checksum verification proves the downloaded bytes matched
-- the server's, it does NOT prove the Lua parses. If an update ships a
-- syntax error in kernel/config/store/bus/events/rsio/steps/telemetry/
-- protocol/transport/migrate, `require`-ing that module throws at load time
-- -- before any of those modules' own code ever runs, let alone reads a
-- file. CC:Tweaked does not auto-reboot on a script error, and a manual
-- reboot just re-runs the identical broken require, so putting this gate
-- after those requires (as an earlier revision did) meant the rollback
-- marker was never reached and automatic recovery never triggered, no
-- matter how many times the node was rebooted. Requiring updater itself
-- here (rather than trusting a `local updater` bound further down) means a
-- broken updater.lua is also caught by this pcall -- see the residual
-- limitation noted on rollback_if_needed() for why that one specific case
-- still can't be recovered from.
do
    local ok, rolled = pcall(function()
        return require("thugnet.core.updater").rollback_if_needed()
    end)
    if ok and rolled then
        print("ThugNet: update boot failed; rolled back to the previous version")
    end
end

local kernel    = require("thugnet.kernel")
local config    = require("thugnet.config")
local store     = require("thugnet.core.store")
local bus       = require("thugnet.core.bus")
local events    = require("thugnet.core.events")
local rsio      = require("thugnet.core.rsio")
local steps     = require("thugnet.core.steps")
local telemetry = require("thugnet.core.telemetry")
local protocol  = require("thugnet.net.protocol")
local transport = require("thugnet.net.transport")
local migrate   = require("thugnet.migrate")
local updater   = require("thugnet.core.updater")
local requests  = require("thugnet.core.requests")

-- convert any v1 files before anything reads them — INCLUDING the wizard
-- gate: validation and the wizard's domain prefill must see the migrated
-- server_config2.json, not the v1 original (a v1 upgrade's wizard answer
-- would otherwise be silently discarded)
local migrated = migrate.run(store)

-- first-boot gate: an absent OR invalid config.json launches the setup wizard
-- (one path covers fresh nodes, typo'd hand edits, and upgrades that add
-- required fields) — a fresh computer is never a silent blank terminal
local setup = require("thugnet.setup")
-- provision() picks the graphical wizard on a color terminal big enough for it,
-- else the plain-terminal wizard; both save through the same setup.commit core
if setup.needed() then setup.provision() end

local cfg = config.load()
os.setComputerLabel(cfg.label)

bus.init(kernel, store, "state.json")
events.init(kernel, store, "events.json")
rsio.init(kernel)
steps.init(kernel)
transport.init(kernel, protocol)
updater.init{ kernel = kernel, store = store, bus = bus, events = events }
-- feature requests need cfg (token + node label), so init after config.load
requests.init{ kernel = kernel, store = store, bus = bus, events = events,
               config = cfg }

for _, name in ipairs(migrated.migrated) do
    events.log("info", "kernel", "migrated v1 file: " .. name)
end

-- flush state on shutdown
kernel.on_event("terminate", function()
    bus.flush()
end)

-- ── role-based services ──────────────────────────────────────────────────
local deps = { kernel = kernel, transport = transport, protocol = protocol,
               store = store, events = events }

local dns_service, server_service

if cfg.roles.dns then
    dns_service = require("thugnet.net.dns")
    dns_service.start(deps)
end

if cfg.roles.server then
    -- the seed names the wizard-chosen domain on a fresh node only; once
    -- server_config2.json exists the live file owns the name (Rename edits it)
    server_service = require("thugnet.net.server")
    server_service.start({
        kernel = kernel, transport = transport, protocol = protocol,
        store = store, events = events,
        rsio = rsio, steps = steps, telemetry = telemetry,
    }, setup.server_seed(cfg))
end

-- the client cache backs every panel; also start it for headless client role
local telemetry_cache = telemetry.cache(kernel)
local client = nil
if cfg.roles.ui or cfg.roles.client then
    client = require("thugnet.net.client")
    client.start({
        kernel = kernel, transport = transport, protocol = protocol,
        store = store, events = events, telemetry_cache = telemetry_cache,
    })
end

if cfg.roles.ui then
    local nav = require("thugnet.ui.nav")
    nav.register(require("thugnet.ui.pages.dashboard"))
    nav.register(require("thugnet.ui.pages.monitoring"))
    nav.register(require("thugnet.ui.pages.domains"))
    nav.register(require("thugnet.ui.pages.events"))
    nav.register(require("thugnet.ui.pages.dns"))
    nav.register(require("thugnet.ui.pages.server"))
    nav.register(require("thugnet.ui.pages.server_config"))
    nav.register(require("thugnet.ui.pages.scenes"))
    nav.register(require("thugnet.ui.pages.automation"))
    nav.register(require("thugnet.ui.pages.displays"))
    nav.register(require("thugnet.ui.pages.settings"))
    nav.register(require("thugnet.ui.pages.feature_request"))
    nav.register(require("thugnet.ui.pages.sent_requests"))
    local custom_pages = require("thugnet.core.custom_pages")
    local custom = require("thugnet.ui.pages.custom")
    local editor_store = require("thugnet.core.editor_store")
    custom_pages.init{ store = store }
    -- before sync: building a custom page reads its placed elements
    editor_store.init{ store = store }
    -- an unreadable element file otherwise looks exactly like "you placed nothing"
    if editor_store.was_corrupt then
        events.log("warn", "ui", "editor_elements.json was unreadable; "
            .. "the original is kept as editor_elements.json.corrupt")
    elseif editor_store.dropped_content then
        events.log("warn", "ui", "some editor elements could not be read; "
            .. "the original is kept as editor_elements.json.unreadable.bak")
    end
    custom.sync(custom_pages.list())
    local scenes = require("thugnet.core.scenes")
    scenes.init({
        kernel = kernel, store = store, events = events,
        client = client, telemetry_cache = telemetry_cache, rsio = rsio,
        steps = steps,
    })
    local automation = require("thugnet.core.automation")
    automation.init({
        kernel = kernel, store = store, events = events,
        telemetry_cache = telemetry_cache, scenes = scenes, client = client,
        config = cfg,
    })
    if cfg.automation then automation.arm() end

    -- Auto-update must never reboot through a running command sequence (it
    -- would leave redstone outputs latched partway) or out from under an open
    -- menu. This probe is the gate; the updater polls it and only then starts
    -- its cancellable countdown.
    local cmenu = require("graphics.context_menu")
    local tprompt = require("graphics.text_prompt")
    updater.set_idle_probe(function()
        if cmenu.is_active() or tprompt.is_active() then return false end
        if server_service and server_service.get_runs then
            for _ in pairs(server_service.get_runs()) do return false end
        end
        if scenes.is_running and scenes.is_running() then return false end
        return true
    end)
    updater.on_notify(function(version)
        events.log("info", "update",
            "ThugNet v" .. version .. " available -- Settings > Updates")
    end)

    require("thugnet.ui.app").start({
        kernel = kernel, bus = bus, events = events, config = cfg,
        client = client, telemetry_cache = telemetry_cache, store = store,
        transport = transport, updater = updater,
        -- live service handles so the home/header status dots mirror the real
        -- network state (server running? DNS up?) instead of static config
        server = server_service, dns = dns_service,
        on_sidebar_menu = {
            new_page = function(name)
                custom_pages.add(name)
                custom.sync(custom_pages.list())
            end,
            rename = function(id, name)
                custom_pages.rename(id, name)
                custom.sync(custom_pages.list())
            end,
            delete = function(id)
                custom_pages.delete(id)
                -- ids are never reused, so orphaned defs would linger forever under
                -- a dead key rather than being inherited by a later page
                editor_store.clear_page(id)
                custom.sync(custom_pages.list())
            end,
        },
    })
    updater.start_schedule()
end

events.log("info", "kernel",
    "ThugNet v" .. require("thugnet.version") .. " booted: " .. cfg.label)

-- Headless feedback: without the `ui` role nothing paints, so a bare terminal
-- otherwise looks like a crash. Print a one-line status (spec §3.2) — and shout
-- if the node has no roles at all, which means config.json wasn't provisioned.
if not cfg.roles.ui then
    -- headless node: a live front panel on the terminal (heartbeat, role and
    -- link LEDs, last warning) instead of one printed line and silence
    require("thugnet.ui.panel").start({
        kernel = kernel, config = cfg, events = events,
        dns = dns_service, server = server_service, client = client,
    })
    updater.start_schedule()
end

-- This boot got all the way here, so the new version works: disarm rollback.
updater.boot_ok()

kernel.run()
