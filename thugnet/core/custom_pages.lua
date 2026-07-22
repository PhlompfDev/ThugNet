-- User-created pages: a persisted list of { id, name }. Ids are stable and
-- never reused -- Phase 6b keys editor_elements.json by them, so renaming or
-- deleting a page must never make another page inherit its saved elements.
local custom_pages = {}

local PATH = "custom_pages.json"
local _store
local list, next_seq = {}, 1

local function persist()
    _store.save(PATH, { next_seq = next_seq, pages = list })
end

local function index_of(id)
    for i, e in ipairs(list) do if e.id == id then return i end end
end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A corrupt file is quarantined and we start from the default, which would reset
-- next_seq to 1 and reissue ids that saved elements still point at -- the exact
-- id-reuse bug this module exists to prevent, reached via a mid-write crash.
-- Truncated JSON still contains most of the ids it held, so scan the raw text
-- for the high-water mark even though it no longer parses.
---@return integer seq the lowest safe next_seq, or 0 when nothing was salvaged
local function salvaged_seq(path)
    local best = 0
    pcall(function()
        if not fs.exists(path) then return end
        local f = fs.open(path, "r")
        if not f then return end
        local raw = f.readAll(); f.close()
        for n in tostring(raw or ""):gmatch("custom_(%d+)") do
            local v = tonumber(n)
            if v and v > best then best = v end
        end
    end)
    if best == 0 then return 0 end
    return best + 1
end

---@param deps table { store }
function custom_pages.init(deps)
    _store = deps.store
    local data, was_corrupt = _store.load(PATH, {})
    list, next_seq = {}, 1

    local raw = type(data.pages) == "table" and data.pages or {}
    local seen = {}
    for _, e in ipairs(raw) do
        if type(e) == "table" and type(e.id) == "string" and type(e.name) == "string"
           and not seen[e.id] then
            -- a duplicated id would otherwise yield a page needing two deletes
            seen[e.id] = true
            table.insert(list, { id = e.id, name = e.name })
        end
    end

    -- next_seq must clear every id ever issued, including ids of entries the
    -- file dropped as malformed, so a rewrite can't collide with saved elements
    if type(data.next_seq) == "number" and data.next_seq > next_seq then
        next_seq = math.floor(data.next_seq)
    end
    for _, e in ipairs(raw) do
        local n = type(e) == "table" and type(e.id) == "string" and e.id:match("^custom_(%d+)$")
        if n and tonumber(n) >= next_seq then next_seq = tonumber(n) + 1 end
    end

    -- the quarantined text is the only surviving record of the ids we issued
    if was_corrupt then
        local salvaged = salvaged_seq(PATH .. ".corrupt")
        if salvaged > next_seq then next_seq = salvaged end
    end
end

function custom_pages.list() return list end

function custom_pages.get(id)
    local i = index_of(id)
    return i and list[i] or nil
end

---@return table|nil entry nil when the name is empty
function custom_pages.add(name)
    name = trim(name)
    if name == "" then return nil end
    local entry = { id = "custom_" .. next_seq, name = name }
    next_seq = next_seq + 1
    table.insert(list, entry)
    persist()
    return entry
end

function custom_pages.rename(id, new_name)
    new_name = trim(new_name)
    if new_name == "" then return false end
    local i = index_of(id)
    if not i then return false end
    list[i].name = new_name          -- id deliberately untouched
    persist()
    return true
end

function custom_pages.delete(id)
    local i = index_of(id)
    if not i then return false end
    table.remove(list, i)
    persist()                         -- next_seq is not rewound: ids never recycle
    return true
end

return custom_pages
