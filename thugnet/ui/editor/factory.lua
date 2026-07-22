-- Turns a stored element def into a live graphics element wired to the bus and
-- the network client, and -- just as importantly -- tears it back down without
-- leaking. The editor rebuilds elements on every property edit, so teardown runs
-- constantly; see the framework hazards in the phase 6b plan.
local ui     = require("graphics.ui")
local cmap   = require("thugnet.ui.editor.colors")
local scenes = require("thugnet.core.scenes")

local factory = {}

-- Interactive first, then Display -- the order the type picker presents
factory.TYPES = {
    "PushButton", "SwitchButton", "Checkbox", "RadioButton",
    "LED", "IndicatorLight", "TextLabel", "HorizontalBar",
    "SensorBar", "SensorReadout", "StorageBreakdown",
}

local SCHEMES = {
    green_red    = { colors.green,  colors.red },
    blue_red     = { colors.blue,   colors.red },
    yellow_gray  = { colors.yellow, colors.gray },
    white_black  = { colors.white,  colors.black },
}

local function col(name, fallback)
    return cmap.to_color(name) or fallback
end

-- The effective colour of every editable slot when the def leaves it unset, as
-- NAMES. Single source: the builders below render from this table, and the
-- props colour prompts pre-fill from it -- so what the prompt shows is exactly
-- what the element is already painted with, never an empty box.
factory.COLOR_DEFAULTS = {
    PushButton       = { fg = "black", bg = "lightGray", afg = "white", abg = "gray" },
    SwitchButton     = { fg = "white", bg = "gray",      afg = "white", abg = "green" },
    Checkbox         = { fg = "black", bg = "lightGray" },
    RadioButton      = { fg = "black", bg = "lightGray" },
    LED              = { fg = "black", bg = "lightGray" },
    IndicatorLight   = { fg = "black", bg = "lightGray" },
    TextLabel        = { fg = "white", bg = "lightGray" },
    HorizontalBar    = { fg = "white", bg = "lightGray", bar_fg = "green", bar_bg = "gray" },
    SensorBar        = { fg = "white", bg = "lightGray", bar_fg = "green", bar_bg = "gray" },
    SensorReadout    = { fg = "white", bg = "lightGray" },
    StorageBreakdown = { fg = "white", bg = "lightGray" },
}

-- def's colour for `field`, falling back to the type's default above
local function dcol(def, field)
    local d = factory.COLOR_DEFAULTS[def.type] or {}
    return col(def[field], colors[d[field]] or colors.white)
end

local function scheme_pair(def)
    local s = SCHEMES[def.scheme or "green_red"] or SCHEMES.green_red
    return ui.cpair(s[1], s[2])
end

-- LED/IndicatorLight assert util.is_int(period) and the flasher only has three
-- buckets, so anything outside 1..3 (or a float from a hand-edited JSON) would
-- crash the element rather than the editor.
local function period_of(def)
    local p = math.floor(tonumber(def.period) or 2)
    if p < 1 or p > 3 then p = 2 end
    return p
end

-- Fire a command through the client, tolerating a missing client (offline tests,
-- a node without the client role).
local function sender(ui_ctx, domain, cmd)
    return function()
        if cmd and cmd ~= "" and domain and domain ~= "" and ui_ctx.client then
            ui_ctx.client.send(domain, cmd, {})
        end
    end
end

local builders = {}

builders.PushButton = function(parent, def, ui_ctx)
    -- route = "scene" fires a panel-side scene; anything else (nil, "cmd", or a
    -- v1 leftover) is the command path through the client
    local function fire()
        if def.route == "scene" then
            if def.scene and def.scene ~= "" then scenes.run(def.scene) end
        else
            sender(ui_ctx, def.domain, def.cmd_true)()
        end
    end
    local e = ui.PushButton{ parent = parent, x = def.x, y = def.y, text = def.label or "",
        fg_bg = ui.cpair(dcol(def, "fg"), dcol(def, "bg")),
        active_fg_bg = ui.cpair(dcol(def, "afg"), dcol(def, "abg")),
        callback = fire }
    -- mirrored = true: a bare set_value(true) SYNTHESIZES A CLICK and would fire
    -- the route every time the bus updated
    return e, function(v) if v then e.set_value(true, true) end end
end

builders.SwitchButton = function(parent, def, ui_ctx)
    local e
    e = ui.SwitchButton{ parent = parent, x = def.x, y = def.y, text = def.label or "",
        default = false,
        fg_bg = ui.cpair(dcol(def, "fg"), dcol(def, "bg")),
        active_fg_bg = ui.cpair(dcol(def, "afg"), dcol(def, "abg")),
        callback = function(state)
            local cmd = state and def.cmd_on or def.cmd_off
            sender(ui_ctx, def.domain, cmd)()
            if def.var_name and ui_ctx.bus then
                ui_ctx.bus.set(def.var_name, state, { source = e, persist = true })
            end
        end }
    return e, function(v) e.set_value(v == true) end
end

builders.Checkbox = function(parent, def, ui_ctx)
    local e
    e = ui.Checkbox{ parent = parent, x = def.x, y = def.y, label = def.label or "",
        default = false,
        box_fg_bg = ui.cpair(dcol(def, "fg"), dcol(def, "bg")),
        fg_bg = ui.cpair(dcol(def, "fg"), dcol(def, "bg")),
        callback = function(state)
            if def.var_name and ui_ctx.bus then
                ui_ctx.bus.set(def.var_name, state, { source = e, persist = true })
            end
        end }
    return e, function(v) e.set_value(v == true) end
end

builders.RadioButton = function(parent, def, ui_ctx)
    local opts = def.options
    if type(opts) ~= "table" or #opts == 0 then opts = { "a" } end
    local e
    e = ui.RadioButton{ parent = parent, x = def.x, y = def.y, options = opts,
        radio_colors = ui.cpair(col(def.radio_a, colors.green), col(def.radio_b, colors.white)),
        select_color = col(def.select_color, colors.blue),
        fg_bg = ui.cpair(dcol(def, "fg"), dcol(def, "bg")),
        callback = function(idx)
            if def.var_name and ui_ctx.bus then
                ui_ctx.bus.set(def.var_name, idx, { source = e, persist = true })
            end
        end }
    return e, function(v) e.set_value(tonumber(v) or 1) end
end

local function indicator(ctor)
    return function(parent, def, _)
        local args = { parent = parent, x = def.x, y = def.y, label = def.label or "",
            colors = scheme_pair(def),
            fg_bg = ui.cpair(dcol(def, "fg"), dcol(def, "bg")) }
        if def.flash then args.flash = true; args.period = period_of(def) end
        local e = ctor(args)
        -- An indicator with nothing bound to it has no state to reflect, and both
        -- elements start false -- so "Blinking" rendered as a permanently dark dot
        -- and the widget looked broken. The wizard deliberately allows a blank var
        -- name, so this is the common case, not an edge one. Show it lit: that is
        -- what the user configured. A BOUND indicator stays off until its key says
        -- otherwise, which is correct -- unknown state is not "on".
        if not (def.var_name and def.var_name ~= "") then e.set_value(true) end
        -- No edge-dedupe here on purpose. Both LED and IndicatorLight now stop their
        -- previous flash callback before re-registering, so a repeated set_value(true)
        -- cannot stack duplicates. Caching the last value instead would desynchronize
        -- from the element: redraw() re-asserts e.value, and any cache would go on
        -- believing the light was lit after something else turned it off.
        return e, function(v) e.set_value(v == true) end
    end
end

builders.LED = indicator(function(a) return ui.LED(a) end)
builders.IndicatorLight = indicator(function(a) return ui.IndicatorLight(a) end)

builders.TextLabel = function(parent, def, _)
    local text = def.text or ""
    local pw = parent.window().getSize()
    local e = ui.TextBox{ parent = parent, x = def.x, y = def.y,
        width = math.max(1, math.min(#text > 0 and #text or 1, pw - def.x + 1)), height = 1,
        text = text, alignment = ui.ALIGN.LEFT,
        fg_bg = ui.cpair(dcol(def, "fg"), dcol(def, "bg")) }
    return e, function(v) e.set_value(tostring(v)) end
end

builders.HorizontalBar = function(parent, def, _)
    local bw = tonumber(def.bar_width) or 10
    local pw = parent.window().getSize()
    -- Clamp to what the parent can actually give, and never floor the width back
    -- UP afterwards: the element re-clamps to the parent anyway, then computes
    -- bar_width from the clamped frame and asserts it is > 0. A width floored above
    -- the available space therefore throws inside the constructor, and a def that
    -- fails to build gets no right-click handler -- leaving an uneditable stub on
    -- the canvas that can only be removed by deleting the whole page.
    local available = math.max(1, pw - def.x + 1)
    -- show_percent steals 5 columns, so it needs 6; drop it rather than crash
    local show_percent = def.show_percent == true and available >= 6
    local width = math.min(show_percent and (bw + 5) or bw, available)
    local e = ui.HorizontalBar{ parent = parent, x = def.x, y = def.y,
        width = width, height = 1, show_percent = show_percent,
        bar_fg_bg = ui.cpair(dcol(def, "bar_fg"), dcol(def, "bar_bg")),
        fg_bg = ui.cpair(dcol(def, "fg"), dcol(def, "bg")) }
    return e, function(v) e.set_value(tonumber(v) or 0) end
end

-- ── telemetry-bound widgets (Phase 6c) ───────────────────────────────────
-- These bind to ui_ctx.telemetry_cache rather than the bus. The watch handle is
-- created in factory.build and cancelled by the same destroy() path as bus
-- watchers; a missing cache (a node without the client role) degrades to a
-- static element rather than failing to build.

-- Total function by design: readings arrive raw off the wire (client.lua copies
-- msg.rate/msg.detail verbatim), and this runs inside the BUILDER -- a throw
-- here would make factory.build return nil and leave an uneditable stub for
-- data the user never wrote. Coerce everything; render "?" for the unknowable.
local function fmt_reading(def, r)
    local label = (type(def.label) == "string" and def.label ~= "") and (def.label .. " ") or ""
    -- a sensor that can't be read publishes an error reading; say so rather
    -- than showing "?", which is indistinguishable from "no data yet"
    if type(r) == "table" and r.error then return label .. "ERR" end
    if type(r) ~= "table" or r.value == nil then return label .. "?" end
    local s = label .. tostring(r.value)
    if r.unit ~= nil then s = s .. " " .. tostring(r.unit) end
    -- derive_rate is per MINUTE (telemetry.lua), and the Monitoring page already
    -- renders it as /m -- a /s suffix here would misstate the same number by 60x
    local rate = tonumber(r.rate)
    if rate then s = s .. string.format(" %+.0f/m", rate) end
    return s
end

builders.SensorBar = function(parent, def, _)
    -- same width discipline as HorizontalBar: clamp to the parent and never
    -- floor back up, or the element's own bar_width assert throws
    local bw = tonumber(def.bar_width) or 10
    local pw = parent.window().getSize()
    local available = math.max(1, pw - def.x + 1)
    local show_percent = def.show_percent == true and available >= 6
    local width = math.min(show_percent and (bw + 5) or bw, available)
    local e = ui.HorizontalBar{ parent = parent, x = def.x, y = def.y,
        width = width, height = 1, show_percent = show_percent,
        bar_fg_bg = ui.cpair(dcol(def, "bar_fg"), dcol(def, "bar_bg")),
        fg_bg = ui.cpair(dcol(def, "fg"), dcol(def, "bg")) }
    return e
end

builders.SensorReadout = function(parent, def, ui_ctx)
    local pw = parent.window().getSize()
    local text = fmt_reading(def,
        ui_ctx.telemetry_cache and ui_ctx.telemetry_cache.reading(def.path))
    local e = ui.TextBox{ parent = parent, x = def.x, y = def.y,
        width = math.max(1, math.min(30, pw - def.x + 1)), height = 1,
        text = text, alignment = ui.ALIGN.LEFT,
        fg_bg = ui.cpair(dcol(def, "fg"), dcol(def, "bg")) }
    return e
end

builders.StorageBreakdown = function(parent, def, ui_ctx)
    local n = math.max(1, math.floor(tonumber(def.top_n) or 5))
    local pw, ph = parent.window().getSize()
    local width = math.max(1, math.min(24, pw - def.x + 1))
    local height = math.max(1, math.min(n, ph - def.y + 1))
    local box = ui.Div{ parent = parent, x = def.x, y = def.y, width = width, height = height }
    local rows = {}
    for i = 1, height do
        rows[i] = ui.TextBox{ parent = box, x = 1, y = i, width = width, height = 1,
            text = "", alignment = ui.ALIGN.LEFT,
            fg_bg = ui.cpair(dcol(def, "fg"), dcol(def, "bg")) }
    end
    -- the update fn doubles as the initial paint; a telemetry watch fires it
    -- immediately when the path already has a reading
    -- total function, like fmt_reading: detail comes off the wire and this runs
    -- in the builder, where a throw means an uneditable stub
    local function show(r)
        local detail = (type(r) == "table" and type(r.detail) == "table") and r.detail or {}
        for i = 1, height do
            local item = detail[i]
            if type(item) == "table" then
                local nm = tostring(item.name):match("[^:]+$") or tostring(item.name)
                rows[i].set_value(nm .. " x" .. tostring(item.count))
            else
                rows[i].set_value("")
            end
        end
    end
    show(ui_ctx.telemetry_cache and ui_ctx.telemetry_cache.reading(def.path))
    box.__show = show   -- picked up by factory.build's telemetry watch wiring
    return box
end

---@return table|nil handle { element, destroy }
function factory.build(parent, def, ui_ctx)
    local b = builders[def.type]
    if not b then return nil end

    local ok, e, apply = pcall(b, parent, def, ui_ctx)
    if not ok or not e then return nil end

    -- Captured NOW, not read inside destroy(): `def` is the live table from
    -- editor_store.list, and props edits mutate it in place before the rebuild.
    -- Toggling flash off would otherwise leave the old element's flasher callback
    -- registered, because destroy() would see the already-updated false.
    local flashing = def.flash == true and (def.type == "LED" or def.type == "IndicatorLight")

    local watcher
    if def.var_name and def.var_name ~= "" and ui_ctx.bus and apply then
        -- bus.watch fires immediately when the key already has a value, so `apply`
        -- must tolerate being called during construction
        watcher = ui_ctx.bus.watch(def.var_name, function(v) pcall(apply, v) end, e)
    end

    -- telemetry binding (SensorBar/SensorReadout/StorageBreakdown); like
    -- bus.watch, cache.watch fires immediately when a reading already exists
    -- The string check matters: the cache is shared state and def.path comes from
    -- a hand-editable file -- a JSON number passed to watch() would otherwise
    -- become a permanent non-string data[] key (watch() also refuses them; belt
    -- and suspenders on both sides of the shared boundary).
    local twatcher
    if type(def.path) == "string" and def.path ~= "" and ui_ctx.telemetry_cache then
        local cache = ui_ctx.telemetry_cache
        if def.type == "SensorBar" then
            twatcher = cache.watch(def.path, function(r)
                pcall(e.set_value, tonumber(type(r) == "table" and r.fraction or nil) or 0)
            end)
        elseif def.type == "SensorReadout" then
            -- fmt_reading INSIDE the pcall: evaluated outside, its throw would
            -- escape the callback (contained only by luck one level up)
            twatcher = cache.watch(def.path, function(r)
                pcall(function() e.set_value(fmt_reading(def, r)) end)
            end)
        elseif def.type == "StorageBreakdown" and e.__show then
            twatcher = cache.watch(def.path, function(r) pcall(e.__show, r) end)
        end
    end

    return {
        element = e,
        destroy = function()
            if watcher then watcher.cancel(); watcher = nil end
            if twatcher then twatcher.cancel(); twatcher = nil end
            -- element.delete() never calls flasher.stop, so a flashing indicator
            -- deleted while lit leaves its callback blitting into a dead window
            if flashing then pcall(e.set_value, false) end
            pcall(e.delete)
        end,
    }
end

return factory
