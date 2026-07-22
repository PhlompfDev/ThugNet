-- Custom pages: user-created freeform canvases. Phase 6a renders them empty;
-- Phase 6b's editor places elements into them, keyed by the page's stable id.
local ui           = require("graphics.ui")
local nav          = require("thugnet.ui.nav")
local menus        = require("thugnet.ui.menus")
local editor_store = require("thugnet.core.editor_store")
local factory      = require("thugnet.ui.editor.factory")
local wizard       = require("thugnet.ui.editor.wizard")
local props        = require("thugnet.ui.editor.props")

local gevents = require("graphics.events")

local custom = {}

-- The armed move, if any: { page_id, idx }. Module-local because a move is a
-- page-level gesture that has to survive the rebuild which arms it -- props.open
-- sets it, the next build renders move mode, and the click that lands commits.
local pending = nil

---@param entry table { id, name } -- copied by value; renames reach the live
---       registry through sync's explicit assignment, not through this table
---@return page_def
function custom.make(entry)
    return {
        id = entry.id,
        name = entry.name,
        category = "custom",
        min_w = 10,
        min_h = 4,
        is_custom = true,
        build = function(content, ui_ctx)
            local theme = ui_ctx.theme
            local w, h = content.window().getSize()
            local defs = editor_store.list(entry.id)

            -- Every surface builds its own copies from the same defs -- that is how
            -- mirroring works; there is no shared element list between the terminal
            -- and a monitor zone.
            -- A move armed on this page turns the canvas into a placement target --
            -- but only on the terminal. `pending` is module-local and every surface
            -- showing the page rebuilds from it, so without this gate arming a move
            -- on the terminal would put every monitor zone mirroring that page into
            -- move mode too: route_touch delivers a player's touch as a left-click
            -- TAP, which would commit the move to the ZONE's coordinates, and a
            -- monitor has no right-click to cancel with. If those coordinates fall
            -- outside the terminal's smaller content area the def is then skipped at
            -- mount there, leaving it unselectable and undeletable from the UI.
            local editable = ui_ctx.surface_kind ~= "zone"
            local moving_idx = editable and pending and pending.page_id == entry.id
                and pending.idx or nil

            local mounted = 0
            for i, d in ipairs(defs) do
                -- a def placed beyond this surface is skipped: a 51x19 terminal and a
                -- 20x10 zone legitimately show different subsets of the same page
                if d.x >= 1 and d.y >= 1 and d.x <= w and d.y <= h then
                    local handle = factory.build(content, d, ui_ctx)
                    if handle then
                        ui_ctx.own({ cancel = handle.destroy })
                        mounted = mounted + 1
                        if moving_idx then
                            -- inert while placing: the canvas needs the click, and a
                            -- button firing its command mid-move would be a nasty
                            -- surprise. Right-click handlers are left unattached so
                            -- the canvas's cancel handler is reachable everywhere.
                            handle.element.disable()
                        else
                            -- `i` is the def's index in the store, not the mount order
                            -- -- skipped out-of-bounds elements must not shift it
                            local my_idx = i
                            handle.element.set_right_click_handler(function()
                                props.open(ui_ctx, entry.id, my_idx, d, ui_ctx.request_rebuild,
                                    function(move_idx)
                                        pending = { page_id = entry.id, idx = move_idx }
                                        ui_ctx.request_rebuild()
                                    end)
                                return true
                            end)
                        end
                    end
                end
            end

            if mounted == 0 then
                local msg = "(empty page)"
                ui.TextBox{ parent = content,
                    x = math.max(1, math.floor((w - #msg) / 2) + 1),
                    y = math.max(1, math.floor(h / 2)),
                    width = math.min(#msg, w), height = 1, text = msg,
                    fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }
            end

            if moving_idx then
                -- never an invisible mode: v1's move flag was silent, so a page stuck
                -- mid-move just looked like it had stopped responding to clicks
                local hint = "moving - click a cell (right-click cancels)"
                local hint_tb = ui.TextBox{ parent = content, x = 1, y = 1,
                    width = math.min(#hint + 10, w), height = 1, text = hint,
                    fg_bg = ui.cpair(theme.tokens.dim, theme.tokens.bg) }

                -- Commit on the release, NOT on drags. v1 repositioned on every drag
                -- event, destroying and recreating the element per cell of movement,
                -- which leaked a flasher callback per cell. The 6c snap readout is a
                -- set_value on one TextBox -- display only, nothing rebuilt.
                content.set_left_click_handler(function(event)
                    local cx, cy = event.current.x, event.current.y
                    if event.type == gevents.MOUSE_CLICK.DOWN
                       or event.type == gevents.MOUSE_CLICK.DRAG then
                        hint_tb.set_value(("moving -> %d,%d (right-click cancels)"):format(cx, cy))
                        return
                    end
                    if event.type ~= gevents.MOUSE_CLICK.UP
                       and event.type ~= gevents.MOUSE_CLICK.TAP then return end
                    -- Clamp: DRAG/UP are gated on the INITIAL press cell, so the
                    -- release can land outside the content -- and committing
                    -- out-of-bounds coords makes the element unmountable here,
                    -- i.e. unreachable from the UI (the mount gate skips it).
                    cx = math.max(1, math.min(cx, w))
                    cy = math.max(1, math.min(cy, h))
                    editor_store.update(entry.id, moving_idx, { x = cx, y = cy })
                    pending = nil
                    ui_ctx.request_rebuild()
                end)

                content.set_right_click_handler(function()
                    pending = nil
                    ui_ctx.request_rebuild()
                    return true
                end)

                -- Only a build that RENDERED move mode clears it on teardown. The
                -- build that arms the move must not, or the very rebuild that arms it
                -- would immediately cancel it.
                ui_ctx.own({ cancel = function() pending = nil end })
            else
                -- The canvas is the fallback: right-click dispatch is depth-first, so
                -- an element consumes the click first and this only fires on empty
                -- space. `event` is already transposed into content-local coords,
                -- which is the coordinate space defs are stored in.
                content.set_right_click_handler(function(event)
                    local px, py = event.current.x, event.current.y
                    ui_ctx.menu(menus.canvas_menu{ add = function()
                        ui_ctx.menu(menus.element_type_menu({ pick = function(t)
                            wizard.start(ui_ctx, t, px, py, function(new_def)
                                editor_store.add(entry.id, new_def)
                                ui_ctx.request_rebuild()
                            end)
                        end }, factory.TYPES))
                    end })
                    return true
                end)
            end
        end,
    }
end

-- Reconcile the nav registry against `list`. Only pages carrying is_custom are
-- ever unregistered, so built-ins can never be swept by a bad list.
---@param list table[] array of { id, name }
function custom.sync(list)
    local wanted = {}
    for _, e in ipairs(list) do wanted[e.id] = e end

    for _, def in ipairs(nav.all()) do
        if def.is_custom and not wanted[def.id] then nav.unregister(def.id) end
    end

    for _, e in ipairs(list) do
        local existing = nav.get(e.id)
        if existing then
            -- Ids arrive from a file, so an entry can collide with a built-in
            -- ({id="dashboard"} would rename the real Dashboard and shadow the
            -- custom page). Only pages we own may be touched; anything else is
            -- skipped entirely -- neither renamed nor re-registered.
            if existing.is_custom then
                existing.name = e.name    -- rename in place, keeps sidebar order
            end
        else
            nav.register(custom.make(e))
        end
    end
end

return custom
