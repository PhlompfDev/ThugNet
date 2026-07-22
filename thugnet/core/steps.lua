-- The step engine: ordered execution of redstone / net / wait steps with
-- delays, wait conditions, timeout policies, and abort. Used by server
-- command sequences AND panel scenes (spec §5).
local steps = {}

local DEFAULT_TIMEOUT = 10
local POLL_SECS = 0.5
local TICK = 0.05

local _kernel
local run_counter = 0

function steps.init(kernel) _kernel = kernel end

local function cond_met(cond, value)
    if value == nil then return false end
    if cond.equals ~= nil then return value == cond.equals end
    if cond.gte ~= nil then return value >= cond.gte end
    if cond.lte ~= nil then return value <= cond.lte end
    return false
end

function steps.run(opts)
    run_counter = run_counter + 1
    local run = { id = run_counter }
    local list = opts.steps or {}
    local ctx = opts.ctx
    local status = "running"
    local timers = {}          -- live handles to cancel on abort

    local function set_status(s) status = s end
    function run.status() return status end

    local function progress(i, step_type, st)
        if opts.on_progress then
            pcall(opts.on_progress, { run_id = run.id, step = i, total = #list,
                                      step_type = step_type, status = st })
        end
    end

    local function finish(st, reason)
        if status == "done" or status == "aborted" or status == "failed" then return end
        set_status(st)
        for _, h in ipairs(timers) do h.cancel() end
        progress(#list, "end", st)
        if opts.on_done then pcall(opts.on_done, { run_id = run.id, status = st, reason = reason }) end
    end

    local function after(secs, fn)
        local h = _kernel.after(secs, fn)
        table.insert(timers, h)
        return h
    end

    local exec_step   -- forward decl

    local function next_step(i)
        if status ~= "running" and status ~= "waiting" then return end
        set_status("running")
        if i > #list then finish("done") return end
        exec_step(i)
    end

    local function do_redstone(step)
        for side, face in pairs(step.faces or {}) do
            local mask = face.bundled and ctx.rsio.mask(face.bundled) or nil
            if face.mode == "static" then
                ctx.rsio.toggle(side, mask)
            elseif face.mode == "pulse" then
                ctx.rsio.pulse(side, mask, (face.duration_ticks or 10) * TICK)
            end
        end
    end

    -- net step with wait resolution + timeout policy
    local function do_net(i, step, tries_left)
        local wait = step.wait or "none"
        local resolved = false
        local timeout_h = nil

        local function resolve_ok()
            if resolved or status == "aborted" then return end
            resolved = true
            if timeout_h then timeout_h.cancel() end
            next_step(i + 1)
        end

        local function on_timeout()
            if resolved or status == "aborted" then return end
            resolved = true
            local policy = step.on_timeout or "abort"
            if policy == "continue" then
                next_step(i + 1)
            elseif type(policy) == "table" and policy.retry then
                if tries_left > 0 then
                    do_net(i, step, tries_left - 1)
                else
                    finish("failed", "timeout")
                end
            else
                finish("failed", "timeout")
            end
        end

        if wait ~= "none" then
            set_status("waiting")
            progress(i, "net", "waiting")
            timeout_h = after(step.timeout_secs or DEFAULT_TIMEOUT, on_timeout)
        end

        ctx.send(step.domain, step.command, step.args, function(ok, state)
            if resolved or status == "aborted" then return end
            if wait == "none" then return end
            if wait == "any" then resolve_ok() return end
            if wait == "ok" then
                if ok then resolve_ok() end
                return   -- not-ok: keep waiting; timeout policy decides
            end
            if type(wait) == "table" and wait.key then
                local v = state and state[wait.key]
                if cond_met(wait, v) then resolve_ok() end
            end
        end)

        if wait == "none" then next_step(i + 1) end
    end

    local function do_wait(i, step)
        if step.ticks then
            set_status("waiting")
            progress(i, "wait", "waiting")
            after(step.ticks * TICK, function()
                if status ~= "aborted" then next_step(i + 1) end
            end)
            return
        end
        -- until_ condition on a telemetry path
        local u = step.until_ or {}
        set_status("waiting")
        progress(i, "wait", "waiting")
        local resolved = false
        local timeout_h = after(step.timeout_secs or DEFAULT_TIMEOUT, function()
            if resolved or status == "aborted" then return end
            resolved = true
            local policy = step.on_timeout or "abort"
            if policy == "continue" then next_step(i + 1)
            else finish("failed", "timeout") end
        end)
        local function poll()
            if resolved or status == "aborted" then return end
            if cond_met(u, ctx.telemetry(u.sensor)) then
                resolved = true
                timeout_h.cancel()
                next_step(i + 1)
            else
                after(POLL_SECS, poll)
            end
        end
        poll()
    end

    exec_step = function(i)
        local step = list[i]
        progress(i, step.type, "running")
        local function body()
            if step.type == "redstone" then
                do_redstone(step)
                next_step(i + 1)
            elseif step.type == "net" then
                local retries = 0
                if type(step.on_timeout) == "table" and step.on_timeout.retry then
                    retries = step.on_timeout.retry
                end
                do_net(i, step, retries)
            elseif step.type == "wait" then
                do_wait(i, step)
            else
                finish("failed", "unknown step type: " .. tostring(step.type))
            end
        end
        if step.delay_ticks and step.delay_ticks > 0 then
            set_status("waiting")
            after(step.delay_ticks * TICK, function()
                if status ~= "aborted" then set_status("running"); body() end
            end)
        else
            body()
        end
    end

    function run.abort()
        if status == "done" or status == "failed" or status == "aborted" then return end
        finish("aborted", "user abort")
    end

    next_step(1)
    return run
end

return steps
