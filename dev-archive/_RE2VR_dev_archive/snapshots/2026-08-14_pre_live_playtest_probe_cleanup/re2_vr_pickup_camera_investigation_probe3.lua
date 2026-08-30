-- Diagnostic only (read-only, no writes) -- round 3 of the pickup black-
-- screen investigation. Round 2 found NewInventoryDetailBehavior.MainCamera
-- is a real "Main Camera" GameObject with a genuine via.Camera component
-- (get_FOV/get_ProjectionType/get_CameraType/get_DebugCamera/etc.), and that
-- setItemCamera fires every frame while the detail screen is open (a live
-- per-frame camera driver, not one-shot setup). Round 2's HMD-position
-- comparison was flawed though: MainCamera's Transform position is
-- WORLD-space, but vrmod:get_position(0) returns TRACKING-space (near-
-- origin) -- comparing them directly is the exact same coordinate-space
-- mistake already documented and fixed once before in this project (see
-- re2_vr_real_weapon_grip_attempt memory, "raw controller position is in
-- VR tracking/room space... completely different coordinate systems, not
-- comparable at all"). Fixed here: compares against the PLAYER's own
-- world-space position instead (re2.get_localplayer()'s Transform).
--
-- This round actually READS the via.Camera properties round 2 only
-- enumerated by name (get_CameraType, get_ProjectionType, get_DebugCamera,
-- get_FOV, get_NearClipPlane, get_FarClipPlane, get_AspectRatio,
-- get_VerticalEnable) -- if this camera is configured as some special/debug
-- type distinct from normal gameplay rendering, that would show up here
-- directly instead of needing to be inferred. Deliberately does NOT try to
-- guess at a "real gameplay camera" API to compare against -- no proven
-- accessor for that is known in this codebase yet, and this project's own
-- history (the force_aim_grip_probe dead end) is a specific lesson against
-- guessing unverified native method names blind.
--
-- Safe to delete/archive once findings are captured.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

local function fmt_vec(v)
    if not v then return "nil" end
    local ok, s = pcall(function() return string.format("(%.3f, %.3f, %.3f)", v.x, v.y, v.z) end)
    return ok and s or "invalid"
end

local function safe_call(obj, method)
    if not obj then return nil end
    local ok, v = pcall(function() return obj:call(method) end)
    if ok then return v end
    return nil
end

local dumped = false
local hooked_open = false
local function install_open_observer()
    if hooked_open then return end
    local detail_type = sdk.find_type_definition(NS("gui.NewInventoryDetailBehavior"))
    if not detail_type then return end
    local m = detail_type:get_method("open")
    if not m then return end
    pcall(function()
        sdk.hook(m,
            function(args)
                if not dumped then
                    dumped = true
                    log.info("[pickup_cam_probe3] === open() fired ===")

                    local ok_self, self_obj = pcall(function() return sdk.to_managed_object(args[2]) end)
                    local main_camera = nil
                    if ok_self and self_obj then
                        local ok_mc, mc = pcall(function() return self_obj:get_field("MainCamera") end)
                        if ok_mc then main_camera = mc end
                    end

                    if not main_camera then
                        log.info("[pickup_cam_probe3] MainCamera unavailable, aborting")
                        return
                    end

                    -- Fixed comparison: player's real WORLD position, same
                    -- coordinate space as MainCamera's Transform, instead of
                    -- round 2's mismatched tracking-space HMD read.
                    local player = re2.get_localplayer()
                    local ok_ppos, player_pos = pcall(function()
                        local tf = player:call("get_Transform")
                        return tf and tf:call("get_Position")
                    end)
                    log.info("[pickup_cam_probe3] Player world position: " .. fmt_vec(ok_ppos and player_pos or nil))

                    local ok_cpos, cam_pos = pcall(function()
                        local tf = main_camera:call("get_Transform")
                        return tf and tf:call("get_Position")
                    end)
                    log.info("[pickup_cam_probe3] MainCamera world position: " .. fmt_vec(ok_cpos and cam_pos or nil))

                    local ok_cam, cam = pcall(function()
                        return main_camera:call("getComponent(System.Type)", sdk.typeof("via.Camera"))
                    end)
                    if not ok_cam or not cam then
                        log.info("[pickup_cam_probe3] via.Camera component unavailable")
                        return
                    end

                    log.info(string.format(
                        "[pickup_cam_probe3] via.Camera readout: FOV=%s NearClip=%s FarClip=%s AspectRatio=%s VerticalEnable=%s CameraType=%s ProjectionType=%s DebugCamera=%s LookAtDistance=%s",
                        tostring(safe_call(cam, "get_FOV")),
                        tostring(safe_call(cam, "get_NearClipPlane")),
                        tostring(safe_call(cam, "get_FarClipPlane")),
                        tostring(safe_call(cam, "get_AspectRatio")),
                        tostring(safe_call(cam, "get_VerticalEnable")),
                        tostring(safe_call(cam, "get_CameraType")),
                        tostring(safe_call(cam, "get_ProjectionType")),
                        tostring(safe_call(cam, "get_DebugCamera")),
                        tostring(safe_call(cam, "get_LookAtDistance"))))

                    local ok_lookat, lookat_pos = pcall(function() return cam:call("get_LookAtPosition") end)
                    log.info("[pickup_cam_probe3] MainCamera LookAtPosition: " .. fmt_vec(ok_lookat and lookat_pos or nil))
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end)
    hooked_open = true
end

re.on_frame(function()
    if not hooked_open then pcall(install_open_observer) end
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Pickup camera investigation probe 3 (read-only)")
    imgui.text("Prefix to grep: [pickup_cam_probe3]")
    imgui.text("Dumped: " .. tostring(dumped))
    imgui.text_colored("Pick up a regular world item once to trigger the readout.", 0xFF88CCFF)
end)

log.info("[pickup_cam_probe3] Loaded. Pick up a regular item once.")
