-- Self-update from the public GitHub mirror of deployable/.
--
-- ASYNC BY NECESSITY. thugnet/kernel.lua is a single os.pullEventRaw loop and
-- `parallel` appears nowhere in this codebase -- a blocking http.get inside
-- any handler would stall rednet, telemetry, scenes AND the UI for the whole
-- request. So every fetch is http.request + an http_success/http_failure
-- handler correlated by URL, exactly like every other service here.
local checksum = require("thugnet.core.checksum")

local updater = {}

updater.BASE = "https://raw.githubusercontent.com/PhlompfDev/ThugNet/main/"
updater.STAGE_DIR  = ".tn_update"
updater.BACKUP_DIR = ".tn_backup"
updater.MARKER     = ".tn_pending_boot"
-- MARKER alone cannot tell "just installed, about to try booting the new
-- version" apart from "already tried once and never reached boot_ok()" --
-- both leave MARKER sitting on disk at the top of boot. ATTEMPT_MARKER is
-- the second phase: its ABSENCE means this is the very first boot after
-- install, so rollback_if_needed() lets it run instead of reverting a brand
-- new, perfectly good update. Only MARKER surviving a FULL boot (i.e.
-- ATTEMPT_MARKER already exists when rollback_if_needed() runs again) means
-- the previous attempt died before boot_ok() -- that is the one case that
-- actually calls for a rollback.
updater.ATTEMPT_MARKER = ".tn_pending_boot.attempt"
updater.INSTALLED  = "installed_manifest.json"

local HTTP_TIMEOUT = 30

local D = {}              -- injected deps
local S = { state = "idle", done = 0, total = 0 }
local pending = {}        -- url -> { cbs = {cb, ...}, timer }
local handlers = {}       -- handles from the last wire(), so re-wiring can cancel them
local after_check         -- forward declared: defined with the notify/auto block below,
                           -- called from check()'s success path further up the file
local cancel_countdown_key_handlers -- forward declared: defined with the notify/auto
                           -- block below, called from set_state() further up the file

-- ── protected paths ──────────────────────────────────────────────────────
-- A root-level .json is runtime state (config.json, state.json, events.json,
-- server_config2.json, displays.json, editor_elements.json, ...). None of
-- them are ever in a manifest, so this guard is belt-and-braces against a
-- malformed one -- but it is stated as a RULE, not a list, so a JSON added
-- in a future phase is protected the day it is introduced.
---@param path string
---@return boolean
function updater.is_protected(path)
    return path:match("^[^/]+%.json$") ~= nil and path ~= "manifest.json"
end

-- ── version comparison ───────────────────────────────────────────────────
local function triple(v)
    local a, b, c = tostring(v):match("^(%d+)%.(%d+)%.(%d+)")
    return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
end

-- Field-by-field, never string compare: "2.10.0" < "2.9.0" lexically.
---@return boolean true when `remote` is a strictly newer version than `current`
function updater.is_newer(remote, current)
    local r1, r2, r3 = triple(remote)
    local c1, c2, c3 = triple(current)
    if r1 ~= c1 then return r1 > c1 end
    if r2 ~= c2 then return r2 > c2 end
    return r3 > c3
end

-- ── state ────────────────────────────────────────────────────────────────
local function set_state(state, reason)
    -- A key handler is only ever registered while S.state == "staged" (the
    -- countdown is live). If something moves the state away from "staged" by
    -- any path other than the countdown's own timer firing or cancel_auto()
    -- (both of which already tear the handler down themselves), the handler
    -- would otherwise survive with nothing left to legitimately cancel --
    -- and a stray keypress later would call cancel_auto() on a cycle that
    -- has already moved on.
    if S.state == "staged" and state ~= "staged" and cancel_countdown_key_handlers then
        cancel_countdown_key_handlers()
    end
    S.state = state
    S.reason = reason
    if D.bus then D.bus.set("update_state", state) end
end

---@return table { state, installed, latest, done, total, reason }
function updater.status()
    return { state = S.state, installed = S.installed, latest = S.latest,
             done = S.done, total = S.total, reason = S.reason }
end

-- ── async fetch ──────────────────────────────────────────────────────────
-- Each callback in a cbs list is invoked in isolation (pcall per-callback,
-- same pattern as bus.lua's watcher dispatch) -- NOT via a bare `for _, fn
-- in ipairs(cbs) do fn(...) end`. kernel.lua wraps the entire registered
-- handler in one pcall, so a bare loop would abort on the first throwing
-- callback and silently strand every sibling caller awaiting the same URL
-- forever. That defeats the whole point of cbs being a list.
local function dispatch_cbs(cbs, ...)
    for _, cb in ipairs(cbs) do
        local ok, err = pcall(cb, ...)
        if not ok then
            local msg = "updater: fetch callback error: " .. tostring(err)
            if D.events then
                D.events.log("warn", "update", msg)
            else
                print(msg)
            end
        end
    end
end

-- kernel.on_event does NOT deduplicate -- every call adds another
-- independent entry to the registry. Re-wiring must cancel whatever this
-- module registered last time before adding a new pair, or every
-- http_success/http_failure delivery would run through one more dead
-- handler, forever, on every subsequent wire() (init() re-wires on every
-- call, in tests AND in production). A handle whose kernel has since been
-- reset() is already orphaned and harmless to cancel, but pcall it anyway --
-- cancelling must never be able to throw and abort the re-wire.
local function wire()
    for _, h in ipairs(handlers) do pcall(h.cancel) end
    handlers = {}
    handlers[#handlers + 1] = D.kernel.on_event("http_success", function(url, handle)
        local p = pending[url]
        if not p then return end
        pending[url] = nil
        p.timer.cancel()
        local body = ""
        if handle then
            body = handle.readAll() or ""
            if handle.close then handle.close() end
        end
        dispatch_cbs(p.cbs, body, nil)
    end)
    handlers[#handlers + 1] = D.kernel.on_event("http_failure", function(url, reason)
        local p = pending[url]
        if not p then return end
        pending[url] = nil
        p.timer.cancel()
        local msg = tostring(reason or "request failed")
        dispatch_cbs(p.cbs, nil, msg)
    end)
end

-- A URL already in flight is deduplicated -- no second http.request -- but
-- every caller's callback is kept and fired when the one real request
-- resolves. Dropping a duplicate caller's callback would strand it (e.g. a
-- double-clicked "What's New" button) on "fetching..." forever.
---@param url string
---@param cb fun(body:string|nil, err:string|nil)
local function fetch(url, cb)
    local p = pending[url]
    if p then table.insert(p.cbs, cb); return end
    local timer = D.kernel.after(HTTP_TIMEOUT, function()
        local pp = pending[url]
        if pp then
            pending[url] = nil
            dispatch_cbs(pp.cbs, nil, "timeout")
        end
    end)
    pending[url] = { cbs = { cb }, timer = timer }
    if type(http) ~= "table" then
        pending[url] = nil; timer.cancel()
        return cb(nil, "http disabled")
    end
    local ok = pcall(http.request, url)
    if not ok then
        pending[url] = nil; timer.cancel()
        cb(nil, "http disabled")
    end
end

updater.fetch = fetch   -- Task 10's changelog view reuses this

-- ── init ─────────────────────────────────────────────────────────────────
---@param deps table { kernel, store, bus, events, version? }
function updater.init(deps)
    D = deps
    S = { state = "idle", done = 0, total = 0 }
    pending = {}
    S.installed = deps.version or require("thugnet.version")
    -- Tests call kernel.reset() (which wipes kernel.lua's ev_handlers) and
    -- then re-init() to get a clean S/pending for the next scenario. wire()
    -- re-registers against whichever kernel is live now, cancelling its own
    -- previous handles first -- so re-wiring is safe whether or not the
    -- kernel was reset in between, and calling init() twice in a row never
    -- accumulates handlers.
    wire()
    return updater
end

-- ── check ────────────────────────────────────────────────────────────────
-- If a check/download is already in progress, the caller's callback is
-- invoked immediately with the current state rather than discarded -- a
-- Settings-page caller like `updater.check(function() render_button() end)`
-- must never be left waiting on a re-render that will never come.
---@param cb? fun(state:string)
function updater.check(cb)
    if S.state == "checking" or S.state == "downloading" then
        if cb then cb(S.state) end
        return
    end
    set_state("checking")
    fetch(updater.BASE .. "manifest.json", function(body, err)
        if err then
            set_state("error", err)
            if D.events then D.events.log("warn", "update", "check failed: " .. err) end
            if cb then cb(S.state) end
            return
        end
        local ok, m = pcall(textutils.unserialiseJSON, body)
        if not ok or type(m) ~= "table" or type(m.version) ~= "string"
            or type(m.files) ~= "table" then
            set_state("error", "bad manifest")
            if D.events then D.events.log("warn", "update", "manifest unreadable") end
            if cb then cb(S.state) end
            return
        end
        S.manifest = m
        S.latest = m.version
        if updater.is_newer(m.version, S.installed) then
            set_state("available")
            if D.events then
                D.events.log("info", "update", "v" .. m.version .. " available")
            end
        else
            set_state("up_to_date")
        end
        after_check()
        if cb then cb(S.state) end
    end)
end

-- ── staged download ──────────────────────────────────────────────────────
---@param rel string path relative to the tree root
---@return string path inside the staging directory
function updater.staged_path(rel)
    return updater.STAGE_DIR .. "/" .. rel
end

local function write_file(path, body)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(body)
    f.close()
    return true
end

local function discard_stage()
    if fs.exists(updater.STAGE_DIR) then pcall(fs.delete, updater.STAGE_DIR) end
    -- the flat-file test stub has no real directories, so sweep the entries
    for _, f in ipairs((S.manifest and S.manifest.files) or {}) do
        if f.p then pcall(fs.delete, updater.staged_path(f.p)) end
    end
end

-- Download every manifest file into STAGE_DIR, verifying length + checksum on
-- arrival. Sequential, not concurrent: CC caps in-flight requests, and it
-- makes the "12/41" progress label honest. ANY failure aborts the whole
-- download and discards the staging tree -- the live tree is never touched
-- until every byte has been verified.
---@param cb? fun(state:string)
function updater.download(cb)
    -- If a download/check is not currently available to start, the caller's
    -- callback is invoked immediately with the current state rather than
    -- discarded -- same reasoning as `check`: a Settings-page caller like
    -- `updater.download(function() render_button() end)` must never be left
    -- waiting on a re-render that will never come.
    if S.state ~= "available" then
        if cb then cb(S.state) end
        return
    end
    local files = S.manifest.files

    -- refuse a manifest that names a config BEFORE issuing any request
    for _, f in ipairs(files) do
        if type(f.p) ~= "string" or updater.is_protected(f.p) then
            set_state("error", "manifest names a protected path: " .. tostring(f.p))
            if D.events then
                D.events.log("warn", "update", "refused manifest: " .. tostring(f.p))
            end
            if cb then cb(S.state) end
            return
        end
    end

    S.done, S.total = 0, #files
    set_state("downloading")

    local function abort(reason)
        discard_stage()
        set_state("error", reason)
        if D.events then D.events.log("warn", "update", "download aborted: " .. reason) end
        if cb then cb(S.state) end
    end

    local function next_file(i)
        if i > #files then
            set_state("staged")
            if D.events then
                D.events.log("info", "update", "v" .. S.latest .. " staged")
            end
            if cb then cb(S.state) end
            return
        end
        local f = files[i]
        fetch(updater.BASE .. f.p, function(body, err)
            if err then return abort(f.p .. ": " .. err) end
            if #body ~= f.n then
                return abort(f.p .. ": wrong size")
            end
            if checksum.sum(body) ~= f.c then
                return abort(f.p .. ": checksum mismatch")
            end
            if not write_file(updater.staged_path(f.p), body) then
                return abort(f.p .. ": cannot write")
            end
            S.done = i
            next_file(i + 1)
        end)
    end

    next_file(1)
end

-- ── install ──────────────────────────────────────────────────────────────
local function read_file(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end

local function backup_path(rel) return updater.BACKUP_DIR .. "/" .. rel end

-- Swap the staged tree in. Config preservation is STRUCTURAL, not a special
-- case: this only ever writes paths in the new manifest and only ever deletes
-- paths in the old one. Runtime JSONs are generated on the node, so they are
-- in neither list and are invisible here by construction. is_protected() is
-- the second line of defence against a malformed manifest.
---@return boolean applied
function updater.apply()
    if S.state ~= "staged" then return false end

    local old = D.store.load(updater.INSTALLED, nil)
    local old_files = {}
    if type(old) == "table" and type(old.files) == "table" then
        for _, f in ipairs(old.files) do
            if type(f.p) == "string" then old_files[f.p] = true end
        end
    else
        -- first update: no record of what we installed. The trees are
        -- near-identical, so the new manifest's list is the right stand-in.
        for _, f in ipairs(S.manifest.files) do old_files[f.p] = true end
    end

    -- 1. back up everything currently tracked
    for p in pairs(old_files) do
        if not updater.is_protected(p) and fs.exists(p) then
            local body = read_file(p)
            if body then write_file(backup_path(p), body) end
        end
    end

    -- 2. swap the staged files in
    local new_files = {}
    for _, f in ipairs(S.manifest.files) do
        if not updater.is_protected(f.p) then
            new_files[f.p] = true
            local body = read_file(updater.staged_path(f.p))
            if body then write_file(f.p, body) end
        end
    end

    -- 3. drop tracked files the new release no longer ships
    for p in pairs(old_files) do
        if not new_files[p] and not updater.is_protected(p) then
            pcall(fs.delete, p)
        end
    end

    -- 4. record what is now installed, clear the stage
    D.store.save(updater.INSTALLED, { version = S.latest, files = S.manifest.files })
    discard_stage()

    if D.events then
        D.events.log("info", "update", "installed v" .. tostring(S.latest) .. ", rebooting")
    end

    -- 5. arm rollback, then reboot
    -- Flush the bus before rebooting: bus.lua debounces persistent-key writes
    -- by ~0.5s (see DEBOUNCE_SECS in bus.lua), and this reboot happens
    -- immediately. Without an explicit flush here, any bus state set in the
    -- half-second before an update would be silently lost on every single
    -- update. This mirrors what startup.lua's terminate handler already does
    -- on a normal shutdown, and what the Reboot button (Task 11) does on a
    -- manual reboot -- both reboot paths should behave consistently.
    if D.bus and D.bus.flush then pcall(D.bus.flush) end
    -- A stale ATTEMPT_MARKER from some earlier, already-resolved cycle must
    -- never leak into THIS cycle's first boot -- that would make boot 1 of a
    -- brand new install roll back immediately, as if it were already boot 2
    -- of a previous, unrelated failure.
    pcall(fs.delete, updater.ATTEMPT_MARKER)
    write_file(updater.MARKER, tostring(S.latest))
    os.reboot()
    return true
end

-- ── rollback ─────────────────────────────────────────────────────────────
-- MARKER is written just before the post-update reboot and deleted (along
-- with ATTEMPT_MARKER) by boot_ok() at the end of a successful boot. So
-- MARKER alone does not mean "the previous boot failed" -- the FIRST boot
-- after a successful install starts with MARKER present too, and must be
-- allowed to run. Only a MARKER that survives a full boot attempt (i.e.
-- ATTEMPT_MARKER already exists, meaning rollback_if_needed() already ran
-- once this cycle and boot_ok() never followed) means that attempt died --
-- restore the backup. This two-phase check is the only reason a bad release
-- cannot brick a node that is a walk away in-game for every module that runs
-- AFTER this gate in startup.lua's boot order (kernel, config, store, bus,
-- events, rsio, steps, telemetry, protocol, transport, migrate, and every
-- module they in turn load) -- and, just as important, the only reason a
-- GOOD release survives its own first boot instead of being silently
-- reverted every time.
--
-- It is NOT a guarantee for the two files that sit ahead of or inside the
-- gate itself: `startup.lua` (CC runs it directly -- if it does not parse,
-- nothing on the node runs at all, this function included) and this file,
-- `updater.lua`, plus the one module it unconditionally requires,
-- `thugnet/core/checksum.lua` (a syntax error in either means the
-- `require("thugnet.core.updater")` call that reaches this very function
-- throws before rollback_if_needed() can run). A bad release touching only
-- those files can still brick a node; see docs/USING-THUGNET.md's
-- Troubleshooting section for the manual recovery (the previous version's
-- files remain on disk under .tn_backup).
---@return boolean rolled_back
function updater.rollback_if_needed()
    if not fs.exists(updater.MARKER) then return false end

    if not fs.exists(updater.ATTEMPT_MARKER) then
        -- First boot since install: let it try. Record that an attempt is
        -- now in flight so a SECOND consecutive rollback_if_needed() call
        -- (i.e. this marker surviving a full boot) knows to roll back.
        pcall(write_file, updater.ATTEMPT_MARKER, "1")
        return false
    end

    local restored = 0
    local function restore_dir(dir, prefix)
        for _, name in ipairs(fs.list(dir)) do
            local abs = dir .. "/" .. name
            local rel = prefix == "" and name or (prefix .. "/" .. name)
            if fs.isDir(abs) then
                restore_dir(abs, rel)
            else
                local body = read_file(abs)
                if body and not updater.is_protected(rel) then
                    write_file(rel, body)
                    restored = restored + 1
                end
            end
        end
    end
    if fs.exists(updater.BACKUP_DIR) or fs.isDir(updater.BACKUP_DIR) then
        pcall(restore_dir, updater.BACKUP_DIR, "")
    end

    pcall(fs.delete, updater.MARKER)
    pcall(fs.delete, updater.ATTEMPT_MARKER)
    if D.events then
        D.events.log("warn", "update",
            "update boot failed; rolled back " .. restored .. " file(s)")
    end
    return true
end

-- Called at the end of a successful boot: one clean boot disarms rollback.
function updater.boot_ok()
    if fs.exists(updater.MARKER) then pcall(fs.delete, updater.MARKER) end
    if fs.exists(updater.ATTEMPT_MARKER) then pcall(fs.delete, updater.ATTEMPT_MARKER) end
end

-- ── notify / auto-update / scheduling ────────────────────────────────────
local FIRST_CHECK_SECS = 30        -- let the network settle after boot
local POLL_SECS        = 1800      -- 30 minutes
local COUNTDOWN_SECS   = 10
local IDLE_POLL_SECS   = 5
local RETRY_SECS       = 600       -- after a cancelled countdown

local notify_fns = {}
local countdown_fns = {}
local idle_probe = nil
local idle_timer, countdown_timer = nil, nil
local countdown_key_handlers = nil  -- { key_handle, char_handle } while the countdown runs

---@param fn fun(version:string) called once per NEW version when notify is on
---@return table handle with .cancel()
function updater.on_notify(fn)
    table.insert(notify_fns, fn)
    return { cancel = function()
        for i, f in ipairs(notify_fns) do
            if f == fn then table.remove(notify_fns, i); break end
        end
    end }
end

-- Fires once, when the cancellable auto-install countdown begins -- the page
-- owns HOW that is shown (a toast); the updater only knows WHEN and with what
-- version/duration. Keeps this module free of any UI import.
---@param fn fun(version:string, secs:number)
---@return table handle with .cancel()
function updater.on_countdown(fn)
    table.insert(countdown_fns, fn)
    return { cancel = function()
        for i, f in ipairs(countdown_fns) do
            if f == fn then table.remove(countdown_fns, i); break end
        end
    end }
end

-- The page supplies this: true only when nothing would be disrupted by a
-- reboot -- no server run in flight, no menu or prompt open, no scene mid
-- execution. Rebooting through a command sequence leaves redstone outputs
-- latched halfway, which is why auto-update waits rather than firing at once.
---@param fn fun():boolean
function updater.set_idle_probe(fn) idle_probe = fn end

-- kernel.on_event is not a UI import -- the updater already depends on
-- D.kernel for http_success/http_failure, so registering a key/char handler
-- here keeps the "press any key to cancel" behaviour out of app.lua/the
-- Settings page entirely. Defined ahead of begin_countdown/cancel_auto (both
-- of which call it) via the forward declaration near the top of the file.
cancel_countdown_key_handlers = function()
    if countdown_key_handlers then
        for _, h in ipairs(countdown_key_handlers) do pcall(h.cancel) end
        countdown_key_handlers = nil
    end
end

function updater.cancel_auto()
    cancel_countdown_key_handlers()
    if countdown_timer then countdown_timer.cancel(); countdown_timer = nil end
    if idle_timer then idle_timer.cancel(); idle_timer = nil end
    if D.events then
        D.events.log("info", "update", "auto-install cancelled; retrying later")
    end
    if D.kernel then
        D.kernel.after(RETRY_SECS, function() updater.maybe_auto() end)
    end
end

local function begin_countdown()
    if countdown_timer then return end
    if D.events then
        D.events.log("warn", "update",
            "installing v" .. tostring(S.latest) .. " in " .. COUNTDOWN_SECS .. "s")
    end
    for _, fn in ipairs(countdown_fns) do pcall(fn, S.latest, COUNTDOWN_SECS) end

    -- Any keypress cancels: both "key" (arrow keys, letters held via terminal
    -- capture) and "char" (printable characters) fire for an ordinary
    -- keystroke in CC, so both are handled or half of all keys would silently
    -- fail to cancel.
    local function on_key() updater.cancel_auto() end
    countdown_key_handlers = {
        D.kernel.on_event("key", on_key),
        D.kernel.on_event("char", on_key),
    }

    countdown_timer = D.kernel.after(COUNTDOWN_SECS, function()
        countdown_timer = nil
        cancel_countdown_key_handlers()
        if S.state == "staged" then updater.apply() end
    end)
end

-- Poll for idle, then start the cancellable countdown.
function updater.maybe_auto()
    if D.bus.get("update_auto") ~= true then return end
    if S.state ~= "staged" then return end
    if idle_timer then return end
    idle_timer = D.kernel.every(IDLE_POLL_SECS, function()
        if S.state ~= "staged" then
            if idle_timer then idle_timer.cancel(); idle_timer = nil end
            return
        end
        if idle_probe == nil or idle_probe() then
            if idle_timer then idle_timer.cancel(); idle_timer = nil end
            begin_countdown()
        end
    end)
end

after_check = function()
    if S.state ~= "available" then return end

    if D.bus.get("update_notify") ~= false
        and D.bus.get("update_notified_version") ~= S.latest then
        D.bus.set("update_notified_version", S.latest, { persist = true })
        for _, fn in ipairs(notify_fns) do pcall(fn, S.latest) end
    end

    if D.bus.get("update_auto") == true then
        updater.download(function(state)
            if state == "staged" then updater.maybe_auto() end
        end)
    end
end

-- First check 30s after boot (the network needs to settle), then every 30
-- minutes. Every node polls independently: no protocol change, and a node
-- can still update itself while DNS is down.
function updater.start_schedule()
    D.kernel.after(FIRST_CHECK_SECS, function() updater.check() end)
    D.kernel.every(POLL_SECS, function() updater.check() end)
end

return updater
