-- Unified event feed: ring buffer + severity hooks + persistence.
local events = {}

local CAP, PERSIST_N, DEBOUNCE = 200, 50, 1

local _kernel, _store, _path
local ring = {}
local counter = 0
local alert_hooks, log_hooks = {}, {}
local save_pending = nil

function events.init(kernel, store, path)
    _kernel, _store, _path = kernel, store, path
    ring = store.load(path, {})
    counter = #ring
    alert_hooks, log_hooks = {}, {}
    save_pending = nil
end

local function schedule_save()
    if save_pending then return end
    save_pending = _kernel.after(DEBOUNCE, function()
        save_pending = nil
        local out = {}
        local start = math.max(1, #ring - PERSIST_N + 1)
        for i = start, #ring do table.insert(out, ring[i]) end
        _store.save(_path, out)
    end)
end

local function make_handle(reg)
    local h = {}
    h.cancel = function() reg[h] = nil end
    return h
end

function events.log(severity, source, text, data)
    counter = counter + 1
    -- t_day/t_ig: in-game day + hour-of-day, for human-readable feed rows
    -- (t_clock is monotonic uptime, useless for "when did this happen")
    local entry = { n = counter, severity = severity, source = source,
                    text = text, data = data, t_clock = os.clock(),
                    t_day = os.day(), t_ig = os.time() }
    table.insert(ring, entry)
    if #ring > CAP then table.remove(ring, 1) end
    schedule_save()
    for h, fn in pairs(log_hooks) do if log_hooks[h] then pcall(fn, entry) end end
    if severity == "alert" then
        for h, fn in pairs(alert_hooks) do if alert_hooks[h] then pcall(fn, entry) end end
    end
    return entry
end

function events.list(filter)
    if not filter then
        local out = {}
        for _, e in ipairs(ring) do table.insert(out, e) end
        return out
    end
    local out = {}
    for _, e in ipairs(ring) do
        if (not filter.source or e.source == filter.source)
           and (not filter.severity or e.severity == filter.severity) then
            table.insert(out, e)
        end
    end
    return out
end

function events.clear()
    ring = {}
    schedule_save()
end

function events.on_alert(fn) local h = make_handle(alert_hooks); alert_hooks[h] = fn; return h end
function events.on_log(fn)   local h = make_handle(log_hooks);   log_hooks[h] = fn;   return h end

return events
