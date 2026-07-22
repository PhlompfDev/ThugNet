-- JSON file persistence. The single owner of fs+JSON for the codebase.
local store = {}

---@param path string
---@param default table returned as-is when the file is missing or corrupt
---@return table data
---@return boolean was_corrupt true only when the file existed, failed to parse,
---        and was quarantined to <path>.corrupt. Callers that derive
---        never-reused counters from the file must tell "absent" (safe to start
---        fresh) apart from "unreadable" (starting fresh reissues live ids).
function store.load(path, default)
    if not fs.exists(path) then return default, false end
    local f = fs.open(path, "r")
    if not f then return default, false end
    local raw = f.readAll(); f.close()
    local ok, data = pcall(textutils.unserialiseJSON, raw)
    if ok and type(data) == "table" then return data, false end
    -- keep the bad file for postmortem instead of silently overwriting it
    pcall(fs.move, path, path .. ".corrupt")
    return default, true
end

---@return boolean ok
function store.save(path, tbl)
    local ok, raw = pcall(textutils.serialiseJSON, tbl)
    if not ok then return false end
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(raw); f.close()
    return true
end

return store
