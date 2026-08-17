local M = {}

local deps_ref

function M.set_bullet_insert_preview_handlers(handlers)
    if type(handlers) ~= "table" then return end
    deps_ref.extend_bullet_insert_preview = handlers.extend
    deps_ref.cancel_bullet_insert_preview = handlers.cancel
    deps_ref.bullet_insert_preview_is_active = handlers.is_active
    deps_ref.bullet_insert_preview_remaining = handlers.get_remaining
end


function M.init(deps)
    deps_ref = deps
    deps_ref.vr_char = deps_ref.vr_char or require("utility/RE2Character")
    deps_ref.weapon_display_name = deps_ref.weapon_display_name or function(wp) return tostring(wp) end
    deps_ref.mark_tuning_dirty = deps_ref.mark_tuning_dirty or function() end
    deps_ref.refresh_tuning_snapshot = deps_ref.refresh_tuning_snapshot or function() end
    rawset(_G, "__vr_mag_holster_ready", true)
end

rawset(_G, "__vr_mag_holster_ready", false)


local mesh_type = sdk.typeof("via.render.Mesh")

local MAG_STATE = {
    ATTACHED = "attached",
    DROPPING = "dropping",
    OUT = "out",
    IN_HAND = "in_hand",
    INSERTING = "inserting",
}

local PLAYER_JOINT = {
    hip = { "r_Prop_Hip_A", "spine_0" },
    shoulder = { "l_Prop_BackWepOffset_A", "spine_2" },
    chest = { "spine_2" },
    left_wrist = { "l_arm_wrist" },
    right_wrist = { "r_arm_wrist" },
}

local function find_player_joint(tf, joint_names)
    if not tf then return nil end
    for _, joint_name in ipairs(joint_names or {}) do
        local joint = deps_ref.sc(tf, "getJointByName", joint_name)
        if joint then return joint end
    end
    return nil
end

-- char_defaults folded into this same table (instead of a new top-level
-- local) -- this file was already at Lua's 200-local ceiling. Per-character
-- ammo pouch position, tuned live via the "Calibrate Ammo Holster" button
-- and baked in so a fresh install (no persisted re2_vr_reload.json yet)
-- starts these characters with a good fit instead of the shared 0/0/0
-- fallback.
local MAG_HOLSTER_DEF = {
    off_right = 0.0, off_up = 0.0, off_forward = 0.0, trigger_dist = 0.25, release_dist = 0.38,
    char_defaults = {
        ada = { off_right = 0.33564046728639596, off_up = -0.14209754422014242, off_forward = 0.06174400380342604 },
    },
}

local mag = {
    state = MAG_STATE.ATTACHED,
    cached_wp = nil,
    target = nil,
    target_kind = nil,
    weapon_xform = nil,
    joint = nil,
    mag_go = nil,
    node_name = nil,
    rest_x = 0.0,
    rest_y = 0.0,
    rest_z = 0.0,
    has_rest = false,
    rest_sx = 1.0,
    rest_sy = 1.0,
    rest_sz = 1.0,
    exit_x = 0.0,
    exit_y = 0.0,
    exit_z = 0.0,
    freeze_pose = false,
    freeze_mode = "local",
    frozen_lx = 0.0,
    frozen_ly = 0.0,
    frozen_lz = 0.0,
    frozen_wx = 0.0,
    frozen_wy = 0.0,
    frozen_wz = 0.0,
    frozen_rot_x = 0.0,
    frozen_rot_y = 0.0,
    frozen_rot_z = 0.0,
    frozen_rot_w = 1.0,
    fall_sx = 0.0,
    fall_sy = 0.0,
    fall_sz = 0.0,
    anim_active = false,
    anim_phase = nil,
    anim_start = 0.0,
    slide_lx0 = 0.0,
    slide_ly0 = 0.0,
    slide_lz0 = 0.0,
    miss_warned = false,
    mesh_hidden = false,
    hide_gos = {},
    exit_ref_valid = false,
    exit_ref_wp = nil,
    exit_ref_wx = 0.0,
    exit_ref_wy = 0.0,
    exit_ref_wz = 0.0,
    exit_ref_weapon_wx = 0.0,
    exit_ref_weapon_wy = 0.0,
    exit_ref_weapon_wz = 0.0,
    exit_ref_weapon_wrx = 0.0,
    exit_ref_weapon_wry = 0.0,
    exit_ref_weapon_wrz = 0.0,
    exit_ref_weapon_wrw = 1.0,
    carried_rounds = 0,
    reserve_cache_t = 0.0,
    reserve_cache_n = nil,
    weapon_ammo_cleared = false,
    cached_weapon_go = nil,
}

function mag.native_bullet_n()
    local weapon = deps_ref and deps_ref.re2 and deps_ref.re2.weapon
    if not weapon then return 0 end
    for _, fname in ipairs({ "BulletNumber", "_BulletNumber", "<BulletNumber>k__BackingField" }) do
        local ok, v = pcall(function() return weapon:get_field(fname) end)
        if ok and type(v) == "number" then
            return math.max(0, math.floor(v))
        end
    end
    return 0
end

function mag.ambient_holster_haptics_suppressed()
    local mh = deps_ref and deps_ref.CFG and deps_ref.CFG.mag_holster
    return mh and mh.suppress_ambient_holster_haptics == true
end

local mag_snapshots = {}

local function clear_mag_snapshots()
    for k, _ in pairs(mag_snapshots) do
        mag_snapshots[k] = nil
    end
end

local function get_weapon_go_token()
    local go = deps_ref.re2.weapon_gameobject
    if go == nil then return nil end
    local ok, addr = pcall(function() return go:get_address() end)
    if ok and addr ~= nil then return tostring(addr) end
    return tostring(go)
end

local function should_skip_mag_snapshot_io()
    return rawget(_G, "__vr_reload_stack_reset_in_progress") == true
end

local mag_hand = {
    active = false,
    grip_prev = false,
    release_fall_active = false,
    release_start = 0.0,
    release_sx = 0.0,
    release_sy = 0.0,
    release_sz = 0.0,
    last_dock_t = 0.0,
}

local mag_holster_st = {
    joint = nil,
    in_zone = false,
    suppress_prev = false,
    grab_ready_prev = false,
    last_grab_t = -1.0,
    last_dist = 99.0,
    last_pos = nil,
    zone_enter_pulse = false,
    blocked_grab_fired = false,
    pending_pulse_2_at = nil,
    pending_pulse_3_at = nil,
    status = nil,
    haptic_pending_frames = 0,
    vrmod_warned = false,
    anchor_joint = nil,
    anchor_fallback = false,
    sub_weapon_grip_block = false,
    left_support_grace_until = 0.0,
}

local mag_holster_cap = {
    pending = false,
    deadline = 0.0,
    last_beep_int = -1,
    snap_hand = nil,
    snap_origin = nil,
    snap_ax = nil,
    snap_ay = nil,
    snap_az = nil,
    snap_right = nil,
    snap_up = nil,
    snap_fwd = nil,
}


local MAG_PREVIEW_SEC = 5.0

local mag_preview = {
    follow_equipped = true,
    edit_wp = nil,
    status = nil,

    active = false,
    weapon_id = nil,
    until_t = 0.0,
    target = nil,
    target_kind = nil,
    rest_x = 0.0,
    rest_y = 0.0,
    rest_z = 0.0,
    has_rest = false,
    was_mesh_hidden = false,
}

local function weapon_no_rack_required(wp)
    wp = wp or mag.cached_wp or deps_ref.get_weapon_go_name()
    if not wp then return false end
    local entry = type(deps_ref.CFG.weapons) == "table" and deps_ref.CFG.weapons[wp] or nil
    if entry and entry.no_slide_rack_required == true then return true end
    local by_wp = deps_ref.CFG.slide_dock and deps_ref.CFG.slide_dock.no_rack_required_by_wp
    return type(by_wp) == "table" and by_wp[wp] == true
end

local function vec3_dist(a, b)
    if not a or not b then return 99.0 end
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function vec3_dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function get_player_transform()
    if not deps_ref then return nil end
    local player = deps_ref.re2.get_localplayer()
    if player then
        local tf = deps_ref.sc(player, "get_Transform")
        if tf then return tf end
    end

    local cm = sdk.get_managed_singleton("app.CharacterManager")
    if not cm then return nil end
    local ctx = deps_ref.sc(cm, "get_PlayerContextFast")
    if not ctx then return nil end
    local go = deps_ref.sc(ctx, "get_GameObject")
    if not go then return nil end
    return deps_ref.sc(go, "get_Transform")
end

local function vec3_valid(pos)
    return pos ~= nil and type(pos.x) == "number" and type(pos.y) == "number" and type(pos.z) == "number"
end

local function get_vr_controller_world_pos(hand)
    if not vrmod then return nil end
    local controllers = nil
    pcall(function() controllers = vrmod:get_controllers() end)
    if not controllers then return nil end

    local list_i = (hand == "right") and 2 or 1
    local ctrl = controllers[list_i]
    if ctrl == nil then
        ctrl = list_i
    end

    local ok, pos = pcall(function() return vrmod:get_position(ctrl) end)
    if ok and vec3_valid(pos) then return pos end
    return nil
end

local function get_hmd_body_yaw_pose()
    local cam = sdk.get_primary_camera()
    if not cam then return nil end
    local wm = deps_ref.sc(cam, "get_WorldMatrix")
    if not wm then return nil end

    local pos = { x = wm[3].x, y = wm[3].y, z = wm[3].z }
    local right, up, fwd = body_yaw_axes_from_transform(get_player_transform())
    if not right then
        local fx, fz = wm[2].x, wm[2].z
        local len = math.sqrt(fx * fx + fz * fz)
        if len < 1e-6 then fx, fz = 0.0, 1.0 else fx, fz = fx / len, fz / len end
        fwd = { x = fx, y = 0, z = fz }
        right = { x = fz, y = 0, z = -fx }
        up = { x = 0, y = 1, z = 0 }
    end
    return pos, nil, nil, nil, right, up, fwd
end

local function body_yaw_axes_from_transform(tf)
    if not tf then return nil end
    local fx, fz = nil, nil
    local rot = deps_ref.sc(tf, "get_Rotation")
    if rot then
        local ok, fwd_v = pcall(function() return rot * Vector3f.new(0, 0, 1) end)
        if ok and fwd_v then fx, fz = fwd_v.x, fwd_v.z end
    end
    if not fx then
        local cam = sdk.get_primary_camera()
        if cam then
            local wm = deps_ref.sc(cam, "get_WorldMatrix")
            if wm then fx, fz = wm[2].x, wm[2].z end
        end
    end
    if not fx then return nil end
    local len = math.sqrt(fx * fx + fz * fz)
    if len < 1e-6 then fx, fz = 0.0, 1.0 else fx, fz = fx / len, fz / len end
    local fwd = { x = fx, y = 0, z = fz }
    local right = { x = fz, y = 0, z = -fx }
    local up = { x = 0, y = 1, z = 0 }
    return right, up, fwd
end

local function get_body_pose_yaw()
    local tf = get_player_transform()
    if not tf then return nil end
    local right, up, fwd = body_yaw_axes_from_transform(tf)
    if not right then return nil end
    local pos = nil
    for _, joint_name in ipairs({ "spine_2", "spine_1", "spine_0", "pelvis" }) do
        local joint = deps_ref.sc(tf, "getJointByName", joint_name)
        if joint then
            pos = deps_ref.sc(joint, "get_Position")
            if pos then break end
        end
    end
    if not pos then pos = deps_ref.sc(tf, "get_Position") end
    if not pos then return nil end
    return pos, right, up, fwd
end

local function refresh_mag_holster_joint(tf, joint_names)
    if not tf then return false end
    if mag_holster_st.joint then
        local valid = false
        pcall(function() valid = mag_holster_st.joint:get_Valid() end)
        if valid then return true end
        mag_holster_st.joint = nil
        mag_holster_st.anchor_joint = nil
    end
    local joint, joint_name = nil, nil
    for _, name in ipairs(joint_names or PLAYER_JOINT.hip) do
        joint = deps_ref.sc(tf, "getJointByName", name)
        if joint then
            joint_name = name
            break
        end
    end
    if joint then
        mag_holster_st.joint = joint
        mag_holster_st.anchor_joint = joint_name
        return true
    end
    mag_holster_st.joint = nil
    mag_holster_st.anchor_joint = nil
    return false
end

local function refresh_left_hand_joint(tf)
    if not tf then return false end
    if mag_hand.hand_joint then
        local valid = false
        pcall(function() valid = mag_hand.hand_joint:get_Valid() end)
        if valid then return true end
        mag_hand.hand_joint = nil
    end
    local joint = find_player_joint(tf, PLAYER_JOINT.left_wrist)
    if joint then
        mag_hand.hand_joint = joint
        return true
    end
    return false
end

local function get_joint_world_pos(tf, joint_name)
    if not tf then return nil end
    local hj = deps_ref.sc(tf, "getJointByName", joint_name)
    if hj then
        return deps_ref.sc(hj, "get_Position")
    end
    return nil
end

local function holster_pos_with_offsets(origin, off_x, off_y, off_z, ax, ay, az, right, up, fwd)
    if not origin then return nil end
    if ax and ay and az then
        return {
            x = origin.x + ax.x * off_x + ay.x * off_y + az.x * off_z,
            y = origin.y + ax.y * off_x + ay.y * off_y + az.y * off_z,
            z = origin.z + ax.z * off_x + ay.z * off_y + az.z * off_z,
        }
    end
    if right and up and fwd then
        return {
            x = origin.x + off_x * right.x + off_y * up.x + off_z * fwd.x,
            y = origin.y + off_x * right.y + off_y * up.y + off_z * fwd.y,
            z = origin.z + off_x * right.z + off_y * up.z + off_z * fwd.z,
        }
    end
    return origin
end

local function current_mag_holster_profile_key()
    return deps_ref.vr_char.get_active_profile_key(deps_ref.re2.get_localplayer())
end

local function seed_mag_holster_profile_entry(key)
    local fallback_key = deps_ref.vr_char.get_pose_fallback_profile(key)
    local per_profile = deps_ref.CFG.mag_holster and deps_ref.CFG.mag_holster.per_profile
    local parent = per_profile and per_profile[fallback_key]
    local char_default = MAG_HOLSTER_DEF.char_defaults[key] or MAG_HOLSTER_DEF
    if type(parent) == "table" then
        return {
            off_right = tonumber(parent.off_right) or char_default.off_right,
            off_up = tonumber(parent.off_up) or char_default.off_up,
            off_forward = tonumber(parent.off_forward) or char_default.off_forward,
        }
    end
    return {
        off_right = tonumber(deps_ref.CFG.mag_holster and deps_ref.CFG.mag_holster.off_right) or char_default.off_right,
        off_up = tonumber(deps_ref.CFG.mag_holster and deps_ref.CFG.mag_holster.off_up) or char_default.off_up,
        off_forward = tonumber(deps_ref.CFG.mag_holster and deps_ref.CFG.mag_holster.off_forward) or char_default.off_forward,
    }
end

local function ensure_mag_holster_profile_entry(profile_key)
    deps_ref.CFG.mag_holster = deps_ref.CFG.mag_holster or {}
    deps_ref.CFG.mag_holster.per_profile = deps_ref.CFG.mag_holster.per_profile or {}
    local key = profile_key or current_mag_holster_profile_key()
    local entry = deps_ref.CFG.mag_holster.per_profile[key]
    if type(entry) ~= "table" then
        entry = seed_mag_holster_profile_entry(key)
        deps_ref.CFG.mag_holster.per_profile[key] = entry
    end
    return entry, key
end

local function active_mag_holster_joint_name()
    if mag_holster_st.anchor_joint then return mag_holster_st.anchor_joint end
    if not mag_holster_st.joint then return nil end
    local tf = get_player_transform()
    if not tf then return nil end
    for _, name in ipairs(PLAYER_JOINT.hip) do
        local joint = deps_ref.sc(tf, "getJointByName", name)
        if joint == mag_holster_st.joint then return name end
    end
    return nil
end

local function sync_mag_holster_profile_active()
    local entry = ensure_mag_holster_profile_entry()
    deps_ref.CFG.mag_holster = deps_ref.CFG.mag_holster or {}
    deps_ref.CFG.mag_holster.off_right = tonumber(entry.off_right) or MAG_HOLSTER_DEF.off_right
    deps_ref.CFG.mag_holster.off_up = tonumber(entry.off_up) or MAG_HOLSTER_DEF.off_up
    deps_ref.CFG.mag_holster.off_forward = tonumber(entry.off_forward) or MAG_HOLSTER_DEF.off_forward
end

local function persist_mag_holster_profile_active()
    local entry = ensure_mag_holster_profile_entry()
    deps_ref.CFG.mag_holster = deps_ref.CFG.mag_holster or {}
    entry.off_right = tonumber(deps_ref.CFG.mag_holster.off_right) or MAG_HOLSTER_DEF.off_right
    entry.off_up = tonumber(deps_ref.CFG.mag_holster.off_up) or MAG_HOLSTER_DEF.off_up
    entry.off_forward = tonumber(deps_ref.CFG.mag_holster.off_forward) or MAG_HOLSTER_DEF.off_forward
end

local function decompose_hand_offset(hand_pos, anchor_pos, ax, ay, az, right, up, fwd)
    if not hand_pos or not anchor_pos then return 0.0, 0.0, 0.0 end
    local dx = hand_pos.x - anchor_pos.x
    local dy = hand_pos.y - anchor_pos.y
    local dz = hand_pos.z - anchor_pos.z
    if ax and ay and az then
        return vec3_dot({ x = dx, y = dy, z = dz }, ax),
            vec3_dot({ x = dx, y = dy, z = dz }, ay),
            vec3_dot({ x = dx, y = dy, z = dz }, az)
    end
    if right and up and fwd then
        return vec3_dot({ x = dx, y = dy, z = dz }, right),
            vec3_dot({ x = dx, y = dy, z = dz }, up),
            vec3_dot({ x = dx, y = dy, z = dz }, fwd)
    end
    return 0.0, 0.0, 0.0
end

local function resolve_mag_holster_anchor()
    local tf = get_player_transform()
    if not tf then return nil end

    refresh_mag_holster_joint(tf, PLAYER_JOINT.hip)

    mag_holster_st.anchor_fallback = false
    if mag_holster_st.joint then
        local origin = deps_ref.sc(mag_holster_st.joint, "get_Position")
        if origin then
            return origin,
                deps_ref.sc(mag_holster_st.joint, "get_AxisX"),
                deps_ref.sc(mag_holster_st.joint, "get_AxisY"),
                deps_ref.sc(mag_holster_st.joint, "get_AxisZ")
        end
    end

    local body_pos, right, up, fwd = get_body_pose_yaw()
    if body_pos then
        mag_holster_st.anchor_fallback = true
        return body_pos, right, up, fwd
    end
    return nil
end

local function mag_holster_capture_pose()
    local origin, ax, ay, az = resolve_mag_holster_anchor()
    if origin then return origin, ax, ay, az end
    return get_body_pose_yaw()
end

local function get_mag_holster_offsets()
    sync_mag_holster_profile_active()
    local mh = deps_ref.CFG.mag_holster or {}
    return tonumber(mh.off_right) or MAG_HOLSTER_DEF.off_right,
        tonumber(mh.off_up) or MAG_HOLSTER_DEF.off_up,
        tonumber(mh.off_forward) or MAG_HOLSTER_DEF.off_forward
end

local function resolve_mag_holster_pos()
    local origin, ax, ay, az = resolve_mag_holster_anchor()
    if not origin then return nil end
    local right, up, fwd = ax, ay, az
    if not (ax and ay and az) then
        _, right, up, fwd = get_body_pose_yaw()
    end
    local off_r, off_u, off_f = get_mag_holster_offsets()
    return holster_pos_with_offsets(origin, off_r, off_u, off_f, ax, ay, az, right, up, fwd)
end

local function haptic_pulse(joystick, duration, frequency, amplitude)
    if not vrmod then return false end
    if not joystick then return false end
    local ok = pcall(function()
        vrmod:trigger_haptic_vibration(0.0, duration, frequency, amplitude, joystick)
    end)
    return ok == true
end

local function get_left_joystick()
    if not vrmod then return nil end
    local ok_mgr, mgr = pcall(require, "vr/VRControllerManager")
    if ok_mgr and mgr and type(mgr.has_controllers) == "function" and mgr:has_controllers() then
        local lc = mgr.controllers_list[1]
        if lc and lc.joystick then return lc.joystick end
    end
    local lj = nil
    pcall(function() lj = vrmod:get_left_joystick() end)
    if lj then return lj end
    local ok, val = pcall(vrmod.get_left_joystick, vrmod)
    return ok and val or nil
end

local function read_left_grip_action_active(lj)
    if not vrmod or not lj then return false end
    if not mag_hand.grip_action_cache or mag_hand.grip_action_cache == 0 then
        pcall(function() mag_hand.grip_action_cache = vrmod:get_action_grip() end)
    end
    if not mag_hand.grip_action_cache then return false end
    local ok, v = pcall(function()
        return vrmod:is_action_active(mag_hand.grip_action_cache, lj)
    end)
    return ok and v == true
end

-- Left trigger, digital hold state, mirrors read_left_grip_action_active.
-- Used by the pump gesture to drive the "pull down while held / release to
-- finish" pump-action reload, replacing the tracked-hand-distance gesture.
local function read_left_trigger_action_active(lj)
    if not vrmod or not lj then return false end
    if not mag_hand.trigger_action_cache or mag_hand.trigger_action_cache == 0 then
        pcall(function() mag_hand.trigger_action_cache = vrmod:get_action_trigger() end)
    end
    if not mag_hand.trigger_action_cache then return false end
    local ok, v = pcall(function()
        return vrmod:is_action_active(mag_hand.trigger_action_cache, lj)
    end)
    return ok and v == true
end

local function is_left_trigger_pressed()
    if not vrmod then return false, nil end
    local lj = get_left_joystick()
    if not lj then return false, lj end
    return read_left_trigger_action_active(lj), lj
end

local function is_left_grip_pressed()
    if not vrmod then return false, nil end
    local lj = get_left_joystick()
    if not lj then return false, lj end
    return read_left_grip_action_active(lj), lj
end

local function get_left_hand_joint()
    local cached = rawget(_G, "__vr_lh_joint")
    if cached then
        local valid = false
        pcall(function() valid = cached:get_Valid() end)
        if valid then return cached end
    end
    local tf = get_player_transform()
    if not tf then return nil end
    for _, joint_name in ipairs(PLAYER_JOINT.left_wrist) do
        local joint = deps_ref.sc(tf, "getJointByName", joint_name)
        if joint then return joint end
    end
    return nil
end

local function get_mag_holster_hand_pos()
    local tf = get_player_transform()
    if tf and refresh_left_hand_joint(tf) and mag_hand.hand_joint then
        local pos = deps_ref.sc(mag_hand.hand_joint, "get_Position")
        if vec3_valid(pos) then return pos end
    end
    -- __vr_lh_joint_pos is only kept fresh while __vr_lh_slide_ik_override
    -- is true (the slide-dock system never clears it afterward), so it's
    -- only trustworthy while that flag says docking is actually live.
    if rawget(_G, "__vr_lh_slide_ik_override") == true then
        local j = rawget(_G, "__vr_lh_joint_pos")
        if j and type(j.x) == "number" then return j end
    end
    local w = rawget(_G, "__vr_lh_world")
    if w and type(w.x) == "number" then return w end
    return get_joint_world_pos(tf, "l_arm_wrist")
end

local function get_left_hand_position()
    local cached = nil
    if rawget(_G, "__vr_lh_slide_ik_override") == true then
        cached = rawget(_G, "__vr_lh_joint_pos")
    end
    if cached and type(cached.x) == "number" then return cached end
    local cached_w = rawget(_G, "__vr_lh_world")
    if cached_w and type(cached_w.x) == "number" then return cached_w end

    local vr_pos = get_vr_controller_world_pos("left")
    if vr_pos then return vr_pos end

    local hand = get_left_hand_joint()
    local joint_pos = hand and deps_ref.sc(hand, "get_Position")
    if vec3_valid(joint_pos) then return joint_pos end

    local tf = get_player_transform()
    if tf then
        for _, joint_name in ipairs(PLAYER_JOINT.left_wrist) do
            local joint = deps_ref.sc(tf, "getJointByName", joint_name)
            local pos = joint and deps_ref.sc(joint, "get_Position")
            if vec3_valid(pos) then return pos end
        end
    end

    return nil
end

local function get_track_pos_for_rack()
    local pos = get_mag_holster_hand_pos()
    if pos then return pos, "hand_skeleton" end
    local wp = get_vr_controller_world_pos("left")
    if wp then return wp, "vr_raw" end
    return nil, "nil"
end

local function snapshot_mag_holster_calibrate_pose()
    local hand_pos = get_mag_holster_hand_pos()
    local origin, ax, ay, az = mag_holster_capture_pose()
    if not hand_pos or not origin then return false end

    mag_holster_cap.snap_hand = hand_pos
    mag_holster_cap.snap_origin = origin
    mag_holster_cap.snap_ax = ax
    mag_holster_cap.snap_ay = ay
    mag_holster_cap.snap_az = az
    return true
end

local function mag_holster_calibrate_delay()
    local mh = deps_ref.CFG.mag_holster or {}
    return tonumber(mh.calibrate_delay_sec) or 5.0
end

local function start_mag_holster_calibrate()
    if deps_ref == nil or type(deps_ref.CFG) ~= "table" then
        log.warn("[re2_vr_reload] Mag holster calibrate skipped — reload not initialized")
        return
    end
    if mag_holster_st.vrmod_warned ~= true and not vrmod then
        mag_holster_st.vrmod_warned = true
        log.warn("[re2_vr_reload] vrmod unavailable — mag holster haptics and grip detection disabled")
    end
    mag_holster_cap.pending = true
    mag_holster_cap.deadline = os.clock() + mag_holster_calibrate_delay()
    mag_holster_cap.last_beep_int = -1
    mag_holster_cap.snap_hand = nil
    mag_holster_cap.snap_origin = nil
    mag_holster_st.status = string.format(
        "Hold left hand at hip — capture in %.0fs (close menu, stand in gameplay)",
        mag_holster_calibrate_delay())
    log.info("[re2_vr_reload] Mag holster calibrate: countdown started")
end

local function tick_mag_holster_calibrate()
    if not mag_holster_cap.pending then return end
    if deps_ref == nil or type(deps_ref.CFG) ~= "table" then
        mag_holster_cap.pending = false
        mag_holster_cap.last_beep_int = -1
        return
    end
    if mag_holster_st.vrmod_warned ~= true and not vrmod then
        mag_holster_st.vrmod_warned = true
        log.warn("[re2_vr_reload] vrmod unavailable — mag holster haptics and grip detection disabled")
    end

    local lj = get_left_joystick()
    local now = os.clock()
    local remaining = mag_holster_cap.deadline - now

    if remaining > 0 then
        snapshot_mag_holster_calibrate_pose()
        local snap_ok = mag_holster_cap.snap_hand ~= nil and mag_holster_cap.snap_origin ~= nil
        mag_holster_st.status = string.format(
            "Mag holster capture in %.1fs — hold left hand still%s",
            remaining, snap_ok and " (tracking OK)" or " (waiting for hand/body...)")
        return
    end

    mag_holster_cap.pending = false
    mag_holster_cap.last_beep_int = -1

    local hand_pos = mag_holster_cap.snap_hand or get_mag_holster_hand_pos()
    local origin = mag_holster_cap.snap_origin
    local ax = mag_holster_cap.snap_ax
    local ay = mag_holster_cap.snap_ay
    local az = mag_holster_cap.snap_az
    if not origin then
        origin, ax, ay, az = mag_holster_capture_pose()
    end
    if not hand_pos or not origin then
        mag_holster_st.status = string.format(
            "Calibrate failed — hand=%s body=%s (close REFramework menu, stand in-game)",
            tostring(hand_pos ~= nil),
            tostring(origin ~= nil))
        log.warn("[re2_vr_reload] Mag holster calibrate FAILED: missing hand or anchor")
        haptic_pulse(lj, 0.12, 80.0, 1.0)
        return
    end

    local off_x, off_y, off_z = decompose_hand_offset(hand_pos, origin, ax, ay, az)
    deps_ref.CFG.mag_holster = deps_ref.CFG.mag_holster or {}
    deps_ref.CFG.mag_holster.off_right = off_x
    deps_ref.CFG.mag_holster.off_up = off_y
    deps_ref.CFG.mag_holster.off_forward = off_z
    persist_mag_holster_profile_active()
    deps_ref.save_cfg()
    deps_ref.refresh_tuning_snapshot()

    haptic_pulse(lj or get_left_joystick(), 0.25, 250.0, 1.0)

    local profile_key = current_mag_holster_profile_key()
    local anchor_label = active_mag_holster_joint_name() or "body"
    mag_holster_st.status = string.format(
        "Calibrated [%s]: r=%.3f u=%.3f f=%.3f (anchor: %s)",
        profile_key, off_x, off_y, off_z, anchor_label)
    log.info(string.format(
        "[re2_vr_reload] Mag holster calibrated [%s]: r=%.3f u=%.3f f=%.3f anchor=%s",
        profile_key, off_x, off_y, off_z, anchor_label))
end

local function quat_from_ypr(yaw_deg, pitch_deg, roll_deg)
    local hy = math.rad(yaw_deg) * 0.5
    local hp = math.rad(pitch_deg) * 0.5
    local hr = math.rad(roll_deg) * 0.5
    local qz = Quaternion.new(math.cos(hy), 0, 0, math.sin(hy))
    local qy = Quaternion.new(math.cos(hp), 0, math.sin(hp), 0)
    local qx = Quaternion.new(math.cos(hr), math.sin(hr), 0, 0)
    return qz * qy * qx
end

local function mag_holster_enabled()
    local mh = deps_ref.CFG.mag_holster
    return mh == nil or mh.enabled ~= false
end

local function is_menu_blocking()
    local fn = rawget(_G, "__vr_is_menu_blocking")
    if type(fn) ~= "function" then return false end
    local ok, blocked = pcall(fn)
    return ok and blocked == true
end

local function get_player_equipment()
    local player = deps_ref.re2.get_localplayer()
    if not player then return nil end
    local equipment = nil
    pcall(function() equipment = player:call("get_Equipment") end)
    if equipment then return equipment end
    local eq_type = sdk.typeof(sdk.game_namespace("survivor.Equipment"))
    if eq_type then
        pcall(function() equipment = player:call("getComponent(System.Type)", eq_type) end)
    end
    return equipment
end

local function read_raw_weapon_chamber_bullet_count()
    local weapon = deps_ref.re2.weapon
    if not weapon then return 0 end
    local n = deps_ref.sc(weapon, "getBulletNumber")
    if type(n) ~= "number" then return 0 end
    return math.max(0, math.floor(n))
end

local function get_weapon_chamber_bullet_count()
    if mag.weapon_ammo_cleared == true then
        return 0
    end
    return read_raw_weapon_chamber_bullet_count()
end

local function get_imgr_singleton()
    return sdk.get_managed_singleton(sdk.game_namespace("gamemastering.InventoryManager"))
end

-- HUD loaded / carried (shotgun reserve box): IMgr remaining=loaded, reloadable=carried.
local function get_imgr_weapon_loaded()
    local im = get_imgr_singleton()
    if not im then return nil end
    local n = deps_ref.sc(im, "getMainWeaponRemainingBullet")
    if type(n) ~= "number" then return nil end
    return math.max(0, math.floor(n))
end

local function get_imgr_weapon_carried()
    local im = get_imgr_singleton()
    if not im then return nil end
    local n = deps_ref.sc(im, "getMainWeaponReloadableBullet")
    if type(n) ~= "number" then return nil end
    return math.max(0, math.floor(n))
end

local function get_shell_hud_ammo()
    local loaded = get_imgr_weapon_loaded()
    local carried = get_imgr_weapon_carried()
    if loaded == nil then loaded = get_weapon_chamber_bullet_count() end
    if carried == nil then carried = get_main_weapon_reserve_ammo_count() end
    return loaded, carried
end

local function get_weapon_mag_slot_round_count()
    local inv = deps_ref.re2.inventory
    if not inv then return 0 end
    local slot = deps_ref.sc(inv, "get_MainSlot")
    if not slot then return 0 end
    local n = deps_ref.sc(slot, "get_Number")
    if type(n) ~= "number" then return 0 end
    return math.max(0, math.floor(n))
end

local function get_weapon_reloadable_count()
    local weapon = deps_ref.re2.weapon
    if not weapon then return 0 end
    local n = deps_ref.sc(weapon, "getReloadableBulletNumber")
    if type(n) == "number" then return math.max(0, math.floor(n)) end
    local equipment = get_player_equipment()
    local wt = deps_ref.sc(weapon, "get_WeaponType")
    if equipment and wt ~= nil then
        n = deps_ref.sc(equipment, "getReloadableBulletNumber", wt)
        if type(n) == "number" then return math.max(0, math.floor(n)) end
    end
    return 0
end

local function capture_mag_carried_rounds()
    local chamber = get_weapon_chamber_bullet_count()
    local slot = get_weapon_mag_slot_round_count()
    local n = chamber
    if slot > n then
        n = slot
    end
    if n > 0 then
        mag.carried_rounds = n
        mag.reserve_cache_n = nil
    end
end

local function clear_mag_carried_rounds()
    mag.carried_rounds = 0
end

local function get_mag_carried_rounds()
    return math.max(0, math.floor(tonumber(mag.carried_rounds) or 0))
end

local function clear_tactical_rack_state_if_needed()
    -- Empty-chamber rack workflow: slide must stay open until manual rack completes.
    if rawget(_G, "__vr_needs_rack") == true then return end
    if get_mag_carried_rounds() > 0 and deps_ref.clear_tactical_rack_state then
        deps_ref.clear_tactical_rack_state()
    end
end

local function get_main_weapon_bullet_id()
    local inv = deps_ref.re2.inventory
    if not inv then return nil end
    local slot = deps_ref.sc(inv, "get_MainSlot")
    local bullet_id = slot and deps_ref.sc(slot, "get_BulletID")
    if bullet_id == nil then
        bullet_id = deps_ref.sc(inv, "get_MainSlotSurplusBulletID")
    end
    return bullet_id
end

-- Spare rounds in HUD not yet in reloadable pool after save load.
local function get_inventory_spare_bullet_count()
    local inv = deps_ref.re2.inventory
    if not inv then return 0 end

    local best = 0
    local surplus = deps_ref.sc(inv, "get_MainSlotSurplusBulletNumber")
    if type(surplus) == "number" then
        best = math.max(best, math.floor(surplus))
    end

    local bullet_id = get_main_weapon_bullet_id()
    if bullet_id ~= nil then
        local stack = deps_ref.sc(inv, "getSlotNumber", bullet_id)
        if type(stack) == "number" then
            local in_weapon = get_weapon_mag_slot_round_count()
            best = math.max(best, math.max(0, math.floor(stack) - in_weapon))
        end
        local im = get_imgr_singleton()
        if im then
            local item_n = deps_ref.sc(im, "getItemNumber", bullet_id)
            if type(item_n) == "number" then
                local in_weapon = get_weapon_mag_slot_round_count()
                best = math.max(best, math.max(0, math.floor(item_n) - in_weapon))
            end
        end
    end

    return best
end

local function prime_main_weapon_reloadable_pool()
    mag.reserve_cache_n = nil
    if get_inventory_spare_bullet_count() <= 0 then return end

    local inv = deps_ref.re2.inventory
    if not inv then return end
    local bullet_id = get_main_weapon_bullet_id()
    if bullet_id ~= nil then
        pcall(function() inv:call("set_MainSlotSurplusBulletID", bullet_id) end)
    end
    local spare = get_inventory_spare_bullet_count()
    if spare > 0 then
        pcall(function() inv:call("set_MainSlotSurplusBulletNumber", spare) end)
    end
    rawset(_G, "__vr_mag_ammo_commit_bypass", true)
    deps_ref.ammo.internal_commit = true
    pcall(function() inv:call("changeBulletMainSlotWithoutReload") end)
    deps_ref.ammo.internal_commit = false
    rawset(_G, "__vr_mag_ammo_commit_bypass", nil)
    mag.reserve_cache_n = nil
end

local function get_main_weapon_reserve_ammo_count()
    local now = os.clock()
    if mag.reserve_cache_n ~= nil and (now - mag.reserve_cache_t) < 0.1 then
        return mag.reserve_cache_n
    end

    local best = 0
    local function consider(n)
        if type(n) == "number" and n > best then best = n end
    end

    local im = sdk.get_managed_singleton(sdk.game_namespace("gamemastering.InventoryManager"))
    if im then
        consider(deps_ref.sc(im, "getMainWeaponReloadableBullet"))
    end

    local inv = deps_ref.re2.inventory
    if inv then
        consider(deps_ref.sc(inv, "getReloadableBulletMainSlot", false))
    end

    local weapon = deps_ref.re2.weapon
    if weapon then
        consider(deps_ref.sc(weapon, "getReloadableBulletNumber"))
        local player = deps_ref.re2.get_localplayer()
        if player then
            local eq_type = sdk.typeof(sdk.game_namespace("survivor.Equipment"))
            if eq_type then
                local ok, eq = pcall(function()
                    return player:call("getComponent(System.Type)", eq_type)
                end)
                if ok and eq then
                    local wt = deps_ref.sc(weapon, "get_WeaponType")
                    if wt ~= nil then
                        consider(deps_ref.sc(eq, "getReloadableBulletNumber", wt))
                    end
                end
            end
        end
    end

    local pooled = best
    local spare = get_inventory_spare_bullet_count()
    consider(spare)

    mag.reserve_cache_t = now
    mag.reserve_cache_n = best
    return best
end

local pending_reserve_top_up = nil

local function zero_weapon_chamber_without_reserve_touch()
    local weapon = deps_ref.re2.weapon
    if not weapon then return false end

    local cleared = false
    local handle = deps_ref.sc(weapon, "get_ReloadTrackHandle")
    local track = handle and (deps_ref.sc(handle, "get_Track") or deps_ref.sc(handle, "getTrack"))
    if track then
        pcall(function() track:set_field("Number", 0) end)
        if get_weapon_chamber_bullet_count() <= 0 then cleared = true end
    end
    if not cleared then
        for _, fname in ipairs({ "BulletNumber", "_BulletNumber", "<BulletNumber>k__BackingField" }) do
            pcall(function()
                if weapon:get_field(fname) ~= nil then
                    weapon:set_field(fname, 0)
                end
            end)
            if get_weapon_chamber_bullet_count() <= 0 then
                cleared = true
                break
            end
        end
    end
    return cleared
end

local function sync_weapon_chamber_display_zero()
    local weapon = deps_ref.re2.weapon
    local inv = deps_ref.re2.inventory
    if inv then
        local slot = deps_ref.sc(inv, "get_MainSlot")
        if slot then
            pcall(function() inv:call("set_MainSlotSurplusBulletNumber", 0) end)
            pcall(function() slot:call("set_Number", 0) end)
        end
    end
    if weapon then
        pcall(function() weapon:call("setBulletNumber", 0) end)
        for _, fname in ipairs({ "BulletNumber", "_BulletNumber", "<BulletNumber>k__BackingField" }) do
            pcall(function()
                if weapon:get_field(fname) ~= nil then
                    weapon:set_field(fname, 0)
                end
            end)
        end
        local handle = deps_ref.sc(weapon, "get_ReloadTrackHandle")
        local track = handle and (deps_ref.sc(handle, "get_Track") or deps_ref.sc(handle, "getTrack"))
        if track then
            pcall(function() track:set_field("Number", 0) end)
        end
    end
    zero_weapon_chamber_without_reserve_touch()
end

local chamber_display_hooks_installed = false

local function should_spoof_weapon_chamber_empty()
    if type(deps_ref.manual_reload_context_active) == "function"
        and not deps_ref.manual_reload_context_active() then
        return false
    end
    return mag.weapon_ammo_cleared == true
end

local function install_chamber_display_hooks()
    if chamber_display_hooks_installed then return end

    local gun_type = sdk.find_type_definition(sdk.game_namespace("implement.Gun"))
    if gun_type then
        local method = gun_type:get_method("getBulletNumber")
        if method then
            sdk.hook(method, nil, function(retval)
                if should_spoof_weapon_chamber_empty() then
                    return 0
                end
                return retval
            end)
        end
    end

    local im_type = sdk.find_type_definition(sdk.game_namespace("gamemastering.InventoryManager"))
    if im_type then
        local method = im_type:get_method("getMainWeaponRemainingBullet")
        if method then
            sdk.hook(method, nil, function(retval)
                if should_spoof_weapon_chamber_empty() then
                    return 0
                end
                return retval
            end)
        end
    end

    chamber_display_hooks_installed = true
end

-- Zero Gun.getBulletNumber while rounds live in mag.carried_rounds.
local function clear_weapon_chamber_ammo()
    if mag.weapon_ammo_cleared == true then
        return get_weapon_chamber_bullet_count() <= 0
    end

    local before = get_weapon_chamber_bullet_count()
    if before <= 0 then
        mag.weapon_ammo_cleared = true
        return true
    end

    local weapon = deps_ref.re2.weapon
    local equipment = get_player_equipment()
    local wt = weapon and deps_ref.sc(weapon, "get_WeaponType")
    local reserve_before = get_main_weapon_reserve_ammo_count()
    local cleared = false
    local tactical = get_mag_carried_rounds() > 0

    if tactical and weapon then
        local handle = deps_ref.sc(weapon, "get_ReloadTrackHandle")
        local track = handle and (deps_ref.sc(handle, "get_Track") or deps_ref.sc(handle, "getTrack"))
        if track then
            pcall(function() track:set_field("Number", 0) end)
            if get_weapon_chamber_bullet_count() <= 0 then cleared = true end
        end
        if not cleared then
            for _, fname in ipairs({ "BulletNumber", "_BulletNumber", "<BulletNumber>k__BackingField" }) do
                pcall(function()
                    if weapon:get_field(fname) ~= nil then
                        weapon:set_field(fname, 0)
                    end
                end)
                if get_weapon_chamber_bullet_count() <= 0 then
                    cleared = true
                    break
                end
            end
        end
    end

    if tactical and not cleared then
        cleared = zero_weapon_chamber_without_reserve_touch()
    end

    if not cleared and not tactical and equipment and before > 0 then
        pcall(function() equipment:call("useMainWeapon", before) end)
        if get_weapon_chamber_bullet_count() <= 0 then cleared = true end
    end
    if not cleared and not tactical and equipment and wt ~= nil then
        pcall(function() equipment:call("use", wt, before) end)
        if get_weapon_chamber_bullet_count() <= 0 then cleared = true end
    end
    if not cleared and not tactical and equipment and wt ~= nil then
        pcall(function() equipment:call("executeEndEject", wt) end)
        if get_weapon_chamber_bullet_count() <= 0 then cleared = true end
    end
    if not cleared and not tactical and weapon then
        pcall(function() weapon:call("executeEndEject") end)
        if get_weapon_chamber_bullet_count() <= 0 then cleared = true end
    end
    if not cleared and weapon then
        local handle = deps_ref.sc(weapon, "get_ReloadTrackHandle")
        local track = handle and (deps_ref.sc(handle, "get_Track") or deps_ref.sc(handle, "getTrack"))
        if track then
            pcall(function() track:set_field("Number", 0) end)
            if get_weapon_chamber_bullet_count() <= 0 then cleared = true end
        end
    end
    if not cleared and weapon then
        for _, fname in ipairs({ "BulletNumber", "_BulletNumber", "<BulletNumber>k__BackingField" }) do
            pcall(function()
                if weapon:get_field(fname) ~= nil then
                    weapon:set_field(fname, 0)
                end
            end)
            if get_weapon_chamber_bullet_count() <= 0 then
                cleared = true
                break
            end
        end
    end

    local reserve_after = get_main_weapon_reserve_ammo_count()
    if reserve_before ~= reserve_after then
        log.warn(string.format(
            "[re2_vr_reload] clear_weapon_chamber_ammo touched reserve %d -> %d",
            reserve_before, reserve_after))
    end

    if not cleared then
        log.warn(string.format(
            "[re2_vr_reload] Could not clear weapon chamber (%d rounds)",
            before))
    end

    mag.weapon_ammo_cleared = cleared
    mag.reserve_cache_n = nil
    return cleared
end

local function return_weapon_ammo_to_reserve()
    local loaded = get_weapon_chamber_bullet_count()
    if loaded <= 0 then
        mag.weapon_ammo_cleared = true
        return 0
    end

    local inv = deps_ref.re2.inventory
    if not inv then return 0 end

    local slot = deps_ref.sc(inv, "get_MainSlot")
    local bullet_id = slot and deps_ref.sc(slot, "get_BulletID")
    if bullet_id == nil then bullet_id = deps_ref.sc(inv, "get_MainSlotSurplusBulletID") end

    mag.reserve_cache_n = nil
    local reserve_before = get_main_weapon_reserve_ammo_count()
    mag.weapon_ammo_cleared = false

    local equipment = get_player_equipment()
    local cleared = false

    if equipment and loaded > 0 then
        pcall(function() equipment:call("useMainWeapon", loaded) end)
        if get_weapon_chamber_bullet_count() <= 0 then
            cleared = true
        end
    end

    if not cleared then
        cleared = zero_weapon_chamber_without_reserve_touch()
    end

    mag.reserve_cache_n = nil
    local reserve_after = get_main_weapon_reserve_ammo_count()
    local credited = math.max(0, reserve_after - reserve_before)

    if cleared and bullet_id ~= nil and credited < loaded then
        pcall(function() inv:call("addSlotNumber", bullet_id, loaded - credited) end)
        mag.reserve_cache_n = nil
    end

    if not cleared then
        log.warn(string.format(
            "[re2_vr_reload] return_weapon_ammo_to_reserve could not clear chamber (%d)",
            loaded))
        mag.weapon_ammo_cleared = false
        return 0
    end

    mag.weapon_ammo_cleared = true
    mag.reserve_cache_n = nil
    reserve_after = get_main_weapon_reserve_ammo_count()
    log.info(string.format(
        "[re2_vr_reload] return_weapon_ammo_to_reserve loaded=%d reserve %d->%d",
        loaded, reserve_before, reserve_after))
    return loaded
end

local function on_chamber_ammo_to_carried(stash_n)
    local chamber = tonumber(stash_n)
    if chamber == nil or chamber < 0 then
        chamber = get_weapon_chamber_bullet_count()
        local slot = get_weapon_mag_slot_round_count()
        if slot > chamber then
            chamber = slot
        end
    end
    chamber = math.max(0, math.floor(chamber))
    if chamber > 0 then
        mag.carried_rounds = chamber
        mag.reserve_cache_n = nil
        mag.weapon_ammo_cleared = true
        sync_weapon_chamber_display_zero()
        log.info(string.format(
            "[re2_vr_reload] Cached %d rounds to carried (chamber clear, reserve untouched)",
            chamber))
    else
        mag.weapon_ammo_cleared = false
        clear_weapon_chamber_ammo()
    end
    clear_tactical_rack_state_if_needed()
end

local function on_mag_physically_out()
    on_chamber_ammo_to_carried()
end

local function mag_holster_supply_available()
    if type(deps_ref.revolver_holster_supply_available) == "function" then
        local rev_sup = deps_ref.revolver_holster_supply_available()
        if rev_sup ~= nil then return rev_sup == true end
    end
    if type(deps_ref.shell_holster_supply_available) == "function" then
        local shell_sup = deps_ref.shell_holster_supply_available()
        if shell_sup ~= nil then return shell_sup == true end
    end
    if mag.state == MAG_STATE.IN_HAND
        or mag.state == MAG_STATE.INSERTING
        or mag.state == MAG_STATE.DROPPING then
        return true
    end
    if mag.state ~= MAG_STATE.OUT then
        return true
    end
    if get_main_weapon_reserve_ammo_count() > 0 then return true end
    return get_mag_carried_rounds() > 0
end

local function mag_holster_context_active()
    if type(deps_ref.revolver_holster_context_active) == "function"
        and deps_ref.revolver_holster_context_active() then
        return true
    end
    if type(deps_ref.shell_holster_context_active) == "function"
        and deps_ref.shell_holster_context_active() then
        return true
    end
    if deps_ref.CFG.enabled ~= true or not mag_holster_enabled() then return false end
    if mag_holster_cap.pending then return true end
    if mag.state == MAG_STATE.OUT
        or mag.state == MAG_STATE.IN_HAND
        or mag.state == MAG_STATE.DROPPING
        or mag.state == MAG_STATE.INSERTING
        or mag_hand.active
        or mag_hand.release_fall_active then
        return true
    end
    return false
end

local function revolver_weapon_equipped_idle()
    if type(deps_ref.revolver_weapon_equipped) == "function" and deps_ref.revolver_weapon_equipped() then
        if type(deps_ref.revolver_has_bullet_in_hand) == "function" and deps_ref.revolver_has_bullet_in_hand() then
            return false
        end
        return true
    end
    return false
end

local function shell_weapon_equipped_idle()
    if type(deps_ref.shell_weapon_equipped) == "function" and deps_ref.shell_weapon_equipped() then
        if type(deps_ref.shell_has_shell_in_hand) == "function" and deps_ref.shell_has_shell_in_hand() then
            return false
        end
        return true
    end
    return false
end

local function revolver_in_hand_exempts_shoot_ready_suppress()
    if type(deps_ref.revolver_aux_input_suppress_wanted) == "function"
        and deps_ref.revolver_aux_input_suppress_wanted() then
        return false
    end
    if type(deps_ref.revolver_shoot_ready_suppress_exempt) == "function"
        and deps_ref.revolver_shoot_ready_suppress_exempt() then
        return true
    end
    if type(deps_ref.revolver_weapon_equipped) ~= "function" or not deps_ref.revolver_weapon_equipped() then
        return false
    end
    if type(deps_ref.revolver_has_bullet_in_hand) ~= "function" then return false end
    return deps_ref.revolver_has_bullet_in_hand() == true
end

local function shell_in_hand_exempts_shoot_ready_suppress()
    if type(deps_ref.shell_shoot_ready_suppress_exempt) == "function"
        and deps_ref.shell_shoot_ready_suppress_exempt() then
        return true
    end
    if type(deps_ref.shell_weapon_equipped) ~= "function" or not deps_ref.shell_weapon_equipped() then
        return false
    end
    if type(deps_ref.shell_has_shell_in_hand) ~= "function" then return false end
    return deps_ref.shell_has_shell_in_hand() == true
end

local function shell_sub_weapon_suppress_active()
    if type(deps_ref.shell_reload_session_active) == "function"
        and deps_ref.shell_reload_session_active() then
        return true
    end
    if type(deps_ref.shell_weapon_equipped) ~= "function" or not deps_ref.shell_weapon_equipped() then
        return false
    end
    if type(deps_ref.shell_has_shell_in_hand) == "function" and deps_ref.shell_has_shell_in_hand() then
        return true
    end
    return false
end

local function revolver_sub_weapon_suppress_active()
    if type(deps_ref.revolver_aux_input_suppress_wanted) == "function"
        and deps_ref.revolver_aux_input_suppress_wanted() then
        return true
    end
    if type(deps_ref.revolver_weapon_equipped) ~= "function" or not deps_ref.revolver_weapon_equipped() then
        return false
    end
    if type(deps_ref.revolver_has_bullet_in_hand) == "function" and deps_ref.revolver_has_bullet_in_hand() then
        return true
    end
    return false
end

local function shell_or_revolver_sub_weapon_suppress_active()
    return shell_sub_weapon_suppress_active() or revolver_sub_weapon_suppress_active()
end

local function mag_holster_session_suppresses_shoot_ready()
    if not deps_ref.manual_reload_context_active() then return false end
    if mag.state == MAG_STATE.IN_HAND
        or mag.state == MAG_STATE.INSERTING
        or mag.state == MAG_STATE.DROPPING then
        return true
    end
    if mag_hand.active or mag_hand.release_fall_active then return true end
    if mag.anim_active then return true end
    if deps_ref.frame.vr_reload_b then return true end
    if os.clock() < deps_ref.suppress.until_t then
        if type(deps_ref.shell_weapon_equipped) == "function" and deps_ref.shell_weapon_equipped() then
            return false
        end
        if type(deps_ref.revolver_weapon_equipped) == "function" and deps_ref.revolver_weapon_equipped() then
            return false
        end
        return true
    end
    return false
end

local function mag_holster_zone_haptics_allowed()
    if revolver_weapon_equipped_idle()
        and type(deps_ref.revolver_holster_wants_grab) == "function"
        and deps_ref.revolver_holster_wants_grab() then
        return true
    end
    if shell_weapon_equipped_idle()
        and type(deps_ref.shell_holster_wants_grab) == "function"
        and deps_ref.shell_holster_wants_grab() then
        return true
    end
    return mag.state == MAG_STATE.OUT
        and not mag_hand.active
        and not mag_hand.release_fall_active
        and mag_holster_supply_available()
end

local function mag_holster_empty_denial_active()
    if type(deps_ref.revolver_holster_empty_denial_active) == "function"
        and deps_ref.revolver_holster_empty_denial_active() then
        return true
    end
    if type(deps_ref.shell_holster_empty_denial_active) == "function"
        and deps_ref.shell_holster_empty_denial_active() then
        return true
    end
    return mag.state == MAG_STATE.OUT
        and not mag_hand.active
        and not mag_hand.release_fall_active
        and not mag_holster_supply_available()
end

local function maybe_mag_holster_zone_haptic(lj, mh)
    if mag.ambient_holster_haptics_suppressed() then
        mag_holster_st.haptic_pending_frames = 0
        mag_holster_st.zone_enter_pulse = false
        return
    end
    if not mag_holster_zone_haptics_allowed() then
        mag_holster_st.haptic_pending_frames = 0
        mag_holster_st.zone_enter_pulse = false
        return
    end
    if mh.zone_haptic_enabled == false or not mag_holster_st.in_zone or not lj then
        if not mag_holster_st.in_zone then
            mag_holster_st.haptic_pending_frames = 0
            mag_holster_st.zone_enter_pulse = false
        end
        return
    end
    if mag_holster_st.zone_enter_pulse then
        mag_holster_st.zone_enter_pulse = false
        mag_holster_st.haptic_pending_frames = 0
        haptic_pulse(lj,
            tonumber(mh.zone_haptic_duration) or 0.15,
            tonumber(mh.zone_haptic_frequency) or 58.883,
            tonumber(mh.zone_haptic_amplitude) or 0.05)
        return
    end
    if mh.zone_haptic_continuous ~= true then
        return
    end
    local interval = tonumber(mh.zone_haptic_frames) or 3
    if interval < 1 then interval = 1 end
    mag_holster_st.haptic_pending_frames = (mag_holster_st.haptic_pending_frames or 0) + 1
    if mag_holster_st.haptic_pending_frames >= interval then
        mag_holster_st.haptic_pending_frames = 0
        haptic_pulse(lj,
            tonumber(mh.zone_haptic_duration) or 0.15,
            tonumber(mh.zone_haptic_frequency) or 58.883,
            tonumber(mh.zone_haptic_amplitude) or 0.05)
    end
end

local function mag_ease(t)
    if t <= 0.0 then return 0.0 end
    if t >= 1.0 then return 1.0 end
    return t * t * (3.0 - 2.0 * t)
end

local function mag_anim_duration(phase)
    local anim = deps_ref.CFG.anim or {}
    if phase == "fall" then
        return math.max(0.01, tonumber(anim.fall_sec) or 0.5)
    end
    if phase == "insert" then
        return math.max(0.01, tonumber(anim.insert_sec) or 0.18)
    end
    return math.max(0.01, tonumber(anim.drop_sec) or 0.18)
end

local function mag_fall_distance()
    return tonumber((deps_ref.CFG.anim or {}).fall_distance) or 1.2
end

local function mag_fall_local_offset_y()
    return tonumber((deps_ref.CFG.anim or {}).fall_local_y) or -0.45
end

local function get_mag_exit_pos(wp_name)
    local def = deps_ref.CFG.mag_exit_default or {}
    local ex = tonumber(def.x) or 0.0
    local ey = tonumber(def.y)
    local ez = tonumber(def.z) or -0.035
    if ey == nil then
        ey = mag.rest_y + (tonumber((deps_ref.CFG.anim or {}).drop_local_y) or -0.12)
    end
    local by_wp = wp_name and deps_ref.CFG.mag_exit_by_wp and deps_ref.CFG.mag_exit_by_wp[wp_name]
    if type(by_wp) == "table" then
        if by_wp.x ~= nil then ex = tonumber(by_wp.x) or ex end
        if by_wp.y ~= nil then ey = tonumber(by_wp.y) or ey end
        if by_wp.z ~= nil then ez = tonumber(by_wp.z) or ez end
    end
    return ex, ey, ez
end

local function cache_mag_exit_for_weapon(wp_name)
    local ex, ey, ez = get_mag_exit_pos(wp_name)
    if ex ~= mag.exit_x or ey ~= mag.exit_y or ez ~= mag.exit_z then
        mag.exit_ref_valid = false
    end
    mag.exit_x = ex
    mag.exit_y = ey
    mag.exit_z = ez
end

local function ensure_mag_exit_entry(wp_name)
    if not wp_name then return nil end
    deps_ref.CFG.mag_exit_by_wp = deps_ref.CFG.mag_exit_by_wp or {}
    local entry = deps_ref.CFG.mag_exit_by_wp[wp_name]
    if type(entry) ~= "table" then
        local def = deps_ref.CFG.mag_exit_default or {}
        entry = {
            x = tonumber(def.x) or 0.0,
            y = tonumber(def.y) or -0.103,
            z = tonumber(def.z) or -0.035,
            pitch = tonumber(def.pitch) or 0.0,
            yaw = tonumber(def.yaw) or 0.0,
            roll = tonumber(def.roll) or 0.0,
        }
        deps_ref.CFG.mag_exit_by_wp[wp_name] = entry
    end
    return entry
end

local function get_mag_node_name(wp_name)
    if not wp_name or type(deps_ref.CFG.mag_node_by_wp) ~= "table" then return nil end
    return deps_ref.CFG.mag_node_by_wp[wp_name]
end

local function weapon_uses_manual_shell_reload(wp_name)
    if not wp_name or type(deps_ref.CFG.weapons) ~= "table" then return false end
    local entry = deps_ref.CFG.weapons[wp_name]
    return entry and entry.needs_manual_shell_reload == true
end

local function weapon_uses_manual_cylinder_reload(wp_name)
    if not wp_name or type(deps_ref.CFG.weapons) ~= "table" then return false end
    local entry = deps_ref.CFG.weapons[wp_name]
    if not entry then return false end
    if entry.needs_manual_cylinder_reload == true then return true end
    return entry.needs_manual_revolver_reload == true
end

local function weapon_uses_manual_revolver_reload(wp_name)
    return weapon_uses_manual_cylinder_reload(wp_name)
end

local function mag_visuals_configured(wp_name)
    if weapon_uses_manual_shell_reload(wp_name) then return false end
    if weapon_uses_manual_revolver_reload(wp_name) then return false end
    return get_mag_node_name(wp_name) ~= nil and deps_ref.is_weapon_enabled(wp_name)
end

local function find_transform_child_by_name(root_tf, name, depth)
    if not root_tf or not name or (depth or 0) > 14 then return nil end
    depth = depth or 0

    local child = deps_ref.sc(root_tf, "get_Child")
    while child do
        local go = deps_ref.sc(child, "get_GameObject")
        local go_name = go and deps_ref.sc(go, "get_Name")
        if go_name == name then
            return child
        end
        local nested = find_transform_child_by_name(child, name, depth + 1)
        if nested then return nested end
        child = deps_ref.sc(child, "get_Next")
    end
    return nil
end

local function collect_child_gameobject_names(root_tf, out, seen, depth)
    if not root_tf then return end
    out = out or {}
    seen = seen or {}
    depth = depth or 0
    if depth > 14 then return end

    local child = deps_ref.sc(root_tf, "get_Child")
    while child do
        local go = deps_ref.sc(child, "get_GameObject")
        local nm = go and deps_ref.sc(go, "get_Name")
        if type(nm) == "string" and nm ~= "" and not seen[nm] then
            seen[nm] = true
            out[#out + 1] = nm
        end

        collect_child_gameobject_names(child, out, seen, depth + 1)
        child = deps_ref.sc(child, "get_Next")
    end
    return out
end

local function deep_copy(tbl)
    if type(tbl) ~= "table" then return tbl end
    local out = {}
    for k, v in pairs(tbl) do
        out[k] = deep_copy(v)
    end
    return out
end

local mag_clipboard = {
    mag_node = nil,        -- string
    mag_exit = nil,        -- {x,y,z}
    mag_hand_hold = nil,   -- {ox,oy,oz,yaw,pitch,roll}
    source_wp = nil,
    source_profile = nil,
}

local function resolve_mag_target(weapon_xform, node_name)
    if not weapon_xform or not node_name then return nil, nil end

    local joint = deps_ref.sc(weapon_xform, "getJointByName", node_name)
    if joint then return joint, "joint" end

    local child_tf = find_transform_child_by_name(weapon_xform, node_name, 0)
    if child_tf then
        local child_joint = deps_ref.sc(weapon_xform, "getJointByName", node_name)
        if child_joint then return child_joint, "joint" end
        return child_tf, "xform"
    end

    return nil, nil
end

local function read_target_local_position(target, kind)
    if not target then return nil end
    if kind == "joint" then
        local pos = deps_ref.sc(target, "get_LocalPosition")
        if pos then return pos end
        pos = deps_ref.sc(target, "get_BaseLocalPosition")
        if pos then return pos end
        local tf = deps_ref.sc(target, "get_Transform")
        if tf then
            pos = deps_ref.sc(tf, "get_LocalPosition")
            if pos then return pos end
        end
        return nil
    end
    return deps_ref.sc(target, "get_LocalPosition")
end

local function write_target_local_position(target, kind, pos)
    if not target or not pos then return false end
    if kind == "joint" then
        if deps_ref.sc(target, "set_LocalPosition", pos) then return true end
        local tf = deps_ref.sc(target, "get_Transform")
        if tf and deps_ref.sc(tf, "set_LocalPosition", pos) then return true end
        return false
    end
    return deps_ref.sc(target, "set_LocalPosition", pos) == true
end

local function write_target_local_rotation(target, kind, rot)
    if not target or not rot then return false end
    if kind == "joint" then
        if deps_ref.sc(target, "set_LocalRotation", rot) then return true end
        local tf = deps_ref.sc(target, "get_Transform")
        if tf and deps_ref.sc(tf, "set_LocalRotation", rot) then return true end
        return false
    end
    return deps_ref.sc(target, "set_LocalRotation", rot) == true
end

local function get_mag_parent_transform()
    if mag.target_kind == "joint" and mag.target then
        local tf = deps_ref.sc(mag.target, "get_Transform")
        if tf then
            local parent = deps_ref.sc(tf, "get_Parent")
            if parent then return parent end
        end
    end
    return mag.weapon_xform
end

local function world_pos_to_parent_local(parent_tf, world_pos)
    if not parent_tf or not world_pos then return nil end
    local parent_pos = deps_ref.sc(parent_tf, "get_Position")
    local parent_rot = deps_ref.sc(parent_tf, "get_Rotation")
    if not parent_pos or not parent_rot then return nil end
    local inv = parent_rot:conjugate()
    local delta = Vector3f.new(
        world_pos.x - parent_pos.x,
        world_pos.y - parent_pos.y,
        world_pos.z - parent_pos.z)
    return inv * delta
end

local function world_pose_to_parent_local(parent_tf, world_pos, world_rot)
    if not parent_tf or not world_pos or not world_rot then return nil, nil end
    local local_pos = world_pos_to_parent_local(parent_tf, world_pos)
    if not local_pos then return nil, nil end
    local parent_rot = deps_ref.sc(parent_tf, "get_Rotation")
    if not parent_rot then return nil, nil end
    local local_rot = parent_rot:conjugate() * world_rot
    return local_pos, local_rot
end

local function read_target_world_position(target, kind)
    if not target then return nil end
    if kind == "joint" then
        local pos = deps_ref.sc(target, "get_Position")
        if pos then return pos end
        local tf = deps_ref.sc(target, "get_Transform")
        if tf then
            pos = deps_ref.sc(tf, "get_Position")
            if pos then return pos end
        end
        return nil
    end
    return deps_ref.sc(target, "get_Position")
end

local function read_target_world_matrix(target, kind)
    if not target then return nil end
    if kind == "joint" then
        local wm = deps_ref.sc(target, "get_WorldMatrix")
        if wm then return wm end
        local tf = deps_ref.sc(target, "get_Transform")
        if tf then
            wm = deps_ref.sc(tf, "get_WorldMatrix")
            if wm then return wm end
        end
        return nil
    end
    return deps_ref.sc(target, "get_WorldMatrix")
end

local function world_matrix_to_position(wm)
    if not wm then return nil end
    local p = wm[3]
    if not p then return nil end
    if p.to_vec3 then
        local ok, v = pcall(function() return p:to_vec3() end)
        if ok and v then return v end
    end
    return Vector3f.new(p.x, p.y, p.z)
end

local function world_matrix_to_rotation(wm)
    if not wm then return nil end
    local ok, rot = pcall(function() return wm:to_quat() end)
    if ok and rot then return rot end
    return nil
end

local function read_target_world_rotation(target, kind)
    local wm = read_target_world_matrix(target, kind)
    if wm then
        local rot = world_matrix_to_rotation(wm)
        if rot then return rot end
    end
    if kind == "joint" then
        local rot = deps_ref.sc(target, "get_Rotation")
        if rot then return rot end
        local tf = deps_ref.sc(target, "get_Transform")
        if tf then
            rot = deps_ref.sc(tf, "get_Rotation")
            if rot then return rot end
        end
        return nil
    end
    return deps_ref.sc(target, "get_Rotation")
end

local function write_target_world_position_only(target, kind, pos)
    if not target or not pos then return false end
    if kind == "joint" then
        if deps_ref.sc(target, "set_Position", pos) then return true end
        local tf = deps_ref.sc(target, "get_Transform")
        if tf and deps_ref.sc(tf, "set_Position", pos) then return true end
        return false
    end
    return deps_ref.sc(target, "set_Position", pos) == true
end

local function write_target_world_rotation(target, kind, rot)
    if not target or not rot then return false end
    if kind == "joint" then
        if deps_ref.sc(target, "set_Rotation", rot) then return true end
        local tf = deps_ref.sc(target, "get_Transform")
        if tf and deps_ref.sc(tf, "set_Rotation", rot) then return true end
        return false
    end
    return deps_ref.sc(target, "set_Rotation", rot) == true
end

local function cache_frozen_rotation(rot)
    if not rot then return end
    mag.frozen_rot_x = rot.x
    mag.frozen_rot_y = rot.y
    mag.frozen_rot_z = rot.z
    mag.frozen_rot_w = rot.w
end

local function get_frozen_rotation()
    return Quaternion.new(mag.frozen_rot_x, mag.frozen_rot_y, mag.frozen_rot_z, mag.frozen_rot_w)
end

local function set_mag_frozen_local(x, y, z)
    mag.freeze_mode = "local"
    mag.frozen_lx = x
    mag.frozen_ly = y
    mag.frozen_lz = z
    mag.freeze_pose = true
end

local function set_mag_frozen_local_full(x, y, z, rot)
    mag.freeze_mode = "local_full"
    mag.frozen_lx = x
    mag.frozen_ly = y
    mag.frozen_lz = z
    if rot then cache_frozen_rotation(rot) end
    mag.freeze_pose = true
end

local function set_mag_frozen_world(x, y, z)
    mag.freeze_mode = "world"
    mag.frozen_wx = x
    mag.frozen_wy = y
    mag.frozen_wz = z
    mag.freeze_pose = true
end

local function clear_mag_freeze()
    mag.freeze_pose = false
    mag.freeze_mode = "local"
end

local function read_target_local_scale(target, kind)
    if not target then return nil end
    if kind == "joint" then
        local s = deps_ref.sc(target, "get_LocalScale")
        if s then return s end
        local tf = deps_ref.sc(target, "get_Transform")
        if tf then return deps_ref.sc(tf, "get_LocalScale") end
        return nil
    end
    return deps_ref.sc(target, "get_LocalScale")
end

local function write_target_local_scale(target, kind, scale)
    if not target or not scale then return false end
    if kind == "joint" then
        if deps_ref.sc(target, "set_LocalScale", scale) then return true end
        local tf = deps_ref.sc(target, "get_Transform")
        if tf and deps_ref.sc(tf, "set_LocalScale", scale) then return true end
        return false
    end
    return deps_ref.sc(target, "set_LocalScale", scale) == true
end

local function visual_hide_uses_scale()
    local vh = deps_ref.CFG and deps_ref.CFG.visual_hide
    if type(vh) ~= "table" then return true end
    return vh.mode ~= "legacy"
end

local function apply_mag_frozen_pose()
    if mag.mesh_hidden then return end
    if not mag.freeze_pose or not mag.target then return end
    if mag.freeze_mode == "world" then
        write_target_world_position_only(mag.target, mag.target_kind,
            Vector3f.new(mag.frozen_wx, mag.frozen_wy, mag.frozen_wz))
    elseif mag.freeze_mode == "world_full" then
        write_target_world_position_only(mag.target, mag.target_kind,
            Vector3f.new(mag.frozen_wx, mag.frozen_wy, mag.frozen_wz))
        write_target_world_rotation(mag.target, mag.target_kind, get_frozen_rotation())
    elseif mag.freeze_mode == "local_full" then
        write_target_local_position(mag.target, mag.target_kind,
            Vector3f.new(mag.frozen_lx, mag.frozen_ly, mag.frozen_lz))
        write_target_local_rotation(mag.target, mag.target_kind, get_frozen_rotation())
    else
        write_target_local_position(mag.target, mag.target_kind,
            Vector3f.new(mag.frozen_lx, mag.frozen_ly, mag.frozen_lz))
    end
end

local function collect_subtree_gameobjects(root_go, out)
    if not root_go or not out then return end
    out[#out + 1] = root_go
    local tf = deps_ref.sc(root_go, "get_Transform")
    if not tf then return end
    local child = deps_ref.sc(tf, "get_Child")
    while child do
        collect_subtree_gameobjects(deps_ref.sc(child, "get_GameObject"), out)
        child = deps_ref.sc(child, "get_Next")
    end
end

local function rebuild_mag_hide_go_list()
    mag.hide_gos = {}
    local roots = {}
    if mag.mag_go then roots[#roots + 1] = mag.mag_go end
    if mag.target and mag.target_kind == "xform" then
        local go = deps_ref.sc(mag.target, "get_GameObject")
        if go then roots[#roots + 1] = go end
    end
    local seen = {}
    for _, root in ipairs(roots) do
        if root and not seen[root] then
            seen[root] = true
            collect_subtree_gameobjects(root, mag.hide_gos)
        end
    end
end

local function get_mag_root_gameobject()
    if mag.mag_go then return mag.mag_go end
    if not mag.target then return nil end
    if mag.target_kind == "xform" then
        return deps_ref.sc(mag.target, "get_GameObject")
    end
    local go = deps_ref.sc(mag.target, "get_GameObject")
    if go then return go end
    local tf = deps_ref.sc(mag.target, "get_Transform")
    return tf and deps_ref.sc(tf, "get_GameObject")
end

local function set_go_render_visible(go, visible)
    if not go then return end
    pcall(function() go:call("set_DrawSelf", visible == true) end)
    pcall(function() go:call("set_Enabled", visible == true) end)
    if not mesh_type then return end
    local mesh = deps_ref.sc(go, "getComponent(System.Type)", mesh_type)
    if not mesh then return end
    pcall(function() mesh:call("set_Enabled", visible == true) end)
    pcall(function() mesh:call("set_DrawSelf", visible == true) end)
    local num = deps_ref.sc(mesh, "get_MaterialNum")
    if type(num) ~= "number" then
        num = deps_ref.sc(mesh, "getMaterialNum")
    end
    num = tonumber(num) or 0
    for i = 0, math.min(num - 1, 63) do
        pcall(function()
            mesh:call("setPartsEnable(System.UInt64, System.Boolean)", i, visible == true)
        end)
    end
end

local function get_mag_mesh_part_indices(wp_name)
    if not wp_name or type(deps_ref.CFG.mesh_parts_by_wp) ~= "table" then return nil end
    local entry = deps_ref.CFG.mesh_parts_by_wp[wp_name]
    if type(entry) ~= "table" then return nil end
    if type(entry[1]) == "number" then return entry end
    if type(entry.mag) == "number" then return { entry.mag } end
    return nil
end

local function set_gun_mesh_parts_visible(indices, visible)
    if not indices or #indices == 0 then return end
    local gun = deps_ref.re2.weapon
    if not gun then return end

    for _, idx in ipairs(indices) do
        pcall(function() gun:call("setPartsEnable", visible == true, { idx }) end)
    end

    local mesh = deps_ref.sc(gun, "get_Mesh")
    if not mesh then return end
    for _, idx in ipairs(indices) do
        pcall(function()
            mesh:call("setPartsEnable(System.UInt64, System.Boolean)", idx, visible == true)
        end)
    end
end

local function apply_mag_hide_visuals()
    if mag.target and mag.has_rest then
        write_target_local_scale(mag.target, mag.target_kind, Vector3f.new(0, 0, 0))
    end
    if visual_hide_uses_scale() then return end
    if #mag.hide_gos == 0 then
        rebuild_mag_hide_go_list()
    end
    for _, go in ipairs(mag.hide_gos) do
        set_go_render_visible(go, false)
    end
    local root = get_mag_root_gameobject()
    if root and #mag.hide_gos == 0 then
        collect_subtree_gameobjects(root, mag.hide_gos)
        for _, go in ipairs(mag.hide_gos) do
            set_go_render_visible(go, false)
        end
    end
    set_gun_mesh_parts_visible(get_mag_mesh_part_indices(mag.cached_wp), false)
end

local function apply_mag_show_visuals()
    if mag.target and mag.has_rest then
        write_target_local_scale(mag.target, mag.target_kind,
            Vector3f.new(mag.rest_sx, mag.rest_sy, mag.rest_sz))
    end
    if visual_hide_uses_scale() then return end
    for _, go in ipairs(mag.hide_gos) do
        set_go_render_visible(go, true)
    end
    set_gun_mesh_parts_visible(get_mag_mesh_part_indices(mag.cached_wp), true)
end

local function hide_mag_mesh()
    mag.mesh_hidden = true
    apply_mag_hide_visuals()
    clear_mag_freeze()
    if mag.target and mag.has_rest then
        write_target_local_position(mag.target, mag.target_kind,
            Vector3f.new(mag.rest_x, mag.rest_y, mag.rest_z))
    end
    apply_mag_hide_visuals()
end

local function show_mag_mesh()
    mag.mesh_hidden = false
    apply_mag_show_visuals()
end

local function enforce_mag_mesh_hidden()
    if not mag.mesh_hidden then return end
    if mag_hand.active then return end
    apply_mag_hide_visuals()
end

local function set_mag_frozen_world_full(pos, rot)
    mag.freeze_mode = "world_full"
    mag.frozen_wx = pos.x
    mag.frozen_wy = pos.y
    mag.frozen_wz = pos.z
    if rot then cache_frozen_rotation(rot) end
    mag.freeze_pose = true
end

local function get_mag_hand_hold_entry()
    local root = deps_ref.CFG.mag_hand_hold or {}
    local wp = mag.cached_wp or deps_ref.get_weapon_go_name()
    local profile = current_mag_holster_profile_key()
    if wp and type(root.by_wp) == "table" and type(root.by_wp[wp]) == "table" then
        local wp_entry = root.by_wp[wp]
        local prof_entry = wp_entry[profile]
            or wp_entry[deps_ref.vr_char.get_pose_fallback_profile(profile)]
        if type(prof_entry) == "table" then
            return prof_entry
        end
    end
    return root
end

local function ensure_mag_hand_hold_entry()
    local wp = mag.cached_wp or deps_ref.get_weapon_go_name()
    if not wp then
        deps_ref.CFG.mag_hand_hold = deps_ref.CFG.mag_hand_hold or {}
        return deps_ref.CFG.mag_hand_hold
    end
    deps_ref.CFG.mag_hand_hold = deps_ref.CFG.mag_hand_hold or {}
    deps_ref.CFG.mag_hand_hold.by_wp = deps_ref.CFG.mag_hand_hold.by_wp or {}
    deps_ref.CFG.mag_hand_hold.by_wp[wp] = deps_ref.CFG.mag_hand_hold.by_wp[wp] or {}
    local profile = current_mag_holster_profile_key()
    deps_ref.CFG.mag_hand_hold.by_wp[wp][profile] = deps_ref.CFG.mag_hand_hold.by_wp[wp][profile] or {}
    return deps_ref.CFG.mag_hand_hold.by_wp[wp][profile]
end

local function compute_mag_hand_world_pose()
    local hand = get_left_hand_joint()
    if not hand then return nil, nil end
    local hpos = deps_ref.sc(hand, "get_Position")
    local hrot = deps_ref.sc(hand, "get_Rotation")
    if not hpos or not hrot then return nil, nil end

    local hold = get_mag_hand_hold_entry()
    local local_off = Vector3f.new(
        tonumber(hold.ox) or 0.0,
        tonumber(hold.oy) or 0.0,
        tonumber(hold.oz) or 0.0)
    local world_off = hrot * local_off
    local target_pos = Vector3f.new(
        hpos.x + world_off.x,
        hpos.y + world_off.y,
        hpos.z + world_off.z)
    local off_rot = quat_from_ypr(
        tonumber(hold.yaw) or 0.0,
        tonumber(hold.pitch) or 0.0,
        tonumber(hold.roll) or 0.0)
    local target_rot = hrot * off_rot
    return target_pos, target_rot
end

local hook = {}

hook.get_mag_dock_local_distance = function()
    local mag_world_pos = compute_mag_hand_world_pose()
    if not mag_world_pos then return nil end
    local parent_tf = get_mag_parent_transform()
    local mag_local = world_pos_to_parent_local(parent_tf, mag_world_pos)
    if not mag_local then return nil end
    cache_mag_exit_for_weapon(mag.cached_wp)
    local exit_local = Vector3f.new(mag.exit_x, mag.exit_y, mag.exit_z)
    return vec3_dist(mag_local, exit_local), mag_local, exit_local
end

hook.get_shell_insert_local_distance = function()
    if not weapon_uses_manual_shell_reload(mag.cached_wp) then return nil end
    cache_mag_exit_for_weapon(mag.cached_wp)
    local exit_local = Vector3f.new(mag.exit_x, mag.exit_y, mag.exit_z)
    if mag_hand.active and mag.target then
        local cur = read_target_local_position(mag.target, mag.target_kind)
        if cur then
            return vec3_dist(cur, exit_local), cur, exit_local
        end
    end
    local mag_world_pos = compute_mag_hand_world_pose()
    if not mag_world_pos then return nil end
    local parent_tf = get_mag_parent_transform()
    local mag_local = world_pos_to_parent_local(parent_tf, mag_world_pos)
    if not mag_local then return nil end
    return vec3_dist(mag_local, exit_local), mag_local, exit_local
end

local function apply_mag_hand_transform()
    if not mag_hand.active or not mag.target then return false end
    local target_pos, target_rot = compute_mag_hand_world_pose()
    if not target_pos or not target_rot then return false end

    local parent_tf = get_mag_parent_transform()
    local local_pos, local_rot = world_pose_to_parent_local(parent_tf, target_pos, target_rot)
    if not local_pos or not local_rot then return false end

    set_mag_frozen_local_full(local_pos.x, local_pos.y, local_pos.z, local_rot)
    write_target_local_position(mag.target, mag.target_kind, local_pos)
    write_target_local_rotation(mag.target, mag.target_kind, local_rot)
    return true
end

local function refresh_mag_exit_world_ref()
    if not mag.target or not mag.has_rest then
        mag.exit_ref_valid = false
        return false
    end
    if mag_hand.active or mag.anim_active then
        return mag.exit_ref_valid == true
    end

    cache_mag_exit_for_weapon(mag.cached_wp)

    local saved_lx = mag.rest_x
    local saved_ly = mag.rest_y
    local saved_lz = mag.rest_z
    local cur = read_target_local_position(mag.target, mag.target_kind)
    if cur then
        saved_lx, saved_ly, saved_lz = cur.x, cur.y, cur.z
    end

    write_target_local_position(mag.target, mag.target_kind,
        Vector3f.new(mag.exit_x, mag.exit_y, mag.exit_z))
    local ref = read_target_world_position(mag.target, mag.target_kind)
    write_target_local_position(mag.target, mag.target_kind,
        Vector3f.new(saved_lx, saved_ly, saved_lz))
    if mag.freeze_pose then
        apply_mag_frozen_pose()
    end

    if not ref then
        mag.exit_ref_valid = false
        return false
    end

    mag.exit_ref_wx = ref.x
    mag.exit_ref_wy = ref.y
    mag.exit_ref_wz = ref.z
    mag.exit_ref_valid = true
    mag.exit_ref_wp = mag.cached_wp

    if mag.weapon_xform then
        local wp = deps_ref.sc(mag.weapon_xform, "get_Position")
        local wr = deps_ref.sc(mag.weapon_xform, "get_Rotation")
        if wp then
            mag.exit_ref_weapon_wx = wp.x
            mag.exit_ref_weapon_wy = wp.y
            mag.exit_ref_weapon_wz = wp.z
        end
        if wr then
            mag.exit_ref_weapon_wrx = wr.x
            mag.exit_ref_weapon_wry = wr.y
            mag.exit_ref_weapon_wrz = wr.z
            mag.exit_ref_weapon_wrw = wr.w
        end
    end
    return true
end

hook.get_mag_exit_world_ref_live = function()
    if not mag.exit_ref_valid or mag.exit_ref_wp ~= mag.cached_wp then
        refresh_mag_exit_world_ref()
    end
    if not mag.exit_ref_valid then return nil end

    local wtf = mag.weapon_xform
    if not wtf then
        return Vector3f.new(mag.exit_ref_wx, mag.exit_ref_wy, mag.exit_ref_wz)
    end

    local wp = deps_ref.sc(wtf, "get_Position")
    local wr = deps_ref.sc(wtf, "get_Rotation")
    if not wp or not wr then
        return Vector3f.new(mag.exit_ref_wx, mag.exit_ref_wy, mag.exit_ref_wz)
    end

    local ox = mag.exit_ref_wx - mag.exit_ref_weapon_wx
    local oy = mag.exit_ref_wy - mag.exit_ref_weapon_wy
    local oz = mag.exit_ref_wz - mag.exit_ref_weapon_wz

    local ref_rot = Quaternion.new(
        mag.exit_ref_weapon_wrx, mag.exit_ref_weapon_wry, mag.exit_ref_weapon_wrz, mag.exit_ref_weapon_wrw)
    local delta = wr * ref_rot:conjugate()
    local rotated = delta * Vector3f.new(ox, oy, oz)
    return Vector3f.new(wp.x + rotated.x, wp.y + rotated.y, wp.z + rotated.z)
end

local function sample_mag_exit_world_pos()
    if not mag.target or not mag.has_rest then return nil end
    if mag_hand.active then
        return hook.get_mag_exit_world_ref_live()
    end

    cache_mag_exit_for_weapon(mag.cached_wp)
    write_target_local_position(mag.target, mag.target_kind,
        Vector3f.new(mag.exit_x, mag.exit_y, mag.exit_z))
    local ref = read_target_world_position(mag.target, mag.target_kind)
    if mag.freeze_pose then
        apply_mag_frozen_pose()
    elseif mag.has_rest then
        write_target_local_position(mag.target, mag.target_kind,
            Vector3f.new(mag.rest_x, mag.rest_y, mag.rest_z))
    end
    if ref then
        mag.exit_ref_wx = ref.x
        mag.exit_ref_wy = ref.y
        mag.exit_ref_wz = ref.z
        mag.exit_ref_valid = true
        mag.exit_ref_wp = mag.cached_wp
    end
    return ref
end

hook.get_mag_dock_dist = function(wp_name)
    if wp_name and type(deps_ref.CFG.mag_dock_by_wp) == "table" then
        local per = deps_ref.CFG.mag_dock_by_wp[wp_name]
        if type(per) == "number" then return per end
    end
    return tonumber(deps_ref.CFG.mag_dock_default) or 0.20
end

local function spawn_mag_to_left_hand()
    if not mag.target or not mag.has_rest then return false end
    if mag.state ~= MAG_STATE.OUT then return false end
    if not mag_holster_supply_available() then return false end

    refresh_mag_exit_world_ref()

    show_mag_mesh()
    mag.mesh_hidden = false
    clear_mag_freeze()
    mag_hand.active = true
    mag_hand.release_fall_active = false
    mag.state = MAG_STATE.IN_HAND
    _G.__vr_mag_in_left_hand = true
    apply_mag_hand_transform()
    hook.extend_mag_suppress_window()
    if deps_ref.play_reload_sfx then deps_ref.play_reload_sfx("mag_grab") end
    return true
end

local function begin_mag_hand_release()
    if not mag.target then return end

    apply_mag_hand_transform()
    local pos, rot = compute_mag_hand_world_pose()
    if not pos then
        pos = read_target_world_position(mag.target, mag.target_kind)
    end
    if not pos then return end
    if not rot then
        rot = read_target_world_rotation(mag.target, mag.target_kind)
    end

    mag_hand.active = false
    mag_hand.release_fall_active = true
    mag_hand.release_start = os.clock()
    mag_hand.release_sx = pos.x
    mag_hand.release_sy = pos.y
    mag_hand.release_sz = pos.z
    mag.state = MAG_STATE.DROPPING
    _G.__vr_mag_in_left_hand = false
    show_mag_mesh()
    mag.mesh_hidden = false
    set_mag_frozen_world_full(pos, rot)
    write_target_world_position_only(mag.target, mag.target_kind, pos)
    if rot then
        write_target_world_rotation(mag.target, mag.target_kind, rot)
    end
    apply_mag_frozen_pose()
    hook.extend_mag_suppress_window()
end

local function tick_mag_hand_release()
    if not mag_hand.release_fall_active or not mag.target then return end

    local elapsed = os.clock() - mag_hand.release_start
    local duration = mag_anim_duration("fall")
    local t = elapsed / duration
    if t > 1.0 then t = 1.0 end
    local fall = mag_fall_distance() * (t * t)
    mag.freeze_mode = "world_full"
    mag.frozen_wx = mag_hand.release_sx
    mag.frozen_wy = mag_hand.release_sy - fall
    mag.frozen_wz = mag_hand.release_sz
    mag.freeze_pose = true
    apply_mag_frozen_pose()

    if t < 1.0 then return end

    mag_hand.release_fall_active = false
    clear_mag_freeze()
    hide_mag_mesh()
    mag.state = MAG_STATE.OUT
    _G.__vr_mag_dropped = true
    on_mag_physically_out()
    if deps_ref.play_reload_sfx then deps_ref.play_reload_sfx("mag_floor") end
end

local function try_mag_insert_dock()
    if not mag_hand.active or not mag.target then return false end
    if mag.anim_active then return false end
    if weapon_uses_manual_shell_reload(mag.cached_wp) then return false end

    local dock_dist = hook.get_mag_dock_local_distance()
    if not dock_dist then return false end

    local thr = hook.get_mag_dock_dist(mag.cached_wp)
    if dock_dist > thr then return false end

    local now = os.clock()
    if now - mag_hand.last_dock_t < 0.5 then return false end
    mag_hand.last_dock_t = now

    hook.begin_mag_insert()
    return true
end

local function tick_mag_holster_pending_pulses()
    if not mag_holster_zone_haptics_allowed() and not mag_holster_empty_denial_active() then
        mag_holster_st.pending_pulse_2_at = nil
        mag_holster_st.pending_pulse_3_at = nil
        mag_holster_st.blocked_grab_fired = false
        return
    end
    local lj = get_left_joystick()
    if mag_holster_st.pending_pulse_2_at and os.clock() >= mag_holster_st.pending_pulse_2_at then
        haptic_pulse(lj, 0.05, 190.0, 1.0)
        mag_holster_st.pending_pulse_2_at = nil
    end
    if mag_holster_st.pending_pulse_3_at and os.clock() >= mag_holster_st.pending_pulse_3_at then
        haptic_pulse(lj, 0.05, 60.0, 1.0)
        mag_holster_st.pending_pulse_3_at = nil
    end
end

local function refresh_mag_holster_zone(hand_pos, lj)
    local mh = deps_ref.CFG.mag_holster or {}
    local trigger_dist = tonumber(mh.trigger_dist) or MAG_HOLSTER_DEF.trigger_dist
    local release_dist = tonumber(mh.release_dist) or MAG_HOLSTER_DEF.release_dist

    local origin, ax, ay, az = resolve_mag_holster_anchor()
    if not origin or not hand_pos then
        mag_holster_st.in_zone = false
        mag_holster_st.last_pos = nil
        return false
    end

    local right, up, fwd = ax, ay, az
    if not (ax and ay and az) then
        _, right, up, fwd = get_body_pose_yaw()
    end

    local off_r, off_u, off_f = get_mag_holster_offsets()
    local holster_pos = holster_pos_with_offsets(origin, off_r, off_u, off_f, ax, ay, az, right, up, fwd)
    if not holster_pos then
        mag_holster_st.in_zone = false
        mag_holster_st.last_pos = nil
        return false
    end

    local d = vec3_dist(hand_pos, holster_pos)
    mag_holster_st.last_dist = d
    mag_holster_st.last_pos = holster_pos

    local was_in_zone = mag_holster_st.in_zone == true
    if not mag_holster_st.in_zone then
        if d <= trigger_dist then mag_holster_st.in_zone = true end
    else
        if d > release_dist then mag_holster_st.in_zone = false end
    end
    
    if mag_holster_st.in_zone and not was_in_zone and mag_holster_zone_haptics_allowed()
        and not mag.ambient_holster_haptics_suppressed() then
        mag_holster_st.zone_enter_pulse = true
    end

    if mag_holster_st.in_zone and mag_holster_zone_haptics_allowed()
        and not mag.ambient_holster_haptics_suppressed() then
        maybe_mag_holster_zone_haptic(lj, mh)
    else
        mag_holster_st.zone_enter_pulse = false
        mag_holster_st.haptic_pending_frames = 0
    end
    return mag_holster_st.in_zone == true
end

local function mag_reload_workflow_active()
    if mag_hand.active or mag_hand.release_fall_active then return true end
    if mag.state == MAG_STATE.IN_HAND
        or mag.state == MAG_STATE.INSERTING
        or mag.state == MAG_STATE.DROPPING then
        return true
    end
    if mag.anim_active then return true end
    if mag_holster_st.in_zone then
        local grip_now = select(1, is_left_grip_pressed())
        if grip_now and (shell_weapon_equipped_idle() or revolver_weapon_equipped_idle()) then
            return true
        end
        if shell_weapon_equipped_idle() or shell_in_hand_exempts_shoot_ready_suppress()
            or revolver_weapon_equipped_idle() or revolver_in_hand_exempts_shoot_ready_suppress() then
            -- Shell/revolver holster: proximity alone must not break shoot-ready.
        else
            return true
        end
    end
    if rawget(_G, "__vr_needs_rack") == true then return true end
    if rawget(_G, "__vr_slide_rack_active") == true then return true end
    return false
end

local function manual_reload_session_active_local()
    if not deps_ref.manual_reload_context_active() then return false end
    if mag.state == MAG_STATE.IN_HAND
        or mag.state == MAG_STATE.INSERTING
        or mag.state == MAG_STATE.DROPPING then
        return true
    end
    if mag_hand.active or mag_hand.release_fall_active then return true end
    if mag.anim_active then return true end
    if deps_ref.frame.vr_reload_b then return true end
    if os.clock() < deps_ref.suppress.until_t then return true end
    return false
end

local function pump_forend_left_support_active()
    return rawget(_G, "__vr_needs_pump") == true
        or rawget(_G, "__vr_pump_active") == true
        or rawget(_G, "__vr_pump_slide_support") == true
end

function mag.holster_left_grip_sub_weapon_suppress()
    if not deps_ref.manual_reload_context_active() then return false end
    local mh = deps_ref.CFG.mag_holster or {}
    if mh.enabled == false or mh.suppress_sub_weapon_in_zone == false then return false end
    if not mag_holster_st.in_zone then return false end
    if not select(1, is_left_grip_pressed()) then return false end
    if shell_weapon_equipped_idle() or revolver_weapon_equipped_idle() then
        return true
    end
    if type(deps_ref.shell_has_shell_in_hand) == "function" and deps_ref.shell_has_shell_in_hand() then
        return true
    end
    if type(deps_ref.revolver_has_bullet_in_hand) == "function" and deps_ref.revolver_has_bullet_in_hand() then
        return true
    end
    return false
end

local function mag_holster_sub_weapon_suppress_wanted()
    local mh = deps_ref.CFG.mag_holster or {}
    if type(deps_ref.revolver_aux_input_suppress_wanted) == "function"
        and deps_ref.revolver_aux_input_suppress_wanted() then
        return true
    end
    if deps_ref.CFG.enabled ~= true or mh.enabled == false then return false end
    if mh.suppress_sub_weapon_in_zone == false then return false end
    if mag.holster_left_grip_sub_weapon_suppress() then
        return true
    end
    if os.clock() < (mag_holster_st.left_support_grace_until or 0) then
        if deps_ref.manual_reload_context_active() then
            if not pump_forend_left_support_active()
                or mag_holster_st.in_zone == true
                or shell_sub_weapon_suppress_active() then
                return true
            end
        else
            mag_holster_st.left_support_grace_until = 0.0
        end
    end
    if not deps_ref.manual_reload_context_active() then return false end
    if shell_sub_weapon_suppress_active() then return true end
    if revolver_sub_weapon_suppress_active() then return true end
    if mag_holster_session_suppresses_shoot_ready() then return true end
    if mag_hand.active then return true end
    if type(deps_ref.revolver_blocks_empty_native_reload) == "function"
        and deps_ref.revolver_blocks_empty_native_reload() then
        return true
    end
    if mag.state == MAG_STATE.DROPPING then return true end
    if mag.state == MAG_STATE.INSERTING or mag.anim_active then return true end
    if mag_holster_st.in_zone then
        if shell_weapon_equipped_idle() or revolver_weapon_equipped_idle() then
            if select(1, is_left_grip_pressed()) then
                return true
            end
            if shell_weapon_equipped_idle() then
                if type(deps_ref.shell_holster_wants_grab) == "function"
                    and deps_ref.shell_holster_wants_grab() then
                    return true
                end
            end
            if revolver_weapon_equipped_idle()
                and type(deps_ref.revolver_holster_wants_grab) == "function"
                and deps_ref.revolver_holster_wants_grab() then
                return true
            end
            if mag_holster_empty_denial_active() then
                return true
            end
        else
            return true
        end
    end
    if rawget(_G, "__vr_needs_rack") == true then return true end
    if rawget(_G, "__vr_slide_rack_active") == true then return true end
    if mag_holster_st.sub_weapon_grip_block then return true end
    return false
end

local function tick_mag_sub_weapon_grip_suppress()
    if not deps_ref.manual_reload_context_active() then
        mag_holster_st.sub_weapon_grip_block = false
        return
    end
    if type(deps_ref.revolver_aux_input_suppress_wanted) == "function"
        and deps_ref.revolver_aux_input_suppress_wanted() then
        mag_holster_st.sub_weapon_grip_block = true
        return
    end
    if mag.holster_left_grip_sub_weapon_suppress() then
        mag_holster_st.sub_weapon_grip_block = true
        return
    end
    if shell_or_revolver_sub_weapon_suppress_active() then
        mag_holster_st.sub_weapon_grip_block = select(1, is_left_grip_pressed()) == true
        return
    end
    local mh = deps_ref.CFG.mag_holster or {}
    if mh.suppress_sub_weapon_in_zone == false then
        mag_holster_st.sub_weapon_grip_block = false
        return
    end
    if manual_reload_session_active_local()
        and not mag_holster_st.in_zone
        and not mag_hand.active
        and not shell_or_revolver_sub_weapon_suppress_active() then
        mag_holster_st.sub_weapon_grip_block = false
        return
    end
    local grip_now = select(1, is_left_grip_pressed())
    if manual_reload_session_active_local() or mag_reload_workflow_active() then
        mag_holster_st.sub_weapon_grip_block = grip_now == true
    elseif mag_holster_st.sub_weapon_grip_block and grip_now then
        mag_holster_st.sub_weapon_grip_block = true
    else
        mag_holster_st.sub_weapon_grip_block = false
    end
end

local function get_suppress_publish_frame()
    return rawget(_G, "__vr_left_support_strip_frame")
        or mag_holster_st.publish_frame_fallback
        or 0
end

local function publish_mag_holster_sub_weapon_suppress()
    local want = mag_holster_sub_weapon_suppress_wanted()
    local pub_frame = get_suppress_publish_frame()
    if mag_holster_st.publish_frame == pub_frame and mag_holster_st.publish_want == want then
        return
    end
    mag_holster_st.publish_frame = pub_frame
    mag_holster_st.publish_want = want
    local was = mag_holster_st.suppress_prev == true
    if want ~= was then
        if type(deps_ref.on_mag_holster_suppress_change) == "function" then
            deps_ref.on_mag_holster_suppress_change(want)
        end
        mag_holster_st.suppress_prev = want
    end
    rawset(_G, "__vr_block_left_support_in_mag_holster_zone", want)
end

local function arm_left_support_suppress_grace(sec)
    local mh = deps_ref.CFG.mag_holster or {}
    sec = tonumber(sec) or tonumber(mh.sub_weapon_grace_sec) or 1.0
    local until_t = os.clock() + sec
    if until_t > (mag_holster_st.left_support_grace_until or 0) then
        mag_holster_st.left_support_grace_until = until_t
    end
    mag_holster_st.publish_frame = -1
    publish_mag_holster_sub_weapon_suppress()
end

local function update_mag_holster_zone()
    tick_mag_holster_pending_pulses()
    if mag_holster_st.vrmod_warned ~= true and not vrmod then
        mag_holster_st.vrmod_warned = true
        log.warn("[re2_vr_reload] vrmod unavailable — mag holster haptics and grip detection disabled")
    end

    _G.__vr_in_mag_holster_zone = false
    if is_menu_blocking() then
        mag_holster_st.in_zone = false
        mag_holster_st.grab_ready_prev = false
        return false
    end
    if not mag_holster_context_active() then
        mag_holster_st.in_zone = false
        mag_holster_st.grab_ready_prev = false
        return false
    end

    sync_mag_holster_profile_active()

    local tf = get_player_transform()
    local hand_pos = nil
    if tf and refresh_left_hand_joint(tf) and mag_hand.hand_joint then
        hand_pos = deps_ref.sc(mag_hand.hand_joint, "get_Position")
    end
    if not hand_pos then
        hand_pos = get_mag_holster_hand_pos()
    end
    local lj = get_left_joystick()
    if not hand_pos then
        local origin, ax, ay, az = resolve_mag_holster_anchor()
        if origin then
            local right, up, fwd = ax, ay, az
            if not (ax and ay and az) then
                _, right, up, fwd = get_body_pose_yaw()
            end
            local off_r, off_u, off_f = get_mag_holster_offsets()
            mag_holster_st.last_pos = holster_pos_with_offsets(origin, off_r, off_u, off_f, ax, ay, az, right, up, fwd)
        end
        mag_holster_st.in_zone = false
        mag_holster_st.grab_ready_prev = false
        return false
    end

    refresh_mag_holster_zone(hand_pos, lj)

    if mag_holster_st.in_zone then
        _G.__vr_in_mag_holster_zone = true
    end

    mag_holster_st.haptic_lj = lj
    return mag_holster_st.in_zone == true
end

local function tick_mag_holster_grip_grab()
    if is_menu_blocking() then
        mag_holster_st.grab_ready_prev = false
        return false
    end
    if not mag_holster_context_active() then return false end
    if not mag_holster_st.in_zone then
        mag_holster_st.grab_ready_prev = false
        -- Also clear the shell-specific fresh-grip tracker (see the shell
        -- grab-edge block below) so leaving the zone always starts clean.
        mag_holster_st.shell_grip_prev_raw = nil
        return false
    end

    local mh = deps_ref.CFG.mag_holster or {}
    local release_dist = tonumber(mh.release_dist) or MAG_HOLSTER_DEF.release_dist
    local d = mag_holster_st.last_dist or 99.0
    local lj = mag_holster_st.haptic_lj or get_left_joystick()

    local grip_now = select(1, is_left_grip_pressed())

    if type(deps_ref.revolver_holster_context_active) == "function"
        and deps_ref.revolver_holster_context_active() then
        local can_revolver = type(deps_ref.revolver_holster_wants_grab) == "function"
            and deps_ref.revolver_holster_wants_grab()
        if not can_revolver then
            local trigger_dist = tonumber(mh.trigger_dist) or MAG_HOLSTER_DEF.trigger_dist
            local empty_denial = mag_holster_empty_denial_active()
            local denial_in_range = empty_denial and d <= trigger_dist
            if empty_denial and grip_now and denial_in_range then
                if not mag_holster_st.blocked_grab_fired then
                    mag_holster_st.blocked_grab_fired = true
                    mag_holster_st.zone_enter_pulse = false
                    mag_holster_st.haptic_pending_frames = 0
                    haptic_pulse(lj, 0.05, 60.0, 1.0)
                    mag_holster_st.pending_pulse_2_at = os.clock() + 0.13
                    mag_holster_st.pending_pulse_3_at = os.clock() + 0.26
                end
            end
            local denial_reset_dist = empty_denial and trigger_dist or release_dist
            if (not grip_now) or d > denial_reset_dist then
                mag_holster_st.blocked_grab_fired = false
            end
            mag_holster_st.grab_ready_prev = false
            return false
        end

        local ready = mag_holster_st.in_zone and grip_now
        local grab_edge = ready and not mag_holster_st.grab_ready_prev
        mag_holster_st.grab_ready_prev = ready
        mag_hand.grip_prev = grip_now

        if grab_edge then
            local cooldown = tonumber(mh.cooldown) or 0.6
            local now = os.clock()
            if now - mag_holster_st.last_grab_t >= cooldown then
                haptic_pulse(lj,
                    tonumber(mh.grab_haptic_duration) or 0.057,
                    tonumber(mh.grab_haptic_frequency) or 169.385,
                    tonumber(mh.grab_haptic_amplitude) or 0.99)
                if type(deps_ref.revolver_on_holster_grab_edge) == "function"
                    and deps_ref.revolver_on_holster_grab_edge() then
                    mag_holster_st.last_grab_t = now
                    return true
                end
            end
        end
        return false
    end

    if type(deps_ref.shell_holster_context_active) == "function"
        and deps_ref.shell_holster_context_active() then
        local can_shell = type(deps_ref.shell_holster_wants_grab) == "function"
            and deps_ref.shell_holster_wants_grab()
        if not can_shell then
            local trigger_dist = tonumber(mh.trigger_dist) or MAG_HOLSTER_DEF.trigger_dist
            local empty_denial = mag_holster_empty_denial_active()
            local denial_in_range = empty_denial and d <= trigger_dist
            if empty_denial and grip_now and denial_in_range then
                if not mag_holster_st.blocked_grab_fired then
                    mag_holster_st.blocked_grab_fired = true
                    mag_holster_st.zone_enter_pulse = false
                    mag_holster_st.haptic_pending_frames = 0
                    haptic_pulse(lj, 0.05, 60.0, 1.0)
                    mag_holster_st.pending_pulse_2_at = os.clock() + 0.13
                    mag_holster_st.pending_pulse_3_at = os.clock() + 0.26
                end
            end
            local denial_reset_dist = empty_denial and trigger_dist or release_dist
            if (not grip_now) or d > denial_reset_dist then
                mag_holster_st.blocked_grab_fired = false
            end
            mag_holster_st.grab_ready_prev = false
            return false
        end

        local ready = mag_holster_st.in_zone and grip_now

        -- Require a genuinely FRESH grip press while already in the zone,
        -- not merely "ready" transitioning true because zone-entry
        -- coincided with a grip that was ALREADY held (from two-handing
        -- the shotgun's foregrip with the same left-grip button). Without
        -- this, sweeping that already-gripping hand through the holster
        -- zone auto-grabbed a shell unintentionally (player report:
        -- two-handing + moving the left hand near the ammo holster
        -- auto-picks-up a shell). Seed the tracker with the current grip
        -- state on the very first in-zone frame so an already-held grip
        -- is correctly treated as "not fresh".
        if mag_holster_st.shell_grip_prev_raw == nil then
            mag_holster_st.shell_grip_prev_raw = grip_now
        end
        local grip_press_edge = grip_now and not mag_holster_st.shell_grip_prev_raw
        mag_holster_st.shell_grip_prev_raw = grip_now

        local grab_edge = ready and not mag_holster_st.grab_ready_prev and grip_press_edge
        mag_holster_st.grab_ready_prev = ready
        mag_hand.grip_prev = grip_now

        if grab_edge then
            local cooldown = tonumber(mh.cooldown) or 0.6
            local now = os.clock()
            if (now - mag_holster_st.last_grab_t) >= cooldown then
                haptic_pulse(lj,
                    tonumber(mh.grab_haptic_duration) or 0.057,
                    tonumber(mh.grab_haptic_frequency) or 169.385,
                    tonumber(mh.grab_haptic_amplitude) or 0.99)
                local grab_ok = false
                if type(deps_ref.shell_on_holster_grab_edge) == "function" then
                    grab_ok = deps_ref.shell_on_holster_grab_edge() == true
                end
                if grab_ok then
                    mag_holster_st.last_grab_t = now
                    return true
                end
            end
        end
        return false
    end

    local can_grab = mag.state == MAG_STATE.OUT
        and not mag_hand.active
        and not mag_hand.release_fall_active
        and mag_holster_supply_available()

    if not can_grab then
        local trigger_dist = tonumber(mh.trigger_dist) or MAG_HOLSTER_DEF.trigger_dist
        local empty_denial = mag_holster_empty_denial_active()
        local denial_in_range = empty_denial and d <= trigger_dist
        if empty_denial and grip_now and denial_in_range then
            if not mag_holster_st.blocked_grab_fired then
                mag_holster_st.blocked_grab_fired = true
                mag_holster_st.zone_enter_pulse = false
                mag_holster_st.haptic_pending_frames = 0
                haptic_pulse(lj, 0.05, 60.0, 1.0)
                mag_holster_st.pending_pulse_2_at = os.clock() + 0.13
                mag_holster_st.pending_pulse_3_at = os.clock() + 0.26
            end
        end
        local denial_reset_dist = empty_denial and trigger_dist or release_dist
        if (not grip_now) or d > denial_reset_dist then
            mag_holster_st.blocked_grab_fired = false
        end
        mag_holster_st.grab_ready_prev = false
        return false
    end

    local ready = mag_holster_st.in_zone and grip_now
    local grab_edge = ready and not mag_holster_st.grab_ready_prev
    mag_holster_st.grab_ready_prev = ready
    mag_hand.grip_prev = grip_now

    if grab_edge then
        local cooldown = tonumber(mh.cooldown) or 0.6
        local now = os.clock()
        if now - mag_holster_st.last_grab_t >= cooldown then
            mag_holster_st.last_grab_t = now
            haptic_pulse(lj,
                tonumber(mh.grab_haptic_duration) or 0.057,
                tonumber(mh.grab_haptic_frequency) or 169.385,
                tonumber(mh.grab_haptic_amplitude) or 0.99)
            return spawn_mag_to_left_hand()
        end
    end
    return false
end

local function update_mag_in_hand()
    if not mag_hand.active then return end
    if rawget(_G, "__vr_shell_in_left_hand") == true then return end
    if rawget(_G, "__vr_bullet_in_left_hand") == true then return end

    local grip_now = is_left_grip_pressed()
    if mag_hand.grip_prev and not grip_now then
        begin_mag_hand_release()
    elseif grip_now then
        try_mag_insert_dock()
    end
    mag_hand.grip_prev = grip_now
end

local function reset_mag_hand_state()
    mag_hand.active = false
    mag_hand.grip_prev = false
    mag_hand.release_fall_active = false
    mag_hand.last_dock_t = 0.0
    _G.__vr_mag_in_left_hand = false
    _G.__vr_in_mag_holster_zone = false
    mag_holster_st.in_zone = false
    mag_holster_st.grab_ready_prev = false
    mag_holster_st.suppress_prev = false
    mag_holster_st.sub_weapon_grip_block = false
    mag_holster_st.left_support_grace_until = 0.0
    mag_holster_st.publish_frame = -1
    mag_holster_st.publish_want = nil
    mag_holster_st.haptic_lj = nil
    mag_hand.grip_action_cache = nil
    mag_hand.hand_joint = nil
    rawset(_G, "__vr_lh_joint", nil)
    rawset(_G, "__vr_block_left_support_in_mag_holster_zone", false)
    if type(deps_ref.on_mag_holster_suppress_change) == "function" then
        deps_ref.on_mag_holster_suppress_change(false)
    end
end

local function restore_mag_rest_pose()
    if not mag.target or not mag.has_rest then return end
    write_target_local_scale(mag.target, mag.target_kind,
        Vector3f.new(mag.rest_sx, mag.rest_sy, mag.rest_sz))
    set_mag_frozen_local(mag.rest_x, mag.rest_y, mag.rest_z)
    apply_mag_frozen_pose()
    show_mag_mesh()
end

local function reset_mag_visual_state(restore_pose)
    reset_mag_hand_state()
    if restore_pose then
        restore_mag_rest_pose()
    else
        show_mag_mesh()
    end
    clear_mag_freeze()
    mag.mesh_hidden = false
    mag.state = MAG_STATE.ATTACHED
    mag.anim_active = false
    mag.anim_phase = nil
    mag.weapon_ammo_cleared = false
    _G.__vr_mag_dropped = false
end

local function block_empty_locomotion_mag_anim()
    if not deps_ref.manual_reload_context_active() then return end
    if get_weapon_chamber_bullet_count() > 0 then return end
    if rawget(_G, "__vr_player_locomoting") ~= true then return end
    if rawget(_G, "__vr_vr_right_trigger") ~= true then return end
    if mag_preview.active then
        cancel_mag_exit_preview(true)
    end
    if not mag.anim_active
        and mag.state ~= MAG_STATE.DROPPING
        and not mag_hand.release_fall_active then
        return
    end
    if mag.state == MAG_STATE.ATTACHED and not mag.anim_active then
        return
    end
    reset_mag_visual_state(mag.target ~= nil and mag.has_rest == true)
end

local function reconcile_mag_with_loaded_game()
    if not deps_ref.manual_reload_context_active() then return end
    if mag.state ~= MAG_STATE.OUT then return end
    if mag_hand.active or mag.anim_active or mag_hand.release_fall_active then return end
    if M.manual_reload_session_active() then return end

    local weapon = deps_ref.re2.weapon
    if not weapon then return end

    local wp = mag.cached_wp
    local snap = wp and mag_snapshots[wp] or nil
    if snap and snap.mag_dropped == true then
        return
    end

    local n = deps_ref.sc(weapon, "getBulletNumber")
    if type(n) ~= "number" or n <= 0 then return end

    clear_mag_carried_rounds()
    if wp then
        mag_snapshots[wp] = nil
    end
    reset_mag_visual_state(mag.target ~= nil and mag.has_rest == true)
end

local function capture_mag_snapshot()
    local dropped = mag.state ~= MAG_STATE.ATTACHED
        or _G.__vr_mag_dropped == true
        or mag.mesh_hidden == true
    return {
        mag_dropped = dropped,
        carried_rounds = dropped and get_mag_carried_rounds() or 0,
    }
end

local function apply_mag_out_at_rest()
    reset_mag_hand_state()
    if mag.cached_wp then
        cache_mag_exit_for_weapon(mag.cached_wp)
    end
    hide_mag_mesh()
    mag.mesh_hidden = true
    mag.state = MAG_STATE.OUT
    mag.anim_active = false
    mag.anim_phase = nil
    _G.__vr_mag_dropped = true
    clear_mag_freeze()
    if mag.target and mag.has_rest then
        set_mag_frozen_local(mag.exit_x, mag.exit_y, mag.exit_z)
    end
    on_mag_physically_out()
end

local function restore_mag_snapshot(snap)
    if should_skip_mag_snapshot_io() then
        if snap and snap.mag_dropped then
            return
        end
        reset_mag_visual_state(true)
        return
    end
    if snap and snap.mag_dropped then
        mag.carried_rounds = math.max(0, math.floor(tonumber(snap.carried_rounds) or 0))
        apply_mag_out_at_rest()
    else
        clear_mag_carried_rounds()
        reset_mag_visual_state(true)
    end
end

local function finalize_mag_state_for_weapon_swap()
    if mag.anim_active then
        if mag.anim_phase == "insert" then
            restore_mag_rest_pose()
            clear_mag_freeze()
            mag.state = MAG_STATE.ATTACHED
            mag.mesh_hidden = false
            _G.__vr_mag_dropped = false
        else
            apply_mag_out_at_rest()
        end
        mag.anim_active = false
        mag.anim_phase = nil
    elseif mag_hand.active
        or mag.state == MAG_STATE.IN_HAND
        or mag_hand.release_fall_active
        or mag.state == MAG_STATE.DROPPING then
        apply_mag_out_at_rest()
    end
end

local function resolve_mag_joint(wp_name)
    mag.target = nil
    mag.target_kind = nil
    mag.weapon_xform = nil
    mag.joint = nil
    mag.mag_go = nil
    mag.node_name = get_mag_node_name(wp_name)
    mag.has_rest = false
    mag.miss_warned = false
    clear_mag_freeze()

    if not mag.node_name then return false end

    local weapon_go = deps_ref.re2.weapon_gameobject
    if not weapon_go then return false end

    local wtf = deps_ref.sc(weapon_go, "get_Transform")
    if not wtf then return false end

    local target, kind = resolve_mag_target(wtf, mag.node_name)
    if not target then
        if not mag.miss_warned then
            mag.miss_warned = true
            log.warn(string.format("[re2_vr_reload] Mag node '%s' not found on %s", mag.node_name, wp_name))
        end
        return false
    end

    local pos = read_target_local_position(target, kind)
    if not pos then return false end

    mag.target = target
    mag.target_kind = kind
    mag.weapon_xform = wtf
    mag.joint = (kind == "joint") and target or nil
    mag.rest_x = pos.x
    mag.rest_y = pos.y
    mag.rest_z = pos.z
    mag.has_rest = true

    local scv = read_target_local_scale(target, kind)
    if scv then
        mag.rest_sx = scv.x
        mag.rest_sy = scv.y
        mag.rest_sz = scv.z
    else
        mag.rest_sx = 1.0
        mag.rest_sy = 1.0
        mag.rest_sz = 1.0
    end

    local go = nil
    if kind == "joint" then
        go = deps_ref.sc(target, "get_GameObject")
        if not go then
            local tf = deps_ref.sc(target, "get_Transform")
            go = tf and deps_ref.sc(tf, "get_GameObject")
        end
    else
        go = deps_ref.sc(target, "get_GameObject")
    end
    mag.mag_go = go
    mag.hide_gos = {}
    rebuild_mag_hide_go_list()
    cache_mag_exit_for_weapon(wp_name)
    refresh_mag_exit_world_ref()
    return true
end

local function cancel_mag_exit_preview(restore_pose)
    if deps_ref.cancel_bullet_insert_preview and deps_ref.bullet_insert_preview_is_active
        and deps_ref.bullet_insert_preview_is_active() then
        deps_ref.cancel_bullet_insert_preview(restore_pose)
    end
    if not mag_preview.active then return end
    if restore_pose ~= false and mag_preview.has_rest and mag_preview.target then
        write_target_local_position(mag_preview.target, mag_preview.target_kind,
            Vector3f.new(mag_preview.rest_x, mag_preview.rest_y, mag_preview.rest_z))
    end
    if mag_preview.was_mesh_hidden then
        hide_mag_mesh()
    end
    mag_preview.active = false
    mag_preview.weapon_id = nil
    mag_preview.until_t = 0.0
    mag_preview.target = nil
    mag_preview.target_kind = nil
    mag_preview.has_rest = false
    mag_preview.was_mesh_hidden = false
end

local function apply_mag_preview_exit()
    if not mag_preview.active or not mag_preview.target or not mag_preview.weapon_id then return end
    local ex, ey, ez = get_mag_exit_pos(mag_preview.weapon_id)
    write_target_local_position(mag_preview.target, mag_preview.target_kind, Vector3f.new(ex, ey, ez))
end

local function tick_mag_exit_preview()
    if not mag_preview.active then return end
    if mag.anim_active then
        cancel_mag_exit_preview(true)
        return
    end
    if deps_ref.get_weapon_go_name() ~= mag_preview.weapon_id then
        cancel_mag_exit_preview(true)
        return
    end
    if os.clock() >= mag_preview.until_t then
        cancel_mag_exit_preview(true)
        return
    end
    apply_mag_preview_exit()
end

local function extend_mag_exit_preview(wp_name)
    mag_preview.status = nil
    if weapon_uses_manual_cylinder_reload(wp_name) then
        if deps_ref.extend_bullet_insert_preview then
            local ok, err = deps_ref.extend_bullet_insert_preview(wp_name, MAG_PREVIEW_SEC)
            if not ok then mag_preview.status = err or "Bullet insert preview failed" end
        else
            mag_preview.status = "Bullet insert preview not wired"
        end
        return
    end
    if not wp_name or not get_mag_node_name(wp_name) then
        mag_preview.status = "No mag node configured for " .. tostring(wp_name)
        return
    end
    if deps_ref.get_weapon_go_name() ~= wp_name then
        mag_preview.status = "Equip " .. tostring(wp_name) .. " for live preview"
        return
    end
    if mag.anim_active then
        mag_preview.status = "Wait for mag animation to finish"
        return
    end

    if mag_preview.active and mag_preview.weapon_id ~= wp_name then
        cancel_mag_exit_preview(true)
    end

    if not mag_preview.active then
        if not mag.has_rest or mag.cached_wp ~= wp_name then
            resolve_mag_joint(wp_name)
            mag.cached_wp = wp_name
        end
        if not mag.target or not mag.has_rest then
            mag_preview.status = "Mag joint not resolved on " .. tostring(wp_name)
            return
        end
        mag_preview.target = mag.target
        mag_preview.target_kind = mag.target_kind
        mag_preview.rest_x = mag.rest_x
        mag_preview.rest_y = mag.rest_y
        mag_preview.rest_z = mag.rest_z
        mag_preview.has_rest = true
        mag_preview.weapon_id = wp_name
        mag_preview.was_mesh_hidden = mag.mesh_hidden
        mag_preview.active = true
        if mag.mesh_hidden then show_mag_mesh() end
        clear_mag_freeze()
    end

    mag_preview.until_t = os.clock() + MAG_PREVIEW_SEC
    if mag.cached_wp == wp_name then
        cache_mag_exit_for_weapon(wp_name)
    end
    apply_mag_preview_exit()
end

local function update_mag_weapon_cache()
    local wp = deps_ref.get_weapon_go_name()
    local go_tok = get_weapon_go_token()
    if wp == mag.cached_wp and go_tok == mag.cached_weapon_go then return end

    cancel_mag_exit_preview(true)

    local prev_wp = mag.cached_wp

    if mag.cached_wp then
        if not should_skip_mag_snapshot_io() then
            finalize_mag_state_for_weapon_swap()
        end
        mag_snapshots[mag.cached_wp] = capture_mag_snapshot()
    end

    local restore_snap = wp and mag_snapshots[wp] or nil
    if should_skip_mag_snapshot_io() then
        restore_snap = nil
    end

    mag.cached_wp = wp
    mag.cached_weapon_go = go_tok
    mag.weapon_ammo_cleared = false
    mag.target = nil
    mag.target_kind = nil
    mag.weapon_xform = nil
    mag.joint = nil
    mag.mag_go = nil
    mag.hide_gos = {}
    mag.has_rest = false
    mag.miss_warned = false
    mag.anim_active = false
    mag.anim_phase = nil
    clear_mag_freeze()
    reset_mag_hand_state()

    if wp and mag_visuals_configured(wp) then
        resolve_mag_joint(wp)
        restore_mag_snapshot(restore_snap)
    else
        mag.state = MAG_STATE.ATTACHED
        mag.mesh_hidden = false
        _G.__vr_mag_dropped = false
    end

    if prev_wp and wp and prev_wp ~= wp and get_weapon_chamber_bullet_count() > 0 then
        if mag.state ~= MAG_STATE.ATTACHED and not (restore_snap and restore_snap.mag_dropped == true) then
            reset_mag_visual_state(mag.target ~= nil and mag.has_rest == true)
        end
    end

end

local function ammo_commit_wrap(fn)
    rawset(_G, "__vr_mag_ammo_commit_bypass", true)
    deps_ref.ammo.internal_commit = true
    pcall(fn)
    deps_ref.ammo.internal_commit = false
    rawset(_G, "__vr_mag_ammo_commit_bypass", nil)
end

-- Restore virtual mag rounds to chamber without consuming reserve.
local function apply_direct_chamber_count(count)
    local weapon = deps_ref.re2.weapon
    local inv = deps_ref.re2.inventory
    if not weapon then return false end

    local function chamber_at_least(n)
        return read_raw_weapon_chamber_bullet_count() >= n
    end

    local slot = inv and deps_ref.sc(inv, "get_MainSlot")
    if slot then
        pcall(function() inv:call("set_MainSlotSurplusBulletNumber", 0) end)
        pcall(function() slot:call("set_Number", count) end)
        if chamber_at_least(count) then return true end
    end

    for _, fname in ipairs({ "BulletNumber", "_BulletNumber", "<BulletNumber>k__BackingField" }) do
        pcall(function()
            if weapon:get_field(fname) ~= nil then
                weapon:set_field(fname, count)
            end
        end)
        if chamber_at_least(count) then return true end
    end

    local handle = deps_ref.sc(weapon, "get_ReloadTrackHandle")
    local track = handle and (deps_ref.sc(handle, "get_Track") or deps_ref.sc(handle, "getTrack"))
    if track then
        for _, fname in ipairs({ "Number", "_Number" }) do
            pcall(function() track:set_field(fname, count) end)
            if chamber_at_least(count) then return true end
        end
    end

    return chamber_at_least(count)
end

function M.sync_chamber_shoot_ready()
    mag.weapon_ammo_cleared = false
    mag.reserve_cache_n = nil
    local weapon = deps_ref and deps_ref.re2 and deps_ref.re2.weapon
    if not weapon then return false end
    local slot_n = get_weapon_mag_slot_round_count()
    if mag.native_bullet_n() <= 0 and slot_n > 0 then
        apply_direct_chamber_count(math.max(1, slot_n))
    end
    pcall(function() weapon:call("executeEndReload") end)
    if mag.native_bullet_n() > 0 then
        pcall(function() weapon:call("endChamberClear") end)
    end
    return mag.native_bullet_n() > 0
end

-- Pull reserve ammo into chamber up to target count.
local function apply_reserve_to_chamber(count)
    count = math.max(0, math.floor(tonumber(count) or 0))
    if count <= 0 then return false end

    local weapon = deps_ref.re2.weapon
    local inv = deps_ref.re2.inventory
    if not weapon or not inv then return false end

    local loaded_before = get_weapon_chamber_bullet_count()
    local need = count - loaded_before
    if need <= 0 then
        return loaded_before >= count
    end

    local slot = deps_ref.sc(inv, "get_MainSlot")
    local bullet_id = slot and deps_ref.sc(slot, "get_BulletID")
    if bullet_id == nil then bullet_id = deps_ref.sc(inv, "get_MainSlotSurplusBulletID") end
    local method = "none"

    mag.reserve_cache_n = nil
    local reserve_before = get_main_weapon_reserve_ammo_count()

    if reserve_before > 0 and bullet_id ~= nil then
        pcall(function() inv:call("set_MainSlotSurplusBulletNumber", 0) end)
        pcall(function() inv:call("addSlotNumber", bullet_id, need) end)
        ammo_commit_wrap(function() inv:call("reloadMainSlot", need) end)
        if get_weapon_chamber_bullet_count() == count then
            method = "inject_reload"
        end
    end

    if method == "none" then
        if bullet_id ~= nil then
            pcall(function() inv:call("set_MainSlotSurplusBulletID", bullet_id) end)
        end
        pcall(function() inv:call("set_MainSlotSurplusBulletNumber", count) end)
        rawset(_G, "__vr_mag_ammo_commit_bypass", true)
        deps_ref.ammo.internal_commit = true
        pcall(function() inv:call("changeBulletMainSlotWithoutReload") end)
        deps_ref.ammo.internal_commit = false
        rawset(_G, "__vr_mag_ammo_commit_bypass", nil)
        mag.reserve_cache_n = nil
        local reserve_mid = get_main_weapon_reserve_ammo_count()
        if reserve_mid > 0 then
            local pull = math.min(need, reserve_mid)
            ammo_commit_wrap(function() inv:call("reloadMainSlot", pull) end)
            if get_weapon_chamber_bullet_count() == count then
                method = "surplus_reload"
            end
        end
    end

    mag.reserve_cache_n = nil
    local reserve_after = get_main_weapon_reserve_ammo_count()
    local applied = get_weapon_chamber_bullet_count() == count

    if applied or method ~= "none" then
        local excess = math.max(0, reserve_after - reserve_before)
        if excess > 0 and bullet_id ~= nil then
            pcall(function() inv:call("reduceSlot", bullet_id, excess) end)
            mag.reserve_cache_n = nil
            reserve_after = get_main_weapon_reserve_ammo_count()
        end
        pcall(function() inv:call("set_MainSlotSurplusBulletNumber", 0) end)
    end

    return applied
end

local function apply_carried_mag_ammo(count, opts)
    opts = opts or {}
    count = math.max(0, math.floor(tonumber(count) or 0))
    if count <= 0 then return false end

    mag.reserve_cache_n = nil
    local applied = false

    if opts.from_carried == true then
        applied = apply_direct_chamber_count(count)
    elseif opts.from_reserve == true then
        applied = apply_reserve_to_chamber(count)
    else
        applied = apply_reserve_to_chamber(count)
        if not applied then
            applied = apply_direct_chamber_count(count)
        end
    end

    if applied then
        mag.weapon_ammo_cleared = false
        mag.reserve_cache_n = nil
    else
        log.warn(string.format("[re2_vr_reload] Could not apply %d rounds to chamber", count))
    end
    return applied
end

local function apply_single_shell_round()
    local inv = deps_ref.re2.inventory
    local weapon = deps_ref.re2.weapon
    if not inv or not weapon then return false, "missing_refs" end

    local loaded_before, carried_before = get_shell_hud_ammo()
    local slot = deps_ref.sc(inv, "get_MainSlot")
    local bullet_id = slot and deps_ref.sc(slot, "get_BulletID")
    if bullet_id == nil then
        bullet_id = deps_ref.sc(inv, "get_MainSlotSurplusBulletID")
    end
    local im = get_imgr_singleton()
    local method = "none"

    local function shell_commit_applied()
        mag.reserve_cache_n = nil
        local loaded_now, carried_now = get_shell_hud_ammo()
        if loaded_now > loaded_before then return true end
        if carried_now < carried_before then return true end
        if get_weapon_chamber_bullet_count() > loaded_before then return true end
        return false
    end

    local function sync_shotgun_chamber()
        pcall(function() weapon:call("executeEndReload") end)
        pcall(function() weapon:call("endChamberClear") end)
    end

    local function with_commit(fn)
        rawset(_G, "__vr_mag_ammo_commit_bypass", true)
        rawset(_G, "__vr_rack_chamber_commit_bypass", true)
        deps_ref.ammo.internal_commit = true
        if deps_ref.clear_native_reload_precede_inhibit_now then
            deps_ref.clear_native_reload_precede_inhibit_now()
        end
        pcall(fn)
        sync_shotgun_chamber()
        deps_ref.ammo.internal_commit = false
        rawset(_G, "__vr_mag_ammo_commit_bypass", nil)
        rawset(_G, "__vr_rack_chamber_commit_bypass", nil)
        mag.reserve_cache_n = nil
    end

    if carried_before > 0 then
        with_commit(function() inv:call("reloadMainSlot", 1) end)
        if shell_commit_applied() then method = "reloadMainSlot" end
    end

    if method == "none" then
        local equipment = get_player_equipment()
        local wt = deps_ref.sc(weapon, "get_WeaponType")
        with_commit(function()
            if equipment then equipment:call("reloadMainWeapon", 1) end
            if equipment and wt ~= nil then equipment:call("executeReload", wt, 1) end
            weapon:call("executeReload", 1)
        end)
        if shell_commit_applied() then method = "executeReload" end
    end

    if method == "none" and im and bullet_id ~= nil and carried_before > 0 then
        with_commit(function()
            pcall(function() im:call("reduceItem", bullet_id, 1) end)
            weapon:call("executeReload", 1)
        end)
        if shell_commit_applied() then method = "reduceItem_executeReload" end
    end

    if method == "none" and bullet_id ~= nil and carried_before > 0 then
        with_commit(function()
            inv:call("reduceSlot", bullet_id, 1)
            weapon:call("executeReload", 1)
        end)
        if shell_commit_applied() then method = "reduceSlot_executeReload" end
    end

    if method == "none" and slot then
        local target = loaded_before + 1
        with_commit(function()
            pcall(function() inv:call("set_MainSlotSurplusBulletNumber", 0) end)
            slot:call("set_Number", target)
            sync_shotgun_chamber()
        end)
        if shell_commit_applied() then method = "slot_set_number" end
    end

    local loaded_after, carried_after = get_shell_hud_ammo()
    local applied = method ~= "none"
    if applied then
        mag.weapon_ammo_cleared = false
        mag.reserve_cache_n = nil
        if mag.native_bullet_n() <= 0 and get_weapon_mag_slot_round_count() > 0 then
            apply_direct_chamber_count(math.max(1, get_weapon_mag_slot_round_count()))
        end
    end
    if not applied then
        log.warn(string.format(
            "[re2_vr_reload] Shell +1 commit failed loaded %d->%d carried %d->%d bullet_id=%s",
            loaded_before, loaded_after, carried_before, carried_after, tostring(bullet_id)))
    end
    return applied, method
end

local function get_reserve_top_up_count()
    local loaded = get_weapon_chamber_bullet_count()
    local inv = deps_ref.re2.inventory
    local slot = inv and deps_ref.sc(inv, "get_MainSlot")
    local max_n = slot and deps_ref.sc(slot, "get_MaxNumber")
    if type(max_n) ~= "number" then max_n = 0 end

    local vacancy = get_weapon_reloadable_count()
    if type(vacancy) ~= "number" or vacancy <= 0 then
        if max_n > loaded then
            vacancy = max_n - loaded
        elseif slot then
            vacancy = deps_ref.sc(slot, "get_VacancyNumber")
            if type(vacancy) ~= "number" or vacancy < 0 then vacancy = 0 end
        else
            vacancy = 0
        end
    end

    local reserve = get_main_weapon_reserve_ammo_count()
    local add = math.min(math.max(0, math.floor(vacancy)), math.max(0, math.floor(reserve)))
    return add, loaded, max_n
end

local function commit_reserve_top_up(expected_carried)
    expected_carried = math.max(0, math.floor(tonumber(expected_carried) or 0))
    mag.reserve_cache_n = nil
    local wp = deps_ref.get_weapon_go_name()
    if expected_carried <= 0 and weapon_uses_manual_shell_reload(wp) then
        return 0
    end
    if expected_carried > 0 and get_weapon_chamber_bullet_count() < expected_carried then
        apply_carried_mag_ammo(expected_carried, { from_carried = true })
    end

    if expected_carried > 0 and get_weapon_chamber_bullet_count() <= 0 then
        log.warn("[re2_vr_reload] carried restore failed; skipping reserve top-up")
        return 0
    end

    local add, loaded_before, cap = get_reserve_top_up_count()
    if add <= 0 then
        if expected_carried > 0 and get_weapon_chamber_bullet_count() >= expected_carried then
            clear_mag_carried_rounds()
        end
        return 0
    end

    local inv = deps_ref.re2.inventory
    if not inv then return 0 end

    local reserve_before = get_main_weapon_reserve_ammo_count()
    deps_ref.ammo.internal_commit = true
    rawset(_G, "__vr_mag_ammo_commit_bypass", true)
    pcall(function() inv:call("reloadMainSlot", add) end)
    deps_ref.ammo.internal_commit = false
    rawset(_G, "__vr_mag_ammo_commit_bypass", nil)
    mag.reserve_cache_n = nil

    if expected_carried > 0 and get_weapon_chamber_bullet_count() >= expected_carried then
        clear_mag_carried_rounds()
    end
    return add
end

local function tick_pending_reserve_top_up()
    if not pending_reserve_top_up then return end
    pending_reserve_top_up.frames_left = pending_reserve_top_up.frames_left - 1
    if pending_reserve_top_up.frames_left > 0 then return end
    local carried = pending_reserve_top_up.carried or 0
    pending_reserve_top_up = nil
    commit_reserve_top_up(carried)
end

hook.commit_reload_ammo = function()
    -- Must clear before chamber restore (mag insert also clears; canister insert does not).
    mag.weapon_ammo_cleared = false

    local carried = get_mag_carried_rounds()

    if carried > 0 then
        apply_carried_mag_ammo(carried, { from_carried = true })
        pending_reserve_top_up = { frames_left = 2, carried = carried }
    else
        commit_reserve_top_up(0)
    end
end

hook.extend_mag_suppress_window = function()
    local extra = 0.2
    if mag.anim_phase == "slide" or mag.anim_phase == "fall" then
        extra = mag_anim_duration("slide") + mag_anim_duration("fall") + 0.25
    elseif mag.anim_phase == "insert" then
        extra = mag_anim_duration("insert") + 0.15
    end
    deps_ref.suppress.until_t = os.clock() + extra
end

local function snapshot_mag_world_position_at_slide_end()
    apply_mag_frozen_pose()

    local wm = read_target_world_matrix(mag.target, mag.target_kind)
    local pos = wm and world_matrix_to_position(wm)
    if not pos then
        pos = read_target_world_position(mag.target, mag.target_kind)
    end
    if not pos then return false end

    local rot = wm and world_matrix_to_rotation(wm)
    if rot then
        cache_frozen_rotation(rot)
    end

    mag.fall_sx = pos.x
    mag.fall_sy = pos.y
    mag.fall_sz = pos.z
    return true
end

hook.begin_mag_slide_to_fall = function()
    if not snapshot_mag_world_position_at_slide_end() then
        mag.anim_phase = "fall"
        mag.anim_start = os.clock()
        hook.extend_mag_suppress_window()
        return
    end

    mag.freeze_mode = "world"
    set_mag_frozen_world(mag.fall_sx, mag.fall_sy, mag.fall_sz)
    apply_mag_frozen_pose()
    mag.anim_phase = "fall"
    mag.anim_start = os.clock()
    hook.extend_mag_suppress_window()
end

hook.begin_mag_drop = function()
    cancel_mag_exit_preview(true)
    if not mag.target or not mag.has_rest then return false end

    capture_mag_carried_rounds()
    clear_tactical_rack_state_if_needed()

    reset_mag_hand_state()

    cache_mag_exit_for_weapon(mag.cached_wp)
    local cur = read_target_local_position(mag.target, mag.target_kind)
    mag.slide_lx0 = cur and cur.x or mag.rest_x
    mag.slide_ly0 = cur and cur.y or mag.rest_y
    mag.slide_lz0 = cur and cur.z or mag.rest_z

    mag.state = MAG_STATE.DROPPING
    mag.anim_active = true
    mag.anim_phase = "slide"
    mag.anim_start = os.clock()
    show_mag_mesh()
    hook.extend_mag_suppress_window()
    _G.__vr_mag_dropped = false
    if deps_ref.play_reload_sfx then deps_ref.play_reload_sfx("mag_drop") end
    return true
end

hook.begin_mag_insert = function()
    cancel_mag_exit_preview(true)
    if not mag.target or not mag.has_rest then return false end

    local from_hand = mag_hand.active == true
    if from_hand then
        apply_mag_hand_transform()
    end

    cache_mag_exit_for_weapon(mag.cached_wp)
    -- Seated X rail; Y+Z from magwell exit (matches drop pitch) into rest pose.
    local sx = mag.rest_x
    local sy = mag.exit_y
    local sz = mag.exit_z

    mag_hand.active = false
    mag_hand.release_fall_active = false
    _G.__vr_mag_in_left_hand = false

    show_mag_mesh()
    set_mag_frozen_local(sx, sy, sz)

    mag.slide_lx0 = sx
    mag.slide_ly0 = sy
    mag.slide_lz0 = sz

    mag.state = MAG_STATE.INSERTING
    mag.anim_active = true
    mag.anim_phase = "insert"
    mag.anim_start = os.clock()
    mag.rack_pending_after_insert = false
    if not weapon_no_rack_required(mag.cached_wp) then
        mag.rack_pending_after_insert = get_mag_carried_rounds() <= 0
        if rawget(_G, "__vr_needs_rack") == true then
            mag.rack_pending_after_insert = true
        end
    end
    hook.extend_mag_suppress_window()
    if deps_ref.play_reload_sfx then deps_ref.play_reload_sfx("mag_insert") end
    return true
end

local function tick_mag_animation()
    if not mag.anim_active or not mag.target then return end

    local elapsed = os.clock() - mag.anim_start
    local phase = mag.anim_phase

    if phase == "slide" then
        local duration = mag_anim_duration("slide")
        local t = elapsed / duration
        if t > 1.0 then t = 1.0 end
        local u = mag_ease(t)
        set_mag_frozen_local(
            mag.slide_lx0 + (mag.exit_x - mag.slide_lx0) * u,
            mag.slide_ly0 + (mag.exit_y - mag.slide_ly0) * u,
            mag.slide_lz0 + (mag.exit_z - mag.slide_lz0) * u)
        if t < 1.0 then return end
        apply_mag_frozen_pose()
        hook.begin_mag_slide_to_fall()
        return
    end

    if phase == "fall" then
        local duration = mag_anim_duration("fall")
        local t = elapsed / duration
        if t > 1.0 then t = 1.0 end
        local fall = mag_fall_distance() * (t * t)
        set_mag_frozen_world(mag.fall_sx, mag.fall_sy - fall, mag.fall_sz)
        if t < 1.0 then return end

        mag.anim_active = false
        mag.anim_phase = nil
        hide_mag_mesh()
        mag.state = MAG_STATE.OUT
        _G.__vr_mag_dropped = true
        on_mag_physically_out()
        if deps_ref.play_reload_sfx then deps_ref.play_reload_sfx("mag_floor") end
        return
    end

    if phase == "insert" then
        local duration = mag_anim_duration("insert")
        local t = elapsed / duration
        if t > 1.0 then t = 1.0 end
        local u = mag_ease(t)
        set_mag_frozen_local(
            mag.rest_x,
            mag.exit_y + (mag.rest_y - mag.exit_y) * u,
            mag.exit_z + (mag.rest_z - mag.exit_z) * u)
        if t < 1.0 then return end

        mag.anim_active = false
        mag.anim_phase = nil
        restore_mag_rest_pose()
        clear_mag_freeze()
        mag.state = MAG_STATE.ATTACHED
        mag.weapon_ammo_cleared = false
        _G.__vr_mag_dropped = false
        hook.commit_reload_ammo()
        arm_left_support_suppress_grace()
        if deps_ref.on_mag_insert_complete then
            deps_ref.on_mag_insert_complete(mag.rack_pending_after_insert == true)
        end
    end
end

local function handle_mag_reload_b_edge()
    if type(deps_ref.shell_blocks_mag_b) == "function" and deps_ref.shell_blocks_mag_b() then
        return
    end
    if type(deps_ref.revolver_blocks_mag_b) == "function" and deps_ref.revolver_blocks_mag_b() then
        return
    end
    if not deps_ref.manual_reload_context_active() then return end
    if not mag.has_rest then return end

    if mag.state == MAG_STATE.ATTACHED then
        hook.begin_mag_drop()
    elseif mag.state == MAG_STATE.OUT and not mag_holster_enabled() then
        hook.begin_mag_insert()
    end
end



    function M.sync_mag_holster_profile()
        sync_mag_holster_profile_active()
    end

    function M.manual_reload_session_active()
        if not deps_ref.manual_reload_context_active() then return false end
        if mag.state ~= MAG_STATE.ATTACHED then return true end
        if mag_hand.active or mag_hand.release_fall_active then return true end
        if mag.anim_active then return true end
        if deps_ref.frame.vr_reload_b then return true end
        if os.clock() < deps_ref.suppress.until_t then return true end
        return false
    end

    M.publish_sub_weapon_suppress = publish_mag_holster_sub_weapon_suppress
    M.arm_left_support_suppress_grace = arm_left_support_suppress_grace

    function M.on_frame()
        if not chamber_display_hooks_installed then
            install_chamber_display_hooks()
        end
        tick_pending_reserve_top_up()
        sync_mag_holster_profile_active()
        if type(_G.__vr_mag_holster_tick_calibrate) ~= "function" then
            tick_mag_holster_calibrate()
        end
        update_mag_holster_zone()
        tick_mag_sub_weapon_grip_suppress()
        publish_mag_holster_sub_weapon_suppress()
        block_empty_locomotion_mag_anim()
        reconcile_mag_with_loaded_game()
        publish_mag_holster_sub_weapon_suppress()
    end

    function M.on_update_scene()
        if mag_hand.release_fall_active then
            tick_mag_hand_release()
        elseif mag.anim_active then
            tick_mag_animation()
        end
    end

    function M.on_late_update()
        tick_mag_holster_grip_grab()
        tick_mag_exit_preview()
        update_mag_in_hand()
        if not mag_preview.active then
            if mag_hand.active then
                apply_mag_hand_transform()
            else
                apply_mag_frozen_pose()
            end
        end
        publish_mag_holster_sub_weapon_suppress()
    end

    function M.on_prepare_rendering()
        tick_mag_exit_preview()
        if not mag_preview.active then
            if mag_hand.active then
                apply_mag_hand_transform()
            else
                apply_mag_frozen_pose()
            end
        end
        enforce_mag_mesh_hidden()
    end

    function M.invalidate_weapon_cache()
        mag.cached_weapon_go = nil
        mag.cached_wp = nil
    end

    function M.refresh_weapon_cache()
        update_mag_weapon_cache()
    end

    function M.reset_stack_state()
        clear_mag_snapshots()
        cancel_mag_exit_preview(true)
        reset_mag_hand_state()
        clear_mag_freeze()
        clear_mag_carried_rounds()
        mag.rack_pending_after_insert = false
        _G.__vr_mag_in_left_hand = false
        _G.__vr_mag_insert_active = false
        mag.cached_wp = nil
        mag.cached_weapon_go = nil
        mag.state = MAG_STATE.ATTACHED
        mag.mesh_hidden = false
        mag.anim_active = false
        mag.anim_phase = nil
        _G.__vr_mag_dropped = false
        update_mag_weapon_cache()
    end

    function M.on_disabled()
        cancel_mag_exit_preview(true)
        if mag.cached_wp ~= nil then
            reset_mag_visual_state(true)
            mag.cached_wp = nil
        end
        clear_mag_snapshots()
        mag_holster_st.suppress_prev = false
        rawset(_G, "__vr_block_left_support_in_mag_holster_zone", false)
        _G.__vr_mag_in_left_hand = false
        _G.__vr_mag_blocks_weapon_holster = false
        if type(deps_ref.on_mag_holster_suppress_change) == "function" then
            deps_ref.on_mag_holster_suppress_change(false)
        end
    end

    function M.on_context_inactive()
        if mag.state == MAG_STATE.OUT
            or mag.state == MAG_STATE.IN_HAND
            or mag.state == MAG_STATE.DROPPING
            or mag.state == MAG_STATE.INSERTING
            or mag_hand.active
            or mag_hand.release_fall_active then
            return
        end
        if mag.state ~= MAG_STATE.ATTACHED or mag.anim_active then
            reset_mag_visual_state(true)
        end
    end

    function M.handle_b_edge()
        handle_mag_reload_b_edge()
    end

    function M.update_weapon_cache()
        update_mag_weapon_cache()
    end

    function M.on_weapon_swap()
        if should_skip_mag_snapshot_io() then
            return
        end
        local wp = mag.cached_wp
        local snap = wp and mag_snapshots[wp] or nil
        if snap and snap.mag_dropped == true then
            if mag.state ~= MAG_STATE.OUT then
                apply_mag_out_at_rest()
            end
            return
        end
        reconcile_mag_with_loaded_game()
    end

    function M.update_globals()
        if not deps_ref.manual_reload_context_active() then
            _G.__vr_mag_in_left_hand = false
            _G.__vr_mag_insert_active = false
            _G.__vr_mag_dropped = false
            _G.__vr_mag_blocks_weapon_holster = false
            publish_mag_holster_sub_weapon_suppress()
            return
        end
        _G.__vr_mag_in_left_hand = mag_hand.active == true
        _G.__vr_mag_insert_active = mag.state == MAG_STATE.INSERTING or mag.anim_active == true
        _G.__vr_mag_dropped = mag.state == MAG_STATE.OUT
        _G.__vr_mag_blocks_weapon_holster = mag_hand.active == true
            or mag.state == MAG_STATE.INSERTING
            or mag_hand.release_fall_active == true
            or (mag.anim_active and mag.anim_phase == "insert")
        publish_mag_holster_sub_weapon_suppress()
    end

    function M.is_mag_out_of_gun()
        if not deps_ref.manual_reload_context_active() then return false end
        return mag.state ~= MAG_STATE.ATTACHED
    end

    function M.on_tuning_restored()
        sync_mag_holster_profile_active()
        cancel_mag_exit_preview(true)
        local wp = mag.cached_wp or deps_ref.get_weapon_go_name()
        if wp then
            cache_mag_exit_for_weapon(wp)
        end
        if mag_hand.active then
            apply_mag_hand_transform()
        end
        mag_holster_st.status = nil
        mag_preview.status = nil
    end

    M.get_mag = function() return mag end
    M.get_mag_ammo_debug = function()
        return {
            reserve = get_main_weapon_reserve_ammo_count(),
            carried = get_mag_carried_rounds(),
            holster_supply = mag_holster_supply_available(),
        }
    end
    M.get_mag_carried_rounds = get_mag_carried_rounds
    M.get_weapon_mag_slot_round_count = get_weapon_mag_slot_round_count
    M.get_mag_hand = function() return mag_hand end
    M.get_mag_holster_st = function() return mag_holster_st end
    M.current_mag_holster_profile_key = function() return current_mag_holster_profile_key() end
    M.get_haptic_left_joystick = get_left_joystick
    M.get_left_hand_position = get_left_hand_position
    M.get_left_hand_joint = get_left_hand_joint
    M.get_mag_hand_hold_entry = get_mag_hand_hold_entry
    M.get_mag_dock_local_distance = hook.get_mag_dock_local_distance
    M.get_shell_insert_local_distance = hook.get_shell_insert_local_distance
    M.get_mag_dock_dist = hook.get_mag_dock_dist
    M.get_left_track_position = function()
        return get_track_pos_for_rack()
    end
    M.get_left_track_pos_with_source = get_track_pos_for_rack
    -- Pass the hand through (default left, preserving every existing
    -- no-arg caller): the old hardcoded "left" made ext_2's motion-rack
    -- right-controller read silently return the LEFT controller, so the
    -- relative-hands pull measured (L - L) = an exact constant zero.
    M.get_vr_controller_world_pos = function(hand)
        return get_vr_controller_world_pos(hand == "right" and "right" or "left")
    end
    M.is_left_grip_pressed = function() return is_left_grip_pressed() end
    M.is_left_trigger_pressed = function() return is_left_trigger_pressed() end
    M.haptic_pulse = haptic_pulse
    M.get_weapon_chamber_bullet_count = get_weapon_chamber_bullet_count
    M.clear_weapon_chamber_ammo = clear_weapon_chamber_ammo
    M.on_chamber_ammo_to_carried = on_chamber_ammo_to_carried
    M.commit_reload_ammo = function()
        hook.commit_reload_ammo()
    end
    M.get_main_weapon_reserve_ammo_count = get_main_weapon_reserve_ammo_count
    M.get_inventory_spare_bullet_count = get_inventory_spare_bullet_count
    M.prime_main_weapon_reloadable_pool = prime_main_weapon_reloadable_pool
    M.get_weapon_reloadable_count = get_weapon_reloadable_count
    M.apply_carried_mag_ammo = apply_carried_mag_ammo
    M.get_imgr_weapon_loaded = get_imgr_weapon_loaded
    M.get_imgr_weapon_carried = get_imgr_weapon_carried
    M.get_shell_hud_ammo = get_shell_hud_ammo
    M.apply_single_shell_round = apply_single_shell_round

    function M.spawn_tube_shell_to_hand()
        if not deps_ref.manual_reload_context_active() then return false end
        local wp = deps_ref.get_weapon_go_name()
        if not wp or not weapon_uses_manual_shell_reload(wp) then return false end
        if not get_mag_node_name(wp) then return false end
        if mag_hand.active then return false end

        if not mag.target or not mag.has_rest or mag.cached_wp ~= wp then
            mag.cached_wp = wp
            mag.cached_weapon_go = get_weapon_go_token()
            resolve_mag_joint(wp)
        end
        if not mag.target or not mag.has_rest then return false end

        refresh_mag_exit_world_ref()
        show_mag_mesh()
        mag.mesh_hidden = false
        clear_mag_freeze()
        mag_hand.active = true
        mag_hand.release_fall_active = false
        mag.state = MAG_STATE.IN_HAND
        _G.__vr_mag_in_left_hand = true
        _G.__vr_shell_in_left_hand = true
        apply_mag_hand_transform()
        hook.extend_mag_suppress_window()
        if deps_ref.play_reload_sfx then deps_ref.play_reload_sfx("mag_grab") end
        log.info(string.format(
            "[re2_vr_reload] Tube shell on hand wp=%s node=%s",
            tostring(wp), tostring(mag.node_name)))
        return true
    end

    function M.clear_tube_shell_hand()
        if not mag_hand.active and rawget(_G, "__vr_shell_in_left_hand") ~= true then return end
        mag_hand.active = false
        mag_hand.grip_prev = false
        mag_hand.release_fall_active = false
        _G.__vr_mag_in_left_hand = false
        if mag.target and mag.has_rest then
            write_target_local_position(mag.target, mag.target_kind,
                Vector3f.new(mag.rest_x, mag.rest_y, mag.rest_z))
        end
        if mag.state == MAG_STATE.IN_HAND then
            mag.state = MAG_STATE.ATTACHED
        end
        mag.mesh_hidden = false
    end

    function M.detach_mag_hand_for_shell()
        local wp = deps_ref.get_weapon_go_name()
        if not wp or not weapon_uses_manual_shell_reload(wp) then return end
        if not mag_hand.active and rawget(_G, "__vr_mag_in_left_hand") ~= true then return end
        mag_hand.active = false
        mag_hand.grip_prev = false
        mag_hand.release_fall_active = false
        _G.__vr_mag_in_left_hand = false
        if mag.target and mag.has_rest then
            write_target_local_position(mag.target, mag.target_kind,
                Vector3f.new(mag.rest_x, mag.rest_y, mag.rest_z))
        end
        if mag.state == MAG_STATE.IN_HAND or mag.state == MAG_STATE.DROPPING then
            mag.state = MAG_STATE.ATTACHED
        end
        mag.anim_active = false
        mag.mesh_hidden = false
        clear_mag_freeze()
    end

M.init = (function(init_fn)
    return function(deps)
        init_fn(deps)
        rawset(_G, "__vr_mag_holster_start_calibrate", start_mag_holster_calibrate)
        rawset(_G, "__vr_mag_holster_tick_calibrate", tick_mag_holster_calibrate)
        rawset(_G, "__vr_mag_holster_get_capture_remaining", function()
            if mag_holster_cap.pending then
                return mag_holster_cap.deadline - os.clock()
            end
            return nil
        end)
    end
end)(M.init)

return M
