-- Automation rules engine: time + telemetry-condition triggers -> scene /
-- command / alert actions. Fires only on the node with config.automation=true
-- (single authority, spec §5). Persists automation.json.
local automation = {}

local PATH = "automation.json"

local D             -- deps { kernel, store, events, telemetry_cache, scenes, client, config }
local rules = {}    -- array of { name, trigger, action, enabled, _state... }
local armed = false

local function persist()
    -- strip private _ fields before saving
    local out = {}
    for _, r in ipairs(rules) do
        out[#out + 1] = { name = r.name, trigger = r.trigger, action = r.action, enabled = r.enabled }
    end
    D.store.save(PATH, out)
end

local function index_of(name)
    for i, r in ipairs(rules) do if r.name == name then return i end end
end

local re_arm   -- fwd (defined in Task 4)

local function changed()
    persist()
    if armed and re_arm then re_arm() end
end

function automation.init(deps)
    D = deps
    rules = D.store.load(PATH, {})
    for _, r in ipairs(rules) do
        r.enabled = r.enabled ~= false
        r.trigger = r.trigger or {}
        r.action = r.action or {}
    end
end

function automation.list() return rules end
function automation.get(name) local i = index_of(name); return i and rules[i] end

function automation.add(name)
    if automation.get(name) then return automation.get(name) end
    local r = { name = name, trigger = {}, action = {}, enabled = true }
    table.insert(rules, r)
    changed()
    return r
end

function automation.rename(name, new_name)
    if type(new_name) ~= "string" or new_name == "" then return false end
    local r = automation.get(name)
    if not r or (automation.get(new_name) and new_name ~= name) then return false end
    r.name = new_name; changed(); return true
end

function automation.delete(name)
    local i = index_of(name)
    if not i then return false end
    table.remove(rules, i); changed(); return true
end

function automation.set_enabled(name, v)
    local r = automation.get(name); if not r then return false end
    r.enabled = v and true or false; changed(); return true
end

function automation.set_trigger(name, trigger)
    local r = automation.get(name); if not r then return false end
    r.trigger = trigger or {}; changed(); return true
end

function automation.set_action(name, action)
    local r = automation.get(name); if not r then return false end
    r.action = action or {}; changed(); return true
end

-- ── firing ────────────────────────────────────────────────────────────────

local function fire(rule)
    D.events.log("info", "automation", "rule fired: " .. rule.name)
    local a = rule.action or {}
    if a.scene and D.scenes then
        D.scenes.run(a.scene)
    elseif a.domain and a.command and D.client then
        D.client.send(a.domain, a.command, nil, function() end)
    elseif a.alert then
        D.events.log("alert", "automation", a.alert)
    end
end

local function cond_met(t, value)
    if value == nil then return false end
    if t.equals ~= nil then return value == t.equals end
    if t.gte ~= nil then return value >= t.gte end
    if t.lte ~= nil then return value <= t.lte end
    return false
end

-- ── time triggers ────────────────────────────────────────────────────────

local NAMED = { dawn = 6, noon = 12, dusk = 18, midnight = 0 }
local function parse_at(at)
    if type(at) ~= "string" then return nil end
    if NAMED[at] ~= nil then return NAMED[at] end
    local hh, mm = at:match("^(%d%d?):(%d%d)$")
    if hh then return tonumber(hh) + tonumber(mm) / 60 end
    return nil
end

local time_handle = nil
local TIME_POLL = 5

local function check_time_rules()
    local now = os.time("ingame")
    local day = os.day()
    for _, rule in ipairs(rules) do
        if rule.enabled and rule.trigger.at then
            local target = parse_at(rule.trigger.at)
            if target and rule._last_day ~= day and now >= target then
                rule._last_day = day
                fire(rule)
            end
        end
    end
end

-- ── condition triggers ──────────────────────────────────────────────────

local cond_handles = {}   -- live telemetry watch + debounce timer handles

local function arm_condition(rule)
    local t = rule.trigger
    rule._fired = false        -- hysteresis latch
    rule._pending = nil        -- sustained debounce timer
    local h = D.telemetry_cache.watch(t.sensor, function(reading)
        local met = cond_met(t, reading and reading.value)
        if met then
            if rule._fired then return end          -- already latched; wait for clear
            if t.sustained_secs then
                if not rule._pending then
                    rule._pending = D.kernel.after(t.sustained_secs, function()
                        rule._pending = nil
                        -- re-check current value before firing
                        local cur = D.telemetry_cache.get(t.sensor)
                        if cond_met(t, cur) and not rule._fired then
                            rule._fired = true; fire(rule)
                        end
                    end)
                end
            else
                rule._fired = true; fire(rule)
            end
        else
            rule._fired = false                      -- condition cleared: re-arm
            if rule._pending then rule._pending.cancel(); rule._pending = nil end
        end
    end)
    table.insert(cond_handles, h)
end

-- ── arm / disarm ────────────────────────────────────────────────────────

function automation.arm()
    if armed then automation.disarm() end
    if not (D.config and D.config.automation) then return end   -- authority node only
    armed = true
    for _, rule in ipairs(rules) do
        if rule.enabled and rule.trigger.sensor then
            arm_condition(rule)
        end
    end
    -- time rules: a target already passed today waits for the next game-day
    local day0, now0 = os.day(), os.time("ingame")
    for _, rule in ipairs(rules) do
        if rule.enabled and rule.trigger.at then
            local target = parse_at(rule.trigger.at)
            rule._last_day = (target and now0 >= target) and day0 or nil
        end
    end
    time_handle = D.kernel.every(TIME_POLL, check_time_rules)
end

function automation.disarm()
    armed = false
    if time_handle then time_handle.cancel(); time_handle = nil end
    for _, h in ipairs(cond_handles) do if h and h.cancel then h.cancel() end end
    cond_handles = {}
    for _, rule in ipairs(rules) do
        if rule._pending then rule._pending.cancel(); rule._pending = nil end
    end
end

re_arm = function() automation.arm() end

return automation
