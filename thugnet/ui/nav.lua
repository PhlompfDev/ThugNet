-- Page registry + gating. Pages register a descriptor; app.lua asks nav
-- which pages exist for this computer's roles/hardware.
local nav = {}

local registry = {}   -- ordered list of page defs
local by_id = {}

---@class page_def
---@field id string
---@field name string sidebar label
---@field min_w integer minimum content width
---@field min_h integer minimum content height
---@field build fun(parent:table, ui_ctx:table) builds page content
---@field requires_role? string only shown when cfg.roles[role] is true
---@field requires_monitor? boolean only shown when a monitor is attached
---@field hidden? boolean registered + reachable via nav_to, never in the sidebar
---@field is_custom? boolean user-created page; gates the sweep and rename in
---       ui/pages/custom.lua so built-ins can never be swept or renamed

function nav.register(def)
    if by_id[def.id] then return end
    table.insert(registry, def)
    by_id[def.id] = def
end

function nav.get(id) return by_id[id] end

---@return boolean true when a page with this id was registered and is now gone
function nav.unregister(id)
    if not by_id[id] then return false end
    for i, def in ipairs(registry) do
        if def.id == id then table.remove(registry, i); break end
    end
    by_id[id] = nil
    return true
end

---@param ctx table { config, has_monitor }
---@return page_def[] visible pages in registration order
function nav.pages(ctx)
    local out = {}
    for _, def in ipairs(registry) do
        local ok = not def.hidden
        if def.requires_role and not (ctx.config.roles or {})[def.requires_role] then ok = false end
        if def.requires_monitor and not ctx.has_monitor then ok = false end
        if ok then table.insert(out, def) end
    end
    return out
end

-- Ungated view of every registered page, for management code that must see
-- pages regardless of role/monitor gating (nav.pages is the *display* view).
---@return page_def[] all registered pages in registration order
function nav.all()
    local out = {}
    for _, def in ipairs(registry) do table.insert(out, def) end
    return out
end

-- test support
function nav.reset()
    registry = {}
    by_id = {}
end

return nav
