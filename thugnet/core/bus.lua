-- Shared state bus: named values, watchers with lifecycle handles,
-- debounced JSON persistence of keys marked persistent.
local bus = {}

local _kernel, _store, _path
local values, persist_keys = {}, {}
local watchers = {}          -- key -> { [handle] = fn }
local all_watchers = {}      -- [handle] = fn
local save_pending = nil     -- kernel.after handle while a debounce is queued

local DEBOUNCE_SECS = 0.5

function bus.init(kernel, store, path)
    _kernel, _store, _path = kernel, store, path
    values = store.load(path, {})
    persist_keys = {}
    for k in pairs(values) do persist_keys[k] = true end
    watchers, all_watchers = {}, {}
    save_pending = nil
end

function bus.get(key) return values[key] end

local function schedule_save()
    if save_pending then return end
    save_pending = _kernel.after(DEBOUNCE_SECS, function()
        save_pending = nil
        bus.flush()
    end)
end

function bus.flush()
    if save_pending then save_pending.cancel(); save_pending = nil end
    local out = {}
    for k in pairs(persist_keys) do out[k] = values[k] end
    _store.save(_path, out)
end

function bus.set(key, value, opts)
    opts = opts or {}
    values[key] = value
    if opts.persist then persist_keys[key] = true end
    if persist_keys[key] then schedule_save() end

    local reg = watchers[key]
    if reg then
        local snap = {}
        for h, fn in pairs(reg) do snap[h] = fn end
        for h, fn in pairs(snap) do
            if reg[h] and (opts.source == nil or h.__element ~= opts.source) then
                local ok, err = pcall(fn, value, key)
                if not ok then print("bus: watcher error on '" .. key .. "': " .. tostring(err)) end
            end
        end
    end
    for h, fn in pairs(all_watchers) do
        local ok = pcall(fn, key, value)
        if not ok then all_watchers[h] = nil end
    end
end

local function make_handle(unreg)
    local h = {}
    h.cancel = function() unreg(h) end
    h.unwatch = h.cancel
    return h
end

---@param fn fun(value:any, key:string)
---@param source_element? table element to skip when it is the set() source
function bus.watch(key, fn, source_element)
    watchers[key] = watchers[key] or {}
    local reg = watchers[key]
    local h = make_handle(function(hh) reg[hh] = nil end)
    h.__element = source_element
    reg[h] = fn
    if values[key] ~= nil then pcall(fn, values[key], key) end
    return h
end

-- Test support: how many watchers a key holds (see telemetry.cache's twin --
-- probe-hit counting cannot observe leaked watchers).
---@return integer count
function bus.watcher_count(key)
    local reg = watchers[key]
    if not reg then return 0 end
    local n = 0
    for _ in pairs(reg) do n = n + 1 end
    return n
end

---@param fn fun(key:string, value:any)
function bus.watch_all(fn)
    local h = make_handle(function(hh) all_watchers[hh] = nil end)
    all_watchers[h] = fn
    return h
end

return bus
