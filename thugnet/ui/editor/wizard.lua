-- Creation prompts for a new element: a per-type chain of text prompts and
-- choice menus that ends in a complete def. Cancelling anywhere simply stops --
-- on_done is called only on completion, so nothing is ever half-stored.
--
-- Prompt convention, inherited from v1: an empty answer to a type's FIRST prompt
-- aborts (you asked for a label and got nothing, so you meant to back out),
-- while a later blank means "none" and the field is left unset.
local factory = require("thugnet.ui.editor.factory")

local wizard = {}

local SCHEMES = {
    { text = "green_red",   value = "green_red"   },
    { text = "blue_red",    value = "blue_red"    },
    { text = "yellow_gray", value = "yellow_gray" },
    { text = "white_black", value = "white_black" },
}

-- flasher.PERIOD: 1 = 250ms, 2 = 500ms, 3 = 1s
local PERIODS = {
    { text = "250ms", value = 1 },
    { text = "500ms", value = 2 },
    { text = "1s",    value = 3 },
}

local function blank_to_nil(s)
    if s == nil or s == "" then return nil end
    return s
end

-- build a menu of { text, value } choices, each calling pick(value)
local function choice_menu(ui_ctx, choices, pick)
    local items = {}
    for _, c in ipairs(choices) do
        table.insert(items, { text = c.text, callback = function() pick(c.value) end })
    end
    ui_ctx.menu(items)
end

local chains = {}

chains.TextLabel = function(ui_ctx, def, done)
    ui_ctx.prompt("Label Text", "", function(text)
        if text == "" then return end
        def.text = text
        done()
    end)
end

chains.Checkbox = function(ui_ctx, def, done)
    ui_ctx.prompt("Label", "", function(label)
        if label == "" then return end
        def.label = label
        ui_ctx.prompt("Var Name (blank=none)", "", function(var)
            def.var_name = blank_to_nil(var)
            done()
        end)
    end)
end

-- LED and IndicatorLight share a chain; their label may legitimately be blank
-- (a bare dot next to a separately-placed TextLabel), so it cannot abort.
local function indicator_chain(ui_ctx, def, done)
    ui_ctx.prompt("Label (can be blank)", "", function(label)
        def.label = label
        ui_ctx.prompt("Var Name (blank=none)", "", function(var)
            def.var_name = blank_to_nil(var)
            choice_menu(ui_ctx, { { text = "Blinking", value = true },
                                  { text = "Solid",    value = false } }, function(flash)
                choice_menu(ui_ctx, SCHEMES, function(scheme)
                    def.scheme = scheme
                    if not flash then return done() end
                    def.flash = true
                    choice_menu(ui_ctx, PERIODS, function(period)
                        def.period = period
                        done()
                    end)
                end)
            end)
        end)
    end)
end

chains.LED = indicator_chain
chains.IndicatorLight = indicator_chain

chains.SwitchButton = function(ui_ctx, def, done)
    ui_ctx.prompt("Button Label", "", function(label)
        if label == "" then return end
        def.label = label
        ui_ctx.prompt("Var Name (blank=none)", "", function(var)
            def.var_name = blank_to_nil(var)
            ui_ctx.prompt("Domain (blank=none)", "", function(domain)
                def.domain = blank_to_nil(domain)
                ui_ctx.prompt("Cmd When ON", "", function(on)
                    def.cmd_on = blank_to_nil(on)
                    ui_ctx.prompt("Cmd When OFF", "", function(off)
                        def.cmd_off = blank_to_nil(off)
                        done()
                    end)
                end)
            end)
        end)
    end)
end

local function scene_names(ui_ctx)
    return function()
        local scenes = require("thugnet.core.scenes")
        local names = {}
        for _, s in ipairs(scenes.list()) do table.insert(names, s.name) end
        return names
    end
end

chains.PushButton = function(ui_ctx, def, done)
    ui_ctx.prompt("Button Label", "", function(label)
        if label == "" then return end
        def.label = label
        choice_menu(ui_ctx, { { text = "Send Command", value = "cmd" },
                              { text = "Run Scene",    value = "scene" } }, function(route)
            if route == "scene" then
                ui_ctx.prompt("Scene Name", "", function(name)
                    -- a scene button with no scene is dead weight; abort instead
                    if name == "" then return end
                    def.route, def.scene = "scene", name
                    done()
                end, scene_names(ui_ctx))
            else
                ui_ctx.prompt("Var Name (blank=none)", "", function(var)
                    -- an unbound button is a legitimate end state (v1 behaviour):
                    -- with no var name there is nothing to bind, so stop rather
                    -- than ask for a command the user has no way to observe
                    if var == "" then return done() end
                    def.var_name = var
                    ui_ctx.prompt("Cmd When True", "", function(cmd)
                        def.cmd_true = blank_to_nil(cmd)
                        ui_ctx.prompt("Domain", "", function(domain)
                            def.domain = blank_to_nil(domain)
                            done()
                        end)
                    end)
                end)
            end
        end)
    end)
end

chains.RadioButton = function(ui_ctx, def, done)
    ui_ctx.prompt("Options (a,b,c)", "", function(csv)
        local opts = {}
        for part in tostring(csv):gmatch("[^,]+") do
            local trimmed = part:match("^%s*(.-)%s*$")
            if trimmed ~= "" then table.insert(opts, trimmed) end
        end
        if #opts == 0 then return end
        def.options = opts
        ui_ctx.prompt("Var Name (blank=none)", "", function(var)
            def.var_name = blank_to_nil(var)
            done()
        end)
    end)
end

chains.HorizontalBar = function(ui_ctx, def, done)
    ui_ctx.prompt("Bar Width (num)", "10", function(raw)
        local n = tonumber(raw)
        if not n or n < 1 then return end
        def.bar_width = math.floor(n)
        choice_menu(ui_ctx, { { text = "Show %", value = true },
                              { text = "No %",   value = false } }, function(pct)
            def.show_percent = pct
            ui_ctx.prompt("Var Name (blank=none)", "", function(var)
                def.var_name = blank_to_nil(var)
                done()
            end)
        end)
    end)
end

-- sensor-path prompt shared by the three telemetry widgets; autocompletes from
-- the live cache but accepts any non-empty path -- a sensor that has not
-- published yet is still a legal binding
local function ask_sensor(ui_ctx, def, next_step)
    ui_ctx.prompt("Sensor (domain:sensor)", "", function(path)
        if path == "" then return end
        def.path = path
        next_step()
    end, function()
        return (ui_ctx.telemetry_cache and ui_ctx.telemetry_cache.paths()) or {}
    end)
end

chains.SensorBar = function(ui_ctx, def, done)
    ask_sensor(ui_ctx, def, function()
        ui_ctx.prompt("Bar Width (num)", "10", function(raw)
            local n = tonumber(raw)
            if not n or n < 1 then return end
            def.bar_width = math.floor(n)
            choice_menu(ui_ctx, { { text = "Show %", value = true },
                                  { text = "No %",   value = false } }, function(pct)
                def.show_percent = pct
                done()
            end)
        end)
    end)
end

chains.SensorReadout = function(ui_ctx, def, done)
    ask_sensor(ui_ctx, def, function()
        ui_ctx.prompt("Label (blank=none)", "", function(label)
            def.label = blank_to_nil(label)
            done()
        end)
    end)
end

chains.StorageBreakdown = function(ui_ctx, def, done)
    ask_sensor(ui_ctx, def, function()
        ui_ctx.prompt("Top N (num)", "5", function(raw)
            local n = tonumber(raw)
            if not n or n < 1 then return end
            def.top_n = math.floor(n)
            done()
        end)
    end)
end

-- Run the creation chain for `type_name`, calling on_done(def) once the user
-- completes it. Never calls on_done if they cancel or abort.
---@param x integer page-local column of the click that started this
---@param y integer page-local row
function wizard.start(ui_ctx, type_name, x, y, on_done)
    local chain = chains[type_name]
    if not chain then return end
    local def = { type = type_name, x = x, y = y }
    chain(ui_ctx, def, function() on_done(def) end)
end

wizard.TYPES = factory.TYPES

return wizard
