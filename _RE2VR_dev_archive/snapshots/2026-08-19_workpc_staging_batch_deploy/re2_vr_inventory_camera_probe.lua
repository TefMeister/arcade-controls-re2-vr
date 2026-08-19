-- re2_vr_inventory_camera_probe.lua
--
-- Diagnostic for the "keep first person during inventory/map" goal. The menu
-- screens switch to a 3rd-person camera; before we can suppress or freeze that,
-- we need to know WHAT moves the camera. This probe answers, empirically:
--   1. What does CameraSystem.get_BusyCameraType report while inventory/map/item
--      box are open? (EVENT=cutscene is known; the menu value is not.)
--   2. Which CameraSystem methods fire at the moment a menu opens/closes?
--   3. What happens to the primary camera (position/FOV/GameObject) across the
--      transition -- is it the same camera being moved, or a camera swap?
--
-- Passive/read-only apart from the method hooks (log-only, no SKIP_ORIGINAL,
-- same auto-hook pattern as re2_vr_inventory_open_hook_probe /
-- re2_vr_slot_exchange_probe). Safe to leave enabled; logs only around menu
-- transitions plus first-N-calls per hooked method.
--
-- Usage: reset scripts, then open + close the INVENTORY, the MAP, and the ITEM
-- BOX (item box is the reference: it's the behavior we like). Then read
-- re2_framework_log.txt for [inv_cam_probe] lines.

local log_prefix = "[inv_cam_probe]"

local function log_line(msg)
    log.info(log_prefix .. " " .. msg)
end

--------------------------------------------------------------------------------
-- 1) One-time method-list dump of CameraSystem (names + param counts), so the
--    follow-up session has the full API surface without re-dumping.
--------------------------------------------------------------------------------
local CAMERA_SYSTEM_TYPE = "app.ropeway.camera.CameraSystem"
local dumped_methods = false

local function dump_camera_system_methods()
    if dumped_methods then return end
    dumped_methods = true

    local td = sdk.find_type_definition(CAMERA_SYSTEM_TYPE)
    if not td then
        log_line("CameraSystem type definition NOT FOUND: " .. CAMERA_SYSTEM_TYPE)
        return
    end

    log_line("======================================== ")
    log_line(CAMERA_SYSTEM_TYPE .. ": full method list")
    local ok_m, methods = pcall(function() return td:get_methods() end)
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            local ok_p, np = pcall(function() return m:get_num_params() end)
            if ok_n and mname then
                log_line("  " .. mname .. " (params: " .. tostring(ok_p and np or "?") .. ")")
            end
        end
    end
    log_line("======================================== ")
end

--------------------------------------------------------------------------------
-- 2) Auto-hook CameraSystem methods that look like camera switching/requesting.
--    Log-only, capped per method so per-frame methods can't flood the log.
--------------------------------------------------------------------------------
local HOOK_NAME_PATTERNS = {
    "request", "change", "switch", "activate", "deactivate",
    "push", "pop", "start", "end", "begin", "finish", "set_Busy",
}
local MAX_LOGS_PER_METHOD = 8
local hook_counts = {}
local hooks_installed = false

local function install_hooks()
    if hooks_installed then return end
    hooks_installed = true

    local td = sdk.find_type_definition(CAMERA_SYSTEM_TYPE)
    if not td then return end

    local ok_m, methods = pcall(function() return td:get_methods() end)
    if not ok_m or methods == nil then return end

    local hooked = 0
    for _, m in ipairs(methods) do
        local ok_n, mname = pcall(function() return m:get_name() end)
        if ok_n and mname then
            local l = mname:lower()
            local want = false
            for _, pat in ipairs(HOOK_NAME_PATTERNS) do
                if l:find(pat:lower(), 1, true) ~= nil then want = true break end
            end
            -- Skip pure getters -- we want the mutating/trigger calls.
            if want and l:sub(1, 4) ~= "get_" then
                local this_name = mname
                local ok_h = pcall(function()
                    sdk.hook(m,
                        function(args)
                            local c = (hook_counts[this_name] or 0) + 1
                            hook_counts[this_name] = c
                            if c <= MAX_LOGS_PER_METHOD then
                                log_line(string.format("*** CameraSystem.%s CALLED (#%d, os.clock=%.3f)",
                                    this_name, c, os.clock()))
                                if c == MAX_LOGS_PER_METHOD then
                                    log_line("    (further " .. this_name .. " calls suppressed)")
                                end
                            end
                        end,
                        nil)
                end)
                if ok_h then hooked = hooked + 1 end
            end
        end
    end
    log_line("installed log-only hooks on " .. hooked .. " CameraSystem methods")
end

--------------------------------------------------------------------------------
-- 3) Menu-transition watcher: BusyCameraType + primary camera snapshot, logged
--    on every open/close of inventory/map/item box and for a short window after.
--------------------------------------------------------------------------------
local WATCHED = {
    { getter = "get_IsOpenInventory", label = "INVENTORY" },
    { getter = "get_IsOpenMap",       label = "MAP" },
    { getter = "isBusyItemBox",       label = "ITEMBOX" },
}
local last_state = {}
local window_until = 0.0
local last_window_log = 0.0

local function gui_bool(gm, getter)
    local ok, v = pcall(function() return gm:call(getter) end)
    return ok and v == true
end

local function camera_snapshot()
    local parts = {}

    local cam_sys = sdk.get_managed_singleton(CAMERA_SYSTEM_TYPE)
    if cam_sys then
        local ok_b, busy = pcall(function() return cam_sys:call("get_BusyCameraType") end)
        table.insert(parts, "BusyCameraType=" .. tostring(ok_b and busy or "?"))

        -- Try a few likely current-controller getters; log whichever exists.
        for _, getter in ipairs({ "get_CurrentController", "get_CameraController",
                                  "getCurrentCameraController", "get_MainCameraController" }) do
            local ok_c, ctrl = pcall(function() return cam_sys:call(getter) end)
            if ok_c and ctrl ~= nil then
                local ok_t, tn = pcall(function() return ctrl:get_type_definition():get_full_name() end)
                table.insert(parts, getter .. "=" .. tostring(ok_t and tn or "?"))
                break
            end
        end
    else
        table.insert(parts, "CameraSystem singleton MISSING")
    end

    local ok_pc, pcam = pcall(function() return sdk.get_primary_camera() end)
    if ok_pc and pcam ~= nil then
        local ok_go, go = pcall(function() return pcam:call("get_GameObject") end)
        local go_name = "?"
        if ok_go and go ~= nil then
            local ok_n, n = pcall(function() return go:call("get_Name") end)
            if ok_n then go_name = tostring(n) end
        end
        table.insert(parts, "cam_go=" .. go_name)

        local ok_fov, fov = pcall(function() return pcam:call("get_FOV") end)
        table.insert(parts, "fov=" .. tostring(ok_fov and fov or "?"))

        local ok_tf, tf = pcall(function() return pcam:call("get_GameObject"):call("get_Transform") end)
        if ok_tf and tf ~= nil then
            local ok_pos, pos = pcall(function() return tf:call("get_Position") end)
            if ok_pos and pos ~= nil then
                local ok_fmt, s = pcall(function()
                    return string.format("pos=(%.2f, %.2f, %.2f)", pos.x, pos.y, pos.z)
                end)
                table.insert(parts, ok_fmt and s or "pos=?")
            end
        end
    else
        table.insert(parts, "no primary camera")
    end

    return table.concat(parts, "  ")
end

re.on_frame(function()
    dump_camera_system_methods()
    install_hooks()

    local gm = sdk.get_managed_singleton(sdk.game_namespace("gui.GUIMaster"))
    if not gm then return end

    local now = os.clock()

    for _, w in ipairs(WATCHED) do
        local v = gui_bool(gm, w.getter)
        if last_state[w.getter] == nil then
            last_state[w.getter] = v
        elseif v ~= last_state[w.getter] then
            last_state[w.getter] = v
            log_line(string.format(">>> %s %s (os.clock=%.3f)", w.label, v and "OPENED" or "CLOSED", now))
            log_line("    " .. camera_snapshot())
            window_until = now + 1.5
            last_window_log = 0.0
        end
    end

    -- Short trailing window: snapshot ~5x/sec so we can see the camera actually
    -- move/blend after the transition fires.
    if now < window_until and (now - last_window_log) > 0.2 then
        last_window_log = now
        log_line("    [+window] " .. camera_snapshot())
    end
end)

log_line("loaded -- open/close inventory, map, and item box, then check this log")
