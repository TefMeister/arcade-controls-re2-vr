-- Diagnostic (read-only, no writes) for the "gun/laser points left after spine
-- straightening" problem. Purpose: find out WHEN spine_0's rotation is
-- actually read by the systems that place the visible gun/hand, relative to
-- when re2_vr_posture_spine_straighten_override.lua applies its correction.
--
-- Why this exists: the mod already has a full custom arm-IK system
-- (re2_vr_ik_extention.lua) that hooks the NATIVE IkArmFit.updateIk method
-- directly, plus separate work at UpdateJointExpression/PrepareRendering/
-- BeginRendering -- not just LateUpdateBehavior. The earlier PRE vs POST
-- LateUpdateBehavior hook-timing experiment on the spine fix didn't fix the
-- pointing-left issue, which suggests the real hand/gun placement isn't
-- decided at that stage at all. This probe logs spine_0's rotation and the
-- right wrist's world position at every relevant pipeline stage (both
-- LateUpdateBehavior hooks, and inside IkArmFit.updateIk itself) so the
-- actual order can be read from the log instead of guessed at.
--
-- This script only reads and logs. It does not write/override anything.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

local state = {
    logging = false,
    burst_remaining = 0,
    frame = 0,
    ik_hook_installed = false,
    ik_hook_warned = false,
    arm_fit_type = nil,
    -- Pressing the button while actually aiming in VR requires taking a hand
    -- off to interact with the overlay, which drops aim (the "zooms out for
    -- a second" the user reported) -- exactly the state we need to capture.
    -- So instead: auto-arm a burst the instant aiming starts (rising edge on
    -- SurvivorCondition.IsHold), no overlay interaction needed mid-aim.
    auto_capture_on_aim = true,
    was_aiming = false,
    survivor_condition_type = nil,
    last_auto_trigger_frame = -1,
}

local AUTO_CAPTURE_FRAMES = 90 -- ~1.5s at 60fps, plenty to see the settle

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

local function get_player_transform()
    local player = re2.get_localplayer()
    if not player then return nil end
    return safe(function() return player:call("get_Transform") end)
end

local function get_survivor_condition(player)
    if not player then return nil end
    if not state.survivor_condition_type then
        state.survivor_condition_type = sdk.typeof(NS("survivor.SurvivorCondition"))
    end
    if not state.survivor_condition_type then return nil end
    return safe(function()
        return player:call("getComponent(System.Type)", state.survivor_condition_type)
    end)
end

local function player_is_aiming()
    local cond = get_survivor_condition(re2.get_localplayer())
    if not cond then return false end
    local aiming = safe(function() return cond:call("get_IsHold") end)
    return aiming == true
end

local function get_spine0_y(tf)
    if not tf then return nil end
    local joint = safe(function() return tf:call("getJointByName", "spine_0") end)
    if not joint then return nil end
    local r = safe(function() return joint:call("get_LocalRotation") end)
    if not r or type(r.y) ~= "number" then return nil end
    return r.y
end

local function get_wrist_world_pos(tf, side)
    if not tf then return nil end
    local name = (side == "R") and "r_arm_wrist" or "l_arm_wrist"
    local joint = safe(function() return tf:call("getJointByName", name) end)
    if not joint then return nil end
    return safe(function() return joint:call("get_Position") end)
end

local function fmt_vec(v)
    if not v then return "nil" end
    return string.format("(%.4f, %.4f, %.4f)", v.x, v.y, v.z)
end

-- Decided ONCE per frame (at the first call site each frame, which is
-- PRE LateUpdateBehavior since it also increments state.frame) so a burst of
-- N means N full frames with every stage logged, not N individual log calls
-- split across ~6 call sites per frame.
local function begin_frame_log_decision()
    if state.logging then
        state.log_this_frame = true
        return
    end
    if state.burst_remaining > 0 then
        state.burst_remaining = state.burst_remaining - 1
        state.log_this_frame = true
        return
    end
    state.log_this_frame = false
end

local function should_log()
    return state.log_this_frame == true
end

local function log_stage(stage)
    if not should_log() then return end
    local tf = get_player_transform()
    local sy = get_spine0_y(tf)
    local rw = get_wrist_world_pos(tf, "R")
    local lw = get_wrist_world_pos(tf, "L")
    log.info(string.format(
        "[aim_align_probe] frame=%d stage=%-24s spine0_y=%s  r_wrist=%s  l_wrist=%s",
        state.frame, stage,
        sy and string.format("%.4f", sy) or "nil",
        fmt_vec(rw), fmt_vec(lw)))
end

local function check_auto_capture_on_aim()
    if not state.auto_capture_on_aim then
        state.was_aiming = false
        return
    end
    local aiming = player_is_aiming()
    if aiming and not state.was_aiming then
        state.burst_remaining = AUTO_CAPTURE_FRAMES
        state.last_auto_trigger_frame = state.frame
    end
    state.was_aiming = aiming
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    state.frame = state.frame + 1
    check_auto_capture_on_aim()
    begin_frame_log_decision()
    log_stage("PRE LateUpdateBehavior")
end)

re.on_application_entry("LateUpdateBehavior", function()
    log_stage("POST LateUpdateBehavior")
end)

re.on_pre_application_entry("UpdateJointExpression", function()
    log_stage("PRE UpdateJointExpression")
end)

re.on_application_entry("UpdateJointExpression", function()
    log_stage("POST UpdateJointExpression")
end)

re.on_pre_application_entry("PrepareRendering", function()
    log_stage("PRE PrepareRendering")
end)

local function resolve_ik_arm_fit_from_args(args)
    if state.arm_fit_type == nil then
        state.arm_fit_type = sdk.find_type_definition(NS("IkArmFit"))
    end
    if state.arm_fit_type == nil then return nil end
    for i = 2, 10 do
        local obj = sdk.to_managed_object(args[i])
        if obj ~= nil then
            local ok, is_fit = pcall(function() return obj:get_type_definition():is_a(state.arm_fit_type) end)
            if ok and is_fit then return obj end
        end
    end
    return nil
end

local function on_pre_update_ik(args)
    if not should_log() then return end
    local tf = get_player_transform()
    local sy = get_spine0_y(tf)
    local rw = get_wrist_world_pos(tf, "R")
    local lw = get_wrist_world_pos(tf, "L")
    local arm_fit = resolve_ik_arm_fit_from_args(args)
    log.info(string.format(
        "[aim_align_probe] frame=%d stage=%-24s spine0_y=%s  r_wrist=%s  l_wrist=%s  arm_fit_found=%s",
        state.frame, "PRE IkArmFit.updateIk",
        sy and string.format("%.4f", sy) or "nil",
        fmt_vec(rw), fmt_vec(lw), tostring(arm_fit ~= nil)))
end

local function on_post_update_ik(retval)
    -- No separate should_log() gate here -- this always follows a
    -- corresponding on_pre_update_ik call for the same native invocation,
    -- and the per-frame decision is already made in state.log_this_frame.
    if not should_log() then return retval end
    local tf = get_player_transform()
    local sy = get_spine0_y(tf)
    local rw = get_wrist_world_pos(tf, "R")
    local lw = get_wrist_world_pos(tf, "L")
    log.info(string.format(
        "[aim_align_probe] frame=%d stage=%-24s spine0_y=%s  r_wrist=%s  l_wrist=%s",
        state.frame, "POST IkArmFit.updateIk",
        sy and string.format("%.4f", sy) or "nil",
        fmt_vec(rw), fmt_vec(lw)))
    return retval
end

local function install_ik_hook()
    if state.ik_hook_installed then return end
    state.arm_fit_type = sdk.find_type_definition(NS("IkArmFit"))
    if not state.arm_fit_type then
        if not state.ik_hook_warned then
            log.warn("[aim_align_probe] IkArmFit type not found")
            state.ik_hook_warned = true
        end
        return
    end
    local method = state.arm_fit_type:get_method("updateIk")
    if not method then
        if not state.ik_hook_warned then
            log.warn("[aim_align_probe] IkArmFit.updateIk not found")
            state.ik_hook_warned = true
        end
        return
    end
    sdk.hook(method, on_pre_update_ik, on_post_update_ik)
    state.ik_hook_installed = true
    log.info("[aim_align_probe] Hooked IkArmFit.updateIk")
end

install_ik_hook()

re.on_draw_ui(function()
    if not imgui then return end
    if not imgui.tree_node("Aim Alignment Probe (paused, blocked on VR access)") then return end
    imgui.text("Aim alignment probe (read-only, logs to re2_framework_log.txt)")
    imgui.text("Prefix to grep for: [aim_align_probe]")

    local ac, av = imgui.checkbox("Auto-capture when aiming starts (no button press needed)", state.auto_capture_on_aim)
    if ac then state.auto_capture_on_aim = av end
    imgui.text("Currently aiming (IsHold): " .. tostring(player_is_aiming()))
    imgui.text("Last auto-trigger: frame " .. tostring(state.last_auto_trigger_frame))

    local c, v = imgui.checkbox("Continuous logging (spammy -- short bursts only)", state.logging)
    if c then state.logging = v end

    if imgui.button("Log next 60 frames (manual)") then
        state.burst_remaining = 60
    end
    imgui.text("Burst remaining: " .. tostring(state.burst_remaining))

    imgui.text_colored(
        "With auto-capture on, just raise the weapon to aim in VR -- no need to touch this panel while aiming.",
        0xFF88CCFF)
    imgui.tree_pop()
end)

log.info("[re2_vr_aim_alignment_probe] Loaded")
