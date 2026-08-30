-- Live diagnostic for the "moving my head moves the weapon/pointer" report
-- (2026-08-15, VR, confirmed to happen with Aim Compensation OFF, so it's a
-- BASE hand-tracking behavior, not specific to
-- re2_vr_posture_spine_straighten_override.lua's aim-compensation feature).
--
-- Suspect: re2_vr_ik_extention.lua's get_fp_style_hand_world_pos() (lines
-- ~636-678). It takes the controller's real-world offset from the HMD
-- (ctrl_pos - hmd_pos, both from vrmod:get_position(), which -- based on how
-- get_vr_controller_world_pos()'s raw result is used AS-IS elsewhere in that
-- same file as a valid absolute hand position -- appear to already be real
-- world-space coordinates) and then RE-ROTATES that offset by the camera's
-- CURRENT yaw before adding it back to the camera position. If ctrl_pos/
-- hmd_pos are already world-space, this re-rotation is redundant and wrong:
-- it bakes the player's live head yaw into the hand target a second time,
-- which would visibly swing the computed hand/weapon position as the player
-- turns their head, even with the physical controller held perfectly still
-- -- exactly the reported symptom. This probe does NOT modify anything; it
-- mirrors that function's exact math step by step and logs each
-- intermediate value, so the actual behavior can be read from real numbers
-- instead of guessed at from code review. Test: hold the right controller
-- as still as possible and just turn your head left/right -- `offset`
-- should stay nearly constant if the controller really isn't moving; watch
-- whether `hand_pos` (the function's final output) swings anyway.

if reframework:get_game_name() ~= "re2" then
    return
end

if not vrmod then
    return
end

local state = {
    logging = false,
    frame = 0,
}

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

local function vec3_valid(p)
    return p ~= nil and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

local function vec3_subtract(a, b)
    return Vector3f.new(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function vec3_add(a, b)
    return Vector3f.new(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function vec3_length(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function quat_rotate_vec3(q, v)
    if q == nil or v == nil then return v end
    local ok, out = pcall(function() return q * v end)
    return ok and out or v
end

local function fmt_vec(v)
    if not v then return "nil" end
    return string.format("(%.4f, %.4f, %.4f)", v.x, v.y, v.z)
end

-- Same yaw-only extraction re2_vr_ik_extention.lua uses (zeroes the Y
-- components of the rotation matrix's basis vectors, i.e. strips pitch/roll,
-- keeps yaw).
local function yaw_only_quat(q)
    local m = q:to_mat4()
    m[1].y = 0.0
    m[2].y = 0.0
    m[3].y = 0.0
    return m:to_quat():normalized()
end

-- Signed yaw angle in degrees from a quaternion's forward vector (matches
-- the mod's own -Z-forward convention, e.g. re2_vr_laser_dot_probe.lua's
-- get_camera_forward()).
local function yaw_deg(q)
    local fwd = safe(function() return (q * Vector3f.new(0, 0, -1)):normalized() end)
    if not fwd then return nil end
    return math.deg(math.atan(fwd.x, -fwd.z))
end

-- Mirrors get_fp_style_hand_world_pos("right") from re2_vr_ik_extention.lua
-- exactly, step by step, with every intermediate value logged.
local function trace_fp_hand_pos()
    local cam = safe(function() return sdk.get_primary_camera() end)
    if not cam then
        log.info("[hand_head_probe] no primary camera")
        return
    end
    local wm = safe(function() return cam:call("get_WorldMatrix") end)
    if not wm then
        log.info("[hand_head_probe] no camera WorldMatrix")
        return
    end

    local cam_pos = Vector3f.new(wm[3].x, wm[3].y, wm[3].z)
    local cam_rot = safe(function() return wm:to_quat() end)
    if not cam_rot then
        log.info("[hand_head_probe] no camera quat")
        return
    end

    local hmd_pos = safe(function() return vrmod:get_position(0) end)
    if not vec3_valid(hmd_pos) then hmd_pos = cam_pos end

    local controllers = safe(function() return vrmod:get_controllers() end)
    local ctrl_idx = controllers and controllers[2] or 2 -- right hand
    local ctrl_pos = safe(function() return vrmod:get_position(ctrl_idx) end)
    if not vec3_valid(ctrl_pos) then
        log.info("[hand_head_probe] no valid right controller position")
        return
    end

    local offset = vec3_subtract(ctrl_pos, hmd_pos)
    local look_rot = yaw_only_quat(cam_rot:normalized())
    local hand_offset = quat_rotate_vec3(look_rot, offset)
    local hand_pos = vec3_add(cam_pos, hand_offset)

    state.frame = state.frame + 1
    log.info(string.format(
        "[hand_head_probe] frame=%d cam_yaw=%.2f  hmd_pos=%s  ctrl_pos=%s  offset=%s (len=%.4f)  hand_pos=%s",
        state.frame,
        yaw_deg(cam_rot) or -999,
        fmt_vec(hmd_pos), fmt_vec(ctrl_pos),
        fmt_vec(offset), vec3_length(offset),
        fmt_vec(hand_pos)))
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    if not state.logging then return end
    trace_fp_hand_pos()
end)

re.on_draw_ui(function()
    if not imgui then return end
    if not imgui.tree_node("Hand/Head Coupling Probe (diagnostic)") then return end

    imgui.text("Read-only, logs to re2_framework_log.txt -- grep for [hand_head_probe]")
    imgui.text_colored(
        "Test: hold the RIGHT controller as still as possible, then just turn your head left/right.",
        0xFF88CCFF)
    imgui.text_colored(
        "'offset' should stay nearly constant if the controller isn't moving. Watch whether",
        0xFF88CCFF)
    imgui.text_colored(
        "'hand_pos' swings anyway as cam_yaw changes -- that would confirm the coupling.",
        0xFF88CCFF)

    local c, v = imgui.checkbox("Log every frame (short bursts only, spammy)", state.logging)
    if c then state.logging = v end

    imgui.tree_pop()
end)

log.info("[re2_vr_hand_head_coupling_probe] Loaded")
