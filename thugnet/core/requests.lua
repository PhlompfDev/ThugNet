-- Feature requests filed from the panel, wired to the public
-- PhlompfDev/ThugNet-Requests repo that the agent loop watches.
--
-- ASYNC BY NECESSITY, same as updater.lua: the kernel is a single
-- os.pullEventRaw loop, so every network touch is http.request + an
-- http_success/http_failure handler correlated by URL. A blocking fetch here
-- would stall rednet, telemetry, scenes AND the UI for the whole request.
--
-- Two directions, two transports:
--   * SUBMIT writes a `## Title` block into INBOX.md above its last `---`
--     rule (the exact shape tools/agent/inbox.js parses) via the GitHub
--     Contents API -- GET for {content, sha}, then PUT with the edited file.
--     That needs a token; it lives in config.json (`requests_token`), which
--     is runtime state the updater structurally never ships or overwrites.
--   * REFRESH reads the raw INBOX.md anonymously and resolves each locally
--     recorded request against it: still above the rule -> waiting for
--     pickup; a `~~Title~~ -> #NNN . status` receipt below it -> that
--     status; receipt vanished after we saw one -> shipped (the sweep only
--     ever removes shipped receipts).
--
-- What was sent from THIS node is remembered in requests.json (runtime,
-- never in a manifest, invisible to the updater by construction).
local requests = {}

requests.REPO = "PhlompfDev/ThugNet-Requests"
requests.RAW_INBOX =
    "https://raw.githubusercontent.com/" .. requests.REPO .. "/main/INBOX.md"
requests.API_INBOX =
    "https://api.github.com/repos/" .. requests.REPO .. "/contents/INBOX.md"
requests.FILE = "requests.json"

local HTTP_TIMEOUT = 30
local SEPARATOR = "---"

local D = {}                 -- injected deps { kernel, store, bus, events, config }
local pending = {}           -- url -> { cbs = {cb, ...}, timer }
local handlers = {}          -- kernel handles from the last wire()
local S = { sending = false, refreshing = false }
local records = nil          -- lazy-loaded list of sent requests

-- -- base64 (pure arithmetic: CC is Lua 5.1 + bit32, the test harness is
-- 5.3 without it -- the same split that made the updater pick Adler-32) ----
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64REV = {}
for i = 1, 64 do B64REV[B64:sub(i, i)] = i - 1 end

function requests.b64encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=")
            .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

-- GitHub wraps its base64 in newlines; strip everything outside the alphabet
-- (a bad char decoded as 0 would silently corrupt the file we then PUT back).
function requests.b64decode(s)
    s = tostring(s or ""):gsub("[^%a%d+/=]", "")
    local out = {}
    for i = 1, #s, 4 do
        local c1, c2 = s:sub(i, i), s:sub(i + 1, i + 1)
        local c3, c4 = s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
        local n = (B64REV[c1] or 0) * 262144 + (B64REV[c2] or 0) * 4096
                + (B64REV[c3] or 0) * 64 + (B64REV[c4] or 0)
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
        if c3 ~= "=" and c3 ~= "" then
            out[#out + 1] = string.char(math.floor(n / 256) % 256)
        end
        if c4 ~= "=" and c4 ~= "" then
            out[#out + 1] = string.char(n % 256)
        end
    end
    return table.concat(out)
end

-- -- async fetch (updater.lua's cbs-list pattern: dedup the REQUEST, never
-- drop a duplicate caller's CALLBACK) -------------------------------------
local function dispatch_cbs(cbs, ...)
    for _, cb in ipairs(cbs) do
        local ok, err = pcall(cb, ...)
        if not ok then
            local msg = "requests: fetch callback error: " .. tostring(err)
            if D.events then D.events.log("warn", "requests", msg)
            else print(msg) end
        end
    end
end

local function wire()
    for _, h in ipairs(handlers) do pcall(h.cancel) end
    handlers = {}
    handlers[#handlers + 1] = D.kernel.on_event("http_success", function(url, handle)
        local p = pending[url]
        if not p then
            -- late arrival after our timeout resolved the callers: the handle
            -- is still a live CC resource that counts against the connection
            -- limit until closed
            if handle and handle.close then pcall(handle.close) end
            return
        end
        pending[url] = nil
        p.timer.cancel()
        local body = ""
        if handle then
            body = handle.readAll() or ""
            if handle.close then handle.close() end
        end
        dispatch_cbs(p.cbs, body, nil)
    end)
    handlers[#handlers + 1] = D.kernel.on_event("http_failure", function(url, reason, handle)
        -- a non-2xx response passes a live handle here too; close on every path
        local detail = nil
        if handle then
            if handle.readAll then
                local ok, b = pcall(handle.readAll)
                if ok then detail = b end
            end
            if handle.close then pcall(handle.close) end
        end
        local p = pending[url]
        if not p then return end
        pending[url] = nil
        p.timer.cancel()
        local msg = tostring(reason or "request failed")
        dispatch_cbs(p.cbs, nil, msg, detail)
    end)
end

-- One helper for both the anonymous raw GET (opts = nil) and the
-- authenticated API GET/PUT (opts = { method, headers, body }). Correlation
-- is by URL -- fine here because the API GET and PUT to the same URL are
-- strictly sequential inside submit().
local function fetch(url, opts, cb)
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
    local arg = url
    if opts then
        arg = { url = url, method = opts.method,
                headers = opts.headers, body = opts.body }
    end
    local ok = pcall(http.request, arg)
    if not ok then
        pending[url] = nil; timer.cancel()
        cb(nil, "http disabled")
    end
end

requests.fetch = fetch   -- exposed for tests

-- -- init -----------------------------------------------------------------
---@param deps table { kernel, store, bus?, events?, config }
function requests.init(deps)
    D = deps
    pending = {}
    S = { sending = false, refreshing = false }
    records = nil
    wire()
    return requests
end

function requests.has_token()
    local t = D.config and D.config.requests_token
    return type(t) == "string" and t ~= ""
end

-- -- local record store ---------------------------------------------------
local function load_records()
    if not records then
        local data = D.store.load(requests.FILE, { sent = {} })
        records = type(data.sent) == "table" and data.sent or {}
    end
    return records
end

local function save_records()
    D.store.save(requests.FILE, { sent = records })
end

---@return table[] sent requests, oldest first: { title, body, at, status, id?, version? }
function requests.list()
    return load_records()
end

-- -- INBOX.md text manipulation (mirror of tools/agent/inbox.js) ----------
-- The separator is the LAST `---` line: receipt lines never contain one, so
-- a `---` typed inside a request body stays body instead of truncating the
-- file (same rule as the agent's parser -- the two must agree or a request
-- could land below the rule and silently become a receipt).
local function split_lines(text)
    local lines = {}
    for line in (tostring(text) .. "\n"):gmatch("(.-)\r?\n") do
        table.insert(lines, line)
    end
    return lines
end

local function last_separator(lines)
    -- trim, don't collapse: "- - -" must NOT read as a separator
    local at = nil
    for i, l in ipairs(lines) do
        if l:match("^%s*(.-)%s*$") == SEPARATOR then at = i end
    end
    return at
end

---@return table pending set of titles still above the rule, table receipts list
function requests.parse_inbox(text)
    local lines = split_lines(text)
    local sep = last_separator(lines)
    local pending_titles, receipts = {}, {}
    local top = sep and (sep - 1) or #lines
    for i = 1, top do
        local t = lines[i]:match("^##%s+(.-)%s*$")
        if t then pending_titles[t] = true end
    end
    if sep then
        for i = sep + 1, #lines do
            local line = lines[i]
            local title = line:match("^%s*~~(.-)~~")
            if title then
                local id = tonumber(line:match("#(%d+)"))
                local after = line:match("#%d+%s*(.*)$") or ""
                local status = after:match("([%a_]+)")
                local version = after:match("v([%d%.]+)")
                if id and status then
                    table.insert(receipts,
                        { title = title, id = id, status = status, version = version })
                end
            end
        end
    end
    return pending_titles, receipts
end

-- A title must survive the round trip through the agent's parser AND its
-- receipt regex: one line, no leading #'s (they would change the heading
-- level), no `~~` (the receipt delimiter).
function requests.clean_title(title)
    return tostring(title or "")
        :gsub("[\r\n]", " ")
        :gsub("~~", "")
        :gsub("^%s*#+%s*", "")
        :gsub("^%s+", ""):gsub("%s+$", "")
end

local function clean_body(body)
    local b = tostring(body or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    return b:gsub("^%s+", ""):gsub("%s+$", "")
end

---@return string new inbox text with the block inserted above the last `---`
function requests.insert_block(text, title, body)
    local lines = split_lines(text)
    local sep = last_separator(lines)
    local block = { "## " .. title }
    if body ~= "" then
        for _, l in ipairs(split_lines(body)) do table.insert(block, l) end
    end
    table.insert(block, "")
    if sep then
        -- keep one blank line between the previous content and our block
        if sep > 1 and lines[sep - 1]:match("%S") then
            table.insert(block, 1, "")
        end
        for i = #block, 1, -1 do table.insert(lines, sep, block[i]) end
    else
        -- malformed inbox with no rule at all: append; the agent treats the
        -- whole file as requests in that case, so the block is still found
        if #lines > 0 and lines[#lines]:match("%S") then table.insert(lines, "") end
        for _, l in ipairs(block) do table.insert(lines, l) end
    end
    return table.concat(lines, "\n")
end

-- -- submit ---------------------------------------------------------------
local function api_headers(extra)
    local h = {
        ["Authorization"] = "token " .. tostring(D.config.requests_token),
        ["Accept"] = "application/vnd.github+json",
    }
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
end

---@param title string
---@param body string
---@param cb fun(ok:boolean, err:string|nil)
function requests.submit(title, body, cb)
    cb = cb or function() end
    title = requests.clean_title(title)
    body = clean_body(body)
    if title == "" then return cb(false, "title is required") end
    if not requests.has_token() then return cb(false, "no github token set") end
    if S.sending then return cb(false, "a request is already sending") end
    S.sending = true
    local function done(ok, err)
        S.sending = false
        cb(ok, err)
    end

    -- sign the block so the receipt is attributable in a shared inbox
    local label = tostring((D.config and D.config.label) or "panel")
    local signed = body
    local sig = "-- " .. label .. " (from the panel)"
    signed = (signed == "") and sig or (signed .. "\n" .. sig)

    fetch(requests.API_INBOX, { headers = api_headers() }, function(resp, err)
        if err then return done(false, "inbox fetch failed: " .. err) end
        local ok, meta = pcall(textutils.unserialiseJSON, resp)
        if not ok or type(meta) ~= "table"
            or type(meta.content) ~= "string" or type(meta.sha) ~= "string" then
            return done(false, "unexpected github response")
        end
        local text = requests.b64decode(meta.content)
        local updated = requests.insert_block(text, title, signed)
        local put_body = textutils.serialiseJSON({
            message = "request: " .. title .. " (via " .. label .. ")",
            content = requests.b64encode(updated),
            sha = meta.sha,
        })
        fetch(requests.API_INBOX, {
            method = "PUT",
            headers = api_headers({ ["Content-Type"] = "application/json" }),
            body = put_body,
        }, function(_, perr)
            if perr then
                -- a stale sha (someone edited between our GET and PUT) lands
                -- here; a fresh Send re-GETs, so retrying is safe
                return done(false, "send failed: " .. perr)
            end
            load_records()
            table.insert(records, {
                title = title, body = body, status = "sent",
                at = (os.epoch and os.epoch("utc")) or 0,
            })
            save_records()
            if D.events then
                D.events.log("info", "requests", "feature request sent: " .. title)
            end
            done(true)
        end)
    end)
end

-- -- refresh --------------------------------------------------------------
-- Resolve every local record against the live inbox. Receipts are claimed
-- one-per-record in order so two same-titled requests map to two receipts
-- rather than both grabbing the first.
---@param cb fun(ok:boolean, err:string|nil)
function requests.refresh(cb)
    cb = cb or function() end
    if S.refreshing then return cb(false, "already refreshing") end
    S.refreshing = true
    fetch(requests.RAW_INBOX, nil, function(text, err)
        S.refreshing = false
        if err then return cb(false, "inbox unavailable: " .. err) end
        local pending_titles, receipts = requests.parse_inbox(text)
        local claimed = {}
        load_records()
        for _, rec in ipairs(records) do
            if pending_titles[rec.title] then
                rec.status = "waiting"
            else
                local hit = nil
                for i, r in ipairs(receipts) do
                    if not claimed[i] and r.title == rec.title then
                        hit = r; claimed[i] = true; break
                    end
                end
                if hit then
                    rec.status = hit.status
                    rec.id = hit.id
                    rec.version = hit.version or rec.version
                elseif rec.id then
                    -- we saw a receipt for it before and it is gone now: the
                    -- sweep only ever removes SHIPPED receipts
                    rec.status = "shipped"
                end
            end
        end
        save_records()
        cb(true)
    end)
end

return requests
