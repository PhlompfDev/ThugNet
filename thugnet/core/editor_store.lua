-- Placed editor elements, keyed by the custom page's stable id (Phase 6a).
-- Pure data: no graphics, no ui. Colours are stored as names -- see
-- thugnet/ui/editor/colors.lua for why.
local editor_store = {}

local PATH = "editor_elements.json"
local _store
local pages = {}     -- page_id -> { def, ... }

local function persist() _store.save(PATH, pages) end

local function valid(def)
    return type(def) == "table" and type(def.type) == "string"
       and type(def.x) == "number" and type(def.y) == "number"
end

-- True when the last init could not read the file, or read it but did not
-- understand part of its contents. startup surfaces this -- silently rendering
-- every custom page empty is indistinguishable from "the user placed nothing".
editor_store.was_corrupt = false
editor_store.dropped_content = false

---@param deps table { store }
function editor_store.init(deps)
    _store = deps.store
    local data, was_corrupt = _store.load(PATH, {})
    editor_store.was_corrupt = was_corrupt == true
    editor_store.dropped_content = false
    pages = {}

    local ok_shape = type(data) == "table"
    for page_id, defs in pairs(ok_shape and data or {}) do
        if type(page_id) == "string" and type(defs) == "table" then
            local keep, total, seen = {}, 0, 0
            for _ in pairs(defs) do total = total + 1 end
            for _, d in ipairs(defs) do
                seen = seen + 1
                if valid(d) then table.insert(keep, d) else editor_store.dropped_content = true end
            end
            -- ipairs finds nothing in a table keyed "1","2",... so a page that is a
            -- JSON object rather than an array reads as empty rather than as damaged
            if seen < total then editor_store.dropped_content = true end
            pages[page_id] = keep
        else
            -- a numeric key (the file round-tripped as an array) or a non-array
            -- page value: parseable, so store.load did NOT quarantine it, and the
            -- migration left it alone -- but we cannot read it
            editor_store.dropped_content = true
        end
    end

    -- persist() rewrites the WHOLE file, so the first add/remove/clear_page would
    -- overwrite content we failed to understand, with no copy anywhere. Snapshot
    -- the parsed original before that can happen. (A genuinely corrupt file is
    -- already quarantined to .corrupt by store.load.)
    if editor_store.dropped_content and ok_shape then
        _store.save(PATH .. ".unreadable.bak", data)
    end
end

function editor_store.list(page_id)
    pages[page_id] = pages[page_id] or {}
    return pages[page_id]
end

---@return integer idx
function editor_store.add(page_id, def)
    local list = editor_store.list(page_id)
    table.insert(list, def)
    persist()
    return #list
end

function editor_store.update(page_id, idx, fields)
    local d = editor_store.list(page_id)[idx]
    if not d then return false end
    for k, v in pairs(fields) do d[k] = v end
    persist()
    return true
end

function editor_store.remove(page_id, idx)
    local list = editor_store.list(page_id)
    if not list[idx] then return false end
    table.remove(list, idx)
    persist()
    return true
end

function editor_store.clear_page(page_id)
    if pages[page_id] == nil then return end
    pages[page_id] = {}
    persist()
end

return editor_store
