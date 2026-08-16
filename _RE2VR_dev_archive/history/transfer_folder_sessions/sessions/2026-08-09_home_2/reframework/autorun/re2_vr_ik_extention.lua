if reframework:get_game_name() ~= "re2" then
    return {}
end

if not vrmod then
    return {}
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

local ok_vrc, vrc_manager = pcall(function() return require("vr/VRControllerManager") end)
if not ok_vrc then
    vrc_manager = nil
end

local CFG_PATH = "re2_vr/re2_vr_ik_extention.json"
local SUPPORT_HAND_DISTANCE = 0.5

local SLIDE_ARM_SLACK = 0.02
local SLIDE_IK_REACH_SLACK = 0.018
local SLIDE_DOCK_SHOULDER_MAX_PUSH = 0.50

local CFG = {
    enabled = true,
    max_m = 0.16,
    prestart_m = 0.025,
    tau_s = 0.10,
    slack = 0.018,
    forward_gate_min = 0.0,
    use_side_forward_gate = true,
    apply_fp_hand_offset = true,
    twohand_boost_enabled = true,
    twohand_l_extra_max_m = 0.08,
    twohand_l_extra_prestart_m = 0.0,
    use_ik_target_matrix = false,
    auto_standing_height_openxr = true,
    auto_standing_height_grace_s = 3.0,
    auto_standing_height_frame_delay = 60,
}

-- OpenXR hand position offsets (first-person arm IK).
local FP_HAND_POS_OFFSET = {
    left = Vector3f.new(-0.052, 0.084, 0.02),
    right = Vector3f.new(0.052, 0.084, 0.02),
}

local BONES = {
    L = {
        key = "L",
        clavicle = "l_arm_clavicle",
        upper = "l_arm_humerus",
        lower = "l_arm_radius",
        wrist = "l_arm_wrist",
    },
    R = {
        key = "R",
        clavicle = "r_arm_clavicle",
        upper = "r_arm_humerus",
        lower = "r_arm_radius",
        wrist = "r_arm_wrist",
    },
}

local DEFAULT_LARGE_WEAPONS = {
    wp1000 = true,
    wp1100 = true,
    wp3000 = true,
    wp3200 = true,
    wp4100 = true,
    wp4400 = true,
    wp4600 = true,
    wp4610 = true,
    wp4700 = true,
}

local stretch_smoothed = { L = 0.0, R = 0.0 }
local stretch_base_local = { L = nil, R = nil }
local stretch_base_frame = -999999
local stretch_last_t = nil
local stretch_smooth_last_frame = -999999

local hand_targets = { L = nil, R = nil }
local ik_hand_targets = { L = nil, R = nil }

local large_weapons = {}
local cached_player_tf = nil
local survivor_condition_type = nil
local grip_action = nil

local auto_height = {
    vr_latched = false,
    grace_until = 0.0,
    frame_delay = 0,
    attempts = 0,
    done = false,
    last_log_t = 0.0,
    MAX_ATTEMPTS = 12,
}

local ik = {
    hook_installed = false,
    hook_warned = false,
    arm_fit_type = nil,
    target_matrix_offset = nil,
    calls_this_frame = 0,
    last_frame = -1,
}

local wrist_hash = { L = nil, R = nil }
local sim_frame = 0
local slide = {
    hand_follow_frame = -1,
    dock_apply_frame = -1,
    dock_apply_prio = 0,
    post_ik_count = 0,
    post_ik_count_frame = -1,
    pole_smoothed = nil,
    left_fit_data = nil,
}

--- Effective left-hand dock source: the real slide-rack/pump-rack gesture
--- (owns __vr_slide_dock_blend_factor / __vr_slide_hand_world_pos and resets
--- them to 0/nil every frame it isn't active) always wins when engaged;
--- otherwise fall back to the cosmetic proximity dock's own globals, which
--- re2_vr_cosmetic_dock.lua publishes independently so it never fights the
--- real gesture's aggressive resets.
function slide.get_dock_state()
    local real_blend = tonumber(rawget(_G, "__vr_slide_dock_blend_factor")) or 0
    if real_blend > 0.001 then
        return real_blend,
            rawget(_G, "__vr_slide_hand_world_pos"),
            rawget(_G, "__vr_slide_hand_world_rot"),
            rawget(_G, "__vr_slide_rack_active") == true
    end
    local cos_blend = tonumber(rawget(_G, "__vr_cosmetic_dock_blend_factor")) or 0
    if cos_blend > 0.001 then
        return cos_blend, rawget(_G, "__vr_cosmetic_dock_hand_world_pos"), nil, false
    end
    return real_blend,
        rawget(_G, "__vr_slide_hand_world_pos"),
        rawget(_G, "__vr_slide_hand_world_rot"),
        rawget(_G, "__vr_slide_rack_active") == true
end

local via_murmur_hash_type = sdk.find_type_definition("via.murmur_hash")
local via_murmur_hash_calc32 = via_murmur_hash_type and via_murmur_hash_type:get_method("calc32") or nil

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

local function clampf(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function vec3_subtract(a, b)
    return Vector3f.new(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function vec3_add(a, b)
    return Vector3f.new(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function vec3_scale(v, s)
    return Vector3f.new(v.x * s, v.y * s, v.z * s)
end

local function vec3_length(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function vec3_distance(a, b)
    return vec3_length(vec3_subtract(a, b))
end

local function vec3_normalize(v)
    local len = vec3_length(v)
    if len < 1e-8 then return nil end
    return Vector3f.new(v.x / len, v.y / len, v.z / len)
end

local function vec3_dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function vec3_cross(a, b)
    return Vector3f.new(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x)
end

local function vec3_reject_normalize(v, from_unit)
    local d = vec3_dot(from_unit, v)
    local r = vec3_subtract(v, vec3_scale(from_unit, d))
    local rl = vec3_length(r)
    if rl < 1e-5 then return nil end
    return vec3_scale(r, 1.0 / rl)
end

local function vec3_valid(p)
    return p ~= nil and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

local function slide_left_arm_ik_locked()
    local blend, pos = slide.get_dock_state()
    if blend <= 0.001 then return false end
    return vec3_valid(pos)
end

local function apply_pump_hand_world_offset(pos)
    if not vec3_valid(pos) then return pos end
    local slide_blend = tonumber(rawget(_G, "__vr_slide_dock_blend_factor")) or 0
    if slide_blend > 0.001 then return pos end
    local pump_off = rawget(_G, "__vr_pump_hand_world_offset")
    if not vec3_valid(pump_off) then return pos end
    return Vector3f.new(
        pos.x + pump_off.x,
        pos.y + pump_off.y,
        pos.z + pump_off.z)
end

local function blend_left_hand_with_slide_dock(pos)
    if not vec3_valid(pos) then return pos end
    local blend = tonumber(rawget(_G, "__vr_slide_dock_blend_factor")) or 0
    if blend <= 0.001 then
        return apply_pump_hand_world_offset(pos)
    end
    if rawget(_G, "__vr_pump_slide_support") == true then
        return pos
    end
    local slide_pos = rawget(_G, "__vr_slide_hand_world_pos")
    if not vec3_valid(slide_pos) then return apply_pump_hand_world_offset(pos) end
    local blended = Vector3f.new(
        pos.x + (slide_pos.x - pos.x) * blend,
        pos.y + (slide_pos.y - pos.y) * blend,
        pos.z + (slide_pos.z - pos.z) * blend
    )
    return apply_pump_hand_world_offset(blended)
end

local function quat_rotate_vec3(q, v)
    if q == nil or v == nil then return v end
    local ok, out = pcall(function() return q * v end)
    return ok and out or v
end

local function quat_inverse(q)
    if q == nil then return nil end
    local ok, inv = pcall(function() return q:inverse() end)
    return ok and inv or nil
end

local function deg2rad(d)
    return (tonumber(d) or 0.0) * (math.pi / 180.0)
end

local function quat_from_euler_deg(pitch, yaw, roll)
    if not Quaternion or not Quaternion.new then return nil end
    local ok, q = pcall(function()
        return Quaternion.new(Vector3f.new(deg2rad(pitch), deg2rad(yaw), deg2rad(roll))):normalized()
    end)
    return ok and q or nil
end

local function quat_mul(a, b)
    if not a or not b then return a end
    local ok, q = pcall(function() return a * b end)
    return ok and q or a
end

local function get_slide_dock_ik_twist()
    local twist = rawget(_G, "__vr_slide_dock_ik_twist")
    if type(twist) ~= "table" then return nil end
    if twist.enabled == false then return nil end
    return twist
end

local function apply_elbow_pole_hint(player_tf, pole, twist, blend)
    if not vec3_valid(pole) or not twist then return pole end
    local t = clampf(blend, 0.0, 1.0)
    if t <= 0.001 then return pole end

    local char_rot = player_tf and safe(function() return player_tf:call("get_Rotation") end) or nil
    local out = Vector3f.new(pole.x, pole.y, pole.z)

    local off = twist.pole_off
    if char_rot and type(off) == "table" then
        local ox = (tonumber(off.x) or 0.0) * t
        local oy = (tonumber(off.y) or 0.0) * t
        local oz = (tonumber(off.z) or 0.0) * t
        if math.abs(ox) > 1e-6 or math.abs(oy) > 1e-6 or math.abs(oz) > 1e-6 then
            local right = quat_rotate_vec3(char_rot, Vector3f.new(1.0, 0.0, 0.0))
            local up = quat_rotate_vec3(char_rot, Vector3f.new(0.0, 1.0, 0.0))
            local fwd = quat_rotate_vec3(char_rot, Vector3f.new(0.0, 0.0, 1.0))
            local shifted = vec3_add(out, vec3_add(
                vec3_add(vec3_scale(right, ox), vec3_scale(up, oy)),
                vec3_scale(fwd, oz)))
            local norm = vec3_normalize(shifted)
            if norm then out = norm end
        end
    end

    local prot = twist.pole_rot
    if char_rot and type(prot) == "table" then
        local pitch = (tonumber(prot.pitch) or 0.0) * t
        local yaw = (tonumber(prot.yaw) or 0.0) * t
        local roll = (tonumber(prot.roll) or 0.0) * t
        if math.abs(pitch) > 1e-4 or math.abs(yaw) > 1e-4 or math.abs(roll) > 1e-4 then
            local off_q = quat_from_euler_deg(pitch, yaw, roll)
            local inv = quat_inverse(char_rot)
            if off_q and inv then
                local world_q = quat_mul(quat_mul(char_rot, off_q), inv)
                local rotated = quat_rotate_vec3(world_q, out)
                if vec3_valid(rotated) then out = rotated end
            end
        end
    end

    return out
end

local function apply_dock_hand_target_offset(player_tf, hand_pos, blend)
    if not vec3_valid(hand_pos) or not player_tf then return hand_pos end
    local twist = get_slide_dock_ik_twist()
    if not twist or not twist.hand_off then return hand_pos end
    local off = twist.hand_off
    if math.abs(off.x or 0) < 1e-6 and math.abs(off.y or 0) < 1e-6 and math.abs(off.z or 0) < 1e-6 then
        return hand_pos
    end
    local char_rot = safe(function() return player_tf:call("get_Rotation") end)
    if not char_rot then return hand_pos end
    local t = clampf(blend, 0.0, 1.0)
    local right = quat_rotate_vec3(char_rot, Vector3f.new(1.0, 0.0, 0.0))
    local up = quat_rotate_vec3(char_rot, Vector3f.new(0.0, 1.0, 0.0))
    local fwd = quat_rotate_vec3(char_rot, Vector3f.new(0.0, 0.0, 1.0))
    return vec3_add(hand_pos, vec3_add(
        vec3_add(
            vec3_scale(right, (off.x or 0.0) * t),
            vec3_scale(up, (off.y or 0.0) * t)
        ),
        vec3_scale(fwd, (off.z or 0.0) * t)
    ))
end

local function reset_stretch_state()
    stretch_smoothed.L, stretch_smoothed.R = 0.0, 0.0
    stretch_base_local.L, stretch_base_local.R = nil, nil
    stretch_base_frame = -999999
    stretch_last_t = nil
    stretch_smooth_last_frame = -999999
    hand_targets.L, hand_targets.R = nil, nil
    ik_hand_targets.L, ik_hand_targets.R = nil, nil
end

local function build_default_large_weapon_table()
    local t = {}
    for wp_id, _ in pairs(DEFAULT_LARGE_WEAPONS) do
        t[wp_id] = true
    end
    return t
end

large_weapons = build_default_large_weapon_table()

local function load_cfg()
    local data = json.load_file(CFG_PATH)
    if type(data) ~= "table" then return end
    for k, v in pairs(data) do
        if CFG[k] ~= nil then
            if type(v) == type(CFG[k]) then
                CFG[k] = v
            elseif type(CFG[k]) == "boolean" then
                CFG[k] = v == true
            end
        end
    end
    if type(data.large_weapons) == "table" and #data.large_weapons > 0 then
        large_weapons = build_default_large_weapon_table()
        for _, wp_id in ipairs(data.large_weapons) do
            if type(wp_id) == "string" and wp_id ~= "" then
                large_weapons[wp_id] = true
            end
        end
    end
    -- IkArmFit TargetMatrix is pre-clamped; never use for stretch distance.
    CFG.use_ik_target_matrix = false
end

pcall(load_cfg)

local function get_player_transform()
    local player = re2.get_localplayer()
    if not player then return nil end
    return safe(function() return player:call("get_Transform") end)
end

local function is_valid_hmd_position(pos)
    if pos == nil or pos.x == nil or pos.y == nil or pos.z == nil then
        return false
    end
    if math.abs(pos.x) < 1e-6 and math.abs(pos.y) < 1e-6 and math.abs(pos.z) < 1e-6 then
        return false
    end
    return true
end

local function auto_height_openxr_active()
    if not vrmod then
        return false
    end
    if type(vrmod.is_openxr_loaded) == "function" then
        local ok, loaded = pcall(vrmod.is_openxr_loaded, vrmod)
        if ok and loaded == true then
            return true
        end
    end
    return false
end

local function auto_height_hmd_active()
    if not vrmod or type(vrmod.is_hmd_active) ~= "function" then
        return false
    end
    local ok, active = pcall(vrmod.is_hmd_active, vrmod)
    return ok and active == true
end

local function auto_height_log_throttled(msg)
    local now = os.clock()
    if (now - auto_height.last_log_t) < 2.0 then
        return
    end
    auto_height.last_log_t = now
    log.info(msg)
end

local function perform_auto_standing_height_reset()
    if type(vrmod.get_position) ~= "function"
        or type(vrmod.get_standing_origin) ~= "function"
        or type(vrmod.set_standing_origin) ~= "function" then
        return false
    end

    local hmd = nil
    pcall(function() hmd = vrmod:get_position(0) end)
    if not is_valid_hmd_position(hmd) then
        return false
    end

    local origin = nil
    pcall(function() origin = vrmod:get_standing_origin() end)
    if origin == nil or origin.x == nil or origin.y == nil or origin.z == nil then
        return false
    end

    if type(vrmod.recenter_view) == "function" then
        pcall(function() vrmod:recenter_view() end)
    end

    local old_y = origin.y
    local w = origin.w or 1.0
    pcall(function()
        vrmod:set_standing_origin(Vector4f.new(origin.x, hmd.y, origin.z, w))
    end)

    log.info(string.format(
        "[re2_vr_ik_extention] Auto standing height (OpenXR): %.3f -> %.3f (attempt %d)",
        old_y, hmd.y, auto_height.attempts + 1))
    return true
end

local function tick_auto_standing_height()
    if auto_height.done or not CFG.auto_standing_height_openxr then
        return
    end

    if not auto_height_openxr_active() or not auto_height_hmd_active() then
        return
    end

    if not auto_height.vr_latched then
        auto_height.vr_latched = true
        local grace = tonumber(CFG.auto_standing_height_grace_s) or 3.0
        if grace < 0.5 then grace = 0.5 end
        if grace > 15.0 then grace = 15.0 end
        auto_height.grace_until = os.clock() + grace
        auto_height.frame_delay = 0
        auto_height.attempts = 0
        log.info(string.format(
            "[re2_vr_ik_extention] OpenXR+HMD latched, auto height in %.1fs",
            grace))
        return
    end

    if os.clock() < auto_height.grace_until then
        return
    end

    local delay = math.floor(tonumber(CFG.auto_standing_height_frame_delay) or 60)
    if delay < 0 then delay = 0 end
    if delay > 600 then delay = 600 end
    if auto_height.frame_delay < delay then
        auto_height.frame_delay = auto_height.frame_delay + 1
        return
    end

    if perform_auto_standing_height_reset() then
        auto_height.done = true
        return
    end

    auto_height.attempts = auto_height.attempts + 1
    if auto_height.attempts >= auto_height.MAX_ATTEMPTS then
        log.warn("[re2_vr_ik_extention] Auto standing height gave up after max attempts")
        auto_height.done = true
        return
    end

    auto_height_log_throttled("[re2_vr_ik_extention] Auto standing height retry pending valid HMD pose")
end

local function vr_active()
    if not CFG.enabled then return false end
    if firstpersonmod ~= nil and type(firstpersonmod.will_be_used) == "function" then
        local ok_fp, fp_active = pcall(function() return firstpersonmod:will_be_used() end)
        if not ok_fp or not fp_active then
            return false
        end
    end
    local ok_hmd, hmd = pcall(function() return vrmod:is_hmd_active() end)
    local ok_ctrl, ctrl = pcall(function() return vrmod:is_using_controllers() end)
    return ok_hmd and hmd and ok_ctrl and ctrl
end

local function get_survivor_condition(player)
    if not player then return nil end
    if not survivor_condition_type then
        survivor_condition_type = sdk.typeof(NS("survivor.SurvivorCondition"))
    end
    if not survivor_condition_type then return nil end
    local ok, cond = pcall(function()
        return player:call("getComponent(System.Type)", survivor_condition_type)
    end)
    return ok and cond or nil
end

local function player_is_reloading()
    if rawget(_G, "__vr_manual_reload_active") == true then return false end
    local cond = get_survivor_condition(re2.get_localplayer())
    if not cond then return false end
    local ok, reloading = pcall(function() return cond:call("get_IsReload") end)
    return ok and reloading == true
end

local function player_is_aiming()
    local cond = get_survivor_condition(re2.get_localplayer())
    if not cond then return false end
    local ok, aiming = pcall(function() return cond:call("get_IsHold") end)
    return ok and aiming == true
end

local function is_left_grip_active()
    if not grip_action or grip_action == 0 then
        pcall(function() grip_action = vrmod:get_action_grip() end)
    end
    if not grip_action then return false end
    local left_joy = nil
    pcall(function() left_joy = vrmod:get_left_joystick() end)
    if not left_joy then return false end
    local ok, active = pcall(function()
        return vrmod:is_action_active(grip_action, left_joy)
    end)
    return ok and active == true
end

--- REFramework VR: controllers[1]=left, controllers[2]=right (matches VRControllerManager list order).
local function get_vr_controller_world_pos(hand)
    if not vrmod then return nil end
    local ok_h, hmd_on = pcall(vrmod.is_hmd_active, vrmod)
    if not ok_h or not hmd_on then return nil end

    local list_i = (hand == "right") and 2 or 1

    if vrc_manager then
        local ok_has, has = pcall(function() return vrc_manager:has_controllers() end)
        if ok_has and has and vrc_manager.controllers_list then
            local ctrl = vrc_manager.controllers_list[list_i]
            if ctrl and vec3_valid(ctrl.position) and vec3_length(ctrl.position) > 1e-6 then
                return Vector3f.new(ctrl.position.x, ctrl.position.y, ctrl.position.z)
            end
        end
    end

    local controllers = nil
    pcall(function() controllers = vrmod:get_controllers() end)
    if not controllers then return nil end
    local idx = controllers[list_i]
    if idx == nil then return nil end
    local ok, pos = pcall(function() return vrmod:get_position(idx) end)
    return ok and vec3_valid(pos) and pos or nil
end

local function get_vr_controller_world_rot(hand)
    if not vrmod or type(vrmod.get_rotation) ~= "function" then return nil end
    local ok_h, hmd_on = pcall(vrmod.is_hmd_active, vrmod)
    if not ok_h or not hmd_on then return nil end

    local list_i = (hand == "right") and 2 or 1
    if vrc_manager then
        local ok_has, has = pcall(function() return vrc_manager:has_controllers() end)
        if ok_has and has and vrc_manager.controllers_list then
            local ctrl = vrc_manager.controllers_list[list_i]
            if ctrl and ctrl.rotation then
                return ctrl.rotation
            end
        end
    end

    local controllers = nil
    pcall(function() controllers = vrmod:get_controllers() end)
    if not controllers then return nil end
    local idx = controllers[list_i]
    if idx == nil then return nil end
    local ok, rot = pcall(vrmod.get_rotation, vrmod, idx)
    return ok and rot or nil
end

--- Approximate FirstPerson hand target: camera-relative controller offset in world space.
local function get_fp_style_hand_world_pos(hand)
    local cam = sdk.get_primary_camera()
    if not cam then return nil end
    local ok_wm, wm = pcall(function() return cam:call("get_WorldMatrix") end)
    if not ok_wm or not wm then return nil end

    local cam_pos = Vector3f.new(wm[3].x, wm[3].y, wm[3].z)
    local cam_rot = wm:to_quat()
    if cam_rot == nil then return nil end

    local list_i = (hand == "right") and 2 or 1
    local hmd_pos = nil
    pcall(function() hmd_pos = vrmod:get_position(0) end)
    if not vec3_valid(hmd_pos) then
        hmd_pos = cam_pos
    end

    local controllers = nil
    pcall(function() controllers = vrmod:get_controllers() end)
    local ctrl_idx = controllers and controllers[list_i] or list_i

    local ctrl_pos = get_vr_controller_world_pos(hand)
    if not vec3_valid(ctrl_pos) then return nil end

    local offset = vec3_subtract(ctrl_pos, hmd_pos)
    local look_rot = cam_rot:normalized()
    local m = look_rot:to_mat4()
    m[1].y = 0.0
    m[2].y = 0.0
    m[3].y = 0.0
    look_rot = m:to_quat():normalized()

    local hand_offset = quat_rotate_vec3(look_rot, offset)
    local hand_pos = vec3_add(cam_pos, hand_offset)
    if CFG.apply_fp_hand_offset ~= false then
        local fp_off = FP_HAND_POS_OFFSET[hand]
        if fp_off then
            hand_pos = vec3_add(hand_pos, quat_rotate_vec3(look_rot, fp_off))
        end
    end
    return hand_pos
end

local function publish_vr_hand_globals()
    local lh = nil
    if rawget(_G, "__vr_lh_slide_ik_override") == true then
        lh = rawget(_G, "__vr_lh_joint_pos")
    end
    if not vec3_valid(lh) then
        lh = get_fp_style_hand_world_pos("left") or get_vr_controller_world_pos("left")
        lh = blend_left_hand_with_slide_dock(lh)
    end
    local rh = get_fp_style_hand_world_pos("right") or get_vr_controller_world_pos("right")
    if lh then rawset(_G, "__vr_lh_world", lh) end
    if rh then rawset(_G, "__vr_rh_world", rh) end
    return lh, rh
end

--- Raw controller / FP-style target (NOT IkArmFit matrix — that is already arm-length clamped).
local function get_raw_hand_target(which)
    -- __vr_lh_joint_pos is only kept fresh by the slide-dock system while
    -- __vr_lh_slide_ik_override is true; it's never cleared once docking
    -- ends, so reading it unconditionally here picks up a stale leftover
    -- position from whenever docking last happened.
    if which ~= "left" or rawget(_G, "__vr_lh_slide_ik_override") == true then
        local joint_key = (which == "left") and "__vr_lh_joint_pos" or "__vr_rh_joint_pos"
        local joint_pos = rawget(_G, joint_key)
        if vec3_valid(joint_pos) then
            return Vector3f.new(joint_pos.x, joint_pos.y, joint_pos.z), "joint_pos"
        end
    end
    local fp = get_fp_style_hand_world_pos(which)
    if fp then return fp, "fp_style" end
    local vr = get_vr_controller_world_pos(which)
    if vr then return vr, "vr_controller" end
    local key = (which == "left") and "__vr_lh_world" or "__vr_rh_world"
    local p = rawget(_G, key)
    if vec3_valid(p) then return p, "global" end
    return nil, "none"
end

local function resolve_hand_target(which)
    local side_key = (which == "left") and "L" or "R"
    if CFG.use_ik_target_matrix and ik_hand_targets[side_key] and vec3_valid(ik_hand_targets[side_key]) then
        local pos = ik_hand_targets[side_key]
        if which == "left" and rawget(_G, "__vr_lh_slide_ik_override") ~= true then
            pos = blend_left_hand_with_slide_dock(pos)
        end
        return pos, "ik_target_matrix"
    end
    local pos, src = get_raw_hand_target(which)
    if which == "left" and rawget(_G, "__vr_lh_slide_ik_override") ~= true then
        pos = blend_left_hand_with_slide_dock(pos)
    end
    return pos, src
end

local function hands_are_supporting_weapon()
    local lh, _ = resolve_hand_target("left")
    local rh, _ = resolve_hand_target("right")
    if not lh or not rh then return false end
    return vec3_distance(lh, rh) <= SUPPORT_HAND_DISTANCE
end

local function is_two_handed()
    if player_is_reloading() then return true end
    if firstpersonmod ~= nil and type(firstpersonmod.was_gripping_weapon) == "function" then
        local ok, gripping = pcall(function() return firstpersonmod:was_gripping_weapon() end)
        if ok and gripping == true then return true end
    end
    if rawget(_G, "__vr_in_holster_zone") == true then return false end
    if rawget(_G, "__vr_in_head_flashlight_zone") == true then return false end
    if not is_left_grip_active() then return false end
    if hands_are_supporting_weapon() then return true end
    if player_is_aiming() then return true end
    return false
end

local function get_weapon_recoil_id(weapon)
    if weapon == nil then return "" end
    local ok_go, go = pcall(function() return weapon:call("get_GameObject") end)
    if ok_go and go then
        local ok_name, name = pcall(function() return go:call("get_Name") end)
        if ok_name and type(name) == "string" and name ~= "" then return name end
    end
    local tdef = weapon:get_type_definition()
    if tdef then
        local ok_fn, fn = pcall(function() return tdef:get_full_name() end)
        if ok_fn and type(fn) == "string" then return fn end
    end
    return ""
end

local function is_large_weapon_equipped()
    local player = re2.get_localplayer()
    if player == nil then return false end
    local ok, _, weapon = pcall(function() return re2.get_weapon_object(player) end)
    if not ok or weapon == nil then return false end
    local wid = get_weapon_recoil_id(weapon)
    return wid ~= "" and large_weapons[wid] == true
end

local function support_hand_docked()
    if rawget(_G, "__vr_block_support_dock") == true then
        return false
    end
    if slide_left_arm_ik_locked() then
        return false
    end
    return is_two_handed() and hands_are_supporting_weapon()
end

local function get_frame_id()
    if re.get_frame_count then
        local ok, n = pcall(function() return re.get_frame_count() end)
        if ok and type(n) == "number" then return n end
    end
    return sim_frame
end

local function get_spine_forward(player_tf)
    if not player_tf then return Vector3f.new(0.0, 0.0, 1.0) end
    local spine =
        safe(function() return player_tf:call("getJointByName", "spine_2") end)
        or safe(function() return player_tf:call("getJointByName", "spine_1") end)
        or safe(function() return player_tf:call("getJointByName", "spine_0") end)
    local rot = spine and safe(function() return spine:call("get_Rotation") end) or nil
    if not rot then
        rot = safe(function() return player_tf:call("get_Rotation") end)
    end
    local fwd = rot and quat_rotate_vec3(rot, Vector3f.new(0.0, 0.0, 1.0)) or Vector3f.new(0.0, 0.0, 1.0)
    return vec3_normalize(fwd) or Vector3f.new(0.0, 0.0, 1.0)
end

local function get_joint_forward_world(joint)
    if not joint then return nil end
    local rot = safe(function() return joint:call("get_Rotation") end)
    if not rot then return nil end
    return vec3_normalize(quat_rotate_vec3(rot, Vector3f.new(0.0, 0.0, 1.0)))
end

local function get_side_gate_forward(player_tf, side_key, spine_fwd)
    if CFG.use_side_forward_gate ~= true or not player_tf then
        return spine_fwd
    end
    local bone = BONES[side_key]
    if not bone then return spine_fwd end
    local clavicle = safe(function() return player_tf:call("getJointByName", bone.clavicle) end)
    local upper = safe(function() return player_tf:call("getJointByName", bone.upper) end)
    local fwd = get_joint_forward_world(clavicle) or get_joint_forward_world(upper)
    return fwd or spine_fwd
end

local function get_clavicle_slide_forward_world(clavicle_joint, spine_fwd)
    local parent = clavicle_joint and safe(function() return clavicle_joint:call("get_Parent") end) or nil
    local parent_rot = parent and safe(function() return parent:call("get_Rotation") end) or nil
    if parent_rot then
        local fwd = vec3_normalize(quat_rotate_vec3(parent_rot, Vector3f.new(0.0, 0.0, 1.0)))
        if fwd then return fwd end
    end
    return get_joint_forward_world(clavicle_joint) or spine_fwd
end

local function get_left_reach_target()
    local pos, _ = get_raw_hand_target("left")
    local blend = tonumber(rawget(_G, "__vr_slide_dock_blend_factor")) or 0
    local slide_pos = rawget(_G, "__vr_slide_hand_world_pos")
    if blend <= 0.001 or not vec3_valid(slide_pos) then
        return apply_pump_hand_world_offset(pos)
    end
    if not vec3_valid(pos) then
        return apply_pump_hand_world_offset(Vector3f.new(slide_pos.x, slide_pos.y, slide_pos.z))
    end
    return apply_pump_hand_world_offset(Vector3f.new(
        pos.x + (slide_pos.x - pos.x) * blend,
        pos.y + (slide_pos.y - pos.y) * blend,
        pos.z + (slide_pos.z - pos.z) * blend))
end

local function refresh_hand_targets()
    hand_targets.L = get_left_reach_target()
    hand_targets.R = select(1, get_raw_hand_target("right"))
end

local function compute_side_stretch_shift(side_key, hand_pos, player_tf, spine_fwd, slack, docked, large_weapon)
    if not hand_pos or not player_tf then return 0.0 end

    local bone = BONES[side_key]
    if not bone then return 0.0 end

    local upper_joint = safe(function() return player_tf:call("getJointByName", bone.upper) end)
    local lower_joint = safe(function() return player_tf:call("getJointByName", bone.lower) end)
    local wrist_joint = safe(function() return player_tf:call("getJointByName", bone.wrist) end)
    if not upper_joint or not lower_joint then return 0.0 end

    local up = safe(function() return upper_joint:call("get_Position") end)
    local lp = safe(function() return lower_joint:call("get_Position") end)
    if not up or not lp then return 0.0 end

    local wp = wrist_joint and safe(function() return wrist_joint:call("get_Position") end) or nil
    local hp = wp
    local upper_len = clampf(vec3_distance(up, lp), 0.18, 0.45)
    local lower_len = hp and clampf(vec3_distance(lp, hp), 0.18, 0.45) or 0.24

    local max_r = upper_len + lower_len - slack
    if max_r < 0.05 then max_r = upper_len + lower_len - 1e-4 end

    local pre = clampf(tonumber(CFG.prestart_m) or 0.0, 0.0, 0.12)
    local max_stretch = clampf(tonumber(CFG.max_m) or 0.0, 0.0, 0.40)
    local gate_min = clampf(tonumber(CFG.forward_gate_min) or 0.0, 0.0, 1.0)
    if side_key == "L" and slide_left_arm_ik_locked() then
        gate_min = 0.0
    end
    local gate_fwd = get_side_gate_forward(player_tf, side_key, spine_fwd)

    local left_stretch_boost = side_key == "L"
        and CFG.twohand_boost_enabled == true
        and (docked or slide_left_arm_ik_locked())
        and large_weapon
    if left_stretch_boost then
        max_stretch = clampf(max_stretch + clampf(CFG.twohand_l_extra_max_m or 0.0, 0.0, 0.40), 0.0, 0.60)
        pre = clampf(pre + clampf(CFG.twohand_l_extra_prestart_m or 0.0, 0.0, 0.12), 0.0, 0.18)
    end

    local d = vec3_distance(up, hand_pos)
    local overflow = d - (max_r - pre)
    if overflow <= 1e-4 then return 0.0 end

    local dir = vec3_normalize(vec3_subtract(hand_pos, up))
    if not dir then return 0.0 end

    local gate_side = vec3_dot(dir, gate_fwd)
    local gate_spine = vec3_dot(dir, spine_fwd)
    local gate_f = math.max(gate_side, gate_spine)
    if gate_f < gate_min then return 0.0 end

    return clampf(overflow, 0.0, max_stretch)
end

--- base_local + parent-local delta along clavicle parent +Z (stable on mirrored rigs).
local function apply_clavicle_stretch_offset(clavicle_joint, side_key, frame_id, shift_m, spine_fwd)
    if not clavicle_joint or not shift_m or shift_m < 1e-5 then return end

    local slide_fwd = get_clavicle_slide_forward_world(clavicle_joint, spine_fwd)
    local parent = safe(function() return clavicle_joint:call("get_Parent") end)
    local parent_rot = parent and safe(function() return parent:call("get_Rotation") end) or nil
    local inv_parent_rot = parent_rot and quat_inverse(parent_rot) or nil
    local world_delta = vec3_scale(slide_fwd, shift_m)
    local local_delta = inv_parent_rot and quat_rotate_vec3(inv_parent_rot, world_delta) or world_delta

    local base_local = safe(function() return clavicle_joint:call("get_BaseLocalPosition") end)
    if not base_local then
        if stretch_base_frame == frame_id and stretch_base_local[side_key] ~= nil then
            base_local = stretch_base_local[side_key]
        else
            base_local = safe(function() return clavicle_joint:call("get_LocalPosition") end)
            if base_local then
                stretch_base_local[side_key] = base_local
                stretch_base_frame = frame_id
            end
        end
    end
    if not base_local then return end

    local out_local = Vector3f.new(
        base_local.x + (local_delta.x or 0.0),
        base_local.y + (local_delta.y or 0.0),
        base_local.z + (local_delta.z or 0.0)
    )
    pcall(function() clavicle_joint:call("set_LocalPosition", out_local) end)
end

local function apply_clavicle_stretch_world_dir(clavicle_joint, side_key, frame_id, shift_m, world_dir)
    if not clavicle_joint or not shift_m or shift_m < 1e-5 or not vec3_valid(world_dir) then return end
    world_dir = vec3_normalize(world_dir)
    if not world_dir then return end

    local parent = safe(function() return clavicle_joint:call("get_Parent") end)
    local parent_rot = parent and safe(function() return parent:call("get_Rotation") end) or nil
    local inv_parent_rot = parent_rot and quat_inverse(parent_rot) or nil
    local world_delta = vec3_scale(world_dir, shift_m)
    local local_delta = inv_parent_rot and quat_rotate_vec3(inv_parent_rot, world_delta) or world_delta

    local base_local = safe(function() return clavicle_joint:call("get_BaseLocalPosition") end)
    if not base_local then
        if stretch_base_frame == frame_id and stretch_base_local[side_key] ~= nil then
            base_local = stretch_base_local[side_key]
        else
            base_local = safe(function() return clavicle_joint:call("get_LocalPosition") end)
            if base_local then
                stretch_base_local[side_key] = base_local
                stretch_base_frame = frame_id
            end
        end
    end
    if not base_local then return end

    local out_local = Vector3f.new(
        base_local.x + (local_delta.x or 0.0),
        base_local.y + (local_delta.y or 0.0),
        base_local.z + (local_delta.z or 0.0)
    )
    pcall(function() clavicle_joint:call("set_LocalPosition", out_local) end)
end

local function apply_slide_dock_shoulder_follow(player_tf, hand_pos)
    if not player_tf or not vec3_valid(hand_pos) then return end

    local bone = BONES.L
    local clav = safe(function() return player_tf:call("getJointByName", bone.clavicle) end)
    local upper = safe(function() return player_tf:call("getJointByName", bone.upper) end)
    local lower = safe(function() return player_tf:call("getJointByName", bone.lower) end)
    local wrist = safe(function() return player_tf:call("getJointByName", bone.wrist) end)
    if not clav or not upper or not lower then return end

    local last_need = 0.0
    for _ = 1, 2 do
        local shoulder = safe(function() return upper:call("get_Position") end)
        local lp = safe(function() return lower:call("get_Position") end)
        if not shoulder or not lp then break end

        local wp = wrist and safe(function() return wrist:call("get_Position") end) or nil
        local upper_len = clampf(vec3_distance(shoulder, lp), 0.18, 0.45)
        local lower_len = wp and lp and clampf(vec3_distance(lp, wp), 0.18, 0.45) or 0.24
        local max_r = upper_len + lower_len - SLIDE_ARM_SLACK
        if max_r < 0.05 then max_r = upper_len + lower_len - 1e-4 end

        local to_hand = vec3_subtract(hand_pos, shoulder)
        local d = vec3_length(to_hand)
        if d <= max_r then
            last_need = 0.0
            break
        end

        local dir = vec3_normalize(to_hand)
        if not dir then break end

        local need = clampf(d - max_r, 0.0, SLIDE_DOCK_SHOULDER_MAX_PUSH)
        last_need = need
        if need <= 1e-5 then break end

        local clav_pos = safe(function() return clav:call("get_Position") end)
        if not clav_pos then break end

        safe(function()
            clav:call("set_Position", vec3_add(clav_pos, vec3_scale(dir, need)))
        end)
    end
    stretch_smoothed.L = last_need
end

local function apply_immediate_left_clavicle_stretch(player_tf, hand_pos)
    apply_slide_dock_shoulder_follow(player_tf, hand_pos)
end

local function smooth_exp_alpha()
    local now_t = os.clock()
    local dt = 0.0
    if stretch_last_t ~= nil then
        dt = math.max(0.0, now_t - stretch_last_t)
    end
    stretch_last_t = now_t
    if dt > 0.20 then dt = 0.20 end
    local tau = math.max(0.001, tonumber(CFG.tau_s) or 0.10)
    return 1.0 - math.exp(-dt / tau)
end

local function update_smooth_for_side(side_key, hand_pos, player_tf, spine_fwd, slack, docked, large_weapon, smooth_alpha)
    if not hand_pos or not player_tf or not smooth_alpha or smooth_alpha < 1e-8 then return end
    if side_key == "L" and slide_left_arm_ik_locked() then
        return
    end

    local target_shift = compute_side_stretch_shift(
        side_key, hand_pos, player_tf, spine_fwd, slack, docked, large_weapon)
    local cur = stretch_smoothed[side_key] or 0.0
    stretch_smoothed[side_key] = cur + (target_shift - cur) * smooth_alpha
end

local function apply_reach_stretch(player_tf, do_smooth)
    if not CFG.enabled or not player_tf then return end

    refresh_hand_targets()
    local lh, rh = hand_targets.L, hand_targets.R
    if not lh and not rh then return end

    local frame_id = get_frame_id()
    if frame_id ~= stretch_base_frame then
        stretch_base_local.L, stretch_base_local.R = nil, nil
        stretch_base_frame = frame_id
    end

    local spine_fwd = get_spine_forward(player_tf)
    local slack = clampf(tonumber(CFG.slack) or 0.018, 0.0, 0.12)
    local docked = support_hand_docked() or slide_left_arm_ik_locked()
    local large_weapon = is_large_weapon_equipped()

    local smooth_alpha = 0.0
    if do_smooth == true and frame_id ~= stretch_smooth_last_frame then
        stretch_smooth_last_frame = frame_id
        smooth_alpha = smooth_exp_alpha()
        if lh and not slide_left_arm_ik_locked() then
            update_smooth_for_side("L", lh, player_tf, spine_fwd, slack, docked, large_weapon, smooth_alpha)
        end
        if rh then update_smooth_for_side("R", rh, player_tf, spine_fwd, slack, docked, large_weapon, smooth_alpha) end
    end

    local function do_side(side_key, hand_pos)
        if not hand_pos then return end
        if side_key == "L" and slide_left_arm_ik_locked() then return end
        local bone = BONES[side_key]
        if not bone then return end

        local cur = stretch_smoothed[side_key] or 0.0
        if cur < 1e-5 then return end

        local clavicle_joint = safe(function() return player_tf:call("getJointByName", bone.clavicle) end)
        apply_clavicle_stretch_offset(clavicle_joint, side_key, frame_id, cur, spine_fwd)
    end

    do_side("L", lh)
    do_side("R", rh)
end

local function call_slide_hand_follow()
    local frame_id = get_frame_id()
    if slide.hand_follow_frame == frame_id then return end
    slide.hand_follow_frame = frame_id
    local sd = rawget(_G, "__vr_reload_slide_dock")
    if sd and type(sd.tick_hand_follow) == "function" then
        pcall(sd.tick_hand_follow)
    end
end

local function check_player_changed()
    local tf = get_player_transform()
    if tf == nil then return end
    if cached_player_tf ~= nil and tf ~= cached_player_tf then
        reset_stretch_state()
    end
    cached_player_tf = tf
end

local function on_stretch_pass(do_smooth)
    if not vr_active() then
        reset_stretch_state()
        return
    end
    call_slide_hand_follow()
    check_player_changed()
    publish_vr_hand_globals()
    local player_tf = get_player_transform()
    if not player_tf then return end
    apply_reach_stretch(player_tf, do_smooth)
end

-- IkArmFit: read TargetMatrix (FirstPerson hand IK target) and stretch before solve.
local function ensure_wrist_hashes()
    if wrist_hash.L ~= nil and wrist_hash.R ~= nil then return end
    if via_murmur_hash_calc32 == nil then return end
    local ok_l, h_l = pcall(function() return via_murmur_hash_calc32:call(nil, "l_arm_wrist", 0) end)
    local ok_r, h_r = pcall(function() return via_murmur_hash_calc32:call(nil, "r_arm_wrist", 0) end)
    if ok_l then wrist_hash.L = h_l end
    if ok_r then wrist_hash.R = h_r end
end

local function get_arm_fit_data(arm_fit)
    if arm_fit == nil then return nil end
    local arm_fit_list = nil
    pcall(function() arm_fit_list = arm_fit:get_field("ArmFitList") end)
    if arm_fit_list == nil then return nil end
    if type(arm_fit_list.get_element) == "function" then
        local ok, elem = pcall(function() return arm_fit_list:get_element(0) end)
        if ok and elem ~= nil then return elem end
    end
    local elems = nil
    pcall(function() elems = arm_fit_list:get_elements() end)
    if elems and #elems > 0 then return elems[1] end
    return nil
end

local function get_wrist_side_from_apply_joint(arm_fit)
    ensure_wrist_hashes()
    local solver_list = nil
    pcall(function() solver_list = arm_fit:get_field("<SolverList>k__BackingField") end)
    if solver_list == nil then return nil end
    local raw_list = nil
    pcall(function() raw_list = solver_list:get_field("data") end)
    if raw_list == nil then return nil end
    local solver = nil
    if type(raw_list.get_element) == "function" then
        local ok, s = pcall(function() return raw_list:get_element(0) end)
        if ok then solver = s end
    end
    if solver == nil then
        local elems = nil
        pcall(function() elems = raw_list:get_elements() end)
        if elems and #elems > 0 then solver = elems[1] end
    end
    if solver == nil then return nil end
    local apply_joint = nil
    pcall(function() apply_joint = solver:get_field("<ApplyJoint>k__BackingField") end)
    if apply_joint == nil then
        pcall(function() apply_joint = solver:get_field("ApplyJoint") end)
    end
    if apply_joint == nil then return nil end
    local joint_hash = nil
    pcall(function() joint_hash = apply_joint:call("get_NameHash") end)
    if joint_hash == nil then return nil end
    if wrist_hash.R ~= nil and joint_hash == wrist_hash.R then return "right" end
    if wrist_hash.L ~= nil and joint_hash == wrist_hash.L then return "left" end
    return nil
end

local function get_wrist_side_for_ik_call(arm_fit)
    if sim_frame ~= ik.last_frame then
        ik.calls_this_frame = 0
        ik.last_frame = sim_frame
    end
    ik.calls_this_frame = ik.calls_this_frame + 1
    local side = get_wrist_side_from_apply_joint(arm_fit)
    if side ~= nil then return side end
    if ik.calls_this_frame == 1 then return "left" end
    if ik.calls_this_frame == 2 then return "right" end
    return nil
end

local function ensure_target_matrix_field_offset(arm_fit_data)
    if ik.target_matrix_offset ~= nil then return ik.target_matrix_offset end
    if arm_fit_data == nil then return nil end
    local td = arm_fit_data:get_type_definition()
    if td == nil then return nil end
    for _, field_name in ipairs({ "<TargetMatrix>k__BackingField", "TargetMatrix" }) do
        local field = td:get_field(field_name)
        if field ~= nil then
            local ok, offset = pcall(function() return field:get_offset_from_base() end)
            if ok and type(offset) == "number" and offset >= 0 then
                ik.target_matrix_offset = offset
                return offset
            end
        end
    end
    return nil
end

local function read_target_matrix_position(arm_fit_data)
    if arm_fit_data == nil then return nil end
    local offset = ensure_target_matrix_field_offset(arm_fit_data)
    if offset ~= nil then
        local x = arm_fit_data:read_float(offset + 48)
        local y = arm_fit_data:read_float(offset + 52)
        local z = arm_fit_data:read_float(offset + 56)
        if type(x) == "number" and type(y) == "number" and type(z) == "number" then
            return Vector3f.new(x, y, z)
        end
    end
    for _, name in ipairs({ "<TargetMatrix>k__BackingField", "TargetMatrix" }) do
        local ok, matrix = pcall(function() return arm_fit_data:get_field(name) end)
        if ok and matrix ~= nil and matrix[3] ~= nil then
            return Vector3f.new(matrix[3].x, matrix[3].y, matrix[3].z)
        end
    end
    return nil
end

local function write_target_matrix_position(arm_fit_data, pos)
    if arm_fit_data == nil or not vec3_valid(pos) then return false end
    local offset = ensure_target_matrix_field_offset(arm_fit_data)
    if offset ~= nil then
        arm_fit_data:write_float(offset + 48, pos.x)
        arm_fit_data:write_float(offset + 52, pos.y)
        arm_fit_data:write_float(offset + 56, pos.z)
    end
    for _, name in ipairs({ "<TargetMatrix>k__BackingField", "TargetMatrix" }) do
        local ok, matrix = pcall(function() return arm_fit_data:get_field(name) end)
        if ok and matrix ~= nil and matrix[3] ~= nil then
            matrix[3].x = pos.x
            matrix[3].y = pos.y
            matrix[3].z = pos.z
            pcall(function() arm_fit_data:set_field(name, matrix) end)
            return true
        end
    end
    return offset ~= nil
end

local function quat_bone_x_along_dir(bone_dir, pole_hint)
    local x = vec3_normalize(bone_dir)
    if not x then return nil end
    local p = vec3_normalize(pole_hint)
    if not p then p = Vector3f.new(0.0, 1.0, 0.0) end

    local z = vec3_cross(p, x)
    local zl = vec3_length(z)
    if zl < 1e-5 then
        z = vec3_cross(Vector3f.new(0.0, 1.0, 0.0), x)
        zl = vec3_length(z)
    end
    if zl < 1e-5 then return nil end
    z = vec3_scale(z, 1.0 / zl)

    local y = vec3_cross(z, x)
    local yl = vec3_length(y)
    if yl < 1e-5 then return nil end
    y = vec3_scale(y, 1.0 / yl)

    local m00, m01, m02 = x.x, y.x, z.x
    local m10, m11, m12 = x.y, y.y, z.y
    local m20, m21, m22 = x.z, y.z, z.z
    local trace = m00 + m11 + m22
    local qw, qx, qy, qz

    if trace > 0 then
        local s = 0.5 / math.sqrt(trace + 1.0)
        qw = 0.25 / s
        qx = (m21 - m12) * s
        qy = (m02 - m20) * s
        qz = (m10 - m01) * s
    elseif m00 > m11 and m00 > m22 then
        local s = 2.0 * math.sqrt(1.0 + m00 - m11 - m22)
        qw = (m21 - m12) / s
        qx = 0.25 * s
        qy = (m01 + m10) / s
        qz = (m02 + m20) / s
    elseif m11 > m22 then
        local s = 2.0 * math.sqrt(1.0 + m11 - m00 - m22)
        qw = (m02 - m20) / s
        qx = (m01 + m10) / s
        qy = 0.25 * s
        qz = (m12 + m21) / s
    else
        local s = 2.0 * math.sqrt(1.0 + m22 - m00 - m11)
        qw = (m10 - m01) / s
        qx = (m02 + m20) / s
        qy = (m12 + m21) / s
        qz = 0.25 * s
    end

    local q = Quaternion.new(qw, qx, qy, qz)
    local ok, n = pcall(function() return q:normalized() end)
    return (ok and n) or q
end

local function solve_arm_ik(shoulder_pos, hand_pos, upper_len, lower_len, pole_vector, bend_sign)
    bend_sign = (bend_sign == nil) and 1.0 or bend_sign
    if not shoulder_pos or not hand_pos or not pole_vector then return nil, nil end
    if upper_len < 1e-4 or lower_len < 1e-4 then return nil, nil end

    local w = vec3_subtract(hand_pos, shoulder_pos)
    local dist = vec3_length(w)
    if dist < 1e-6 then return nil, nil end

    local max_reach = upper_len + lower_len - SLIDE_IK_REACH_SLACK
    if max_reach < 1e-3 then max_reach = upper_len + lower_len - 1e-4 end
    local reach = math.min(dist, max_reach - 1e-4)
    if reach < 1e-4 then return nil, nil end

    local to_target = vec3_normalize(vec3_scale(w, 1.0 / dist))
    if not to_target then return nil, nil end

    local effector = vec3_add(shoulder_pos, vec3_scale(to_target, reach))

    local cos_shoulder = (upper_len * upper_len + reach * reach - lower_len * lower_len) / (2.0 * upper_len * reach)
    cos_shoulder = clampf(cos_shoulder, -1.0, 1.0)
    local sin_shoulder = math.sqrt(math.max(0.0, 1.0 - cos_shoulder * cos_shoulder))

    local pole_planar = vec3_reject_normalize(pole_vector, to_target) or pole_vector
    local n = vec3_cross(pole_planar, to_target)
    local nl = vec3_length(n)
    if nl < 1e-5 then
        n = vec3_cross(pole_planar, Vector3f.new(0.0, 1.0, 0.0))
        nl = vec3_length(n)
    end
    if nl < 1e-5 then return nil, nil end
    n = vec3_scale(n, 1.0 / nl)

    local perp = vec3_cross(n, to_target)
    local pl = vec3_length(perp)
    if pl < 1e-5 then return nil, nil end
    perp = vec3_scale(perp, bend_sign / pl)

    local function dirs_from_perp(pu)
        local ud = vec3_normalize(vec3_add(
            vec3_scale(to_target, cos_shoulder),
            vec3_scale(pu, sin_shoulder)
        ))
        if not ud then return nil, nil end
        local elbow_seed = vec3_add(shoulder_pos, vec3_scale(ud, upper_len))
        local fr = vec3_normalize(vec3_subtract(effector, elbow_seed))
        if not fr then return nil, nil end
        return ud, fr
    end

    local upper_dir, fore = dirs_from_perp(perp)
    if not upper_dir or not fore then return nil, nil end

    local elbow_pos = vec3_add(shoulder_pos, vec3_scale(upper_dir, upper_len))
    local reaching_low = hand_pos.y < shoulder_pos.y - 0.06
    local elbow_too_high = elbow_pos.y > shoulder_pos.y - 0.03
    if reaching_low and elbow_too_high then
        local perp2 = vec3_scale(perp, -1.0)
        local ud2, fr2 = dirs_from_perp(perp2)
        if ud2 and fr2 then
            upper_dir, fore = ud2, fr2
        end
    end

    return upper_dir, fore
end

local function mix_bone_pole_vector(ud, fd, pole_vector, mix)
    mix = clampf(tonumber(mix) or 0.0, 0.0, 1.0)
    local pole_blended = pole_vector
    local elbow_axis = vec3_normalize(vec3_cross(ud, fd))
    if elbow_axis then
        local pole_mix = vec3_normalize(vec3_add(
            vec3_scale(elbow_axis, mix),
            vec3_scale(pole_vector, 1.0 - mix)
        ))
        if pole_mix then pole_blended = pole_mix end
    end
    return pole_blended
end

local function mix_elbow_pole_vector(ud, fd, pole_vector, elbow_pole_mix)
    return mix_bone_pole_vector(ud, fd, pole_vector, elbow_pole_mix)
end

local function ik_world_rotations_from_dirs(upper_dir, fore, pole_vector, bone_axis_flip, elbow_pole_mix, upper_pole_mix)
    bone_axis_flip = (bone_axis_flip == nil) and 1.0 or bone_axis_flip
    local ud = vec3_scale(upper_dir, bone_axis_flip)
    local fd = vec3_scale(fore, bone_axis_flip)
    local pole_upper = mix_bone_pole_vector(ud, fd, pole_vector, upper_pole_mix or 0.0)
    local q_upper = quat_bone_x_along_dir(ud, pole_upper)
    if not q_upper then return nil, nil end

    local pole_lower = mix_bone_pole_vector(ud, fd, pole_vector, elbow_pole_mix)
    local q_lower = quat_bone_x_along_dir(fd, pole_lower)
    if not q_lower then return nil, nil end
    return q_upper, q_lower
end

local function quat_blend(a, b, t)
    if not b then return a end
    if not a then return b end
    t = clampf(t, 0.0, 1.0)
    if t <= 0.001 then return a end
    if t >= 0.999 then return b end
    local ok, out = pcall(function() return a:slerp(b, t) end)
    if ok and out then return out end
    ok, out = pcall(function() return a:nlerp(b, t) end)
    if ok and out then return out end
    return b
end

local function apply_rot_to_joint(joint, world_rot)
    if not joint or not world_rot then return end
    local parent = safe(function() return joint:call("get_Parent") end)
    if parent then
        local parent_rot = safe(function() return parent:call("get_Rotation") end)
        local inv = parent_rot and quat_inverse(parent_rot)
        local local_rot = inv and safe(function() return (inv * world_rot):normalized() end)
        if local_rot then
            safe(function() joint:call("set_LocalRotation", local_rot) end)
            return
        end
    end
    safe(function() joint:call("set_Rotation", world_rot) end)
end

local function apply_dock_bone_twist_offset(joint, bone_spec, blend)
    if not joint or type(bone_spec) ~= "table" then return end
    local t = clampf(blend, 0.0, 1.0)
    local px = (tonumber(bone_spec.pos_x) or 0.0) * t
    local py = (tonumber(bone_spec.pos_y) or 0.0) * t
    local pz = (tonumber(bone_spec.pos_z) or 0.0) * t
    if math.abs(px) > 1e-6 or math.abs(py) > 1e-6 or math.abs(pz) > 1e-6 then
        local lp = safe(function() return joint:call("get_LocalPosition") end)
        if lp then
            pcall(function()
                joint:call("set_LocalPosition", Vector3f.new(lp.x + px, lp.y + py, lp.z + pz))
            end)
        end
    end
    local pitch = (tonumber(bone_spec.pitch) or tonumber(bone_spec.rot_pitch) or 0.0) * t
    local yaw = (tonumber(bone_spec.yaw) or tonumber(bone_spec.rot_yaw) or 0.0) * t
    local roll = (tonumber(bone_spec.roll) or tonumber(bone_spec.rot_roll) or 0.0) * t
    if math.abs(pitch) < 1e-4 and math.abs(yaw) < 1e-4 and math.abs(roll) < 1e-4 then
        return
    end
    local cur = safe(function() return joint:call("get_Rotation") end)
    local off_q = quat_from_euler_deg(pitch, yaw, roll)
    if cur and off_q then
        local out = quat_mul(cur, off_q)
        if out then apply_rot_to_joint(joint, out) end
    end
end

local LEFT_WRIST_JOINT_NAMES = {
    "l_arm_wrist", "L_Arm_Wrist", "L_Arm_Hand", "l_hand_palm", "L_Hand_Palm",
}

local function get_left_arm_pole_world(char_rot)
    local world_down = Vector3f.new(0.0, -1.0, 0.0)
    if not char_rot then return world_down end
    local char_right = quat_rotate_vec3(char_rot, Vector3f.new(1.0, 0.0, 0.0))
    local char_fwd = quat_rotate_vec3(char_rot, Vector3f.new(0.0, 0.0, 1.0))
    local char_down = quat_rotate_vec3(char_rot, Vector3f.new(0.0, -1.0, 0.0))
    local char_back = vec3_scale(char_fwd, -1.0)
    local blend = vec3_add(
        vec3_add(vec3_scale(char_right, 0.42), vec3_scale(char_down, 0.42)),
        vec3_scale(char_back, 0.14)
    )
    return vec3_normalize(blend) or char_down
end

local function get_slide_dock_pole(player_tf)
    local char_rot = player_tf and safe(function() return player_tf:call("get_Rotation") end) or nil
    local body_pole = get_left_arm_pole_world(char_rot)
    local rack_active = rawget(_G, "__vr_slide_rack_active") == true
    local target = body_pole

    if not rack_active then
        local weapon_pole = rawget(_G, "__vr_slide_dock_ik_pole")
        if vec3_valid(weapon_pole) then
            local mix = vec3_normalize(vec3_add(
                vec3_scale(weapon_pole, 0.20),
                vec3_scale(body_pole, 0.80)
            ))
            if mix then target = mix end
        end
    end

    if not vec3_valid(target) then
        target = get_spine_forward(player_tf)
    end

    if not vec3_valid(slide.pole_smoothed) then
        slide.pole_smoothed = Vector3f.new(target.x, target.y, target.z)
    else
        local alpha = rack_active and 0.07 or 0.16
        local sm = vec3_normalize(vec3_add(
            vec3_scale(slide.pole_smoothed, 1.0 - alpha),
            vec3_scale(target, alpha)
        ))
        if sm then slide.pole_smoothed = sm end
    end

    return slide.pole_smoothed or target
end

local function apply_slide_dock_hand_rotation(player_tf, wrist, hand_rot, rot_blend)
    if not hand_rot or rot_blend <= 0.001 then return end
    local arm_snap = rawget(_G, "__vr_slide_dock_arm_snap")
    local function apply_joint(joint, snap_key)
        if not joint then return end
        local from_rot = arm_snap and snap_key and arm_snap[snap_key]
        if not from_rot then
            from_rot = safe(function() return joint:call("get_Rotation") end)
        end
        local blended = quat_blend(from_rot, hand_rot, rot_blend)
        if blended then apply_rot_to_joint(joint, blended) end
    end
    apply_joint(wrist, "wrist")
    local hand = safe(function() return player_tf:call("getJointByName", "L_Arm_Hand") end)
    if hand and hand ~= wrist then
        apply_joint(hand, "wrist")
    end
end

local function measure_arm_reach(player_tf, side_key)
    local bone = BONES[side_key]
    if not bone then return 0.42 end
    local upper = safe(function() return player_tf:call("getJointByName", bone.upper) end)
    local lower = safe(function() return player_tf:call("getJointByName", bone.lower) end)
    local wrist = safe(function() return player_tf:call("getJointByName", bone.wrist) end)
    if not upper or not lower then return 0.42 end
    local up = safe(function() return upper:call("get_Position") end)
    local lp = safe(function() return lower:call("get_Position") end)
    if not up or not lp then return 0.42 end
    local wp = wrist and safe(function() return wrist:call("get_Position") end) or nil
    local upper_len = clampf(vec3_distance(up, lp), 0.18, 0.45)
    local lower_len = wp and clampf(vec3_distance(lp, wp), 0.18, 0.45) or 0.24
    return math.max(upper_len + lower_len - SLIDE_ARM_SLACK, 0.05)
end

local function effective_slide_dock_arm_blend(blend, rack_active)
    blend = clampf(tonumber(blend) or 0, 0.0, 1.0)
    if rack_active then return blend end
    if rawget(_G, "__vr_pump_fp_passthrough") == true then return 0.0 end
    if rawget(_G, "__vr_pump_slide_support") == true then return blend end
    return blend
end

local function sync_fp_left_hand_block()
    if firstpersonmod == nil or type(firstpersonmod.set_block_left_hand_ik) ~= "function" then
        return
    end
    local blend, _, _, rack_active = slide.get_dock_state()
    local pump_support = rawget(_G, "__vr_pump_slide_support") == true
    local arm_blend = effective_slide_dock_arm_blend(blend, rack_active)
    local want = (pump_support and blend > 0.02)
        or arm_blend > 0.15
        or rawget(_G, "__vr_left_hand_pose_slide_active") == true
        or rack_active
        or (rawget(_G, "__vr_block_empty_pump_reload_motion") == true
            and rawget(_G, "__vr_needs_pump") ~= true
            and rawget(_G, "__vr_pump_active") ~= true)
    if rawget(_G, "__vr_fp_left_hand_blocked") == want then return end
    pcall(function() firstpersonmod:set_block_left_hand_ik(want) end)
    rawset(_G, "__vr_fp_left_hand_blocked", want)
end

local function restore_fp_left_hand_block()
    if firstpersonmod == nil or type(firstpersonmod.set_block_left_hand_ik) ~= "function" then
        return
    end
    if rawget(_G, "__vr_fp_left_hand_blocked") ~= true then return end
    pcall(function() firstpersonmod:set_block_left_hand_ik(false) end)
    rawset(_G, "__vr_fp_left_hand_blocked", false)
end

_G.__vr_restore_fp_left_hand_block = restore_fp_left_hand_block

local function blend_vec3_toward(from_pos, to_pos, blend)
    if not vec3_valid(from_pos) or not vec3_valid(to_pos) then return from_pos end
    if blend >= 0.999 then
        return Vector3f.new(to_pos.x, to_pos.y, to_pos.z)
    end
    return Vector3f.new(
        from_pos.x + (to_pos.x - from_pos.x) * blend,
        from_pos.y + (to_pos.y - from_pos.y) * blend,
        from_pos.z + (to_pos.z - from_pos.z) * blend)
end

local function get_left_wrist_joint(player_tf)
    if not player_tf then return nil end
    for _, name in ipairs(LEFT_WRIST_JOINT_NAMES) do
        local joint = safe(function() return player_tf:call("getJointByName", name) end)
        if joint then return joint end
    end
    return nil
end

local function read_joint_world_rot(joint)
    if not joint then return nil end
    return safe(function() return joint:call("get_Rotation") end)
end

local function get_left_hand_blend_source_pos()
    publish_vr_hand_globals()
    local lw = rawget(_G, "__vr_lh_world")
    if vec3_valid(lw) then
        return Vector3f.new(lw.x, lw.y, lw.z)
    end
    local fp = get_fp_style_hand_world_pos("left")
    if vec3_valid(fp) then return fp end
    local ctrl = get_vr_controller_world_pos("left")
    if vec3_valid(ctrl) then return ctrl end
    if rawget(_G, "__vr_lh_slide_ik_override") ~= true then
        local joint_pos = rawget(_G, "__vr_lh_joint_pos")
        if vec3_valid(joint_pos) then
            return Vector3f.new(joint_pos.x, joint_pos.y, joint_pos.z)
        end
    end
    local player_tf = get_player_transform()
    if player_tf then
        local wrist = get_left_wrist_joint(player_tf)
        local wp = wrist and safe(function() return wrist:call("get_Position") end)
        if vec3_valid(wp) then
            return Vector3f.new(wp.x, wp.y, wp.z)
        end
    end
    return nil
end

local function get_left_hand_blend_source_rot()
    local ctrl_rot = get_vr_controller_world_rot("left")
    if ctrl_rot then return ctrl_rot end
    local player_tf = get_player_transform()
    if player_tf then
        local wrist = get_left_wrist_joint(player_tf)
        local wr = read_joint_world_rot(wrist)
        if wr then return wr end
    end
    if rawget(_G, "__vr_lh_slide_ik_override") ~= true then
        local rot = rawget(_G, "__vr_lh_joint_rot")
        if rot then return rot end
    end
    return nil
end

local function clear_slide_dock_arm_snap()
    rawset(_G, "__vr_slide_dock_arm_snap", nil)
end

local function capture_slide_dock_arm_snap(player_tf)
    if not player_tf then
        clear_slide_dock_arm_snap()
        return
    end
    local bone = BONES.L
    local snap = {}
    local clav = safe(function() return player_tf:call("getJointByName", bone.clavicle) end)
    local upper = safe(function() return player_tf:call("getJointByName", bone.upper) end)
    local lower = safe(function() return player_tf:call("getJointByName", bone.lower) end)
    local wrist = safe(function() return player_tf:call("getJointByName", bone.wrist) end)
    local cr = read_joint_world_rot(clav)
    local ur = read_joint_world_rot(upper)
    local lr = read_joint_world_rot(lower)
    local wr = read_joint_world_rot(wrist)
    if cr then snap.clavicle = cr end
    if ur then snap.upper = ur end
    if lr then snap.lower = lr end
    if wr then snap.wrist = wr end
    if next(snap) then
        rawset(_G, "__vr_slide_dock_arm_snap", snap)
    else
        clear_slide_dock_arm_snap()
    end
end

local function capture_slide_dock_blend_origin()
    publish_vr_hand_globals()
    local pos = get_left_hand_blend_source_pos()
    if vec3_valid(pos) then
        rawset(_G, "__vr_slide_dock_blend_from_pos", Vector3f.new(pos.x, pos.y, pos.z))
    end
    local rot = get_left_hand_blend_source_rot()
    if rot then
        rawset(_G, "__vr_slide_dock_blend_from_rot", rot)
    end
    capture_slide_dock_arm_snap(get_player_transform())
end

_G.__vr_get_live_left_hand_for_slide_blend = get_left_hand_blend_source_pos
_G.__vr_get_live_left_hand_for_slide_blend_rot = get_left_hand_blend_source_rot
_G.__vr_capture_slide_dock_blend_origin = capture_slide_dock_blend_origin
_G.__vr_clear_slide_dock_arm_snap = clear_slide_dock_arm_snap

local function resolve_slide_dock_hand_target(slide_pos, blend, fallback_pos)
    if not vec3_valid(slide_pos) then return fallback_pos end
    if blend >= 0.999 then
        return Vector3f.new(slide_pos.x, slide_pos.y, slide_pos.z)
    end
    local from_pos = rawget(_G, "__vr_slide_dock_blend_from_pos")
    if not vec3_valid(from_pos) then
        from_pos = rawget(_G, "__vr_lh_world")
    end
    if not vec3_valid(from_pos) then
        from_pos = get_fp_style_hand_world_pos("left")
    end
    if not vec3_valid(from_pos) then
        from_pos = get_vr_controller_world_pos("left")
    end
    if not vec3_valid(from_pos) then
        from_pos = fallback_pos
    end
    if not vec3_valid(from_pos) then
        return Vector3f.new(slide_pos.x, slide_pos.y, slide_pos.z)
    end
    return blend_vec3_toward(from_pos, slide_pos, blend)
end

local function resolve_slide_dock_hand_rot(slide_rot, blend)
    if not slide_rot then return nil end
    if blend >= 0.999 then return slide_rot end
    local from_rot = rawget(_G, "__vr_slide_dock_blend_from_rot")
    if not from_rot then return slide_rot end
    return quat_blend(from_rot, slide_rot, blend)
end

local function apply_left_arm_ik_for_slide_dock(player_tf, hand_pos, hand_rot, blend)
    local bone = BONES.L
    local clavicle = safe(function() return player_tf:call("getJointByName", bone.clavicle) end)
    local upper = safe(function() return player_tf:call("getJointByName", bone.upper) end)
    local lower = safe(function() return player_tf:call("getJointByName", bone.lower) end)
    local wrist = safe(function() return player_tf:call("getJointByName", bone.wrist) end)
    if not upper or not lower or not wrist then return false end

    local twist = get_slide_dock_ik_twist()
    local bend_sign = twist and tonumber(twist.bend_sign) or -1.0
    if bend_sign >= 0 then bend_sign = 1.0 else bend_sign = -1.0 end
    local elbow_pole_mix = twist and twist.elbow_pole_mix or 0.58
    local upper_pole_mix = twist and twist.upper_pole_mix or 0.0
    local bone_axis_flip = 1.0
    local mit_blend = clampf(blend, 0.0, 1.0)

    hand_pos = apply_dock_hand_target_offset(player_tf, hand_pos, mit_blend)

    local shoulder = safe(function() return upper:call("get_Position") end)
    if not shoulder then return false end

    local lp = safe(function() return lower:call("get_Position") end)
    local wp = safe(function() return wrist:call("get_Position") end)
    local upper_len = lp and clampf(vec3_distance(shoulder, lp), 0.18, 0.45) or 0.28
    local lower_len = wp and lp and clampf(vec3_distance(lp, wp), 0.18, 0.45) or 0.24

    local pole = get_slide_dock_pole(player_tf)
    if twist then
        pole = apply_elbow_pole_hint(player_tf, pole, twist, mit_blend)
    end
    local rot_blend = blend
    local snap_frac = clampf((rot_blend - 0.55) / 0.45, 0.0, 1.0)

    local upper_dir, fore = solve_arm_ik(shoulder, hand_pos, upper_len, lower_len, pole, bend_sign)
    if not upper_dir or not fore then
        if twist then
            if clavicle and twist.clavicle then
                apply_dock_bone_twist_offset(clavicle, twist.clavicle, mit_blend)
            end
            if twist.upper then apply_dock_bone_twist_offset(upper, twist.upper, mit_blend) end
            if twist.lower then apply_dock_bone_twist_offset(lower, twist.lower, mit_blend) end
        end
        apply_slide_dock_hand_rotation(player_tf, wrist, hand_rot, rot_blend)
        if twist and twist.wrist then
            apply_dock_bone_twist_offset(wrist, twist.wrist, mit_blend)
        end
        return true
    end

    local q_upper, q_lower = ik_world_rotations_from_dirs(
        upper_dir, fore, pole, bone_axis_flip, elbow_pole_mix, upper_pole_mix)
    if snap_frac > 1e-4 then
        local elbow_pos = vec3_add(shoulder, vec3_scale(upper_dir, upper_len))
        local fore_exact = vec3_normalize(vec3_subtract(hand_pos, elbow_pos))
        if fore_exact then
            local ud = vec3_scale(upper_dir, bone_axis_flip)
            local fd = vec3_scale(fore_exact, bone_axis_flip)
            local pole_upper = mix_bone_pole_vector(ud, fd, pole, upper_pole_mix)
            local q_upper_snap = quat_bone_x_along_dir(ud, pole_upper)
            if q_upper_snap and q_upper then
                q_upper = quat_blend(q_upper, q_upper_snap, snap_frac)
            elseif q_upper_snap then
                q_upper = q_upper_snap
            end
            local pole_lower = mix_bone_pole_vector(ud, fd, pole, elbow_pole_mix)
            local q_lower_snap = quat_bone_x_along_dir(fd, pole_lower)
            if q_lower_snap and q_lower then
                q_lower = quat_blend(q_lower, q_lower_snap, snap_frac)
            elseif q_lower_snap then
                q_lower = q_lower_snap
            end
        end
    end

    local arm_snap = rawget(_G, "__vr_slide_dock_arm_snap")
    if arm_snap and rot_blend < 0.999 then
        if arm_snap.upper and q_upper then
            q_upper = quat_blend(arm_snap.upper, q_upper, rot_blend)
        end
        if arm_snap.lower and q_lower then
            q_lower = quat_blend(arm_snap.lower, q_lower, rot_blend)
        end
    end

    if q_upper then apply_rot_to_joint(upper, q_upper) end
    if q_lower then apply_rot_to_joint(lower, q_lower) end
    if arm_snap and rot_blend < 0.999 and arm_snap.clavicle and clavicle then
        local clav_target = read_joint_world_rot(clavicle)
        if clav_target then
            local q_clav = quat_blend(arm_snap.clavicle, clav_target, rot_blend)
            if q_clav then apply_rot_to_joint(clavicle, q_clav) end
        end
    end
    if twist then
        if clavicle and twist.clavicle then
            apply_dock_bone_twist_offset(clavicle, twist.clavicle, mit_blend)
        end
        if twist.upper then apply_dock_bone_twist_offset(upper, twist.upper, mit_blend) end
        if twist.lower then apply_dock_bone_twist_offset(lower, twist.lower, mit_blend) end
    end
    apply_slide_dock_hand_rotation(player_tf, wrist, hand_rot, rot_blend)
    if twist and twist.wrist then
        apply_dock_bone_twist_offset(wrist, twist.wrist, mit_blend)
    end
    return true
end

local function apply_slide_dock_to_left_arm(priority)
    priority = priority or 1
    if not vr_active() then return end

    call_slide_hand_follow()

    local blend, slide_pos, slide_rot, rack_active = slide.get_dock_state()
    local frame_id = get_frame_id()

    if blend <= 0.001 or not vec3_valid(slide_pos) then
        if blend <= 0.001 then
            rawset(_G, "__vr_lh_slide_ik_override", false)
            restore_fp_left_hand_block()
            slide.pole_smoothed = nil
            stretch_smoothed.L = 0.0
            clear_slide_dock_arm_snap()
        end
        return
    end

    local arm_blend = effective_slide_dock_arm_blend(blend, rack_active)
    if arm_blend <= 0.001 then
        return
    end

    if slide.dock_apply_frame == frame_id and priority < slide.dock_apply_prio then
        return
    end

    sync_fp_left_hand_block()
    rawset(_G, "__vr_lh_slide_ik_override", true)

    local player_tf = get_player_transform()
    if not player_tf then return end

    local wrist = get_left_wrist_joint(player_tf)
    local fallback_pos = wrist and safe(function() return wrist:call("get_Position") end) or nil
    local hand_pos = resolve_slide_dock_hand_target(slide_pos, blend, fallback_pos)
    if not vec3_valid(hand_pos) then return end

    local hand_rot = resolve_slide_dock_hand_rot(slide_rot, blend)

    apply_immediate_left_clavicle_stretch(player_tf, hand_pos)
    apply_left_arm_ik_for_slide_dock(player_tf, hand_pos, hand_rot, arm_blend)

    rawset(_G, "__vr_lh_joint_pos", hand_pos)
    if hand_rot then rawset(_G, "__vr_lh_joint_rot", hand_rot) end
    if blend >= 0.999 or rack_active then
        rawset(_G, "__vr_slide_rack_ik_done", true)
    end

    slide.dock_apply_frame = frame_id
    slide.dock_apply_prio = priority
end

_G.__vr_apply_slide_dock_left_arm = apply_slide_dock_to_left_arm

local function resolve_ik_arm_fit_from_args(args)
    if ik.arm_fit_type == nil then
        ik.arm_fit_type = sdk.find_type_definition(NS("IkArmFit"))
    end
    if ik.arm_fit_type == nil then return nil end
    for i = 2, 10 do
        local obj = sdk.to_managed_object(args[i])
        if obj ~= nil then
            local ok, is_fit = pcall(function() return obj:get_type_definition():is_a(ik.arm_fit_type) end)
            if ok and is_fit then return obj end
        end
    end
    return nil
end

local function on_pre_update_ik(args)
    if not vr_active() then return end

    call_slide_hand_follow()

    local arm_fit = resolve_ik_arm_fit_from_args(args)
    if arm_fit == nil then return end

    local arm_fit_data = get_arm_fit_data(arm_fit)
    if arm_fit_data == nil then return end

    local pos = read_target_matrix_position(arm_fit_data)
    local side = get_wrist_side_for_ik_call(arm_fit)
    if pos ~= nil and side == "left" then
        ik_hand_targets.L = pos
    elseif pos ~= nil and side == "right" then
        ik_hand_targets.R = pos
    end

    local player_tf = get_player_transform()
    if not player_tf then return end

    local slide_blend, slide_pos, slide_rot, rack_active = slide.get_dock_state()
    local arm_blend = effective_slide_dock_arm_blend(slide_blend, rack_active)
    if side == "left" and slide_blend > 0.001 and vec3_valid(slide_pos)
        and rawget(_G, "__vr_pump_fp_passthrough") ~= true then
        local dock_target = resolve_slide_dock_hand_target(slide_pos, slide_blend, pos)
        write_target_matrix_position(arm_fit_data, dock_target)
        ik_hand_targets.L = dock_target
        slide.left_fit_data = arm_fit_data
        rawset(_G, "__vr_lh_joint_pos", dock_target)
        local dock_rot = resolve_slide_dock_hand_rot(slide_rot, slide_blend)
        if dock_rot then rawset(_G, "__vr_lh_joint_rot", dock_rot) end
        if slide_blend > 0.02 then
            sync_fp_left_hand_block()
            rawset(_G, "__vr_lh_slide_ik_override", true)
        end
        if slide_blend >= 0.999 or rack_active then
            rawset(_G, "__vr_slide_rack_ik_done", true)
        end
        pos = dock_target
    elseif side == "left" then
        slide.left_fit_data = nil
        if slide_blend <= 0.001 then
            rawset(_G, "__vr_lh_slide_ik_override", false)
        end
    end

    apply_reach_stretch(player_tf, false)
end

local function on_post_update_ik(retval)
    local blend, slide_pos, _, rack_active = slide.get_dock_state()
    if blend > 0.001 and vec3_valid(slide_pos) then
        local arm_blend = effective_slide_dock_arm_blend(blend, rack_active)
        if arm_blend > 0.001 then
            local frame_id = get_frame_id()
            if slide.post_ik_count_frame ~= frame_id then
                slide.post_ik_count_frame = frame_id
                slide.post_ik_count = 0
            end
            slide.post_ik_count = slide.post_ik_count + 1

            if slide.left_fit_data ~= nil then
                local wrist = get_player_transform()
                local fallback = nil
                if wrist then
                    local wj = get_left_wrist_joint(wrist)
                    fallback = wj and safe(function() return wj:call("get_Position") end) or nil
                end
                local dock_target = resolve_slide_dock_hand_target(slide_pos, blend, fallback)
                if vec3_valid(dock_target) then
                    write_target_matrix_position(slide.left_fit_data, dock_target)
                end
            end

            apply_slide_dock_to_left_arm(50 + slide.post_ik_count)
            return retval
        end
    end

    return retval
end

local function install_ik_hook()
    if ik.hook_installed then return end
    ensure_wrist_hashes()

    ik.arm_fit_type = sdk.find_type_definition(NS("IkArmFit"))
    if not ik.arm_fit_type then
        if not ik.hook_warned then
            log.warn("[re2_vr_ik_extention] IkArmFit type not found")
            ik.hook_warned = true
        end
        return
    end

    local hooked = 0
    local methods = ik.arm_fit_type:get_methods()
    if methods then
        for _, method in ipairs(methods) do
            if method and method:get_name() == "updateIk" then
                sdk.hook(method, on_pre_update_ik, on_post_update_ik)
                hooked = hooked + 1
            end
        end
    end

    if hooked == 0 then
        local method = ik.arm_fit_type:get_method("updateIk")
        if method then
            sdk.hook(method, on_pre_update_ik, on_post_update_ik)
            hooked = 1
        end
    end

    if hooked == 0 then
        if not ik.hook_warned then
            log.warn("[re2_vr_ik_extention] IkArmFit.updateIk not found")
            ik.hook_warned = true
        end
        return
    end

    ik.hook_installed = true
    log.info(string.format("[re2_vr_ik_extention] Hooked IkArmFit.updateIk (%d)", hooked))
end

-- Keep VRControllerManager updating.
re.on_pre_application_entry("UpdateBehavior", function()
    if vrc_manager and vr_active() then
        pcall(function() vrc_manager:update() end)
    end
end)

re.on_pre_application_entry("UpdateMotion", function()
    sim_frame = sim_frame + 1
    on_stretch_pass(true)
end)

re.on_application_entry("UpdateMotion", function()
    on_stretch_pass(false)
end)

re.on_pre_application_entry("LateUpdateBehavior", function()
    on_stretch_pass(false)
end)

re.on_application_entry("LateUpdateBehavior", function()
    on_stretch_pass(false)
end)

re.on_frame(function()
    tick_auto_standing_height()
end)

re.on_pre_application_entry("LockScene", function()
    tick_auto_standing_height()
    on_stretch_pass(false)
end)

re.on_application_entry("LockScene", function()
    on_stretch_pass(false)
    apply_slide_dock_to_left_arm(2)
end)

re.on_application_entry("UpdateJointExpression", function()
    apply_slide_dock_to_left_arm(4)
    on_stretch_pass(false)
end)

re.on_application_entry("PrepareRendering", function()
    apply_slide_dock_to_left_arm(6)
end)

re.on_application_entry("BeginRendering", function()
    call_slide_hand_follow()
    apply_slide_dock_to_left_arm(90)
end)

re.on_application_entry("EndRendering", function()
    apply_slide_dock_to_left_arm(300)
end)

install_ik_hook()

log.info(string.format(
    "[re2_vr_ik_extention] Loaded cfg=%s VRControllerManager=%s",
    CFG_PATH,
    tostring(vrc_manager ~= nil)))

return {}
