-- The single shared FaceEditor (spec §7): plus-shaped face selector, mode
-- cycle, bundled color grid, pulse duration. One implementation, used by
-- the command editor and the sequence editor (and any future consumer).
--
-- Operates on a redstone step's `faces` table:
--   { [side] = { mode = "static"|"pulse", bundled = {names}|nil,
--                duration_ticks?, on? } }
-- Every mutation calls on_change() (dirty tracking) and rebuilds the box.
--
-- The plus is v1's: each face is a single colored blit cell (\143) on a
-- raised panel, fg colored by mode — off/dim, static/alert, pulse/accent2.
-- The selected face carries an accent background instead of a text marker.
--
-- Left-click a face: cycle off -> static -> pulse -> off (v1 behavior).
-- Right-click a face: select it for the color grid.
-- Right-click the mode label (pulse only): Pulse Duration… prompt.
--
-- Known limitation: the dark theme retunes the 16 palette slots, so grid
-- cells for brown/gray/black render off-hue; positions are stable (4x4,
-- CC color order) so muscle memory still works.
local ui = require("graphics.ui")

local face_editor = {}

face_editor.WIDTH = 26
face_editor.HEIGHT = 6

-- v1 plus layout inside the 7x5 face panel: gaps on all four sides
local FACES = {
    { side = "top",    x = 4, y = 1 },
    { side = "left",   x = 2, y = 3 },
    { side = "front",  x = 4, y = 3 },
    { side = "right",  x = 6, y = 3 },
    { side = "back",   x = 2, y = 5 },
    { side = "bottom", x = 4, y = 5 },
}

-- CC color order, 4x4
local GRID_COLORS = {
    "white", "orange", "magenta", "lightBlue",
    "yellow", "lime", "pink", "gray",
    "lightGray", "cyan", "purple", "blue",
    "brown", "green", "red", "black",
}

local MODE_CYCLE = { off = "static", static = "pulse", pulse = "off" }

---@param parent graphics_element
---@param x integer
---@param y integer
---@param ui_ctx table needs theme, prompt
---@param get_faces function -> mutable faces table (a redstone step's)
---@param on_change function called after every mutation
---@return table handle { redraw(), selected_side() }
function face_editor.build(parent, x, y, ui_ctx, get_faces, on_change)
    local theme = ui_ctx.theme
    local box = ui.Div{ parent = parent, x = x, y = y,
                        width = face_editor.WIDTH, height = face_editor.HEIGHT,
                        fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }

    local selected = "front"
    local rebuild

    -- blit fg per mode (v1's FACE_COLORS, retuned to theme tokens)
    local MODE_FG = {
        off = theme.tokens.dim,
        static = theme.tokens.alert,
        pulse = theme.tokens.accent2,
    }

    local function face_of(side) return get_faces()[side] end

    local function mutate(fn)
        fn()
        on_change()
        rebuild()
    end

    local function cycle(side)
        local faces = get_faces()
        local cur = faces[side] and faces[side].mode or "off"
        local nxt = MODE_CYCLE[cur]
        mutate(function()
            if nxt == "off" then
                faces[side] = nil
            elseif nxt == "static" then
                faces[side] = { mode = "static" }
            else -- pulse (preserve bundled picked while static)
                local f = faces[side] or {}
                f.mode = "pulse"
                f.duration_ticks = f.duration_ticks or 10
                faces[side] = f
            end
        end)
    end

    rebuild = function()
        box.remove_all()

        -- the face panel: a raised card the plus sits on, so the blit cells
        -- read as a block face rather than floating characters
        local panel = ui.Div{ parent = box, x = 1, y = 1, width = 7, height = 5,
                              fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.raised) }
        ui.Tiling{ parent = panel, x = 1, y = 1, width = 7, height = 5,
                   fill_c = ui.cpair(theme.tokens.raised, theme.tokens.raised) }

        for _, def in ipairs(FACES) do
            local side = def.side
            local f = face_of(side)
            local mode = f and f.mode or "off"
            local is_sel = side == selected
            -- \143 is a half-block: fg paints the top half, bg the bottom.
            -- fg == bg makes the cell one solid square of the mode color; the
            -- selected face swaps only its bottom half to accent. The pressed
            -- pair repeats the resting pair so a left click never flashes
            -- accent — mode-color change on rebuild IS the click feedback.
            local cell = ui.cpair(MODE_FG[mode],
                                  is_sel and theme.tokens.accent or MODE_FG[mode])
            local btn = ui.PushButton{
                parent = panel, x = def.x, y = def.y, width = 1, text = "\143",
                fg_bg = cell,
                active_fg_bg = cell,
                callback = function() cycle(side) end,
            }
            btn.set_right_click_handler(function()
                selected = side
                rebuild()
                return true
            end)
        end

        local f = face_of(selected)
        local mode = f and f.mode or "off"

        -- mode row (right-click for pulse duration)
        local mode_text = "mode: " .. mode
        if mode == "pulse" then
            mode_text = mode_text .. " " .. (f.duration_ticks or 10) .. "t"
        end
        local mode_tb = ui.TextBox{ parent = box, x = 10, y = 1, width = 16, height = 1,
                                    text = mode_text,
                                    fg_bg = ui.cpair(theme.tokens.text, theme.tokens.bg) }
        if mode == "pulse" then
            mode_tb.set_right_click_handler(function()
                ui_ctx.menu({ { text = "Pulse Duration...", callback = function()
                    ui_ctx.prompt("Pulse ticks", tostring(f.duration_ticks or 10), function(v)
                        local n = tonumber(v)
                        if n and n >= 1 then
                            mutate(function() f.duration_ticks = math.floor(n) end)
                        end
                    end)
                end } })
                return true
            end)
        end

        -- bundled toggle
        if f then
            ui.Checkbox{
                parent = box, x = 10, y = 2, label = "Bundled",
                box_fg_bg = ui.cpair(theme.tokens.accent, theme.tokens.raised),
                fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg),
                default = f.bundled ~= nil,
                callback = function(v)
                    mutate(function()
                        if v then f.bundled = f.bundled or {}
                        else f.bundled = nil end
                    end)
                end,
            }
        else
            ui.TextBox{ parent = box, x = 10, y = 2, width = 13, height = 1,
                        text = "(face off)",
                        fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
        end

        -- 4x4 bundled color grid (only when face exists and bundled is on)
        if f and f.bundled then
            for i, name in ipairs(GRID_COLORS) do
                local r = math.floor((i - 1) / 4)
                local c = (i - 1) % 4
                local member = false
                for _, n in ipairs(f.bundled) do
                    if n == name then member = true break end
                end
                ui.PushButton{
                    parent = box, x = 10 + c * 2, y = 3 + r, width = 2,
                    text = member and "x " or "  ",
                    fg_bg = ui.cpair(colors.white, colors[name]),
                    active_fg_bg = ui.cpair(colors.black, colors[name]),
                    callback = function()
                        mutate(function()
                            if member then
                                for j, n in ipairs(f.bundled) do
                                    if n == name then table.remove(f.bundled, j) break end
                                end
                            else
                                table.insert(f.bundled, name)
                            end
                        end)
                    end,
                }
            end
        end

        -- selected face name, under the face panel
        ui.TextBox{ parent = box, x = 1, y = 6, width = 9, height = 1,
                    text = ("\x10 " .. selected):sub(1, 9),
                    fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }

        box.redraw()
    end

    rebuild()

    return {
        redraw = rebuild,
        selected_side = function() return selected end,
    }
end

return face_editor
