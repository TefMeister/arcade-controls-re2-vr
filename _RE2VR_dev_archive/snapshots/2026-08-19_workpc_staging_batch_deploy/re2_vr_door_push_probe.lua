-- re2_vr_door_push_probe.lua
--
-- Diagnostic for the "push doors open with your hands" feature. The plan does NOT
-- need real hand/door collision: detect a hand near the door + a forward push
-- gesture (controller position/velocity, proven in re2_vr_grenade.lua /
-- VRControllerManager), then fire the game's own door-open path. Before building
-- that, this probe answers, empirically:
--   1. Do the door/interact singletons exist, and what API do they expose?
--      (app.ropeway.GimmickDoorManager, app.ropeway.gimmick.action.InteractManager,
--      per-door app.ropeway.GimmickDoorController -- names from the community
--      RE2-RT RSZ class dump, alphazolam/RE_RSZ, not guessed.)
--   2. Which methods fire when a door is opened NORMALLY? (log-only auto-hooks;
--      walk up to a door, open it the vanilla way, read the log.)
--   3. Where are the doors, and can we measure hand-to-door distance?
--      ("Snapshot nearby doors" button: per-door GameObject name, position,
--      distance to player and to each hand joint.)
--
-- Read-only apart from log-only hooks (no SKIP_ORIGINAL, no writes). Safe to
-- leave enabled.
--
-- Usage: reset scripts, load into gameplay, click "Dump door/interact API" once,
-- then walk to a door, click "Snapshot nearby doors", open the door normally,
-- and check re2_framework_log.txt for [door_probe] lines.

local RE2 = require("utility/RE2")

local log_prefix = "[door_probe]"

local function log_line(msg)
    log.info(log_prefix .. " " .. msg)
end

local TYPES = {
    door_manager    = "app.ropeway.GimmickDoorManager",
    door_controller = "app.ropeway.GimmickDoorController",
    interact_mgr    = "app.ropeway.gimmick.action.InteractManager",
    interact        = "app.ropeway.gimmick.action.Interact",
}

--------------------------------------------------------------------------------
-- 1) API dumps (methods matching interesting keywords + ALL fields)
--------------------------------------------------------------------------------
local METHOD_KEYWORDS = {
    "open", "close", "start", "request", "exec", "state", "unlock",
    "door", "interact", "push", "action", "set", "notify",
}

local function dump_type_api(type_name)
    local td = sdk.find_type_definition(type_name)
    if td == nil then
        log_line("TYPE NOT FOUND: " .. type_name)
        return
    end

    log_line("======================================== ")
    log_line(type_name .. " -- fields:")
    local ok_f, fields = pcall(function() return td:get_fields() end)
    if ok_f and fields then
        for _, f in ipairs(fields) do
            local ok_n, fname = pcall(function() return f:get_name() end)
            local ok_t, ftype = pcall(function() return f:get_type():get_full_name() end)
            if ok_n and fname then
                log_line("  field: " .. fname .. " : " .. tostring(ok_t and ftype or "?"))
            end
        end
    end

    log_line(type_name .. " -- methods matching keywords:")
    local ok_m, methods = pcall(function() return td:get_methods() end)
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            if ok_n and mname then
                local l = mname:lower()
                for _, kw in ipairs(METHOD_KEYWORDS) do
                    if l:find(kw, 1, true) ~= nil then
                        local ok_p, np = pcall(function() return m:get_num_params() end)
                        log_line("  method: " .. mname .. " (params: " .. tostring(ok_p and np or "?") .. ")")
                        break
                    end
                end
            end
        end
    end
    log_line("======================================== ")
end

local function dump_all_apis()
    for _, tname in pairs(TYPES) do
        dump_type_api(tname)
    end
    for _, singleton_name in ipairs({ TYPES.door_manager, TYPES.interact_mgr }) do
        local ok, s = pcall(function() return sdk.get_managed_singleton(singleton_name) end)
        log_line("singleton " .. singleton_name .. ": " .. ((ok and s ~= nil) and "FOUND" or "not found"))
    end
end

--------------------------------------------------------------------------------
-- 2) Log-only auto-hooks: what fires when a door opens normally?
--------------------------------------------------------------------------------
local HOOK_TARGETS = {
    { type_name = TYPES.door_controller, patterns = { "open", "close", "start", "request", "exec", "changestate", "setstate", "unlock", "push" } },
    { type_name = TYPES.interact_mgr,    patterns = { "exec", "invoke", "request", "start", "notify", "interact" } },
}
local MAX_LOGS_PER_METHOD = 8
local hook_counts = {}
local hooks_installed = false

local function install_hooks()
    if hooks_installed then return end
    hooks_installed = true

    for _, target in ipairs(HOOK_TARGETS) do
        local td = sdk.find_type_definition(target.type_name)
        if td ~= nil then
            local hooked = 0
            local ok_m, methods = pcall(function() return td:get_methods() end)
            if ok_m and methods then
                for _, m in ipairs(methods) do
                    local ok_n, mname = pcall(function() return m:get_name() end)
                    if ok_n and mname and mname:sub(1, 4) ~= "get_" then
                        local l = mname:lower()
                        local want = false
                        for _, pat in ipairs(target.patterns) do
                            if l:find(pat, 1, true) ~= nil then want = true break end
                        end
                        if want then
                            local key = target.type_name .. "." .. mname
                            local ok_h = pcall(function()
                                sdk.hook(m,
                                    function(args)
                                        local c = (hook_counts[key] or 0) + 1
                                        hook_counts[key] = c
                                        if c <= MAX_LOGS_PER_METHOD then
                                            log_line(string.format("*** %s CALLED (#%d, os.clock=%.3f)", key, c, os.clock()))
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
            log_line("installed " .. hooked .. " log-only hooks on " .. target.type_name)
        else
            log_line("cannot hook, type not found: " .. target.type_name)
        end
    end
end

--------------------------------------------------------------------------------
-- 3) Nearby-door snapshot: positions + player/hand distances
--------------------------------------------------------------------------------
local HAND_JOINT_CANDIDATES = {
    left  = { "l_hand", "l_arm_wrist", "l_wrist", "L_Hand" },
    right = { "r_hand", "r_arm_wrist", "r_wrist", "R_Hand" },
}

local function get_player_joint_pos(player, candidates)
    local ok_tf, tf = pcall(function() return player:call("get_Transform") end)
    if not ok_tf or tf == nil then return nil, nil end
    for _, name in ipairs(candidates) do
        local ok_j, joint = pcall(function() return tf:call("getJointByName(System.String)", name) end)
        if ok_j and joint ~= nil then
            local ok_p, pos = pcall(function() return joint:call("get_Position") end)
            if ok_p and pos ~= nil then return pos, name end
        end
    end
    return nil, nil
end

local function fmt_vec(v)
    if v == nil then return "?" end
    local ok, s = pcall(function() return string.format("(%.2f, %.2f, %.2f)", v.x, v.y, v.z) end)
    return ok and s or "?"
end

local function dist(a, b)
    if a == nil or b == nil then return nil end
    local ok, d = pcall(function() return (a - b):length() end)
    return ok and d or nil
end

local last_snapshot_lines = {}

local function snapshot_nearby_doors()
    last_snapshot_lines = {}
    local function out(msg)
        log_line(msg)
        table.insert(last_snapshot_lines, msg)
    end

    local door_type = sdk.typeof(TYPES.door_controller)
    if door_type == nil then
        out("sdk.typeof failed for " .. TYPES.door_controller)
        return
    end

    local scene = nil
    local ok_s = pcall(function()
        local scene_manager = sdk.get_native_singleton("via.SceneManager")
        scene = sdk.call_native_func(scene_manager, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    end)
    if not ok_s or scene == nil then
        out("could not get current scene")
        return
    end

    local doors = nil
    local ok_f = pcall(function()
        doors = scene:call("findComponents(System.Type)", door_type)
    end)
    if not ok_f or doors == nil then
        out("findComponents(GimmickDoorController) failed")
        return
    end

    local elems = nil
    pcall(function() elems = doors:get_elements() end)
    if elems == nil then
        out("findComponents returned no readable array")
        return
    end

    local player = RE2.get_localplayer()
    local player_pos = nil
    if player ~= nil then
        pcall(function() player_pos = player:call("get_Transform"):call("get_Position") end)
    end
    local l_pos, l_joint = nil, nil
    local r_pos, r_joint = nil, nil
    if player ~= nil then
        l_pos, l_joint = get_player_joint_pos(player, HAND_JOINT_CANDIDATES.left)
        r_pos, r_joint = get_player_joint_pos(player, HAND_JOINT_CANDIDATES.right)
    end
    out(string.format("player pos=%s  l_hand[%s]=%s  r_hand[%s]=%s",
        fmt_vec(player_pos), tostring(l_joint), fmt_vec(l_pos), tostring(r_joint), fmt_vec(r_pos)))

    -- Sort-free pass: log every door within 10 m of the player (or all doors if
    -- the player position is unknown), nearest info inline.
    local total, near = 0, 0
    for _, door in ipairs(elems) do
        total = total + 1
        local go_name, door_pos = "?", nil
        pcall(function()
            local go = door:call("get_GameObject")
            go_name = go:call("get_Name")
            door_pos = go:call("get_Transform"):call("get_Position")
        end)

        local d_player = dist(player_pos, door_pos)
        if d_player == nil or d_player < 10.0 then
            near = near + 1
            out(string.format("  door go=%s pos=%s  d(player)=%.2f  d(l_hand)=%s  d(r_hand)=%s",
                tostring(go_name), fmt_vec(door_pos), d_player or -1,
                tostring(dist(l_pos, door_pos)), tostring(dist(r_pos, door_pos))))

            -- Try a few likely state getters so we learn how to read door state.
            for _, getter in ipairs({ "get_CurrentState", "get_State", "getCurrentStateName", "get_IsOpen", "get_IsOpened" }) do
                local ok_g, v = pcall(function() return door:call(getter) end)
                if ok_g and v ~= nil then
                    out("      " .. getter .. " = " .. tostring(v))
                end
            end
        end
    end
    out("doors found in scene: " .. total .. " (within 10 m: " .. near .. ")")
end

--------------------------------------------------------------------------------
-- Driver + UI
--------------------------------------------------------------------------------
local dumped = false

re.on_frame(function()
    install_hooks()
end)

re.on_draw_ui(function()
    if not imgui.tree_node("Door Push Probe (diagnostic)") then return end

    imgui.text("Step 1: click 'Dump door/interact API' once (writes to log).")
    imgui.text("Step 2: walk to a door, click 'Snapshot nearby doors'.")
    imgui.text("Step 3: open the door NORMALLY -- the hooks log what fires.")
    imgui.text("Then send back the [door_probe] lines from re2_framework_log.txt.")

    if imgui.button("Dump door/interact API") then
        dumped = true
        local ok, err = pcall(dump_all_apis)
        if not ok then log_line("dump crashed: " .. tostring(err)) end
    end

    if imgui.button("Snapshot nearby doors") then
        local ok, err = pcall(snapshot_nearby_doors)
        if not ok then log_line("snapshot crashed: " .. tostring(err)) end
    end

    if #last_snapshot_lines > 0 and imgui.tree_node("Last snapshot") then
        for _, line in ipairs(last_snapshot_lines) do
            imgui.text(line)
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

log_line("loaded")
