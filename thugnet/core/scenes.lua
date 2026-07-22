-- Panel-side scenes: named ordered step-engine macros. Runs scenes through
-- core/steps.lua with a panel ctx (client.send / telemetry_cache / rsio).
-- Spec §5 scenes.lua.
local scenes = {}

local PATH = "scenes.json"

local D            -- deps { kernel, store, events, client, telemetry_cache, rsio, steps }
local list = {}    -- array of { name, steps }

local function persist() D.store.save(PATH, list) end

local function index_of(name)
    for i, s in ipairs(list) do if s.name == name then return i end end
end

function scenes.init(deps)
    D = deps
    list = D.store.load(PATH, {})
    for _, s in ipairs(list) do s.steps = s.steps or {} end
end

function scenes.list() return list end
function scenes.get(name) local i = index_of(name); return i and list[i] end

function scenes.add(name)
    local existing = scenes.get(name)
    if existing then return existing end
    local s = { name = name, steps = {} }
    table.insert(list, s)
    persist()
    return s
end

function scenes.rename(name, new_name)
    if type(new_name) ~= "string" or new_name == "" then return false end
    local s = scenes.get(name)
    if not s or (scenes.get(new_name) and new_name ~= name) then return false end
    s.name = new_name
    persist()
    return true
end

function scenes.delete(name)
    local i = index_of(name)
    if not i then return false end
    table.remove(list, i)
    persist()
    return true
end

local function unique_name(base)
    local name = base
    local n = 1
    while scenes.get(name) do n = n + 1; name = base .. " " .. n end
    return name
end

function scenes.duplicate(name)
    local s = scenes.get(name)
    if not s then return nil end
    local copy_steps = {}
    for i, step in ipairs(s.steps) do copy_steps[i] = step end
    local dup = { name = unique_name(name .. " copy"), steps = copy_steps }
    table.insert(list, dup)
    persist()
    return dup
end

function scenes.set_steps(name, steps)
    local s = scenes.get(name)
    if not s then return false end
    s.steps = steps or {}
    persist()
    return true
end

-- ── running scenes ────────────────────────────────────────────────────────

local runs = {}            -- run_id -> { scene, run = <steps run>, last = <progress> }
local progress_hooks = {}  -- [h] = fn
scenes.last_progress = nil

local function fan_progress(p)
    scenes.last_progress = p
    for h, fn in pairs(progress_hooks) do
        if progress_hooks[h] then pcall(fn, p) end
    end
end

function scenes.on_progress(fn)
    local h = {}
    h.cancel = function() progress_hooks[h] = nil end
    h.unwatch = h.cancel
    progress_hooks[h] = fn
    return h
end

local function scene_ctx()
    return {
        rsio = D.rsio,
        kernel = D.kernel,
        send = function(domain, name, args, cb)
            if D.client and D.client.send then D.client.send(domain, name, args, cb)
            elseif cb then cb(false, nil) end
        end,
        telemetry = function(path)
            return D.telemetry_cache and D.telemetry_cache.get(path)
        end,
    }
end

function scenes.run(name)
    local s = scenes.get(name)
    if not s then
        -- A silent nil here makes a scene-routed editor button whose scene was
        -- renamed, deleted, or typo'd into a dead control with zero feedback --
        -- the events feed is the only place the user can learn why.
        if D and D.events then
            D.events.log("alert", "scenes", "unknown scene: " .. tostring(name))
        end
        return nil
    end
    local rec = { scene = name }
    local run = D.steps.run{
        steps = s.steps or {},
        ctx = scene_ctx(),
        on_progress = function(p)
            local step_def = (s.steps or {})[p.step] or {}
            rec.last = { scene = name, run_id = p.run_id, step = p.step,
                         total = p.total, step_name = step_def.name, status = p.status }
            fan_progress(rec.last)
        end,
        on_done = function(r)
            runs[r.run_id] = nil
            fan_progress({ scene = name, run_id = r.run_id, step = 0, total = 0,
                           status = r.status })
            D.events.log(r.status == "done" and "info" or "alert", "scenes",
                ("scene %s: %s"):format(name, r.status))
        end,
    }
    rec.run = run
    runs[run.id] = rec
    D.events.log("info", "scenes", "scene started: " .. name)
    return run.id
end

function scenes.abort(run_id)
    local rec = runs[run_id]
    if not rec then return false end
    rec.run.abort()
    return true
end

function scenes.running()
    local out = {}
    for rid, rec in pairs(runs) do
        local l = rec.last or {}
        table.insert(out, { scene = rec.scene, run_id = rid, step = l.step,
                            total = l.total, step_name = l.step_name,
                            status = l.status or "running" })
    end
    return out
end

-- Auto-update's idle probe asks this: rebooting mid-scene leaves whatever
-- the scene had already switched in a half-applied state.
---@return boolean
function scenes.is_running()
    for _ in pairs(runs) do return true end
    return false
end

return scenes
