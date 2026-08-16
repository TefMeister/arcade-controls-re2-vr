if reframework:get_game_name() ~= "re2" then
    return {}
end

if not vrmod then
    return {}
end

local re2 = require("utility/RE2")
local GameObject = require("utility/GameObject")
local vrc_manager = require("vr/VRControllerManager")
local statics = require("utility/Statics")

local CFG_PATH = "re2_vr/re2_vr_haptics.json"
local NS = sdk.game_namespace

local function imgui_col(r, g, b, a)
    a = a or 255
    return ((a & 0xFF) << 24) | ((b & 0xFF) << 16) | ((g & 0xFF) << 8) | (r & 0xFF)
end

local UI_ACCENT = imgui_col(136, 204, 255)
local UI_ENABLE = imgui_col(0, 255, 0)
local UI_DISABLE = imgui_col(255, 64, 64)

local CFG = {
    enabled = true,
    duration = 0.05,
    intensity = 0.4,
    frequency = 1.0,
    left_hand_ratio = 0.7,
    support_hand_distance = 0.15,
    use_recoil_multipliers = true,
    weapons = {},
    -- Melee: steady vibration refreshed each frame while capsule raycast reports contact.
    melee_enabled = true,
    melee_intensity = 0.55,
    melee_frequency = 140.0,
    melee_pulse_duration = 0.04,
    melee_ray_samples = 5,
    melee_swing_speed_threshold = 1.0,
    melee_swing_grace_s = 0.15,
}

local pending_haptic_shots = 0
local pending_left_hand_support = false
local fire_hooks_installed = false
local grip_action = nil
local via_motion_type = sdk.typeof("via.motion.Motion")
local survivor_condition_type = nil
local l_arm_wrist_hash = nil
local r_arm_wrist_hash = nil
local FP_GRIP_DOCK_DISTANCE_LUA = 0.15
local IK_SNAP_GRIP_DISTANCE = 0.06
local HANDS_SUPPORT_DISTANCE = 0.35

local via_murmur_hash_type = sdk.find_type_definition("via.murmur_hash")
local via_murmur_hash_calc32 = via_murmur_hash_type and via_murmur_hash_type:get_method("calc32") or nil

local LARGE_WEAPONS = {
    wp1000 = true, wp1100 = true, wp3000 = true, wp3200 = true,
    wp4100 = true, wp4400 = true, wp4600 = true, wp4610 = true, wp4700 = true,
}

-- OpenXR hand offsets (first-person arm IK)
local FP_HAND_ROT_OFFSET = {
    right = Vector3f.new(0.28, -2.982, -1.495),
}
local FP_HAND_POS_OFFSET = {
    left = Vector3f.new(-0.052, 0.084, 0.02),
    right = Vector3f.new(0.052, 0.084, 0.02),
}

local function sync_haptic_globals()
    _G.__vr_weapon_haptics_enabled = CFG.enabled
    _G.__vr_melee_haptics_enabled = CFG.melee_enabled
end

local function save_cfg()
    pcall(function()
        json.dump_file(CFG_PATH, CFG)
    end)
    sync_haptic_globals()
end

local function load_cfg_from_disk()
    local data = json.load_file(CFG_PATH)
    if type(data) ~= "table" then
        return
    end
    for k, v in pairs(data) do
        if k == "weapons" and type(v) == "table" then
            CFG.weapons = v
        elseif CFG[k] ~= nil and type(v) == type(CFG[k]) then
            CFG[k] = v
        end
    end
end

load_cfg_from_disk()
sync_haptic_globals()

if type(CFG.weapons) ~= "table" then
    CFG.weapons = {}
end

local function get_support_hand_distance()
    local d = tonumber(CFG.support_hand_distance) or 0.15
    if d < 0.05 then d = 0.05 end
    if d > 0.25 then d = 0.25 end
    return d
end

local function get_foregrip_dock_distance_threshold()
    return math.max(get_support_hand_distance(), FP_GRIP_DOCK_DISTANCE_LUA)
end

local function vec3_dist(a, b)
    if a == nil or b == nil then return 1e9 end
    if type(a.x) ~= "number" or type(b.x) ~= "number" then return 1e9 end
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function vec3_valid(p)
    return p ~= nil and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

local function vec3_add(a, b)
    return Vector3f.new(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function vec3_subtract(a, b)
    return Vector3f.new(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function quat_from_vr_rotation(rot)
    if rot == nil then return nil end
    if type(rot) == "Quaternion" then
        return rot:normalized()
    end
    if type(rot.w) == "number" then
        return Quaternion.new(rot.w, rot.x, rot.y, rot.z):normalized()
    end
    local ok, q = pcall(function() return rot:to_quat() end)
    return ok and q and q:normalized() or nil
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

local function ensure_wrist_hashes()
    if l_arm_wrist_hash ~= nil and r_arm_wrist_hash ~= nil then return end
    if via_murmur_hash_calc32 == nil then return end
    local ok_l, h_l = pcall(function() return via_murmur_hash_calc32:call(nil, "l_arm_wrist", 0) end)
    local ok_r, h_r = pcall(function() return via_murmur_hash_calc32:call(nil, "r_arm_wrist", 0) end)
    if ok_l then l_arm_wrist_hash = h_l end
    if ok_r then r_arm_wrist_hash = h_r end
end

local function get_player_via_motion(player)
    if not player or not via_motion_type then return nil end
    local motion = nil
    pcall(function()
        motion = player:call("getComponent(System.Type)", via_motion_type)
    end)
    return motion
end

local function get_camera_look_quat()
    local cam = sdk.get_primary_camera()
    if not cam then return nil end
    local ok_wm, wm = pcall(function() return cam:call("get_WorldMatrix") end)
    if not ok_wm or not wm then return nil end
    local cam_rot = wm:to_quat()
    if cam_rot == nil then return nil end
    local m = cam_rot:normalized():to_mat4()
    m[1].y = 0.0
    m[2].y = 0.0
    m[3].y = 0.0
    local ok_q, look_rot = pcall(function() return m:to_quat():normalized() end)
    return ok_q and look_rot or nil
end

--- Right-hand world rotation matching FirstPerson calculate_joint_pos_rot (look * controller * offset).
local function get_fp_style_right_hand_rotation()
    local look_rot = get_camera_look_quat()
    if look_rot == nil then return nil end

    local controllers = nil
    pcall(function() controllers = vrmod:get_controllers() end)
    if not controllers or not controllers[2] then return nil end

    local ok, rot = pcall(function() return vrmod:get_rotation(controllers[2]) end)
    if not ok or rot == nil then return nil end
    local controller_quat = quat_from_vr_rotation(rot)
    if controller_quat == nil then return nil end

    local offset_euler = FP_HAND_ROT_OFFSET.right
    local ok_off, offset_quat = pcall(function()
        return Quaternion.new(offset_euler):normalized()
    end)
    if not ok_off or offset_quat == nil then return nil end

    local ok_mul, out = pcall(function()
        return (look_rot * controller_quat * offset_quat):normalized()
    end)
    return ok_mul and out or nil
end

local function get_survivor_condition()
    local player = re2.get_localplayer()
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

local function player_is_aiming()
    local cond = get_survivor_condition()
    if not cond then return false end
    local ok, aiming = pcall(function() return cond:call("get_IsHold") end)
    return ok and aiming == true
end

local function player_is_reloading()
    if rawget(_G, "__vr_manual_reload_active") == true then return false end
    local cond = get_survivor_condition()
    if not cond then return false end
    local ok, reloading = pcall(function() return cond:call("get_IsReload") end)
    return ok and reloading == true
end

local function fp_was_gripping_weapon()
    if firstpersonmod ~= nil and type(firstpersonmod.was_gripping_weapon) == "function" then
        local ok, gripping = pcall(function() return firstpersonmod:was_gripping_weapon() end)
        if ok and gripping == true then return true end
    end
    return false
end

local function fp_left_hand_ik_blocked()
    if firstpersonmod ~= nil and type(firstpersonmod.get_block_left_hand_ik) == "function" then
        local ok, blocked = pcall(function() return firstpersonmod:get_block_left_hand_ik() end)
        if ok and blocked == true then return true end
    end
    return false
end

local function get_hand_world_pos(which)
    local key = (which == "left") and "__vr_lh_world" or "__vr_rh_world"
    local p = rawget(_G, key)
    if p ~= nil and type(p.x) == "number" then
        return p
    end
    local controllers = nil
    pcall(function() controllers = vrmod:get_controllers() end)
    if not controllers then return nil end
    local idx = (which == "left") and 1 or 2
    local ctrl = controllers[idx]
    if not ctrl then return nil end
    local ok, pos = pcall(function() return vrmod:get_position(ctrl) end)
    return ok and pos or nil
end

--- Raw tracked controller position (fallback when FP-style is unavailable).
local function get_vr_controller_world_pos(hand)
    if vrc_manager then
        local ok_has, has = pcall(function() return vrc_manager:has_controllers() end)
        if ok_has and has and vrc_manager.controllers_list then
            local list_i = (hand == "right") and 2 or 1
            local ctrl = vrc_manager.controllers_list[list_i]
            if ctrl and vec3_valid(ctrl.position) then
                return Vector3f.new(ctrl.position.x, ctrl.position.y, ctrl.position.z)
            end
        end
    end
    return get_hand_world_pos(hand)
end

--- Approximate FirstPerson calculate_joint_pos_rot world target (camera-relative controller).
local function get_fp_style_hand_world_pos(hand)
    local cam = sdk.get_primary_camera()
    if not cam then return nil end
    local ok_wm, wm = pcall(function() return cam:call("get_WorldMatrix") end)
    if not ok_wm or not wm then return nil end

    local cam_pos = Vector3f.new(wm[3].x, wm[3].y, wm[3].z)
    local cam_rot = wm:to_quat()
    if cam_rot == nil then return nil end

    local ctrl_pos = get_vr_controller_world_pos(hand)
    if not vec3_valid(ctrl_pos) then return nil end

    local hmd_pos = nil
    pcall(function() hmd_pos = vrmod:get_position(0) end)
    if not vec3_valid(hmd_pos) then
        hmd_pos = cam_pos
    end

    local offset = vec3_subtract(ctrl_pos, hmd_pos)
    local look_rot = cam_rot:normalized()
    local m = look_rot:to_mat4()
    m[1].y = 0.0
    m[2].y = 0.0
    m[3].y = 0.0
    local ok_look, flat_look = pcall(function() return m:to_quat():normalized() end)
    if not ok_look or flat_look == nil then return nil end

    local hand_pos = vec3_add(cam_pos, quat_rotate_vec3(flat_look, offset))
    local fp_off = FP_HAND_POS_OFFSET[hand]
    if fp_off then
        hand_pos = vec3_add(hand_pos, quat_rotate_vec3(flat_look, fp_off))
    end
    return hand_pos
end

local function get_weapon_go_name(weapon)
    if weapon == nil then return "" end
    local ok_go, go = pcall(function() return weapon:call("get_GameObject") end)
    if ok_go and go then
        local ok_name, name = pcall(function() return go:call("get_Name") end)
        if ok_name and type(name) == "string" and name ~= "" then return name end
    end
    return ""
end

local function is_large_weapon_equipped()
    local player = re2.get_localplayer()
    if not player then return false end
    local _, weapon = re2.get_weapon_object(player)
    if weapon == nil then return false end
    local wid = get_weapon_go_name(weapon)
    return wid ~= "" and LARGE_WEAPONS[wid] == true
end

local function hands_are_supporting_weapon()
    local lh = get_hand_world_pos("left")
    local rh = get_hand_world_pos("right")
    if lh == nil or rh == nil then return false end
    return vec3_dist(lh, rh) <= HANDS_SUPPORT_DISTANCE
end

--- Skeleton foregrip offset relative to weapon hand (cached per frame).
local skeleton_grip_cache = { frame = -1, pos_rel = nil }

local function get_skeleton_grip_offset_relative()
    local frame = -1
    if re.get_frame_count then
        local ok, n = pcall(function() return re.get_frame_count() end)
        if ok and type(n) == "number" then frame = n end
    end
    if skeleton_grip_cache.frame == frame and skeleton_grip_cache.pos_rel ~= nil then
        return skeleton_grip_cache.pos_rel
    end

    local player = re2.get_localplayer()
    if not player then return nil end
    local motion = get_player_via_motion(player)
    if motion == nil then return nil end

    ensure_wrist_hashes()
    if l_arm_wrist_hash == nil or r_arm_wrist_hash == nil then return nil end

    local left_index, right_index = nil, nil
    pcall(function() left_index = motion:call("getJointIndexByNameHash", l_arm_wrist_hash) end)
    pcall(function() right_index = motion:call("getJointIndexByNameHash", r_arm_wrist_hash) end)
    if left_index == nil or right_index == nil then return nil end

    local original_left_pos, original_right_pos, original_right_rot = nil, nil, nil
    pcall(function() original_left_pos = motion:call("getWorldPosition", left_index) end)
    pcall(function() original_right_pos = motion:call("getWorldPosition", right_index) end)
    pcall(function() original_right_rot = motion:call("getWorldRotation", right_index) end)
    if original_left_pos == nil or original_right_pos == nil or original_right_rot == nil then
        return nil
    end

    local inv_right = quat_inverse(original_right_rot)
    if inv_right == nil then return nil end

    local delta = original_left_pos - original_right_pos
    local pos_rel = quat_rotate_vec3(inv_right, delta)
    skeleton_grip_cache.frame = frame
    skeleton_grip_cache.pos_rel = pos_rel
    return pos_rel
end

--- FirstPerson lh_grip_position = rh_pos + rh_rot * original_left_pos_relative.
local function get_weapon_support_grip_world_pos()
    local rh = get_fp_style_hand_world_pos("right") or get_hand_world_pos("right")
    if rh == nil then return nil end

    local rh_rot = get_fp_style_right_hand_rotation()
    if rh_rot == nil then return nil end

    local original_left_pos_relative = get_skeleton_grip_offset_relative()
    if original_left_pos_relative == nil then return nil end

    return rh + quat_rotate_vec3(rh_rot, original_left_pos_relative)
end

--- Foregrip snap when left hand is near the weapon support point.
local function compute_ik_lh_grip_distance()
    local jpos = rawget(_G, "__vr_lh_joint_pos")
    if not vec3_valid(jpos) then return 1e9 end
    local grip_pos = get_weapon_support_grip_world_pos()
    if grip_pos == nil then return 1e9 end
    return vec3_dist(jpos, grip_pos)
end

--- Left-hand distance to foregrip target (first-person arm IK).
local function compute_firstperson_lh_grip_distance()
    local lh = get_fp_style_hand_world_pos("left") or get_hand_world_pos("left")
    if lh == nil then return 1e9 end

    local grip_pos = get_weapon_support_grip_world_pos()
    if grip_pos == nil then
        return 1e9
    end

    return vec3_dist(lh, grip_pos)
end

local function haptic_pulse(joystick, duration, frequency, amplitude)
    if not joystick then return end
    pcall(function()
        vrmod:trigger_haptic_vibration(0.0, duration, frequency, amplitude, joystick)
    end)
end

local function vr_controllers_active()
    if not CFG.enabled then return false end
    if firstpersonmod == nil or type(firstpersonmod.will_be_used) ~= "function" then
        return false
    end
    local ok_fp, fp_active = pcall(function() return firstpersonmod:will_be_used() end)
    if not ok_fp or not fp_active then return false end
    local ok_hmd, hmd = pcall(function() return vrmod:is_hmd_active() end)
    local ok_ctrl, ctrl = pcall(function() return vrmod:is_using_controllers() end)
    return ok_hmd and hmd and ok_ctrl and ctrl
end

local function vr_melee_haptics_active()
    if not CFG.melee_enabled then return false end
    local ok_hmd, hmd = pcall(function() return vrmod:is_hmd_active() end)
    local ok_ctrl, ctrl = pcall(function() return vrmod:is_using_controllers() end)
    return ok_hmd and hmd and ok_ctrl and ctrl
end

local function get_current_weapon_id()
    if firstpersonmod == nil then return "" end
    local ok_id, weapon_id = pcall(function() return firstpersonmod:get_current_weapon_recoil_id() end)
    if ok_id and type(weapon_id) == "string" then
        return weapon_id
    end
    return ""
end

local function get_weapon_haptic_entry(weapon_id)
    if type(weapon_id) ~= "string" or weapon_id == "" then return nil end
    if type(CFG.weapons) ~= "table" then return nil end
    local entry = CFG.weapons[weapon_id]
    if type(entry) == "table" then return entry end
    return nil
end

local function get_weapon_haptic_multiplier()
    local weapon_id = get_current_weapon_id()
    if weapon_id == "" then return 1.0 end

    local entry = get_weapon_haptic_entry(weapon_id)
    if entry and type(entry.intensity) == "number" and entry.intensity >= 0.0 then
        return entry.intensity
    end

    if CFG.use_recoil_multipliers and firstpersonmod ~= nil then
        local ok_mult, mult = pcall(function()
            return firstpersonmod:get_per_weapon_recoil_intensity(weapon_id)
        end)
        if ok_mult and type(mult) == "number" and mult > 0.0 then
            return mult
        end
    end

    return 1.0
end

local function player_has_gun_out()
    local player = re2.get_localplayer()
    if not player then return false end
    local ok, _, weapon = pcall(function() return re2.get_weapon_object(player) end)
    return ok and weapon ~= nil
end

local function in_support_blocked_zone()
    return rawget(_G, "__vr_in_holster_zone") == true
        or rawget(_G, "__vr_in_head_flashlight_zone") == true
end

local function is_left_grip_active()
    if not grip_action then
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

--- Foregrip dock when aiming/reloading rules allow left-hand support.
local function is_firstperson_foregrip_docked()
    if fp_left_hand_ik_blocked() then
        return false
    end
    if not player_is_aiming() then
        return false
    end
    if player_is_reloading() then
        return false
    end

    local was_grip = fp_was_gripping_weapon()
    local left_grip = is_left_grip_active()
    local grip_dist = compute_firstperson_lh_grip_distance()
    local ik_grip_dist = compute_ik_lh_grip_distance()
    local dock_threshold = get_foregrip_dock_distance_threshold()
    local hands_close = hands_are_supporting_weapon()

    if was_grip and left_grip then
        return true
    end

    if was_grip then
        return true
    end

    if ik_grip_dist <= IK_SNAP_GRIP_DISTANCE then
        return true
    end

    if grip_dist <= dock_threshold then
        return true
    end

    if not left_grip and hands_close and grip_dist <= dock_threshold + 0.03 then
        return true
    end

    if is_large_weapon_equipped() and hands_close then
        return true
    end

    return false
end

-- Left grip held counts as two-handed support (no foregrip distance check).
local function is_two_hand_haptic_active()
    if not is_left_grip_active() then
        return false
    end
    if in_support_blocked_zone() then
        return false
    end
    return true
end

-- Two-handed when left IK follow is active.
local function is_two_handed_for_haptics()
    if player_is_reloading() then
        return true
    end
    if in_support_blocked_zone() then
        return false
    end
    if not is_left_grip_active() then
        return false
    end
    if hands_are_supporting_weapon() then
        return true
    end
    if player_is_aiming() then
        return true
    end
    return false
end

-- Left grip path + foregrip dock path.
local function is_weapon_support_active_for_haptics()
    if is_two_hand_haptic_active() then
        return true
    end
    if is_firstperson_foregrip_docked() then
        return true
    end
    return is_two_handed_for_haptics()
end

local function should_pulse_left_hand_haptic()
    if in_support_blocked_zone() then
        return false
    end
    if not player_has_gun_out() then
        return false
    end
    if fp_left_hand_ik_blocked() then
        return false
    end
    if player_is_reloading() then
        return true
    end
    return is_weapon_support_active_for_haptics()
end

local function add_pending_haptic_shot()
    if not vr_controllers_active() then return end
    if should_pulse_left_hand_haptic() then
        pending_left_hand_support = true
    end
    if pending_haptic_shots < 20 then
        pending_haptic_shots = pending_haptic_shots + 1
    end
end

local function on_pre_request_fire(args)
    add_pending_haptic_shot()
end

local function on_post_request_fire(retval)
    return retval
end

local function try_hook_request_fire(type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then return false end
    local method = td:get_method("requestFire")
    if not method then return false end
    sdk.hook(method, on_pre_request_fire, on_post_request_fire)
    log.info(string.format("[re2_vr_haptics] Hooked %s.requestFire", type_name))
    return true
end

local function install_fire_hooks()
    if fire_hooks_installed then return end
    local hooked = try_hook_request_fire(NS("survivor.Equipment"))
    if not hooked then
        try_hook_request_fire(NS("weapon.generator.BulletShellGenerator"))
        try_hook_request_fire(NS("weapon.generator.ShotgunShellGenerator"))
    end
    fire_hooks_installed = true
end

local function process_pending_haptics()
    if pending_haptic_shots <= 0 then return end
    if not vr_controllers_active() then
        pending_haptic_shots = 0
        return
    end

    local n = pending_haptic_shots
    pending_haptic_shots = 0
    if n > 10 then n = 10 end

    local weapon_mult = get_weapon_haptic_multiplier()
    local amplitude = math.min(1.0, CFG.intensity * (weapon_mult > 0.0 and weapon_mult or 1.0))
    local left_support = pending_left_hand_support or should_pulse_left_hand_haptic()
    pending_left_hand_support = false

    local right_joystick = nil
    local left_joystick = nil
    pcall(function() right_joystick = vrmod:get_right_joystick() end)
    pcall(function() left_joystick = vrmod:get_left_joystick() end)

    for _ = 1, n do
        haptic_pulse(right_joystick, CFG.duration, CFG.frequency, amplitude)
        if left_support and left_joystick then
            local left_amp = math.min(1.0, math.max(0.0, amplitude * CFG.left_hand_ratio))
            haptic_pulse(left_joystick, CFG.duration, CFG.frequency, left_amp)
        end
    end
end

-- Melee collision haptics via capsule geometry during implement.Melee.lateUpdate.
local melee_type = sdk.find_type_definition(NS("implement.Melee"))
local melee_hooks_installed = false
local ContinuousCapsuleShape = sdk.find_type_definition("via.physics.ContinuousCapsuleShape")

local CollisionLayer = statics.generate("app.CollisionManager.Layer")
local MELEE_PROBE_LAYERS = { 3, 6, 2, 7, 1 }
local wrist_rotator = Vector3f.new(-1, 0, 0):to_quat()

local melee_weapon_pos = Vector3f.new(0, 0, 0)
local melee_weapon_rot = Quaternion.new(0, 0, 0, 1)
local melee_capsule_end = nil
local melee_prev_weapon_pos = nil
local melee_is_knife_out = false
local melee_last_swing_t = 0.0
local melee_contact_strength = 0.0
local melee_game_hit_hold = 0
local melee_last_probe_hit = false
local melee_last_probe_layer = -1
local melee_wrist_hash = nil

local via_physics_system_type = sdk.find_type_definition("via.physics.System")
local cast_ray_method = via_physics_system_type and via_physics_system_type:get_method(
    "castRay(via.physics.CastRayQuery, via.physics.CastRayResult)") or nil

local application = sdk.get_native_singleton("via.Application")
local application_type = sdk.find_type_definition("via.Application")
local get_uptime_second_function = application_type and application_type:get_method("get_UpTimeSecond") or nil

local function melee_uptime()
    if not application or not get_uptime_second_function then
        return os.clock()
    end
    local ok, t = pcall(function() return get_uptime_second_function:call(application) end)
    return ok and t or os.clock()
end

local function update_melee_weapon_kinematics()
    local player = re2.get_localplayer()
    if not player then
        melee_is_knife_out = false
        return
    end

    local weapon_go, weapon = re2.get_weapon_object(player)
    if not weapon_go or not weapon then
        melee_is_knife_out = false
        local player_transform = player:call("get_Transform")
        if not player_transform then return end

        if melee_wrist_hash == nil then
            local wrist = player_transform:call("getJointByName", "r_arm_wrist")
            if wrist then
                melee_wrist_hash = wrist:call("get_NameHash")
            end
        end

        local wrist_joint = melee_wrist_hash and player_transform:call("getJointByHash", melee_wrist_hash) or nil
        if wrist_joint then
            melee_prev_weapon_pos = melee_weapon_pos
            melee_weapon_pos = wrist_joint:call("get_Position")
            melee_weapon_rot = (wrist_joint:call("get_Rotation") * wrist_rotator):normalized()
            melee_capsule_end = nil
        end
        return
    end

    melee_is_knife_out = GameObject.get_component(weapon_go, NS("implement.Melee")) ~= nil
    melee_capsule_end = nil

    local weapon_transform = weapon_go:call("get_Transform")
    if not weapon_transform then return end

    melee_prev_weapon_pos = melee_weapon_pos
    melee_weapon_pos = weapon_transform:call("get_Position")
    melee_weapon_rot = weapon_transform:call("get_Rotation")

    local joints = weapon_transform:call("get_Joints")
    if joints then
        local joint_elems = joints:get_elements()
        if joint_elems then
            for _, joint in ipairs(joint_elems) do
                local ok_name, joint_name = pcall(function() return joint:call("get_Name") end)
                if ok_name and joint_name == "vfx_muzzle1" then
                    local ok_pos, joint_pos = pcall(function() return joint:call("get_Position") end)
                    if ok_pos then melee_capsule_end = joint_pos end
                    break
                end
            end
        end
    end
end

local function get_melee_capsule_segment()
    local p0 = melee_weapon_pos
    local p1 = melee_capsule_end
    if p1 == nil then
        -- Blade length fallback when vfx_muzzle1 joint is missing.
        local blade_len = 0.35
        p1 = p0 + (melee_weapon_rot * Vector3f.new(0, 0, blade_len))
    end
    return p0, p1
end

local function should_melee_physically_swing()
    if not melee_is_knife_out then
        return false
    end
    local now = melee_uptime()
    if now - melee_last_swing_t <= CFG.melee_swing_grace_s then
        return true
    end
    vrc_manager:update()
    if vrc_manager:has_controllers() and vrc_manager.controllers_list[2] then
        if vrc_manager.controllers_list[2].speed > CFG.melee_swing_speed_threshold then
            melee_last_swing_t = now
            return true
        end
    end
    if melee_prev_weapon_pos then
        local tip_speed = (melee_weapon_pos - melee_prev_weapon_pos):length() / 0.016
        if tip_speed > CFG.melee_swing_speed_threshold then
            melee_last_swing_t = now
            return true
        end
    end
    return false
end

local function cast_physics_ray_on_layer(start_pos, end_pos, layer)
    if not cast_ray_method then return false, 0.0 end
    local via_physics_system = sdk.get_native_singleton("via.physics.System")
    if not via_physics_system then return false, 0.0 end

    local ok, ray_query = pcall(function() return sdk.create_instance("via.physics.CastRayQuery") end)
    if not ok or not ray_query then return false, 0.0 end

    local ray_result = nil
    ok = pcall(function() ray_result = sdk.create_instance("via.physics.CastRayResult") end)
    if not ok or not ray_result then return false, 0.0 end

    pcall(function()
        ray_query:call("setRay(via.vec3, via.vec3)", start_pos, end_pos)
        ray_query:call("clearOptions")
        ray_query:call("enableAllHits")
        ray_query:call("enableNearSort")
        local filter_info = ray_query:call("get_FilterInfo")
        filter_info:call("set_Group", 0)
        filter_info:call("set_MaskBits", 0xFFFFFFFF - 1)
        if layer ~= nil then
            filter_info:call("set_Layer", layer)
        elseif CollisionLayer and CollisionLayer.Bullet ~= nil then
            filter_info:call("set_Layer", CollisionLayer.Bullet)
        end
        ray_query:call("set_FilterInfo", filter_info)
        cast_ray_method:call(via_physics_system, ray_query, ray_result)
    end)

    local hit = false
    local strength = 0.0
    pcall(function()
        if ray_result:call("get_NumContactPoints") > 0 then
            hit = true
            local cp = ray_result:call("getContactPoint(System.UInt32)", 0)
            if cp then
                local dist = cp:get_field("Distance") or 0.0
                local seg_len = (end_pos - start_pos):length()
                if seg_len > 0.001 then
                    strength = math.max(0.35, 1.0 - (dist / seg_len))
                else
                    strength = 1.0
                end
            else
                strength = 1.0
            end
        end
    end)
    return hit, strength
end

local function cast_physics_ray_multi_layer(start_pos, end_pos)
    for _, layer in ipairs(MELEE_PROBE_LAYERS) do
        local hit, strength = cast_physics_ray_on_layer(start_pos, end_pos, layer)
        if hit then
            melee_last_probe_layer = layer
            return true, strength
        end
    end
    melee_last_probe_layer = -1
    return false, 0.0
end

local function probe_segment(p0, p1)
    local seg = p1 - p0
    local seg_len = seg:length()
    if seg_len < 0.01 then
        return false, 0.0
    end

    local max_strength = 0.0
    local any_hit = false
    local samples = math.max(2, math.floor(CFG.melee_ray_samples))

    for i = 0, samples - 1 do
        local t0 = i / samples
        local t1 = (i + 1) / samples
        local a = p0 + (seg * t0)
        local b = p0 + (seg * t1)
        local hit, strength = cast_physics_ray_multi_layer(a, b)
        if hit then
            any_hit = true
            max_strength = math.max(max_strength, strength)
        end
    end

    return any_hit, max_strength
end

local function probe_collidable_capsule(collidable)
    if not collidable or not ContinuousCapsuleShape then return false, 0.0 end
    local ok, transformed_shape = pcall(function() return collidable:call("get_TransformedShape") end)
    if not ok or not transformed_shape then return false, 0.0 end
    local ok2, is_capsule = pcall(function()
        return transformed_shape:get_type_definition() == ContinuousCapsuleShape
    end)
    if not ok2 or not is_capsule then return false, 0.0 end

    local ok3, capsule = pcall(function() return transformed_shape:call("get_Capsule") end)
    if not ok3 or not capsule then return false, 0.0 end

    local p0, p1 = nil, nil
    pcall(function()
        p0 = capsule:get_field("p0")
        p1 = capsule:get_field("p1")
    end)
    if p0 and p1 then
        return probe_segment(p0, p1)
    end
    return false, 0.0
end

local function probe_melee_hijacked_colliders(melee)
    local any_hit = false
    local max_strength = 0.0

    local go = nil
    pcall(function() go = melee:call("get_GameObject") end)
    if not go then return false, 0.0 end

    local request_set = GameObject.get_component(go, "via.physics.RequestSetCollider")
    if request_set then
        local ok_n, num = pcall(function()
            return request_set:call("getNumCollidablesFromIndex(System.UInt32)", 0)
        end)
        if ok_n and num and num > 0 then
            for i = 0, num - 1 do
                local ok_c, collidable = pcall(function()
                    return request_set:call("getCollidableFromIndex(System.UInt32, System.UInt32)", 0, i)
                end)
                if ok_c and collidable then
                    local hit, strength = probe_collidable_capsule(collidable)
                    if hit then
                        any_hit = true
                        max_strength = math.max(max_strength, strength)
                    end
                end
            end
        end
    end

    local ok_list, collidables_list = pcall(function()
        return melee:get_field("<TargetCollidables>k__BackingField")
    end)
    if ok_list and collidables_list then
        local ok_items, items = pcall(function()
            return collidables_list:get_field("mItems"):get_elements()
        end)
        if ok_items and items then
            for _, collidable in ipairs(items) do
                local hit, strength = probe_collidable_capsule(collidable)
                if hit then
                    any_hit = true
                    max_strength = math.max(max_strength, strength)
                end
            end
        end
    end

    return any_hit, max_strength
end

local function probe_melee_capsule_contact()
    if not melee_is_knife_out then
        return false, 0.0
    end

    local max_strength = 0.0
    local any_hit = false

    local p0, p1 = get_melee_capsule_segment()
    local hit_seg, str_seg = probe_segment(p0, p1)
    if hit_seg then
        any_hit = true
        max_strength = math.max(max_strength, str_seg)
    end

    if melee_prev_weapon_pos then
        local hit_sweep, str_sweep = cast_physics_ray_multi_layer(melee_prev_weapon_pos, p0)
        if hit_sweep then
            any_hit = true
            max_strength = math.max(max_strength, str_sweep)
        end
    end

    melee_last_probe_hit = any_hit
    return any_hit, max_strength
end

local function melee_swing_contact_ready()
    return should_melee_physically_swing()
end

local function clear_melee_contact_state()
    melee_contact_strength = 0.0
    melee_game_hit_hold = 0
    melee_last_probe_hit = false
    melee_last_probe_layer = -1
end

local function decay_melee_contact()
    if melee_game_hit_hold > 0 then
        melee_game_hit_hold = melee_game_hit_hold - 1
    end
    if melee_contact_strength > 0.0 then
        melee_contact_strength = math.max(0.0, melee_contact_strength - 0.18)
    end
end

local function register_melee_contact(strength)
    strength = math.min(1.0, math.max(0.0, strength))
    melee_contact_strength = math.max(melee_contact_strength, strength)
end

local function melee_contact_active()
    if not melee_swing_contact_ready() then
        return false
    end
    return melee_contact_strength > 0.05 or melee_game_hit_hold > 0
end

local function apply_melee_sustain_haptics()
    if not vr_melee_haptics_active() then
        return
    end
    if not melee_contact_active() then
        return
    end

    local strength = math.min(1.0, melee_contact_strength + (melee_game_hit_hold > 0 and 0.25 or 0.0))
    local amplitude = math.min(1.0, CFG.melee_intensity * strength)
    local right_joy = nil
    pcall(function() right_joy = vrmod:get_right_joystick() end)
    if not right_joy then return end

    haptic_pulse(right_joy, CFG.melee_pulse_duration, CFG.melee_frequency, amplitude)
end

local function try_melee_contact_hit(hit, strength)
    if not hit or not melee_swing_contact_ready() then
        return false
    end
    register_melee_contact(strength)
    return true
end

local function on_pre_melee_lateupdate_haptics(args)
    if not vr_melee_haptics_active() or not melee_is_knife_out then
        return
    end

    if not melee_swing_contact_ready() then
        clear_melee_contact_state()
        return
    end

    local melee = sdk.to_managed_object(args[2])
    if not melee then return end

    local hit, strength = probe_melee_hijacked_colliders(melee)
    if not hit then
        hit, strength = probe_melee_capsule_contact()
    end

    if try_melee_contact_hit(hit, strength) then
        apply_melee_sustain_haptics()
    end
end

local function process_melee_collision_haptics()
    if not vr_melee_haptics_active() then
        clear_melee_contact_state()
        return
    end

    if not melee_is_knife_out then
        clear_melee_contact_state()
        return
    end

    if not melee_swing_contact_ready() then
        clear_melee_contact_state()
        return
    end

    local hit, strength = probe_melee_capsule_contact()
    if try_melee_contact_hit(hit, strength) then
        apply_melee_sustain_haptics()
    elseif not melee_last_probe_hit then
        decay_melee_contact()
    else
        apply_melee_sustain_haptics()
    end
end

local function melee_hit_from_retval(retval)
    if retval == nil then return false end
    local ok_i, as_i = pcall(function() return sdk.to_int64(retval) ~= 0 end)
    if ok_i and as_i then return true end
    local ok_b, as_b = pcall(function() return retval == true end)
    if ok_b and as_b then return true end
    return false
end

local function on_post_melee_check_hit_attack(retval)
    if not vr_melee_haptics_active() or not melee_is_knife_out or not melee_swing_contact_ready() then
        return retval
    end
    if melee_hit_from_retval(retval) then
        melee_game_hit_hold = 8
        register_melee_contact(1.0)
        apply_melee_sustain_haptics()
    end
    return retval
end

local function on_post_melee_check_hit_terrain(retval)
    if not vr_melee_haptics_active() or not melee_is_knife_out or not melee_swing_contact_ready() then
        return retval
    end
    if melee_hit_from_retval(retval) then
        melee_game_hit_hold = 8
        register_melee_contact(1.0)
        apply_melee_sustain_haptics()
    end
    return retval
end

local function on_pre_melee_check_hit_attack_nop(args)
end

local function on_post_hook_passthrough(retval)
    return retval
end

local function install_melee_hooks()
    if melee_hooks_installed then return end
    if not melee_type then return end

    local late_update = melee_type:get_method("lateUpdate")
    if late_update then
        sdk.hook(late_update, on_pre_melee_lateupdate_haptics, on_post_hook_passthrough)
        log.info("[re2_vr_haptics] Hooked implement.Melee.lateUpdate (capsule probe)")
    end

    local check_hit = melee_type:get_method("onCheckHitAttack")
    if check_hit then
        sdk.hook(check_hit, on_pre_melee_check_hit_attack_nop, on_post_melee_check_hit_attack)
        log.info("[re2_vr_haptics] Hooked implement.Melee.onCheckHitAttack")
    end

    local check_terrain = melee_type:get_method("onCheckHitTerrain")
    if check_terrain then
        sdk.hook(check_terrain, on_pre_melee_check_hit_attack_nop, on_post_melee_check_hit_terrain)
        log.info("[re2_vr_haptics] Hooked implement.Melee.onCheckHitTerrain")
    end

    melee_hooks_installed = true
end

re.on_application_entry("BeginRendering", function()
    update_melee_weapon_kinematics()
end)

re.on_application_entry("UpdateMotion", function()
    process_melee_collision_haptics()
end)

-- Run after FirstPerson arm IK (on_pre_late_update_behavior -> update_player_arm_ik).
re.on_application_entry("LateUpdateBehavior", function()
    process_pending_haptics()
end)

re.on_frame(function()
    if not fire_hooks_installed then
        install_fire_hooks()
    end
    if not melee_hooks_installed then
        install_melee_hooks()
    end
    if melee_contact_active() then
        apply_melee_sustain_haptics()
    elseif not melee_swing_contact_ready() then
        clear_melee_contact_state()
    end
end)

local function draw_feature_enable_toggle(is_enabled, id, label)
    local changed = false
    local new_val = is_enabled
    if is_enabled then
        imgui.push_style_color(0, UI_ENABLE)
        if imgui.button("Enable##" .. id) then
            new_val = false
            changed = true
        end
        imgui.pop_style_color(1)
    else
        imgui.push_style_color(0, UI_DISABLE)
        if imgui.button("Disable##" .. id) then
            new_val = true
            changed = true
        end
        imgui.pop_style_color(1)
    end
    imgui.same_line()
    imgui.text(label)
    return changed, new_val
end

local function draw_haptics_ui()
    local c, v

    imgui.text_colored("Haptics:", UI_ACCENT)

    c, v = draw_feature_enable_toggle(CFG.enabled, "weapon_haptics_enable", "Weapon Haptics")
    if c then
        CFG.enabled = v
        save_cfg()
    end

    c, v = draw_feature_enable_toggle(CFG.melee_enabled, "melee_haptics_enable", "Melee Haptics")
    if c then
        CFG.melee_enabled = v
        save_cfg()
    end

    imgui.separator()
    imgui.separator()
end

_G.__vr_ui_callbacks = _G.__vr_ui_callbacks or {}
table.insert(_G.__vr_ui_callbacks, { order = 43, fn = draw_haptics_ui })

if not _G.__vr_ui_master_installed then
    _G.__vr_ui_master_installed = true
    re.on_draw_ui(function()
        if not _G.__vr_ui_callbacks then
            return
        end
        table.sort(_G.__vr_ui_callbacks, function(a, b)
            return (a.order or 0) < (b.order or 0)
        end)
        for _, cb in ipairs(_G.__vr_ui_callbacks) do
            if cb.fn then
                pcall(cb.fn)
            end
        end
    end)
end

install_fire_hooks()
install_melee_hooks()
log.info("[re2_vr_haptics] Loaded — config: " .. CFG_PATH)

return {}
