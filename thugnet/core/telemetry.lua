-- Telemetry: sensor polling with rate derivation (server side) and the
-- panel-side cache keyed by "domain:sensor" paths. Spec §5.
local telemetry = {}

local RATE_WINDOW = 60      -- seconds of samples kept for rate derivation
local HISTORY_N = 30        -- cache history ring length
local REPUBLISH_SECS = 10   -- heartbeat publish even when unchanged
local EPSILON_FRAC = 0.001  -- publish when |dv| > 0.1% of |v|

-- ── peripheral readers per sensor kind ───────────────────────────────────

local function read_fluid(p)
    local tanks = p.tanks and p.tanks() or {}
    local t = tanks[1]
    if not t then return { value = 0, fraction = 0 } end
    local cap = math.max(t.capacity or 1, 1)
    return { value = t.amount or 0, fraction = (t.amount or 0) / cap }
end

local function read_energy(p)
    local stored = (p.getEnergy and p.getEnergy())
        or (p.getEnergyStored and p.getEnergyStored()) or 0
    local cap = (p.getEnergyCapacity and p.getEnergyCapacity())
        or (p.getMaxEnergyStored and p.getMaxEnergyStored()) or 1
    return { value = stored, fraction = stored / math.max(cap, 1) }
end

local function count_items(p)
    local total = 0
    for _, item in pairs(p.list and p.list() or {}) do
        total = total + (item.count or 0)
    end
    return total
end

local function read_item_count(p)
    local total = count_items(p)
    local slots = (p.size and p.size()) or 1
    return { value = total, fraction = total / (slots * 64) }
end

local function read_inventory(p, top_n)
    local by_name = {}
    local total = 0
    for _, item in pairs(p.list and p.list() or {}) do
        local n = item.name or "?"
        by_name[n] = (by_name[n] or 0) + (item.count or 0)
        total = total + (item.count or 0)
    end
    local detail = {}
    for name, count in pairs(by_name) do table.insert(detail, { name = name, count = count }) end
    table.sort(detail, function(a, b) return a.count > b.count end)
    while #detail > (top_n or 5) do table.remove(detail) end
    local slots = (p.size and p.size()) or 1
    return { value = total, fraction = total / (slots * 64), detail = detail }
end

local function read_method(p, method)
    local v = p[method] and p[method]()
    if type(v) ~= "number" then return nil end
    return { value = v }
end

-- ── rate derivation ──────────────────────────────────────────────────────

local function push_sample(samples, t, v)
    table.insert(samples, { t = t, v = v })
    while #samples > 1 and samples[1].t < t - RATE_WINDOW do
        table.remove(samples, 1)
    end
end

local function derive_rate(samples)
    if #samples < 2 then return nil end
    local a, b = samples[1], samples[#samples]
    local dt = b.t - a.t
    if dt <= 0 then return nil end
    return (b.v - a.v) / dt * 60   -- per minute
end

-- ── poller (server side) ─────────────────────────────────────────────────

---@param kernel table
---@param publish_fn fun(name:string, reading:table)
function telemetry.poller(kernel, publish_fn)
    local p = {}
    local tickers = {}     -- sensor name -> kernel handle
    local state = {}       -- sensor name -> { samples, last_reading, last_pub_t, last_pub_v, errored }

    local function poll_one(sensor)
        local st = state[sensor.name]
        local dev = peripheral.wrap(sensor.peripheral)
        local ok, reading = pcall(function()
            if not dev then return nil end
            if sensor.kind == "fluid" then return read_fluid(dev)
            elseif sensor.kind == "energy" then return read_energy(dev)
            elseif sensor.kind == "item_count" then return read_item_count(dev)
            elseif sensor.kind == "item_rate" then return { value = count_items(dev) }
            elseif sensor.kind == "inventory" then return read_inventory(dev, sensor.top_n)
            elseif sensor.kind == "method" then return read_method(dev, sensor.method or "getSpeed")
            end
            return nil
        end)

        if not ok or reading == nil then
            if not st.errored then
                st.errored = true
                -- remembered as the last reading so readings() reports it:
                -- otherwise a failing sensor is missing from the republish
                -- that follows a DNS relink and silently drops off the panel
                st.last_reading = { error = true, unit = sensor.unit }
                publish_fn(sensor.name, st.last_reading)
            end
            return
        end
        st.errored = false

        push_sample(st.samples, os.clock(), reading.value)
        local rate = derive_rate(st.samples)

        if sensor.kind == "item_rate" then
            -- the sensor's VALUE is the rate; no fraction
            reading = { value = rate or 0 }
        else
            reading.rate = rate
        end
        reading.unit = sensor.unit
        st.last_reading = reading

        -- throttle: publish on meaningful change or every REPUBLISH_SECS
        local now = os.clock()
        local changed = st.last_pub_v == nil
        if not changed then
            local dv = math.abs(reading.value - st.last_pub_v)
            local threshold = math.abs(st.last_pub_v) * EPSILON_FRAC
            if math.abs(st.last_pub_v) < 1e-6 then threshold = 0 end
            changed = dv > threshold
        end
        if changed or (now - (st.last_pub_t or -math.huge)) >= REPUBLISH_SECS then
            st.last_pub_t = now
            st.last_pub_v = reading.value
            publish_fn(sensor.name, reading)
        end
    end

    ---@param sensors table[] sensor descriptors {name, peripheral, kind, poll_secs?, unit?, method?, top_n?}
    function p.set_sensors(sensors)
        for _, h in pairs(tickers) do h.cancel() end
        tickers = {}
        state = {}
        for _, sensor in ipairs(sensors or {}) do
            state[sensor.name] = { samples = {} }
            local s = sensor
            tickers[sensor.name] = kernel.every(sensor.poll_secs or 2, function() poll_one(s) end)
            poll_one(s)   -- immediate first sample
        end
    end

    function p.get(name)
        local st = state[name]
        return st and st.last_reading
    end

    function p.readings()
        local out = {}
        for name, st in pairs(state) do out[name] = st.last_reading end
        return out
    end

    function p.stop()
        for _, h in pairs(tickers) do h.cancel() end
        tickers = {}
    end

    return p
end

-- ── cache (panel side) ───────────────────────────────────────────────────

function telemetry.cache(_)
    local c = {}
    local data = {}       -- path -> { reading, history = {{t,value}...}, watchers = {[h]=fn} }

    local function entry(path)
        data[path] = data[path] or { history = {}, watchers = {} }
        return data[path]
    end

    ---@param domain string
    ---@param sensor string
    ---@param reading table { value, fraction?, rate?, unit?, detail?, error? }
    function c.update(domain, sensor, reading)
        local path = domain .. ":" .. sensor
        local e = entry(path)
        e.reading = reading
        if reading.value ~= nil then
            table.insert(e.history, { t = os.clock(), value = reading.value })
            while #e.history > HISTORY_N do table.remove(e.history, 1) end
        end
        for h, fn in pairs(e.watchers) do
            if e.watchers[h] then pcall(fn, reading, path) end
        end
    end

    ---@return number|nil current value
    function c.get(path)
        local e = data[path]
        return e and e.reading and e.reading.value
    end

    function c.reading(path)
        local e = data[path]
        return e and e.reading
    end

    function c.history(path)
        local e = data[path]
        return (e and e.history) or {}
    end

    ---@return table handle with .unwatch()
    function c.watch(path, fn)
        -- The cache is SHARED state and defs come from a hand-editable file: a
        -- non-string path (a JSON number) would become a permanent data[] key,
        -- and paths()'s table.sort throws comparing it against real sensor
        -- strings -- taking down every paths() consumer, Monitoring included.
        -- Refuse the entry; hand back an inert handle so callers need no guard.
        if type(path) ~= "string" then
            local h = {}
            h.cancel = function() end
            h.unwatch = h.cancel
            return h
        end
        local e = entry(path)
        local h = {}
        h.cancel = function() e.watchers[h] = nil end
        h.unwatch = h.cancel
        e.watchers[h] = fn
        if e.reading then pcall(fn, e.reading, path) end
        return h
    end

    -- Test support: how many watchers a path holds. A leak assertion that only
    -- counts its own probe's hits cannot see leaked watchers at all -- their
    -- callbacks touch destroyed elements, not the probe counter.
    ---@return integer count
    function c.watcher_count(path)
        local e = data[path]
        if not e then return 0 end
        local n = 0
        for _ in pairs(e.watchers) do n = n + 1 end
        return n
    end

    function c.paths()
        -- Published sensors only. watch() lazily creates an entry for paths that
        -- have never published (a widget bound to a typo'd sensor), and listing
        -- those would feed the typo back through every sensor autocomplete as if
        -- it were live -- surviving even the widget's deletion.
        local out = {}
        for path, e in pairs(data) do
            if e.reading then table.insert(out, path) end
        end
        table.sort(out)
        return out
    end

    return c
end

return telemetry
