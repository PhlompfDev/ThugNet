-- The property-edit menu for an element already on the canvas.
--
-- Every edit goes through editor_store.update then on_changed, which rebuilds the
-- page from the defs. There is deliberately no in-place mutation path: the def is
-- the single source of truth, so an edit and a fresh boot always produce the same
-- element, and nothing has to be kept in sync with a live handle.
local menus        = require("thugnet.ui.menus")
local editor_store = require("thugnet.core.editor_store")
local cmap         = require("thugnet.ui.editor.colors")
local factory      = require("thugnet.ui.editor.factory")

local props = {}

-- What each colour slot actually paints, per type -- "FG" told the user
-- nothing (it is usually the TEXT colour, but not always: a Checkbox's fg is
-- also its box, a bar's fg is its percent text). Owner directive 2026-07-21:
-- name the thing being coloured.
local COLOR_LABELS = {
    PushButton       = { fg = "Button Text Color", bg = "Button Color",
                         afg = "Pressed Text Color", abg = "Pressed Button Color" },
    SwitchButton     = { fg = "Text Color (Off)", bg = "Button Color (Off)",
                         afg = "Text Color (On)", abg = "Button Color (On)" },
    Checkbox         = { fg = "Text & Box Color", bg = "Background Color" },
    RadioButton      = { fg = "Text Color", bg = "Background Color" },
    LED              = { fg = "Label Text Color", bg = "Background Color" },
    IndicatorLight   = { fg = "Label Text Color", bg = "Background Color" },
    TextLabel        = { fg = "Text Color", bg = "Background Color" },
    HorizontalBar    = { fg = "Percent Text Color", bg = "Background Color",
                         bar_fg = "Bar Fill Color", bar_bg = "Bar Track Color" },
    SensorBar        = { fg = "Percent Text Color", bg = "Background Color",
                         bar_fg = "Bar Fill Color", bar_bg = "Bar Track Color" },
    SensorReadout    = { fg = "Text Color", bg = "Background Color" },
    StorageBreakdown = { fg = "Text Color", bg = "Background Color" },
}

local function color_label(def, field)
    local labels = COLOR_LABELS[def.type] or {}
    return labels[field] or (field:upper() .. " Color")
end

-- The colour the element is ACTUALLY painted with right now: the explicit def
-- value, or the type's factory default. Pre-filling this means the prompt is
-- never an empty box the user has to guess against. (A cleared slot stores
-- `false`, which correctly falls through to the default here.)
local function effective_color(def, field)
    if type(def[field]) == "string" then return def[field] end
    local d = factory.COLOR_DEFAULTS[def.type]
    return (d and d[field]) or ""
end

local SCHEMES = { "green_red", "blue_red", "yellow_gray", "white_black" }
local PERIODS = { { text = "250ms", value = 1 }, { text = "500ms", value = 2 },
                  { text = "1s",    value = 3 } }

local function choice_menu(ui_ctx, choices, pick)
    local items = {}
    for _, c in ipairs(choices) do
        local text  = type(c) == "table" and c.text or c
        local value = type(c) == "table" and c.value or c
        table.insert(items, { text = text, callback = function() pick(value) end })
    end
    ui_ctx.menu(items)
end

---@param ui_ctx table page context (menu, prompt, request_rebuild)
---@param page_id string 6a stable custom page id
---@param idx integer index of the def within the page
---@param def table the def being edited (for reading current values)
---@param on_changed fun() called after any successful edit
---@param on_move fun(idx:integer)|nil arms the page's move mode; Move is a
---       page-level gesture, so the page owns it and passes the arming hook in
function props.open(ui_ctx, page_id, idx, def, on_changed, on_move)
    local function apply(fields)
        if editor_store.update(page_id, idx, fields) and on_changed then on_changed() end
    end

    -- Ask for a pair of colour slots, then write BOTH in one apply.
    --
    -- The single apply is load-bearing, not tidiness: apply() calls on_changed,
    -- which is request_rebuild, and the rebuild's teardown closes any open text
    -- prompt. Applying after the first answer therefore destroyed the second
    -- prompt ~0.1s after it opened, so the second colour could never be set.
    -- The wizard's chains have the same shape for the same reason.
    ---@param slots table[] { { label, current, field }, ... }
    local function ask_colors(slots)
        local fields = {}
        local function step(i)
            local s = slots[i]
            if not s then
                if next(fields) then apply(fields) end
                return
            end
            ui_ctx.prompt(s.label, s.current or "", function(name)
                if name == "" then
                    -- `false`, not nil: update() merges with pairs(), and a nil value
                    -- makes the key vanish from the table entirely, so the field
                    -- would be skipped instead of cleared. The factory's to_color()
                    -- rejects any non-string, so false reads back as "use default".
                    fields[s.field] = false
                elseif cmap.to_color(name) then
                    -- an unrecognised name is ignored rather than stored, so a typo
                    -- can never bake an unrenderable value into the def
                    fields[s.field] = name
                end
                step(i + 1)
            end, function() return cmap.NAMES end)
        end
        step(1)
    end

    local actions = {}

    function actions.edit_label()
        if def.type == "TextLabel" then
            ui_ctx.prompt("Text", def.text or "", function(v)
                if v ~= "" then apply({ text = v }) end
            end)
        else
            ui_ctx.prompt("Label", def.label or "", function(v) apply({ label = v }) end)
        end
    end

    function actions.edit_options()
        local current = table.concat(def.options or {}, ",")
        ui_ctx.prompt("Options (a,b,c)", current, function(csv)
            local opts = {}
            for part in tostring(csv):gmatch("[^,]+") do
                local trimmed = part:match("^%s*(.-)%s*$")
                if trimmed ~= "" then table.insert(opts, trimmed) end
            end
            if #opts > 0 then apply({ options = opts }) end
        end)
    end

    local function color_slot(field)
        return { label = color_label(def, field),
                 current = effective_color(def, field), field = field }
    end

    function actions.edit_colors()
        ask_colors({ color_slot("fg"), color_slot("bg") })
    end

    function actions.edit_active()
        ask_colors({ color_slot("afg"), color_slot("abg") })
    end

    function actions.edit_bar_colors()
        ask_colors({ color_slot("bar_fg"), color_slot("bar_bg") })
    end

    function actions.edit_scheme()
        choice_menu(ui_ctx, SCHEMES, function(s) apply({ scheme = s }) end)
    end

    function actions.toggle_flash()
        if def.flash then
            apply({ flash = false })
        else
            -- flash requires a period, and LED/IndicatorLight assert on a missing
            -- one -- so default it here rather than build an element that crashes
            apply({ flash = true, period = def.period or 2 })
        end
    end

    function actions.edit_period()
        choice_menu(ui_ctx, PERIODS, function(p) apply({ period = p }) end)
    end

    function actions.edit_width()
        ui_ctx.prompt("Bar Width (num)", tostring(def.bar_width or 10), function(raw)
            local n = tonumber(raw)
            if n and n >= 1 then apply({ bar_width = math.floor(n) }) end
        end)
    end

    function actions.toggle_percent()
        apply({ show_percent = not (def.show_percent == true) })
    end

    -- single prompts, so applying inside the callback is safe -- there is no
    -- second prompt for the rebuild's teardown to destroy
    function actions.edit_sensor()
        -- tostring: a hand-edited numeric path would throw inside the prompt's
        -- length check, taking down the one affordance that could repair it
        ui_ctx.prompt("Sensor (domain:sensor)", tostring(def.path or ""), function(path)
            if path ~= "" then apply({ path = path }) end
        end, function()
            return (ui_ctx.telemetry_cache and ui_ctx.telemetry_cache.paths()) or {}
        end)
    end

    function actions.edit_top_n()
        ui_ctx.prompt("Top N (num)", tostring(def.top_n or 5), function(raw)
            local n = tonumber(raw)
            if n and n >= 1 then apply({ top_n = math.floor(n) }) end
        end)
    end

    -- Route: command vs scene. Each path collects its fields into a local and
    -- applies ONCE at the end -- apply triggers the rebuild whose teardown closes
    -- any open prompt, so applying mid-chain would destroy the next prompt.
    function actions.edit_route()
        ui_ctx.menu({
            { text = "Send Command", callback = function()
                local fields = { route = "cmd" }
                ui_ctx.prompt("Cmd When True", def.cmd_true or "", function(cmd)
                    if cmd ~= "" then fields.cmd_true = cmd end
                    ui_ctx.prompt("Domain", def.domain or "", function(domain)
                        if domain ~= "" then fields.domain = domain end
                        apply(fields)
                    end)
                end)
            end },
            { text = "Run Scene", callback = function()
                ui_ctx.prompt("Scene Name", def.scene or "", function(name)
                    if name ~= "" then apply({ route = "scene", scene = name }) end
                end, function()
                    local scenes = require("thugnet.core.scenes")
                    local names = {}
                    for _, s in ipairs(scenes.list()) do table.insert(names, s.name) end
                    return names
                end)
            end },
        })
    end

    function actions.move()
        if on_move then on_move(idx) end
    end

    function actions.delete()
        if editor_store.remove(page_id, idx) and on_changed then on_changed() end
    end

    ui_ctx.menu(menus.element_menu(actions, { type = def.type, flash = def.flash == true }))
end

return props
