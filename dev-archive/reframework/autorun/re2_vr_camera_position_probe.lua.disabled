-- Diagnostic for the residual body sway banked in re2_vr_torso_twist_status.md
-- (2026-08-16 update): with spine correction OFF, the headset view stays rock
-- stable even while the body/animation keeps moving; with it ON, the view
-- itself picks up shake, footstep-synced. Every joint from root down through
-- spine_2, plus legs, has already been ruled out via rotation-freeze A/B
-- testing -- freezing any of them had zero effect on the sway. That method
-- only ever froze a joint's ROTATION and watched for a change; it never
-- directly measured the one value that actually matters: where the rendered
-- camera itself ends up. The leading untested theory (carried over from
-- re2_vr_laser_sight_drift_status.md's original dot-drift investigation,
-- which turned out to be a genuinely different bug but the same FAMILY of
-- trap -- a native value gets recomputed downstream of this mod's write in a
-- way static joint elimination can't see) is that this mod's VR camera
-- position is computed relative to something spine correction perturbs, even
-- though no single joint's rotation-freeze test caught it.
--
-- This probe logs TWO independent readings every frame during a capture
-- window, side by side:
--   1. sdk.get_primary_camera()'s actual world position/forward -- what
--      literally gets rendered to the headset.
--   2. vrmod:get_position(0)/get_rotation(0) -- the RAW physical HMD pose
--      straight from the tracking runtime, upstream of anything this game or
--      this mod computes from it.
-- If the player holds their head physically still, (2) should stay flat
-- regardless of spine_on -- it's just hardware tracking. If (1) stays flat
-- too when spine_on=false but starts jittering when spine_on=true while (2)
-- stays flat throughout, that's direct proof the shake is injected by this
-- mod's/the game's camera computation, not real head movement -- confirming
-- the "camera position, not any joint" theory. If (1) and (2) move together
-- in both phases, the sway is either real head movement or genuine hardware
-- tracking noise, not a spine-correction-coupled bug.
--
-- Also logs vrmod:get_standing_origin() (the playspace-to-world anchor) and
-- offset = camera_pos - hmd_pos, so a sudden change in the OFFSET itself
-- (rather than either reading alone) is visible too -- that would mean
-- whatever translates raw HMD pose into the rendered camera position is
-- itself being perturbed.
--
-- Read-only. No hooks, no writes -- pure polling, same discipline as
-- re2_vr_laser_dot_probe.lua's get_pointer_effect_world_pos().

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")

local state = {
    manual_capture_until = nil,
    frame = 0,
    log_this_frame = false,

    last_cam_pos = nil,
    last_hmd_pos = nil,
    last_cam_delta = 0.0,
    last_hmd_delta = 0.0,
    max_cam_delta_this_capture = 0.0,
    max_hmd_delta_this_capture = 0.0,
}

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

local function fmt_vec(v)
    if not v then return "nil" end
    return string.format("(%.4f, %.4f, %.4f)", v.x, v.y, v.z)
end

local function vec3_len(v)
    if not v then return nil end
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function vec3_sub(a, b)
    if not a or not b then return nil end
    return Vector3f.new(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function vec3_dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function angle_between_deg(a, b)
    if not a or not b then return nil end
    local la, lb = vec3_len(a), vec3_len(b)
    if not la or not lb or la < 1e-6 or lb < 1e-6 then return nil end
    local cosang = vec3_dot(a, b) / (la * lb)
    cosang = math.max(-1.0, math.min(1.0, cosang))
    return math.deg(math.acos(cosang))
end

-- Actual rendered camera pose -- same mat[3]/to_quat() pattern already
-- confirmed working in re2_vr_laser_dot_probe.lua/re2_vr_crosshair.lua.
local function get_render_camera_pose()
    local cam = safe(function() return sdk.get_primary_camera() end)
    local mat = cam and safe(function() return cam:get_WorldMatrix() end)
    if not mat then return nil, nil end
    local pos = mat[3]
    local fwd = safe(function() return (mat:to_quat() * Vector3f.new(0, 0, -1)):normalized() end)
    return pos, fwd
end

-- Raw physical HMD tracking pose, upstream of any game/mod computation --
-- same vrmod:get_position(0)/get_rotation(0) calls already confirmed working
-- in re2_vr_ik_extention.lua and re8_vr.lua.
local function get_raw_hmd_pose()
    if type(vrmod) ~= "table" and type(vrmod) ~= "userdata" then return nil, nil end
    local pos = safe(function() return vrmod:get_position(0) end)
    local fwd = safe(function()
        return (vrmod:get_rotation(0):to_quat() * Vector3f.new(0, 0, -1)):normalized()
    end)
    return pos, fwd
end

local function get_standing_origin()
    if type(vrmod) ~= "table" and type(vrmod) ~= "userdata" then return nil end
    return safe(function() return vrmod:get_standing_origin() end)
end

-- Self-contained flat (XZ) speed estimate, same technique as
-- re2_vr_posture_spine_straighten_override.lua's update_speed_estimate, kept
-- independent so this probe works standalone even if that script's globals
-- change shape.
local move = { last_pos = nil, last_t = nil, ema_speed = 0.0 }
local function update_move_speed()
    local player = re2.get_localplayer()
    local tf = player and safe(function() return player:call("get_Transform") end)
    local pos = tf and safe(function() return tf:call("get_Position") end)
    local now_t = os.clock()
    local dt = 0.0
    if move.last_t then dt = math.max(0.0, now_t - move.last_t) end
    move.last_t = now_t
    if pos and move.last_pos and dt > 1e-4 then
        local dx = pos.x - move.last_pos.x
        local dz = pos.z - move.last_pos.z
        local inst_speed = math.min(math.sqrt(dx * dx + dz * dz) / dt, 5.0)
        local alpha = 1.0 - math.exp(-dt / 0.15)
        move.ema_speed = move.ema_speed + (inst_speed - move.ema_speed) * alpha
    end
    if pos then move.last_pos = pos end
    return move.ema_speed
end

local function log_stage(stage)
    if not state.log_this_frame then return end

    local cam_pos, cam_fwd = get_render_camera_pose()
    local hmd_pos, hmd_fwd = get_raw_hmd_pose()
    local origin = get_standing_origin()
    local spine_on = rawget(_G, "__vr_spine_correction_enabled")
    local spine_timing = rawget(_G, "__vr_spine_correction_timing")
    local speed = update_move_speed()

    local cam_delta = 0.0
    if cam_pos and state.last_cam_pos then
        cam_delta = vec3_len(vec3_sub(cam_pos, state.last_cam_pos)) or 0.0
    end
    local hmd_delta = 0.0
    if hmd_pos and state.last_hmd_pos then
        hmd_delta = vec3_len(vec3_sub(hmd_pos, state.last_hmd_pos)) or 0.0
    end
    if cam_pos then state.last_cam_pos = cam_pos end
    if hmd_pos then state.last_hmd_pos = hmd_pos end
    state.last_cam_delta = cam_delta
    state.last_hmd_delta = hmd_delta
    state.max_cam_delta_this_capture = math.max(state.max_cam_delta_this_capture, cam_delta)
    state.max_hmd_delta_this_capture = math.max(state.max_hmd_delta_this_capture, hmd_delta)

    local offset = (cam_pos and hmd_pos) and vec3_sub(cam_pos, hmd_pos) or nil
    local ang_delta = angle_between_deg(cam_fwd, hmd_fwd)

    log.info(string.format(
        "[camera_position_probe] frame=%d stage=%-24s spine_on=%-5s spine_timing=%-7s speed=%.2f  cam_pos=%s  cam_delta=%.5f  hmd_pos=%s  hmd_delta=%.5f  standing_origin=%s  offset=%s  cam_vs_hmd_fwd_deg=%s",
        state.frame, stage, tostring(spine_on == true), tostring(spine_timing or "?"), speed,
        fmt_vec(cam_pos), cam_delta,
        fmt_vec(hmd_pos), hmd_delta,
        fmt_vec(origin),
        offset and fmt_vec(offset) or "nil",
        ang_delta and string.format("%.2f", ang_delta) or "nil"))
end

local function begin_frame_log_decision()
    if state.manual_capture_until and os.clock() < state.manual_capture_until then
        state.log_this_frame = true
        return
    end
    state.log_this_frame = false
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    state.frame = state.frame + 1
    begin_frame_log_decision()
    log_stage("PRE LateUpdateBehavior")
end)

re.on_application_entry("LateUpdateBehavior", function()
    log_stage("POST LateUpdateBehavior")
end)

re.on_pre_application_entry("PrepareRendering", function()
    log_stage("PRE PrepareRendering")
end)

re.on_draw_ui(function()
    if not imgui then return end
    if not imgui.tree_node("Camera Position Probe (diagnostic)") then return end

    imgui.text("Read-only, no hooks/writes -- pure polling every logged frame.")
    imgui.text("Logs to re2_framework_log.txt -- grep for [camera_position_probe]")
    imgui.text("Compares the RENDERED camera pose against the RAW physical HMD pose.")
    imgui.text_colored(
        "Goal: is the residual sway (banked in torso_twist_status.md) camera-computation,",
        0xFF88CCFF)
    imgui.text_colored(
        "or real head movement/hardware tracking noise? Every joint has already been ruled out.",
        0xFF88CCFF)

    imgui.spacing()
    if imgui.button("Start 10s continuous capture NOW") then
        state.manual_capture_until = os.clock() + 10.0
        state.max_cam_delta_this_capture = 0.0
        state.max_hmd_delta_this_capture = 0.0
    end
    local remaining_s = state.manual_capture_until and math.max(0.0, state.manual_capture_until - os.clock()) or 0.0
    imgui.text(string.format("Capture time remaining: %.1fs", remaining_s))
    imgui.text("Spine correction currently: " .. tostring(rawget(_G, "__vr_spine_correction_enabled") == true))
    imgui.text_colored(
        "Press the button, THEN stand still (or walk normally) -- toggle spine correction mid-window",
        0xFF88CCFF)
    imgui.text_colored(
        "if you want both phases in one capture (spine_on= is logged per line, same as the other probes).",
        0xFF88CCFF)

    imgui.spacing()
    imgui.separator()
    imgui.text(string.format("Last frame: cam_delta=%.5f  hmd_delta=%.5f", state.last_cam_delta, state.last_hmd_delta))
    imgui.text(string.format("Max this capture: cam_delta=%.5f  hmd_delta=%.5f",
        state.max_cam_delta_this_capture, state.max_hmd_delta_this_capture))
    imgui.text_colored(
        "If cam_delta spikes while hmd_delta stays flat (esp. when spine_on flips true), that's the smoking gun.",
        0xFF88CCFF)

    imgui.tree_pop()
end)

log.info("[re2_vr_camera_position_probe] Loaded")
