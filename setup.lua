-- Re-run the ThugNet setup wizard deliberately (a first boot runs it
-- automatically when config.json is absent or invalid). Chains into startup
-- once a configuration is saved.
local base = fs.getDir(shell.getRunningProgram())
package.path = package.path .. string.format(";%s/?.lua;%s/?/?.lua;%s/?/?/?.lua", base, base, base)

local setup = require("thugnet.setup")
setup.provision()
-- absolute path: shell.execute resolves relative to the shell's CURRENT
-- directory, so running /setup while cd'd elsewhere would silently not chain
shell.execute("/" .. fs.combine(base, "startup.lua"))
