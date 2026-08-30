-- re2_vr_enemy_spawn_probe.lua
--
-- Diagnostic for the planned "replace every dog with a zombie" feature
-- (cutscene dog excluded). The plan: find the native call that creates an
-- enemy WITH its kind/type still a parameter, then rewrite dog -> zombie in
-- a pre-hook before the dog ever exists. Community swap mods prove the swap
-- is viable (ModDB "all zombies" mod replaces dogs/Ivy/Mr.X with zombies),
-- but they are pak/asset-based and pre-RT-build; we want a runtime swap that
-- survives game updates. Before building that, this probe answers:
--   1. Does an enemy-manager singleton exist, and what is its API?
--      (Candidate names tried empirically; "Dump enemy manager API" logs all
--      fields + all methods with param counts.)
--   2. Which manager method fires when an enemy actually spawns, and what
--      are its arguments? (Log-only auto-hooks on create/spawn/generate-ish
--      methods, logging each arg's managed type or integer value -- an int
--      arg that reads 4000 on a dog spawn is exactly the rewrite point.)
--   3. What identifies a dog at the data level? (Use the Tyrant State
--      Probe's "Dump fields" button on a DOG-flagged enemy for this --
--      look for Kind/KindID-ish fields reading 4000.)
--
-- Read-only (no SKIP_ORIGINAL, no writes). Safe to leave enabled.
--
-- Usage: reset scripts, click "Dump enemy manager API" once, then play into
-- an area where dogs spawn (kennel / west streets) and let them appear.
-- Timestamps here correlate with the tyrant probe's "NEW ENEMY ... << DOG"
-- lines. Send back the [spawn_probe] lines from re2_framework_log.txt.

local log_prefix = "[spawn_probe]"

local function log_line(msg)
    log.info(log_prefix .. " " .. msg)
end

--------------------------------------------------------------------------------
-- 1) Find the enemy manager (candidate names, resolved empirically)
--------------------------------------------------------------------------------
local MANAGER_CANDIDATES = {
    "app.ropeway.EnemyManager",
    "app.ropeway.enemy.EnemyManager",
    "app.ropeway.gamemastering.EnemyManager",
    "app.ropeway.EmManager",
}

local manager_type_name = nil

local function resolve_manager()
    if manager_type_name ~= nil then return end
    for _, name in ipairs(MANAGER_CANDIDATES) do
        if sdk.find_type_definition(name) ~= nil then
            manager_type_name = name
            local ok, s = pcall(function() return sdk.get_managed_singleton(name) end)
            log_line("manager type FOUND: " .. name .. " (singleton instance: "
                .. ((ok and s ~= nil) and "yes" or "no") .. ")")
            return
        end
    end
end

--------------------------------------------------------------------------------
-- 2) Full API dump (all fields, ALL methods -- this is a one-shot, so no
--    keyword filter; the spawn/creation API may not have a guessable name)
--------------------------------------------------------------------------------
local function dump_manager_api()
    resolve_manager()
    if manager_type_name == nil then
        log_line("NO manager type found among candidates:")
        for _, name in ipairs(MANAGER_CANDIDATES) do log_line("  tried: " .. name) end
        return
    end
    local td = sdk.find_type_definition(manager_type_name)
    log_line("======== API DUMP " .. manager_type_name .. " ========")
    while td ~= nil do
        pcall(function()
            local fields = td:get_fields()
            for _, f in ipairs(fields) do
                pcall(function()
                    log_line("  field: " .. td:get_name() .. "." .. f:get_name()
                        .. " : " .. f:get_type():get_full_name())
                end)
            end
        end)
        pcall(function()
            local methods = td:get_methods()
            for _, m in ipairs(methods) do
                pcall(function()
                    log_line("  method: " .. td:get_name() .. "." .. m:get_name()
                        .. " (params: " .. tostring(m:get_num_params()) .. ")")
                end)
            end
        end)
        local parent = nil
        pcall(function() parent = td:get_parent_type() end)
        td = parent
        if td ~= nil and td:get_full_name():find("^via%.") ~= nil then td = nil end
    end
    log_line("======== END API DUMP ========")
end

--------------------------------------------------------------------------------
-- 3) Log-only auto-hooks on creation-ish manager methods, with arg decoding
--------------------------------------------------------------------------------
local HOOK_PATTERNS = {
    "create", "spawn", "generat", "instantiat", "entry", "regist", "setup",
    "request", "add", "born", "appear",
}
local MAX_LOGS_PER_METHOD = 10
local hook_counts = {}
local hooks_installed = false

local function describe_arg(arg)
    -- Try managed object first, then fall back to raw integer.
    local desc = nil
    pcall(function()
        local obj = sdk.to_managed_object(arg)
        if obj ~= nil then
            local tn = obj:get_type_definition():get_full_name()
            desc = "<" .. tn .. ">"
            -- GameObjects and strings are worth naming outright.
            if tn == "via.GameObject" then
                pcall(function() desc = desc .. " name=" .. obj:call("get_Name") end)
            elseif tn == "System.String" then
                pcall(function() desc = "\"" .. tostring(sdk.to_managed_string(arg)) .. "\"" end)
            end
        end
    end)
    if desc == nil then
        pcall(function() desc = "int:" .. tostring(sdk.to_int64(arg)) end)
    end
    return desc or "?"
end

local function install_hooks()
    if hooks_installed then return end
    resolve_manager()
    if manager_type_name == nil then return end
    hooks_installed = true

    local td = sdk.find_type_definition(manager_type_name)
    local hooked = 0
    local ok_m, methods = pcall(function() return td:get_methods() end)
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            local ok_p, np = pcall(function() return m:get_num_params() end)
            if ok_n and mname and ok_p and mname:sub(1, 4) ~= "get_" then
                local l = mname:lower()
                local want = false
                for _, pat in ipairs(HOOK_PATTERNS) do
                    if l:find(pat, 1, true) ~= nil then want = true break end
                end
                if want then
                    local key = mname
                    local num_params = np
                    local ok_h = pcall(function()
                        sdk.hook(m,
                            function(args)
                                local c = (hook_counts[key] or 0) + 1
                                hook_counts[key] = c
                                if c <= MAX_LOGS_PER_METHOD then
                                    local parts = {}
                                    for i = 1, num_params do
                                        -- args[1]=thread, args[2]=this, args[3+]=params
                                        table.insert(parts, describe_arg(args[2 + i]))
                                    end
                                    log_line(string.format("*** %s.%s(%s) (#%d, os.clock=%.3f)",
                                        manager_type_name, key, table.concat(parts, ", "), c, os.clock()))
                                    if c == MAX_LOGS_PER_METHOD then
                                        log_line("    (further " .. key .. " calls suppressed)")
                                    end
                                end
                            end,
                            nil)
                    end)
                    if ok_h then hooked = hooked + 1 end
                end
            end
        end
    end
    log_line("installed " .. hooked .. " log-only creation hooks on " .. manager_type_name)
end

--------------------------------------------------------------------------------
-- Driver + UI
--------------------------------------------------------------------------------
re.on_frame(function()
    install_hooks()
end)

re.on_draw_ui(function()
    if not imgui.tree_node("Enemy Spawn Probe (diagnostic)") then return end

    imgui.text("Feeds the dogs -> zombies swap feature.")
    imgui.text("1. Click 'Dump enemy manager API' once (writes to log).")
    imgui.text("2. Play into a dog area (kennel / streets), let dogs spawn.")
    imgui.text("3. On a DOG-flagged enemy in the Tyrant State Probe panel,")
    imgui.text("   click 'Dump fields' (look for Kind-ish fields = 4000).")
    imgui.text("Log prefix: [spawn_probe] in re2_framework_log.txt")
    imgui.spacing()

    if imgui.button("Dump enemy manager API") then
        local ok, err = pcall(dump_manager_api)
        if not ok then log_line("dump crashed: " .. tostring(err)) end
    end

    imgui.text("manager: " .. tostring(manager_type_name or "not found yet"))
    imgui.text("hooks installed: " .. tostring(hooks_installed))

    imgui.tree_pop()
end)

log_line("loaded")
