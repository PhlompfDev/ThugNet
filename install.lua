-- ThugNet installer -- one-shot bootstrap for a fresh CC:Tweaked computer.
--
-- Run it straight off the public mirror; nothing needs to be on disk first:
--
--   wget run https://raw.githubusercontent.com/PhlompfDev/ThugNet/main/install.lua
--
-- It fetches manifest.json from the mirror and downloads every file the
-- manifest lists into place, verifying each file's byte length and Adler-32
-- checksum -- the SAME verification thugnet/core/updater.lua runs when a node
-- self-updates. Nothing here requires anything from thugnet/, because on a
-- bare computer none of it exists yet: the installer is deliberately
-- standalone, and the Adler-32 below is a byte-for-byte copy of
-- thugnet/core/checksum.lua so a file that verifies here verifies there.
--
-- Re-running it on an existing node is a safe repair: it only ever writes the
-- code files the manifest names. Runtime state (config.json, state.json, ...)
-- is never listed in a manifest, so a node's identity and settings are left
-- untouched. To UPDATE a running node, use Settings > Updates instead -- that
-- path stages, verifies, and rolls back atomically; this one is for a bare
-- computer or a wiped install.

local BASE = "https://raw.githubusercontent.com/PhlompfDev/ThugNet/main/"
local MAX_ATTEMPTS = 3   -- per-fetch tries before giving up

if type(http) ~= "table" then
    printError("ThugNet install: the HTTP API is disabled on this computer.")
    printError("Enable it in CC:Tweaked's config (http.enabled), then retry.")
    return
end

-- Adler-32 -- identical to thugnet/core/checksum.lua (see its header for why
-- Adler and not CRC32: pure modular addition works the same in CC's Lua 5.1
-- and the test harness's 5.3). Returns b * 65536 + a.
local function checksum(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

-- The same rule as updater.is_protected / publish.js isProtected: a root-level
-- .json is runtime state and must never be written by an installer. The mirror
-- manifest never lists one, but guard anyway against a malformed manifest.
local function is_protected(path)
    return path:match("^[^/]+%.json$") ~= nil and path ~= "manifest.json"
end

-- Blocking GET with bounded retry+backoff. Blocking is fine here: this is a
-- one-shot script, not the node's single-loop kernel, so there is no rednet or
-- UI to stall. Backoff also rides out a brief CDN rate-limit on the burst.
local function get(url)
    local err
    for attempt = 1, MAX_ATTEMPTS do
        local h, e = http.get(url)
        if h then
            local body = h.readAll() or ""
            h.close()
            return body
        end
        err = e or "request failed"
        if attempt < MAX_ATTEMPTS then sleep(attempt) end
    end
    return nil, err
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

term.clear()
term.setCursorPos(1, 1)
print("ThugNet installer")
print("Fetching manifest ...")

local raw, err = get(BASE .. "manifest.json")
if not raw then
    printError("Could not fetch the manifest: " .. tostring(err))
    return
end

local manifest = textutils.unserialiseJSON(raw)
if type(manifest) ~= "table" or type(manifest.files) ~= "table"
    or type(manifest.version) ~= "string" then
    printError("The manifest is unreadable. Try again in a minute.")
    return
end

local files = manifest.files
print(("Installing ThugNet v%s -- %d files"):format(manifest.version, #files))
print("")

-- The download rewrites ONE status line in place rather than scrolling 100+
-- lines off the top; remember where it lives so each file can overwrite it.
local _, status_y = term.getCursorPos()

for i, f in ipairs(files) do
    if type(f.p) ~= "string" or is_protected(f.p) then
        print("")
        printError("Refusing a bad manifest entry: " .. tostring(f.p))
        return
    end

    term.setCursorPos(1, status_y)
    term.clearLine()
    term.write(("%3d/%d  %s"):format(i, #files, f.p))

    local body, gerr = get(BASE .. f.p)
    if not body then
        print("")
        printError(("Download failed for %s: %s"):format(f.p, tostring(gerr)))
        return
    elseif #body ~= f.n then
        print("")
        printError(("%s: wrong size (got %d, want %d)"):format(f.p, #body, f.n))
        return
    elseif checksum(body) ~= f.c then
        print("")
        printError(f.p .. ": checksum mismatch -- try again in a minute.")
        return
    elseif not write_file(f.p, body) then
        print("")
        printError("Could not write " .. f.p .. " (out of disk space?)")
        return
    end

    sleep(0.15)   -- gentle pacing so the CDN doesn't rate-limit the burst
end

-- Seed installed_manifest.json so the FIRST self-update knows exactly which
-- files to back up and which retired files to prune. updater.apply() writes
-- this same file after every update; seeding it here makes update #1 behave
-- like update #2 instead of falling back to "assume the new list == old list".
write_file("installed_manifest.json",
    textutils.serialiseJSON({ version = manifest.version, files = files }))

term.setCursorPos(1, status_y)
term.clearLine()
print(("Installed ThugNet v%s (%d files)."):format(manifest.version, #files))
print("Rebooting into the setup wizard ...")
sleep(2)
os.reboot()
