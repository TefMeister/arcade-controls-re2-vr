if package.loaded["re2_vr_reload_ext_3"] then
    return package.loaded["re2_vr_reload_ext_3"]
end

local M = {}

local CFG
local sc
local re2
local get_weapon_go_name
local manual_reload_context_active
local weapon_display_name
local mark_tuning_dirty
local play_reload_sfx
local get_left_hand_position
local get_left_hand_joint
local get_left_track_position
local get_left_track_pos_with_source
local get_mag_hand_hold_entry
local get_mag_dock_dist
local is_left_grip_pressed
local detach_mag_hand_for_shell
local get_weapon_chamber_bullet_count
local get_main_weapon_reserve_ammo_count
local get_inventory_spare_bullet_count
local prime_main_weapon_reloadable_pool
local apply_carried_mag_ammo
local get_shell_hud_ammo
local apply_single_shell_round
local extend_suppress_window
local arm_left_support_grace
local publish_sub_weapon_suppress
local clear_weapon_chamber_ammo
local sync_chamber_shoot_ready
local on_chamber_ammo_to_carried
local commit_reload_ammo
local weapon_uses_canister_mag_reload
local get_mag_carried_rounds
local get_weapon_mag_slot_round_count
local try_bullet_dock
local update_bullet_in_hand
local haptic_pulse
local native_change_bullet_suspend_active
local reload_drop

local PLAYER_JOINT = {
    right_wrist = { "r_arm_wrist" },
}

local function find_player_joint(tf, joint_names)
    if not tf then return nil end
    for _, joint_name in ipairs(joint_names or {}) do
        local joint = sc(tf, "getJointByName", joint_name)
        if joint then return joint end
    end
    return nil
end

local rv = {
    ammo_prime_wp = nil,
    cylinder_open = false,
    open_t = 0.0,
    lerp_t = 0.0,
    swing_joint = nil,
    swing_joint_name = nil,
    swing_joint_wp = nil,
    swing_kind = nil,
    swing_rest_w = 1.0,
    swing_rest_x = 0.0,
    swing_rest_y = 0.0,
    swing_rest_z = 0.0,
    chamber_joint = nil,
    chamber_kind = nil,
    chamber_rest_w = 1.0,
    chamber_rest_x = 0.0,
    chamber_rest_y = 0.0,
    chamber_rest_z = 0.0,
    in_hand = false,
    weapon_wp = nil,
    mesh_ref = nil,
    gun_tf = nil,
    weapon_xform = nil,
    dock_joint = nil,
    dock_kind = nil,
    target = nil,
    target_kind = nil,
    node_name = nil,
    insert_chamber_slot = nil,
    change_bullet_suspend = false,
    change_bullet_suspend_wp = nil,
    mesh_indices = nil,
    rest_x = 0.0,
    rest_y = 0.0,
    rest_z = 0.0,
    rest_w = 1.0,
    rest_rx = 0.0,
    rest_ry = 0.0,
    rest_rz = 0.0,
    rest_sx = 1.0,
    rest_sy = 1.0,
    rest_sz = 1.0,
    has_rest = false,
    enabled_parts = false,
    last_dock_t = 0.0,
    pending_insert = nil,
    grip_prev = false,
    shoot_ready_grace_until = 0.0,
    anim_active = false,
    anim_start = 0.0,
    slide_lx0 = 0.0,
    slide_ly0 = 0.0,
    slide_lz0 = 0.0,
    slide_lx1 = 0.0,
    slide_ly1 = 0.0,
    slide_lz1 = 0.0,
    slide_rw0 = 1.0,
    slide_rx0 = 0.0,
    slide_ry0 = 0.0,
    slide_rz0 = 0.0,
    slide_rw1 = 1.0,
    slide_rx1 = 0.0,
    slide_ry1 = 0.0,
    slide_rz1 = 0.0,
    release_fall_active = false,
    release_local_fall = false,
    release_start = 0.0,
    release_sx = 0.0,
    release_sy = 0.0,
    release_sz = 0.0,
    release_rx = 0.0,
    release_ry = 0.0,
    release_rz = 0.0,
    release_rw = 1.0,
    release_chamber_slot = nil,
    release_bullet_source = nil,
    chamber_extracted = false,
    spent_round_in_chamber = false,
    chamber_round_seated = false,
    extract_stash_rounds = nil,
    canister_stash_by_wp = {},
    last_loaded_count = nil,
    last_loaded_track_wp = nil,
    bullet_source = nil,
    weapon_chamber_grip_prev = false,
    insert_preview_active = false,
    insert_preview_until = 0.0,
    insert_preview_wp = nil,
    insert_preview_rest_x = 0.0,
    insert_preview_rest_y = 0.0,
    insert_preview_rest_z = 0.0,
    freeze_pose = false,
    freeze_wx = 0.0,
    freeze_wy = 0.0,
    freeze_wz = 0.0,
    frozen_rot_x = 0.0,
    frozen_rot_y = 0.0,
    frozen_rot_z = 0.0,
    frozen_rot_w = 1.0,
    close_last_pos = nil,
    close_last_pos_t = 0.0,
    close_anchor_x = nil,
    close_anchor_y = nil,
    close_anchor_z = nil,
    close_anchor_t = 0.0,
    close_play_off_x = nil,
    close_play_off_y = nil,
    close_play_off_z = nil,
    close_play_right_x = nil,
    close_play_right_y = nil,
    close_play_right_z = nil,
    close_play_up_x = nil,
    close_play_up_y = nil,
    close_play_up_z = nil,
    close_play_fwd_x = nil,
    close_play_fwd_y = nil,
    close_play_fwd_z = nil,
    close_play_axes_ready = false,
    close_cooldown_until = 0.0,
    close_pending_until = nil,
    dbg_stick_wp = nil,
    dbg_stick_gun_x = nil,
    dbg_stick_gun_y = nil,
    dbg_stick_gun_z = nil,
    dbg_stick_joint_x = nil,
    dbg_stick_joint_y = nil,
    dbg_stick_joint_z = nil,
    grab_rest_wp = nil,
    grab_rest_go = nil,
}

local REVOLVER_CAPACITY = {
    wp0300 = 6,
    wp3200 = 5,
    wp0800 = 5,
    wp4100 = 1,
}

local function rv_cfg()
    return CFG and CFG.revolver_reload or {}
end

local function visual_hide_uses_scale()
    local vh = CFG and CFG.visual_hide
    if type(vh) ~= "table" then return true end
    return vh.mode ~= "legacy"
end

local function weapon_entry(wp)
    if not wp or type(CFG.weapons) ~= "table" then return nil end
    return CFG.weapons[wp]
end

local function cylinder_close_sfx_kind(wp)
    wp = wp or get_weapon_go_name()
    local entry = weapon_entry(wp)
    if entry and entry.needs_manual_cylinder_reload == true then
        return "pump_fire"
    end
    return "mag_insert"
end

local function play_cylinder_close_sfx()
    if play_reload_sfx then play_reload_sfx(cylinder_close_sfx_kind()) end
end

function M.is_revolver_weapon(wp)
    wp = wp or get_weapon_go_name()
    if not wp then return false end
    if rv_cfg().enabled == false then return false end
    local entry = weapon_entry(wp)
    if not entry then return false end
    if entry.needs_manual_cylinder_reload == true then return true end
    return entry.needs_manual_revolver_reload == true
end

local function change_bullet_suspend_blocks_manual()
    if rv.change_bullet_suspend == true then return true end
    if native_change_bullet_suspend_active then
        return native_change_bullet_suspend_active() == true
    end
    return false
end

function M.is_revolver_weapon_active()
    if change_bullet_suspend_blocks_manual() then return false end
    if not manual_reload_context_active() then return false end
    return M.is_revolver_weapon(get_weapon_go_name())
end

function M.cylinder_is_open()
    return rv.cylinder_open == true
end

function M.cylinder_blocks_fire()
    if not M.is_revolver_weapon_active() then return false end
    local wp = get_weapon_go_name()
    if weapon_uses_canister_mag_reload and weapon_uses_canister_mag_reload(wp) then
        if rv.chamber_extracted == true then return true end
        if rv.in_hand and rv.bullet_source == "weapon" then return true end
        if rv.release_fall_active and rv.release_bullet_source == "weapon" then return true end
        return false
    end
    return rv.cylinder_open == true
end

local function get_player_transform()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    if not cm then return nil end
    local ctx = sc(cm, "get_PlayerContextFast")
    if not ctx then return nil end
    local go = sc(ctx, "get_GameObject")
    if not go then return nil end
    return sc(go, "get_Transform")
end

local function get_right_hand_joint()
    local cached = rawget(_G, "__vr_rh_joint")
    if cached then
        local valid = false
        pcall(function() valid = cached:get_Valid() end)
        if valid then return cached end
    end
    local tf = get_player_transform()
    if not tf then return nil end
    return find_player_joint(tf, PLAYER_JOINT.right_wrist)
end

local function get_right_joystick()
    local vm = rawget(_G, "vrmod")
    if not vm then return nil end
    local ok, rj = pcall(function() return vm:get_right_joystick() end)
    return ok and rj or nil
end

local function quat_from_vr_rotation(rot)
    if not rot then return nil end
    if type(rot.w) == "number" then
        return Quaternion.new(rot.w, rot.x, rot.y, rot.z)
    end
    local ok, q = pcall(function() return rot:normalized() end)
    if ok and q then return q end
    ok, q = pcall(function() return rot:to_quat() end)
    return ok and q or nil
end

local function quat_rotate_vec3(q, v)
    if not q or not v then return nil end
    local ok, r = pcall(function() return q * v end)
    return ok and r or nil
end

local function normalize_vec3(x, y, z)
    if type(x) ~= "number" then return nil end
    local len = math.sqrt(x * x + y * y + z * z)
    if len < 1e-6 then return nil end
    return x / len, y / len, z / len
end

local function get_hmd_openxr_pos()
    local vm = rawget(_G, "vrmod")
    if not vm then return nil end
    local ok, pos = pcall(function() return vm:get_position(0) end)
    if ok and pos and type(pos.x) == "number" then return pos end
    return nil
end

local function get_right_controller_raw_openxr_pos()
    local vm = rawget(_G, "vrmod")
    if not vm then return nil end
    local controllers
    pcall(function() controllers = vm:get_controllers() end)
    if not controllers or not controllers[2] then return nil end
    local ok, pos = pcall(function() return vm:get_position(controllers[2]) end)
    if ok and pos and type(pos.x) == "number" then return pos end
    return nil
end

local function get_right_controller_hmd_offset()
    local ctrl = get_right_controller_raw_openxr_pos()
    local hmd = get_hmd_openxr_pos()
    if not ctrl or not hmd then return nil end
    return Vector3f.new(ctrl.x - hmd.x, ctrl.y - hmd.y, ctrl.z - hmd.z)
end

local function capture_close_play_axes()
    local vm = rawget(_G, "vrmod")
    if not vm then
        rv.close_play_axes_ready = false
        return false
    end
    local controllers
    pcall(function() controllers = vm:get_controllers() end)
    if not controllers or not controllers[2] then
        rv.close_play_axes_ready = false
        return false
    end
    local ok, rot = pcall(function() return vm:get_rotation(controllers[2]) end)
    local q = ok and quat_from_vr_rotation(rot) or nil
    if not q then
        rv.close_play_axes_ready = false
        return false
    end
    local right = quat_rotate_vec3(q, Vector3f.new(1, 0, 0))
    local up = quat_rotate_vec3(q, Vector3f.new(0, 1, 0))
    local fwd = quat_rotate_vec3(q, Vector3f.new(0, 0, 1))
    if not right or not up or not fwd then
        rv.close_play_axes_ready = false
        return false
    end
    local rx, ry, rz = normalize_vec3(right.x, right.y, right.z)
    local ux, uy, uz = normalize_vec3(up.x, up.y, up.z)
    local fx, fy, fz = normalize_vec3(fwd.x, fwd.y, fwd.z)
    if not rx or not ux or not fx then
        rv.close_play_axes_ready = false
        return false
    end
    rv.close_play_right_x = rx
    rv.close_play_right_y = ry
    rv.close_play_right_z = rz
    rv.close_play_up_x = ux
    rv.close_play_up_y = uy
    rv.close_play_up_z = uz
    rv.close_play_fwd_x = fx
    rv.close_play_fwd_y = fy
    rv.close_play_fwd_z = fz
    rv.close_play_axes_ready = true
    return true
end

local function clear_close_play_anchor()
    rv.close_play_off_x = nil
    rv.close_play_off_y = nil
    rv.close_play_off_z = nil
    rv.close_play_right_x = nil
    rv.close_play_right_y = nil
    rv.close_play_right_z = nil
    rv.close_play_up_x = nil
    rv.close_play_up_y = nil
    rv.close_play_up_z = nil
    rv.close_play_fwd_x = nil
    rv.close_play_fwd_y = nil
    rv.close_play_fwd_z = nil
    rv.close_play_axes_ready = false
end

local function flatten_axis_xz(ax)
    if not ax then return nil end
    local len = math.sqrt(ax.x * ax.x + ax.z * ax.z)
    if len < 1e-6 then return nil end
    return { x = ax.x / len, y = 0.0, z = ax.z / len }
end

local function get_controller_flat_right()
    local vm = rawget(_G, "vrmod")
    if not vm then return nil end
    local controllers
    pcall(function() controllers = vm:get_controllers() end)
    if not controllers or not controllers[2] then return nil end
    local ok, rot = pcall(function() return vm:get_rotation(controllers[2]) end)
    local q = ok and quat_from_vr_rotation(rot) or nil
    if not q then return nil end
    local ok2, axis = pcall(function() return q * Vector3f.new(1, 0, 0) end)
    return ok2 and flatten_axis_xz(axis) or nil
end

local function get_player_flat_axes()
    local tf = get_player_transform()
    if not tf then return nil, nil end
    local rot = sc(tf, "get_Rotation")
    local fx, fz = nil, nil
    if rot then
        local ok, fwd_v = pcall(function() return rot * Vector3f.new(0, 0, 1) end)
        if ok and fwd_v then fx, fz = fwd_v.x, fwd_v.z end
    end
    if not fx then
        local fwd = sc(tf, "get_AxisZ")
        if fwd then fx, fz = fwd.x, fwd.z end
    end
    if not fx then return nil, nil end
    local flen = math.sqrt(fx * fx + fz * fz)
    if flen < 1e-6 then return nil, nil end
    fx, fz = fx / flen, fz / flen
    return { x = fz, y = 0.0, z = -fx }, { x = fx, y = 0.0, z = fz }
end

local function get_gesture_flat_axes()
    local cam = sdk.get_primary_camera()
    if cam then
        local wm = sc(cam, "get_WorldMatrix")
        if wm then
            local fx, fz = wm[2].x, wm[2].z
            local flen = math.sqrt(fx * fx + fz * fz)
            if flen > 1e-6 then
                fx, fz = fx / flen, fz / flen
                return { x = fz, y = 0.0, z = -fx }, { x = fx, y = 0.0, z = fz }
            end
        end
    end
    return get_player_flat_axes()
end

local function vec3_dot_axis(axis, dx, dy, dz)
    return dx * axis.x + dy * (axis.y or 0.0) + dz * axis.z
end

local function measure_rightward_lateral(dx, dy, dz)
    local best = 0.0
    local best_src = "none"
    local hmd_right, fwd = get_gesture_flat_axes()
    if hmd_right then
        local v = vec3_dot_axis(hmd_right, dx, dy, dz)
        if v > best then best, best_src = v, "hmd_right" end
    end
    local ctrl_right = get_controller_flat_right()
    if ctrl_right then
        local v = vec3_dot_axis(ctrl_right, dx, dy, dz)
        if v > best then best, best_src = v, "controller_right" end
    end
    local horiz_fwd = 0.0
    if fwd then horiz_fwd = vec3_dot_axis(fwd, dx, dy, dz) end
    return best, best_src, hmd_right, fwd, horiz_fwd
end

local function get_right_gesture_position()
    local vm = rawget(_G, "vrmod")
    if vm then
        local controllers
        pcall(function() controllers = vm:get_controllers() end)
        if controllers and controllers[2] then
            local ok, pos = pcall(function() return vm:get_position(controllers[2]) end)
            if ok and pos and type(pos.x) == "number" then return pos, "controller" end
        end
    end
    local w = rawget(_G, "__vr_rh_world")
    if w and type(w.x) == "number" then return w, "rh_world" end
    local rh = get_right_hand_joint()
    local pos = rh and sc(rh, "get_Position")
    return pos, pos and "joint" or "none"
end

local function weapon_close_gesture_enabled(wp)
    wp = wp or get_weapon_go_name()
    if not wp or not M.is_revolver_weapon(wp) then return false end
    if rv_cfg().close_gesture_enabled == false then return false end
    local entry = weapon_entry(wp)
    if entry and entry.cylinder_close_gesture == false then return false end
    return true
end

local function get_weapon_close_gesture_modes(wp)
    wp = wp or get_weapon_go_name()
    if not weapon_close_gesture_enabled(wp) then
        return { right = false, up = false }
    end
    local entry = weapon_entry(wp) or {}
    return {
        right = entry.cylinder_close_gesture_right ~= false,
        up = entry.cylinder_close_gesture_up == true,
    }
end

function M.weapon_close_gesture_enabled(wp)
    return weapon_close_gesture_enabled(wp)
end

local function clear_close_gesture_tracking()
    rv.close_last_pos = nil
    rv.close_last_pos_t = 0.0
    rv.close_anchor_x = nil
    rv.close_anchor_y = nil
    rv.close_anchor_z = nil
    rv.close_anchor_t = 0.0
    clear_close_play_anchor()
    rv.close_pending_until = nil
end

local function schedule_close_from_gesture(mode, swipe, dist, ratio)
    local now = os.clock()
    local cfg = rv_cfg()
    local delay = tonumber(cfg.close_gesture_delay_sec) or 0.1
    local cooldown = tonumber(cfg.close_gesture_cooldown_sec) or 0.8
    rv.close_pending_until = now + delay
    rv.close_cooldown_until = now + cooldown
    if haptic_pulse then
        local rj = get_right_joystick()
        if rj then haptic_pulse(rj, 0.06, 200.0, 0.7) end
    end
    log.info(string.format(
        "[re2_vr_reload] Cylinder close gesture wp=%s mode=%s swipe=%.2f dist=%.3f ratio=%.2f",
        tostring(get_weapon_go_name()), tostring(mode), tonumber(swipe) or 0,
        tonumber(dist) or 0, tonumber(ratio) or 0))
end

local function try_close_gesture_motion_world(dx, dy, dz, dt, modes, cfg)
    if not modes or dt <= 1e-6 then return false end

    local total = math.sqrt(dx * dx + dy * dy + dz * dz)
    if total < 1e-6 then return false end

    local vertical_ratio = math.abs(dy) / total
    local up_ratio = dy > 0 and (dy / total) or 0.0
    local lateral, _, hmd_right, fwd = measure_rightward_lateral(dx, dy, dz)
    local horiz = 0.0
    if hmd_right and fwd then
        local lat_h = vec3_dot_axis(hmd_right, dx, dy, dz)
        local lat_f = vec3_dot_axis(fwd, dx, dy, dz)
        horiz = math.sqrt(lat_h * lat_h + lat_f * lat_f)
    end
    local swipe = lateral / dt
    local right_ratio = horiz > 1e-6 and (lateral / horiz) or 0.0

    if modes.right then
        local swipe_min = tonumber(cfg.close_gesture_swipe_speed) or 0.55
        local swipe_dist_min = tonumber(cfg.close_gesture_swipe_dist) or 0.025
        local lateral_ratio_min = tonumber(cfg.close_gesture_lateral_ratio) or 0.45
        local max_vertical_ratio = tonumber(cfg.close_gesture_max_vertical_ratio) or 0.45
        if lateral > 0
            and lateral >= swipe_dist_min
            and swipe >= swipe_min
            and right_ratio >= lateral_ratio_min
            and lateral >= math.abs(dy)
            and vertical_ratio <= max_vertical_ratio then
            schedule_close_from_gesture("right", swipe, lateral, right_ratio)
            return true
        end
    end

    if modes.up then
        local up_speed_min = tonumber(cfg.close_gesture_up_swipe_speed) or 0.55
        local up_dist_min = tonumber(cfg.close_gesture_up_swipe_dist) or 0.025
        local up_ratio_min = tonumber(cfg.close_gesture_up_ratio) or 0.5
        local up_speed = dy / dt
        if dy > 0
            and dy >= up_dist_min
            and up_speed >= up_speed_min
            and up_ratio >= up_ratio_min
            and dy >= horiz then
            schedule_close_from_gesture("up", up_speed, dy, up_ratio)
            return true
        end
    end

    return false
end

local function try_close_gesture_motion_play(dx, dy, dz, dt, modes, cfg)
    if not modes or dt <= 1e-6 or not rv.close_play_axes_ready then return false end

    local total = math.sqrt(dx * dx + dy * dy + dz * dz)
    if total < 1e-6 then return false end

    local rax = rv.close_play_right_x
    local ray = rv.close_play_right_y
    local raz = rv.close_play_right_z
    local uax = rv.close_play_up_x
    local uay = rv.close_play_up_y
    local uaz = rv.close_play_up_z
    local fax = rv.close_play_fwd_x
    local fay = rv.close_play_fwd_y
    local faz = rv.close_play_fwd_z

    local lateral = dx * rax + dy * ray + dz * raz
    local vertical = dx * uax + dy * uay + dz * uaz
    local fwd_comp = dx * fax + dy * fay + dz * faz
    local horiz = math.sqrt(lateral * lateral + fwd_comp * fwd_comp)
    local vertical_ratio = math.abs(vertical) / total
    local up_ratio = vertical > 0 and (vertical / total) or 0.0
    local swipe = lateral / dt
    local right_ratio = horiz > 1e-6 and (lateral / horiz) or 0.0

    if modes.right then
        local swipe_min = tonumber(cfg.close_gesture_swipe_speed) or 0.55
        local swipe_dist_min = tonumber(cfg.close_gesture_swipe_dist) or 0.025
        local lateral_ratio_min = tonumber(cfg.close_gesture_lateral_ratio) or 0.45
        local max_vertical_ratio = tonumber(cfg.close_gesture_max_vertical_ratio) or 0.45
        if lateral > 0
            and lateral >= swipe_dist_min
            and swipe >= swipe_min
            and right_ratio >= lateral_ratio_min
            and lateral >= math.abs(vertical)
            and vertical_ratio <= max_vertical_ratio then
            schedule_close_from_gesture("right_play", swipe, lateral, right_ratio)
            return true
        end
    end

    if modes.up then
        local up_speed_min = tonumber(cfg.close_gesture_up_swipe_speed) or 0.55
        local up_dist_min = tonumber(cfg.close_gesture_up_swipe_dist) or 0.025
        local up_ratio_min = tonumber(cfg.close_gesture_up_ratio) or 0.5
        local up_speed = vertical / dt
        if vertical > 0
            and vertical >= up_dist_min
            and up_speed >= up_speed_min
            and up_ratio >= up_ratio_min
            and vertical >= horiz then
            schedule_close_from_gesture("up_play", up_speed, vertical, up_ratio)
            return true
        end
    end

    return false
end

local function close_cylinder_now()
    if not rv.cylinder_open then return false end
    rv.cylinder_open = false
    play_cylinder_close_sfx()
    if extend_suppress_window then extend_suppress_window() end
    rv.shoot_ready_grace_until = 0.0
    rv.chamber_extracted = false
    rv.spent_round_in_chamber = false
    rv.chamber_round_seated = true
    if sync_chamber_shoot_ready then sync_chamber_shoot_ready() end
    return true
end

local function tick_close_gesture()
    local now = os.clock()
    if rv.close_pending_until and now >= rv.close_pending_until then
        rv.close_pending_until = nil
        close_cylinder_now()
    end

    if not M.is_revolver_weapon_active() or not rv.cylinder_open then
        clear_close_gesture_tracking()
        return
    end
    if not weapon_close_gesture_enabled() then
        clear_close_gesture_tracking()
        return
    end
    if rv.in_hand or rv.anim_active or rv.pending_insert then
        clear_close_gesture_tracking()
        return
    end

    local cfg = rv_cfg()
    local window_min = tonumber(cfg.close_gesture_window_min) or 0.035
    local window_max = tonumber(cfg.close_gesture_window_max) or 0.17
    local on_cooldown = now <= (rv.close_cooldown_until or 0)
    local modes = get_weapon_close_gesture_modes()
    local play_off = get_right_controller_hmd_offset()
    local pos = get_right_gesture_position()

    if not on_cooldown and not rv.close_pending_until and (modes.right or modes.up) then
        if play_off then
            if not rv.close_play_off_x or (now - (rv.close_anchor_t or 0)) > window_max then
                rv.close_play_off_x = play_off.x
                rv.close_play_off_y = play_off.y
                rv.close_play_off_z = play_off.z
                rv.close_anchor_t = now
                capture_close_play_axes()
            end
            local dt = now - (rv.close_anchor_t or now)
            if dt >= window_min and dt <= window_max and rv.close_play_axes_ready then
                local dx = play_off.x - rv.close_play_off_x
                local dy = play_off.y - rv.close_play_off_y
                local dz = play_off.z - rv.close_play_off_z
                if try_close_gesture_motion_play(dx, dy, dz, dt, modes, cfg) then
                    clear_close_play_anchor()
                    rv.close_anchor_t = 0.0
                end
            end
        elseif pos then
            if not rv.close_anchor_x or (now - (rv.close_anchor_t or 0)) > window_max then
                rv.close_anchor_x = pos.x
                rv.close_anchor_y = pos.y
                rv.close_anchor_z = pos.z
                rv.close_anchor_t = now
            end
            local dt = now - (rv.close_anchor_t or now)
            if dt >= window_min and dt <= window_max then
                local dx = pos.x - (rv.close_anchor_x or pos.x)
                local dy = pos.y - (rv.close_anchor_y or pos.y)
                local dz = pos.z - (rv.close_anchor_z or pos.z)
                if try_close_gesture_motion_world(dx, dy, dz, dt, modes, cfg) then
                    rv.close_anchor_x = nil
                end
            end
        end
    end
    if pos then
        rv.close_last_pos = Vector3f.new(pos.x, pos.y, pos.z)
        rv.close_last_pos_t = now
    end
end

local function vec3_dist(a, b)
    if not a or not b or type(a.x) ~= "number" or type(b.x) ~= "number" then return 1e9 end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function quat_from_ypr(yaw_deg, pitch_deg, roll_deg)
    local yaw = math.rad(yaw_deg or 0.0)
    local pitch = math.rad(pitch_deg or 0.0)
    local roll = math.rad(roll_deg or 0.0)
    local cy, sy = math.cos(yaw * 0.5), math.sin(yaw * 0.5)
    local cp, sp = math.cos(pitch * 0.5), math.sin(pitch * 0.5)
    local cr, sr = math.cos(roll * 0.5), math.sin(roll * 0.5)
    return Quaternion.new(
        cr * cp * cy + sr * sp * sy,
        sr * cp * cy - cr * sp * sy,
        cr * sp * cy + sr * cp * sy,
        cr * cp * sy - sr * sp * cy)
end

local function quat_from_euler_deg(pitch_deg, yaw_deg, roll_deg)
    if not Quaternion or not Quaternion.new then return nil end
    local ok, q = pcall(function()
        return Quaternion.new(Vector3f.new(
            math.rad(tonumber(pitch_deg) or 0.0),
            math.rad(tonumber(yaw_deg) or 0.0),
            math.rad(tonumber(roll_deg) or 0.0))):normalized()
    end)
    return ok and q or nil
end

local function quat_slerp(a, b, t)
    if not a or not b then return a or b end
    t = math.max(0.0, math.min(1.0, tonumber(t) or 0.0))
    local aw, ax, ay, az = a.w, a.x, a.y, a.z
    local bw, bx, by, bz = b.w, b.x, b.y, b.z
    local dot = aw * bw + ax * bx + ay * by + az * bz
    if dot < 0.0 then
        dot = -dot
        bw, bx, by, bz = -bw, -bx, -by, -bz
    end
    if dot > 0.9995 then
        local w = aw + (bw - aw) * t
        local x = ax + (bx - ax) * t
        local y = ay + (by - ay) * t
        local z = az + (bz - az) * t
        local inv = 1.0 / math.sqrt(w * w + x * x + y * y + z * z)
        return Quaternion.new(w * inv, x * inv, y * inv, z * inv)
    end
    local theta0 = math.acos(dot)
    local sin0 = math.sin(theta0)
    if sin0 < 1e-6 then return Quaternion.new(aw, ax, ay, az) end
    local theta = theta0 * t
    local s0 = math.sin(theta0 - theta) / sin0
    local s1 = math.sin(theta) / sin0
    return Quaternion.new(
        aw * s0 + bw * s1,
        ax * s0 + bx * s1,
        ay * s0 + by * s1,
        az * s0 + bz * s1)
end

local function find_transform_child_by_name(root_tf, name, depth)
    if not root_tf or not name or (depth or 0) > 14 then return nil end
    depth = depth or 0
    local child = sc(root_tf, "get_Child")
    while child do
        local go = sc(child, "get_GameObject")
        local go_name = go and sc(go, "get_Name")
        if go_name == name then return child end
        local nested = find_transform_child_by_name(child, name, depth + 1)
        if nested then return nested end
        child = sc(child, "get_Next")
    end
    return nil
end

local function resolve_bullet_target(weapon_xform, node_name)
    if not weapon_xform or not node_name then return nil, nil end
    local names = { node_name }
    if node_name:sub(1, 1) == "_" then
        names[#names + 1] = node_name:sub(2)
    else
        names[#names + 1] = "_" .. node_name
    end
    for _, nm in ipairs(names) do
        local joint = sc(weapon_xform, "getJointByName", nm)
        if joint then return joint, "joint" end
        local child_tf = find_transform_child_by_name(weapon_xform, nm, 0)
        if child_tf then
            local child_joint = sc(weapon_xform, "getJointByName", nm)
            if child_joint then return child_joint, "joint" end
            return child_tf, "xform"
        end
    end
    return nil, nil
end

local function read_target_local_position(target, kind)
    if not target then return nil end
    if kind == "joint" then
        local pos = sc(target, "get_LocalPosition")
        if pos then return pos end
        local tf = sc(target, "get_Transform")
        if tf then return sc(tf, "get_LocalPosition") end
        return nil
    end
    return sc(target, "get_LocalPosition")
end

local function read_target_local_rotation(target, kind)
    if not target then return nil end
    if kind == "joint" then
        local rot = sc(target, "get_LocalRotation")
        if rot then return rot end
        local tf = sc(target, "get_Transform")
        if tf then return sc(tf, "get_LocalRotation") end
        return nil
    end
    return sc(target, "get_LocalRotation")
end

local function write_target_local_position(target, kind, pos)
    if not target or not pos then return false end
    if kind == "joint" then
        if sc(target, "set_LocalPosition", pos) then return true end
        local tf = sc(target, "get_Transform")
        if tf and sc(tf, "set_LocalPosition", pos) then return true end
        return false
    end
    return sc(target, "set_LocalPosition", pos) == true
end

local function write_target_local_rotation(target, kind, rot)
    if not target or not rot then return false end
    if kind == "joint" then
        if sc(target, "set_LocalRotation", rot) then return true end
        local tf = sc(target, "get_Transform")
        if tf and sc(tf, "set_LocalRotation", rot) then return true end
        return false
    end
    return sc(target, "set_LocalRotation", rot) == true
end

local function read_target_local_scale(target, kind)
    if not target then return nil end
    if kind == "joint" then
        local s = sc(target, "get_LocalScale")
        if s then return s end
        local tf = sc(target, "get_Transform")
        if tf then return sc(tf, "get_LocalScale") end
        return nil
    end
    return sc(target, "get_LocalScale")
end

local function write_target_local_scale(target, kind, scale)
    if not target or not scale then return false end
    if kind == "joint" then
        if sc(target, "set_LocalScale", scale) then return true end
        local tf = sc(target, "get_Transform")
        if tf and sc(tf, "set_LocalScale", scale) then return true end
        return false
    end
    return sc(target, "set_LocalScale", scale) == true
end

local function read_target_world_position(target, kind)
    if not target then return nil end
    local pos = sc(target, "get_Position")
    if pos then return pos end
    if kind == "joint" then
        local tf = sc(target, "get_Transform")
        if tf then return sc(tf, "get_Position") end
    end
    return nil
end

local function read_target_world_rotation(target, kind)
    if not target then return nil end
    local rot = sc(target, "get_Rotation")
    if rot then return rot end
    if kind == "joint" then
        local tf = sc(target, "get_Transform")
        if tf then return sc(tf, "get_Rotation") end
    end
    return nil
end

local function write_target_world_position_only(target, kind, pos)
    if not target or not pos then return false end
    if kind == "joint" then
        if sc(target, "set_Position", pos) then return true end
        local tf = sc(target, "get_Transform")
        if tf and sc(tf, "set_Position", pos) then return true end
        return false
    end
    return sc(target, "set_Position", pos) == true
end

local function write_target_world_rotation(target, kind, rot)
    if not target or not rot then return false end
    if kind == "joint" then
        if sc(target, "set_Rotation", rot) then return true end
        local tf = sc(target, "get_Transform")
        if tf and sc(tf, "set_Rotation", rot) then return true end
        return false
    end
    return sc(target, "set_Rotation", rot) == true
end

local function get_bullet_parent_transform()
    if rv.target_kind == "joint" and rv.target then
        local tf = sc(rv.target, "get_Transform")
        if tf then
            local parent = sc(tf, "get_Parent")
            if parent then return parent end
        end
    end
    return rv.weapon_xform
end

local function world_pose_to_parent_local(parent_tf, world_pos, world_rot)
    if not parent_tf or not world_pos or not world_rot then return nil, nil end
    local parent_rot = sc(parent_tf, "get_Rotation")
    local parent_pos = sc(parent_tf, "get_Position")
    if not parent_rot or not parent_pos then return nil, nil end
    local inv = parent_rot:conjugate()
    local delta = Vector3f.new(
        world_pos.x - parent_pos.x,
        world_pos.y - parent_pos.y,
        world_pos.z - parent_pos.z)
    local local_pos = inv * delta
    local local_rot = inv * world_rot
    return local_pos, local_rot
end

local function get_left_hand_rotation()
    if get_left_hand_joint then
        local hand = get_left_hand_joint()
        if hand then
            local r = sc(hand, "get_Rotation")
            if r then return r end
        end
    end
    local rot = rawget(_G, "__vr_lh_joint_rot")
    if rot and type(rot.w) == "number" then return rot end
    return nil
end

local function get_bullet_joint_name(wp)
    if reload_drop then
        return reload_drop.resolve_drop_joint_name(CFG, wp)
    end
    if type(CFG.bullet_joint_by_wp) == "table" and CFG.bullet_joint_by_wp[wp] then
        return CFG.bullet_joint_by_wp[wp]
    end
    if type(CFG.mag_node_by_wp) == "table" and CFG.mag_node_by_wp[wp] then
        return CFG.mag_node_by_wp[wp]
    end
    return "_04"
end

local function get_bullet_mesh_indices(wp)
    local by_wp = CFG.bullet_mesh_parts_by_wp
    if type(by_wp) ~= "table" then return nil end
    local entry = by_wp[wp]
    if entry == false then return nil end
    if type(entry) == "table" then
        if type(entry[1]) == "number" then return entry end
        if type(entry.idx) == "number" then return { entry.idx } end
    end
    return nil
end

local function get_bullet_chamber_nodes(wp)
    local by_wp = CFG.bullet_chamber_nodes_by_wp
    if type(by_wp) ~= "table" then return nil end
    local entry = by_wp[wp]
    if entry == false then return nil end
    if type(entry) == "table" and #entry > 0 then return entry end
    return nil
end

local get_revolver_loaded_count
local get_revolver_capacity
local apply_chamber_bullet_cylinder_follow
local sync_chamber_bullet_cylinder_pose
local refresh_weapon_refs
local ensure_cylinder_joints_cached
local apply_cylinder_open_visual
local get_mag_exit_local
local get_bullet_insert_local_quat
local set_bullet_mesh_visible

local function get_bullet_barrel_node_name(wp)
    local by_wp = CFG.bullet_barrel_node_by_wp
    if type(by_wp) == "table" and by_wp[wp] then return by_wp[wp] end
    return nil
end

local function uses_joint_scale_bullet_visual(wp)
    wp = wp or get_weapon_go_name()
    -- Per-chamber joint scale hiding (wp0800-style); takes priority over mesh-part indices.
    return get_bullet_chamber_nodes(wp) ~= nil
end

local function clear_chamber_vis_cache()
    rv.chamber_vis = nil
end

local function capture_scale_node_entry(target, kind, name)
    if not target then return nil end
    local scv = read_target_local_scale(target, kind)
    if not scv then return nil end
    return {
        name = name,
        target = target,
        kind = kind,
        sx = scv.x,
        sy = scv.y,
        sz = scv.z,
    }
end

local function cache_chamber_vis_joints(tf, wp)
    if not tf or not wp or not uses_joint_scale_bullet_visual(wp) then
        clear_chamber_vis_cache()
        return false
    end
    local nodes = get_bullet_chamber_nodes(wp)
    if not nodes or #nodes == 0 then
        clear_chamber_vis_cache()
        return false
    end
    local cached = { wp = wp, nodes = {} }
    for _, nm in ipairs(nodes) do
        local t, k = resolve_bullet_target(tf, nm)
        if t then
            local entry = capture_scale_node_entry(t, k, nm)
            if entry then cached.nodes[#cached.nodes + 1] = entry end
        end
    end
    local barrel_name = get_bullet_barrel_node_name(wp)
    if barrel_name then
        local t, k = resolve_bullet_target(tf, barrel_name)
        if t then cached.barrel = capture_scale_node_entry(t, k, barrel_name) end
    end
    rv.chamber_vis = cached
    return #cached.nodes > 0
end

local function apply_scale_node_entry(entry, visible)
    if not entry or not entry.target then return end
    if visible then
        write_target_local_scale(entry.target, entry.kind,
            Vector3f.new(entry.sx, entry.sy, entry.sz))
    else
        write_target_local_scale(entry.target, entry.kind, Vector3f.new(0.0, 0.0, 0.0))
    end
end

local function ensure_chamber_vis_cached(wp)
    wp = wp or get_weapon_go_name()
    if not wp or not uses_joint_scale_bullet_visual(wp) then return false end
    if rv.chamber_vis and rv.chamber_vis.wp == wp and rv.chamber_vis.nodes and #rv.chamber_vis.nodes > 0 then
        return true
    end
    local tf = rv.weapon_xform
    if not tf then
        local weapon = re2.weapon
        local go = weapon and sc(weapon, "get_GameObject")
        tf = go and sc(go, "get_Transform")
        if tf then rv.weapon_xform = tf end
    end
    if not tf then return false end
    return cache_chamber_vis_joints(tf, wp)
end

local function get_cylinder_chamber_skip_index(cv)
    if not (rv.in_hand or rv.anim_active or rv.release_fall_active) then
        return nil
    end
    if rv.bullet_source == "holster" or rv.release_bullet_source == "holster" then
        return nil
    end
    if rv.release_fall_active and rv.release_chamber_slot then
        return rv.release_chamber_slot
    end
    local skip_index = rv.insert_chamber_slot
    if skip_index == nil and rv.node_name and cv and cv.nodes then
        for i, entry in ipairs(cv.nodes) do
            if entry.name == rv.node_name then
                skip_index = i
                break
            end
        end
    end
    return skip_index
end

local function sync_cylinder_bullet_scales(wp)
    wp = wp or get_weapon_go_name()
    if change_bullet_suspend_blocks_manual() then return end
    if rv.insert_preview_active then return end
    if not wp or not uses_joint_scale_bullet_visual(wp) then return end
    if not ensure_chamber_vis_cached(wp) then return end
    local cv = rv.chamber_vis
    if not cv or not cv.nodes then return end

    local loaded = get_revolver_loaded_count()

    local skip_index = get_cylinder_chamber_skip_index(cv)
    local holster_hold = (rv.bullet_source == "holster" or rv.release_bullet_source == "holster")
        and (rv.in_hand or rv.anim_active or rv.release_fall_active)

    for i, entry in ipairs(cv.nodes) do
        local grab_node = holster_hold and rv.node_name and entry.name == rv.node_name
        if grab_node then
            apply_scale_node_entry(entry, true)
        elseif skip_index and i == skip_index then
            apply_scale_node_entry(entry, true)
        else
            apply_scale_node_entry(entry, i <= loaded)
        end
    end

    if cv.barrel then
        local open = rv.cylinder_open == true or (rv.open_t or 0) > 0.001
        local barrel_name = get_bullet_barrel_node_name(wp)
        local on_barrel = barrel_name and rv.node_name == barrel_name
            and (rv.bullet_source == "holster" or rv.release_bullet_source == "holster")
            and (rv.in_hand or rv.anim_active or rv.release_fall_active)
        apply_scale_node_entry(cv.barrel, on_barrel or not open)
    end
end

local function get_next_chamber_slot_index(wp)
    local loaded = get_revolver_loaded_count()
    local nodes = get_bullet_chamber_nodes(wp)
    local max_slots = nodes and #nodes or get_revolver_capacity(wp)
    if loaded >= max_slots then return max_slots end
    local slot = loaded + 1
    if slot < 1 then slot = 1 end
    if slot > max_slots then slot = max_slots end
    return slot
end

local function get_hand_bullet_node_name(wp)
    wp = wp or get_weapon_go_name()
    local nodes = get_bullet_chamber_nodes(wp)
    if nodes then
        local slot = get_next_chamber_slot_index(wp)
        return nodes[slot] or nodes[1]
    end
    return get_bullet_joint_name(wp)
end

local function get_active_bullet_mesh_indices(wp)
    local all = get_bullet_mesh_indices(wp)
    if not all or #all == 0 then return all end
    local slot = get_next_chamber_slot_index(wp)
    local idx = all[slot] or all[1]
    if idx == nil then return all end
    return { idx }
end

local function get_dock_joint_name(wp)
    local by_wp = CFG.bullet_dock_joint_by_wp
    if type(by_wp) == "table" and by_wp[wp] then return by_wp[wp] end
    return "Chamber"
end

local function get_cylinder_joint_name(wp)
    local sd = CFG.slide_dock or {}
    if type(sd.slide_node_by_wp) == "table" then
        local slide_node = sd.slide_node_by_wp[wp]
        if type(slide_node) == "string" and slide_node ~= "" then
            return slide_node
        end
    end
    if type(CFG.cylinder_joint_by_wp) == "table" then
        local cyl = CFG.cylinder_joint_by_wp[wp]
        if type(cyl) == "string" and cyl ~= "" then
            return cyl
        end
    end
    return "_04"
end

function M.invalidate_cylinder_joint_cache()
    rv.swing_joint = nil
    rv.swing_joint_name = nil
    rv.swing_joint_wp = nil
    rv.swing_kind = nil
    rv.rest_captured = false
end

local function quat_to_euler_deg(q)
    if not q then return 0.0, 0.0, 0.0 end
    local sinr_cosp = 2.0 * (q.w * q.x + q.y * q.z)
    local cosr_cosp = 1.0 - 2.0 * (q.x * q.x + q.y * q.y)
    local roll = math.deg(math.atan(sinr_cosp, cosr_cosp))
    local sinp = 2.0 * (q.w * q.y - q.z * q.x)
    local pitch
    if math.abs(sinp) >= 1.0 then
        pitch = math.deg((math.pi * 0.5) * (sinp > 0.0 and 1.0 or -1.0))
    else
        pitch = math.deg(math.asin(sinp))
    end
    local siny_cosp = 2.0 * (q.w * q.z + q.x * q.y)
    local cosy_cosp = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    local yaw = math.deg(math.atan(siny_cosp, cosy_cosp))
    return pitch, yaw, roll
end

local function lerp_f(a, b, t)
    return a + (b - a) * t
end

local function get_cylinder_open_bind(wp)
    local sd = CFG.slide_dock or {}
    local def = sd.slide_bind_default or {}
    local by_wp = sd.slide_bind_by_wp
    local entry = type(by_wp) == "table" and by_wp[wp] or nil
    local e = type(entry) == "table" and entry or {}
    return {
        x = tonumber(e.open_x) or tonumber(e.x) or tonumber(def.x) or 0.0,
        y = tonumber(e.open_y) or tonumber(e.y) or tonumber(def.y) or 0.0,
        z = tonumber(e.open_z) or tonumber(e.parked_z) or tonumber(def.parked_z) or 0.04,
        pitch = tonumber(e.open_rot_pitch) or tonumber(def.open_rot_pitch) or 0.0,
        yaw = tonumber(e.open_rot_yaw) or tonumber(def.open_rot_yaw) or 0.0,
        roll = tonumber(e.open_rot_roll) or tonumber(def.open_rot_roll) or 0.0,
    }
end

local function get_chamber_bullet_open_bind(wp)
    local sd = CFG.slide_dock or {}
    local by_wp = sd.slide_bind_by_wp
    local entry = type(by_wp) == "table" and by_wp[wp] or nil
    local e = type(entry) == "table" and entry or {}
    return {
        x = e.bullet_open_x,
        y = e.bullet_open_y,
        z = e.bullet_open_z,
        pitch = e.bullet_open_rot_pitch,
        yaw = e.bullet_open_rot_yaw,
        roll = e.bullet_open_rot_roll,
    }
end

local function resolve_chamber_bullet_open_pose(bind, rest_q)
    local tx = tonumber(bind.x) or rv.rest_x
    local ty = tonumber(bind.y) or rv.rest_y
    local tz = tonumber(bind.z) or rv.rest_z
    local q_rest = rest_q or Quaternion.new(rv.rest_w, rv.rest_rx, rv.rest_ry, rv.rest_rz)
    local rp, ry, rr = quat_to_euler_deg(q_rest)
    local q_open = quat_from_euler_deg(
        tonumber(bind.pitch) or rp,
        tonumber(bind.yaw) or ry,
        tonumber(bind.roll) or rr)
    return tx, ty, tz, q_rest, q_open
end

local function weapon_entry(wp)
    if type(CFG.weapons) ~= "table" then return nil end
    return CFG.weapons[wp]
end

local function uses_chamber_bullet_cylinder_follow(wp)
    wp = wp or get_weapon_go_name()
    if not wp or not M.is_revolver_weapon(wp) then return false end
    if uses_joint_scale_bullet_visual(wp) then return false end
    if get_bullet_chamber_nodes(wp) then return false end
    local entry = weapon_entry(wp)
    if entry and entry.bullet_follows_cylinder_open == false then return false end
    if entry and entry.bullet_follows_cylinder_open == true then return true end
    if entry and type(entry.reload_drop_slots) == "number" and entry.reload_drop_slots <= 1 then
        return true
    end
    return false
end

local function uses_canister_mag_reload(wp)
    return weapon_uses_canister_mag_reload and weapon_uses_canister_mag_reload(wp) == true
end

local function canister_restore_supply_available(wp)
    wp = wp or get_weapon_go_name()
    local stash = (rv.canister_stash_by_wp or {})[wp] or 0
    local carried = get_mag_carried_rounds and get_mag_carried_rounds() or 0
    local reserve = get_main_weapon_reserve_ammo_count and get_main_weapon_reserve_ammo_count() or 0
    return math.max(stash, carried) > 0 or reserve > 0
end

local function sync_canister_extracted_state(wp)
    wp = wp or get_weapon_go_name()
    if not uses_canister_mag_reload(wp) then return end
    if rv.in_hand or rv.anim_active or rv.release_fall_active or rv.pending_insert then return end
    rv.canister_stash_by_wp = rv.canister_stash_by_wp or {}
    local stash = rv.canister_stash_by_wp[wp] or 0
    local live = get_mag_carried_rounds and get_mag_carried_rounds() or 0
    if stash > 0 and live <= 0 and on_chamber_ammo_to_carried then
        on_chamber_ammo_to_carried(stash)
        live = get_mag_carried_rounds and get_mag_carried_rounds() or stash
    elseif live > 0 then
        rv.canister_stash_by_wp[wp] = live
        stash = live
    end
    local carried = math.max(stash, live)
    local loaded = get_revolver_loaded_count()
    local was = rv.chamber_extracted == true
    if loaded > 0 then
        rv.chamber_extracted = false
        rv.chamber_round_seated = true
        rv.canister_stash_by_wp[wp] = nil
    elseif carried > 0 then
        rv.chamber_extracted = true
        rv.chamber_round_seated = false
    elseif loaded <= 0 then
        local reserve = get_main_weapon_reserve_ammo_count and get_main_weapon_reserve_ammo_count() or 0
        if reserve > 0 then
            rv.chamber_extracted = true
            rv.chamber_round_seated = false
        end
    end
end

local function should_skip_canister_reconcile()
    return rawget(_G, "__vr_reload_stack_reset_in_progress") == true
end

-- After save/session reset the game may report chamber loaded while mod state still has chamber_extracted.
local function reconcile_canister_with_loaded_game()
    if should_skip_canister_reconcile() then return end
    if not manual_reload_context_active() then return end
    local wp = get_weapon_go_name()
    if not wp or not uses_canister_mag_reload(wp) then return end
    if not rv.chamber_extracted then return end
    if rv.in_hand or rv.anim_active or rv.release_fall_active or rv.pending_insert then return end
    if rv.insert_preview_active then return end
    if rv.cylinder_open then return end

    local loaded = get_revolver_loaded_count()
    local slot_n = get_weapon_mag_slot_round_count and get_weapon_mag_slot_round_count() or 0
    if loaded <= 0 and slot_n <= 0 then return end

    rv.canister_stash_by_wp = rv.canister_stash_by_wp or {}
    rv.canister_stash_by_wp[wp] = nil
    rv.extract_stash_rounds = nil
    rv.chamber_extracted = false
    rv.chamber_round_seated = true
    if sync_chamber_shoot_ready then sync_chamber_shoot_ready() end
    if not rv.target or not rv.has_rest then refresh_weapon_refs() end
    sync_canister_bullet_visual(wp)
end

local function uses_chamber_extract_reload(wp)
    if uses_canister_mag_reload(wp) then return true end
    return uses_chamber_bullet_cylinder_follow(wp)
end

local function weapon_keeps_spent_chamber_bullet(wp)
    wp = wp or get_weapon_go_name()
    if not wp or not M.is_revolver_weapon(wp) then return false end
    local entry = weapon_entry(wp)
    if entry then
        if entry.keep_spent_chamber_bullet == true then return true end
        if entry.keep_spent_chamber_bullet == false then return false end
    end
    local def = rv_cfg().keep_spent_chamber_bullet_default
    if def == true then return true end
    if def == false then return false end
    return uses_chamber_extract_reload(wp)
end

local function chamber_bullet_pose_busy()
    return rv.in_hand or rv.anim_active or rv.release_fall_active or rv.pending_insert ~= nil
        or rv.insert_preview_active == true
end

local function chamber_extract_suppressed()
    return os.clock() < (rv.shoot_ready_grace_until or 0)
        or rv.anim_active == true
        or rv.pending_insert ~= nil
        or rv.insert_preview_active == true
end

local function chamber_has_extractable_round(wp)
    wp = wp or get_weapon_go_name()
    if uses_canister_mag_reload(wp) then
        if not rv.cylinder_open then return false end
        if rv.chamber_extracted then return false end
        if chamber_extract_suppressed() then return false end
        if chamber_bullet_pose_busy() then return false end
        if rv.in_hand or rv.bullet_source == "holster" then return false end
        if get_revolver_loaded_count() > 0 then return true end
        if rv.enabled_parts and rv.target ~= nil then return true end
        return false
    end
    if get_revolver_loaded_count() > 0 then
        if weapon_keeps_spent_chamber_bullet(wp) then
            if not rv.spent_round_in_chamber then return false end
        else
            return false
        end
    end
    if not weapon_keeps_spent_chamber_bullet(wp) then
        return rv.spent_round_in_chamber == true
    end
    if rv.spent_round_in_chamber then return true end
    if os.clock() < (rv.shoot_ready_grace_until or 0) then return false end
    if rv.chamber_extracted then return false end
    if chamber_bullet_pose_busy() then return false end
    if rv.in_hand or rv.bullet_source == "holster" then return false end
    -- Spent casing may still be visible before tracking latch after firing.
    if rv.cylinder_open and rv.enabled_parts and rv.target ~= nil then
        return true
    end
    return false
end

local function chamber_needs_extract(wp)
    if not uses_chamber_extract_reload(wp) then return false end
    if rv.chamber_extracted then return false end
    if chamber_extract_suppressed() then return false end
    return chamber_has_extractable_round(wp)
end

local function insert_preview_sec()
    return tonumber(rv_cfg().insert_preview_sec) or 6.0
end

local function cancel_bullet_insert_preview(restore_pose)
    if not rv.insert_preview_active then return end
    if restore_pose ~= false and rv.target and rv.has_rest then
        write_target_local_position(rv.target, rv.target_kind, Vector3f.new(
            rv.insert_preview_rest_x or rv.rest_x,
            rv.insert_preview_rest_y or rv.rest_y,
            rv.insert_preview_rest_z or rv.rest_z))
    end
    rv.insert_preview_active = false
    rv.insert_preview_until = 0.0
    rv.insert_preview_wp = nil
    if M.is_revolver_weapon_active() then
        apply_cylinder_open_visual(rv.open_t or 0.0)
        if not chamber_bullet_pose_busy() then
            sync_chamber_bullet_cylinder_pose()
        end
    end
end

local function apply_bullet_insert_preview_pose(wp)
    wp = wp or get_weapon_go_name()
    if not M.is_revolver_weapon(wp) then return false end
    if get_weapon_go_name() ~= wp then return false end
    if not rv.target or not rv.has_rest then
        if not refresh_weapon_refs() then return false end
    end
    if not rv.target then return false end
    ensure_cylinder_joints_cached()
    apply_cylinder_open_visual(1.0)
    if uses_chamber_bullet_cylinder_follow(wp) then
        apply_chamber_bullet_cylinder_follow(1.0)
    end
    local exit = get_mag_exit_local(wp)
    set_bullet_mesh_visible(true, wp)
    rv.enabled_parts = true
    write_target_local_position(rv.target, rv.target_kind, exit)
    write_target_local_rotation(rv.target, rv.target_kind, get_bullet_insert_local_quat(wp))
    return true
end

local function tick_bullet_insert_preview()
    if not rv.insert_preview_active then return false end
    if get_weapon_go_name() ~= rv.insert_preview_wp then
        cancel_bullet_insert_preview(true)
        return false
    end
    if os.clock() >= (rv.insert_preview_until or 0) then
        cancel_bullet_insert_preview(true)
        return false
    end
    apply_bullet_insert_preview_pose(rv.insert_preview_wp)
    return true
end

function M.extend_bullet_insert_preview(wp, sec)
    wp = wp or get_weapon_go_name()
    if not M.is_revolver_weapon(wp) then return false, "Not a cylinder weapon" end
    if get_weapon_go_name() ~= wp then
        return false, "Equip " .. tostring(wp) .. " for live preview"
    end
    if rv.in_hand or rv.anim_active or rv.pending_insert then
        return false, "Wait for reload animation to finish"
    end
    if not rv.insert_preview_active then
        if not refresh_weapon_refs() or not rv.target or not rv.has_rest then
            return false, "Bullet joint not resolved on " .. tostring(wp)
        end
        rv.insert_preview_rest_x = rv.rest_x
        rv.insert_preview_rest_y = rv.rest_y
        rv.insert_preview_rest_z = rv.rest_z
        rv.insert_preview_active = true
        rv.insert_preview_wp = wp
    elseif rv.insert_preview_wp ~= wp then
        cancel_bullet_insert_preview(true)
        return M.extend_bullet_insert_preview(wp, sec)
    end
    rv.insert_preview_until = os.clock() + (tonumber(sec) or insert_preview_sec())
    apply_bullet_insert_preview_pose(wp)
    return true, nil
end

function M.cancel_bullet_insert_preview(restore_pose)
    cancel_bullet_insert_preview(restore_pose)
end

function M.insert_preview_is_active()
    return rv.insert_preview_active == true
end

function M.get_insert_preview_remaining()
    if not rv.insert_preview_active then return 0.0 end
    return math.max(0.0, (rv.insert_preview_until or 0) - os.clock())
end

local function tick_spent_chamber_bullet_track(wp)
    if uses_canister_mag_reload(wp) then
        rv.last_loaded_track_wp = wp
        rv.last_loaded_count = get_revolver_loaded_count()
        return
    end
    if not weapon_keeps_spent_chamber_bullet(wp) then
        rv.last_loaded_track_wp = nil
        rv.last_loaded_count = nil
        return
    end
    local loaded = get_revolver_loaded_count()
    if rv.last_loaded_track_wp ~= wp then
        rv.last_loaded_track_wp = wp
        rv.last_loaded_count = loaded
        rv.spent_round_in_chamber = false
        return
    end
    local prev = rv.last_loaded_count
    if type(prev) == "number" and prev > 0 and loaded <= 0 and not chamber_bullet_pose_busy() then
        rv.spent_round_in_chamber = true
        rv.chamber_extracted = false
    elseif loaded > 0 and not rv.in_hand and not rv.anim_active and not rv.pending_insert then
        rv.spent_round_in_chamber = false
    end
    rv.last_loaded_count = loaded
end

local function load_cylinder_open_bind(wp)
    local bind = get_cylinder_open_bind(wp)
    rv.open_x = bind.x
    rv.open_y = bind.y
    rv.open_z = bind.z
    rv.open_pitch = bind.pitch
    rv.open_yaw = bind.yaw
    rv.open_roll = bind.roll
end

local function capture_cylinder_rest_from_joint(wp)
    if not rv.swing_joint then return false end
    if (rv.open_t or 0) > 0.001 or rv.cylinder_open then return false end
    local pos = read_target_local_position(rv.swing_joint, rv.swing_kind)
    local rot = read_target_local_rotation(rv.swing_joint, rv.swing_kind)
    if not pos then return false end
    rv.swing_rest_x = pos.x
    rv.swing_rest_y = pos.y
    rv.swing_rest_z = pos.z
    if rot then
        rv.swing_rest_w = rot.w
        rv.swing_rest_rx = rot.x
        rv.swing_rest_ry = rot.y
        rv.swing_rest_rz = rot.z
        rv.swing_rest_pitch, rv.swing_rest_yaw, rv.swing_rest_roll = quat_to_euler_deg(rot)
    end
    rv.rest_wp = wp
    rv.rest_captured = true
    return true
end

function M.capture_cylinder_rest()
    local wp = get_weapon_go_name()
    if not wp or not M.is_revolver_weapon(wp) then return false end
    if not rv.swing_joint then
        local weapon = re2.weapon
        local go = weapon and sc(weapon, "get_GameObject")
        local tf = go and sc(go, "get_Transform")
        if tf then cache_cylinder_joints(tf, wp) end
    end
    return capture_cylinder_rest_from_joint(wp)
end

local function cache_cylinder_joints(tf, wp)
    rv.swing_joint = nil
    rv.swing_joint_name = nil
    rv.swing_joint_wp = nil
    rv.swing_kind = nil
    if not tf then return end
    wp = wp or get_weapon_go_name()
    local swing_name = get_cylinder_joint_name(wp)
    local swing, swing_kind = resolve_bullet_target(tf, swing_name)
    if swing then
        rv.swing_joint = swing
        rv.swing_joint_name = swing_name
        rv.swing_joint_wp = wp
        rv.swing_kind = swing_kind
        if rv.rest_wp ~= wp or rv.swing_joint_name ~= swing_name then
            rv.rest_captured = false
        end
        if not rv.rest_captured then
            capture_cylinder_rest_from_joint(wp)
        end
        load_cylinder_open_bind(wp)
    end
end

get_revolver_capacity = function(wp)
    wp = wp or get_weapon_go_name()
    local inv = re2.inventory
    local slot = inv and sc(inv, "get_MainSlot")
    local max_n = slot and sc(slot, "get_MaxNumber")
    if type(max_n) == "number" and max_n > 0 then return math.floor(max_n) end
    return REVOLVER_CAPACITY[wp] or 6
end

get_revolver_loaded_count = function()
    local slot_n = nil
    if get_weapon_mag_slot_round_count then
        local n = get_weapon_mag_slot_round_count()
        if type(n) == "number" then slot_n = math.max(0, math.floor(n)) end
    end
    local hud_n = nil
    if get_shell_hud_ammo then
        local loaded = get_shell_hud_ammo()
        if type(loaded) == "number" then hud_n = math.max(0, math.floor(loaded)) end
    end
    if slot_n ~= nil and hud_n ~= nil then
        return math.min(slot_n, hud_n)
    end
    if slot_n ~= nil then return slot_n end
    if hud_n ~= nil then return hud_n end
    if get_weapon_chamber_bullet_count then
        return math.max(0, math.floor(get_weapon_chamber_bullet_count() or 0))
    end
    return 0
end

local function revolver_cylinder_open_for_reload()
    return rv.cylinder_open == true or (rv.open_t or 0) > 0.01
end

local function get_revolver_vacancy(wp)
    return math.max(0, get_revolver_capacity(wp) - get_revolver_loaded_count())
end

get_mag_exit_local = function(wp)
    wp = wp or get_weapon_go_name()
    local def = CFG.mag_exit_default or {}
    local ex = tonumber(def.x) or 0.0
    local ey = tonumber(def.y)
    local ez = tonumber(def.z) or -0.035
    if ey == nil then ey = -0.103 end
    local by_wp = wp and CFG.mag_exit_by_wp and CFG.mag_exit_by_wp[wp]
    if type(by_wp) == "table" then
        if by_wp.x ~= nil then ex = tonumber(by_wp.x) or ex end
        if by_wp.y ~= nil then ey = tonumber(by_wp.y) or ey end
        if by_wp.z ~= nil then ez = tonumber(by_wp.z) or ez end
    end
    return Vector3f.new(ex, ey, ez)
end

local function get_mag_exit_rotation(wp)
    wp = wp or get_weapon_go_name()
    local def = CFG.mag_exit_default or {}
    local pitch = tonumber(def.pitch) or 0.0
    local yaw = tonumber(def.yaw) or 0.0
    local roll = tonumber(def.roll) or 0.0
    local by_wp = wp and CFG.mag_exit_by_wp and CFG.mag_exit_by_wp[wp]
    if type(by_wp) == "table" then
        if by_wp.pitch ~= nil then pitch = tonumber(by_wp.pitch) or pitch end
        if by_wp.yaw ~= nil then yaw = tonumber(by_wp.yaw) or yaw end
        if by_wp.roll ~= nil then roll = tonumber(by_wp.roll) or roll end
    end
    return pitch, yaw, roll
end

get_bullet_insert_local_quat = function(wp)
    wp = wp or get_weapon_go_name()
    local pitch, yaw, roll = get_mag_exit_rotation(wp)
    if pitch == 0.0 and yaw == 0.0 and roll == 0.0 then
        return Quaternion.new(rv.rest_w, rv.rest_rx, rv.rest_ry, rv.rest_rz)
    end
    local q_insert = quat_from_euler_deg(pitch, yaw, roll)
    if q_insert then return q_insert end
    return Quaternion.new(rv.rest_w, rv.rest_rx, rv.rest_ry, rv.rest_rz)
end

local function get_bullet_insert_dock_dist(wp)
    if get_mag_dock_dist then return get_mag_dock_dist(wp) end
    if type(CFG.mag_dock_by_wp) == "table" and type(CFG.mag_dock_by_wp[wp]) == "number" then
        return CFG.mag_dock_by_wp[wp]
    end
    return tonumber(rv_cfg().dock_dist_default) or 0.20
end

local function get_weapon_chamber_grab_dist(wp)
    wp = wp or get_weapon_go_name()
    local entry = weapon_entry(wp)
    if entry and type(entry.chamber_grab_dist) == "number" then
        return entry.chamber_grab_dist
    end
    local cfg = rv_cfg()
    if type(cfg.chamber_grab_dist_by_wp) == "table" and type(cfg.chamber_grab_dist_by_wp[wp]) == "number" then
        return cfg.chamber_grab_dist_by_wp[wp]
    end
    local grab_def = tonumber(cfg.chamber_grab_dist_default)
    if grab_def then return grab_def end
    return 0.28
end

local function world_pos_to_parent_local(parent_tf, world_pos)
    if not parent_tf or not world_pos then return nil end
    local parent_rot = sc(parent_tf, "get_Rotation")
    local parent_pos = sc(parent_tf, "get_Position")
    if not parent_rot or not parent_pos then return nil end
    local inv = parent_rot:conjugate()
    local delta = Vector3f.new(
        world_pos.x - parent_pos.x,
        world_pos.y - parent_pos.y,
        world_pos.z - parent_pos.z)
    return inv * delta
end

local function parent_local_pos_to_world(parent_tf, local_pos)
    if not parent_tf or not local_pos then return nil end
    local parent_rot = sc(parent_tf, "get_Rotation")
    local parent_pos = sc(parent_tf, "get_Position")
    if not parent_rot or not parent_pos then return nil end
    local world_off = parent_rot * local_pos
    return Vector3f.new(
        parent_pos.x + world_off.x,
        parent_pos.y + world_off.y,
        parent_pos.z + world_off.z)
end

local function get_track_pos_for_chamber_grab()
    if get_left_track_pos_with_source then
        local pos = get_left_track_pos_with_source()
        if pos then return pos end
    end
    if get_left_track_position then
        local pos = get_left_track_position()
        if pos then return pos end
    end
    local lh = rawget(_G, "__vr_lh_joint_pos")
    if lh and type(lh.x) == "number" then return lh end
    local lw = rawget(_G, "__vr_lh_world")
    if lw and type(lw.x) == "number" then return lw end
    if get_left_hand_position then
        local pos = get_left_hand_position()
        if pos then return pos end
    end
    if get_left_hand_joint then
        local hand = get_left_hand_joint()
        if hand then return sc(hand, "get_Position") end
    end
    return nil
end

local function distance_to_world_point_for_grab(world_pos)
    if not world_pos then return nil end
    local best = 99.0
    local function try(pos)
        if pos and type(pos.x) == "number" then
            local d = vec3_dist(pos, world_pos)
            if d < best then best = d end
        end
    end
    try(get_track_pos_for_chamber_grab())
    try(rawget(_G, "__vr_lh_world"))
    try(rawget(_G, "__vr_lh_joint_pos"))
    if get_left_hand_position then try(get_left_hand_position()) end
    if get_left_hand_joint then
        local hand = get_left_hand_joint()
        if hand then try(sc(hand, "get_Position")) end
    end
    if best >= 99.0 then return nil end
    return best
end

local function get_chamber_grab_dock_worlds(wp)
    wp = wp or get_weapon_go_name()
    if not rv.has_rest then return nil end
    if not rv.weapon_xform and not refresh_weapon_refs() then return nil end
    local parent_tf = get_bullet_parent_transform() or rv.weapon_xform
    if not parent_tf then return nil end
    local docks = {}
    local rest_world = parent_local_pos_to_world(parent_tf,
        Vector3f.new(rv.rest_x, rv.rest_y, rv.rest_z))
    if rest_world then docks[#docks + 1] = rest_world end
    if rv.weapon_xform then
        local exit = get_mag_exit_local(wp)
        if exit then
            local exit_world = parent_local_pos_to_world(rv.weapon_xform, exit)
            if exit_world then docks[#docks + 1] = exit_world end
        end
    end
    if #docks == 0 then return nil end
    return docks
end

local function measure_chamber_grab_dock_distance(wp)
    local docks = get_chamber_grab_dock_worlds(wp)
    if not docks then return nil end
    local best = nil
    for _, dock in ipairs(docks) do
        local d = distance_to_world_point_for_grab(dock)
        if d ~= nil and (best == nil or d < best) then best = d end
    end
    return best
end

local function bullet_ease(t)
    if t <= 0.0 then return 0.0 end
    if t >= 1.0 then return 1.0 end
    return t * t * (3.0 - 2.0 * t)
end

local function bullet_anim_duration(phase)
    local anim = CFG.anim or {}
    if phase == "insert" then return math.max(0.01, tonumber(anim.insert_sec) or 0.18) end
    if phase == "fall" then return math.max(0.01, tonumber(anim.fall_sec) or 0.5) end
    return math.max(0.01, tonumber(anim.drop_sec) or 0.18)
end

local function bullet_fall_distance()
    return tonumber((CFG.anim or {}).fall_distance) or 1.2
end

local function get_bullet_hand_hold_entry(wp)
    if get_mag_hand_hold_entry then
        local hold = get_mag_hand_hold_entry()
        if type(hold) == "table" then return hold end
    end
    return CFG.mag_hand_hold or {}
end

local function set_bullet_joint_visible(visible)
    if not rv.target or not rv.has_rest then return end
    if visible then
        write_target_local_scale(rv.target, rv.target_kind,
            Vector3f.new(rv.rest_sx, rv.rest_sy, rv.rest_sz))
    else
        write_target_local_scale(rv.target, rv.target_kind, Vector3f.new(0, 0, 0))
    end
end

set_bullet_mesh_visible = function(visible, wp)
    wp = wp or get_weapon_go_name()
    if uses_joint_scale_bullet_visual(wp) then return end
    if visual_hide_uses_scale() then
        set_bullet_joint_visible(visible)
        return
    end
    local indices = visible and get_active_bullet_mesh_indices(wp) or get_bullet_mesh_indices(wp)
    if not indices or #indices == 0 then return end
    local gun = re2.weapon
    for _, idx in ipairs(indices) do
        if gun then
            pcall(function() gun:call("setPartsEnable", visible == true, { idx }) end)
        end
        if rv.mesh_ref then
            pcall(function()
                rv.mesh_ref:call("setPartsEnable(System.UInt64, System.Boolean)", idx, visible == true)
            end)
        end
    end
end

local function ensure_bullet_fall_visible(wp)
    wp = wp or get_weapon_go_name()
    if uses_joint_scale_bullet_visual(wp) then
        if not ensure_chamber_vis_cached(wp) then return end
        local cv = rv.chamber_vis
        local barrel_name = get_bullet_barrel_node_name(wp)
        if barrel_name and rv.node_name == barrel_name and cv and cv.barrel then
            apply_scale_node_entry(cv.barrel, true)
        end
        local slot = rv.release_chamber_slot or rv.insert_chamber_slot
        if slot and cv and cv.nodes and cv.nodes[slot] then
            apply_scale_node_entry(cv.nodes[slot], true)
        elseif rv.target and rv.has_rest then
            write_target_local_scale(rv.target, rv.target_kind,
                Vector3f.new(rv.rest_sx, rv.rest_sy, rv.rest_sz))
        end
        return
    end
    set_bullet_mesh_visible(true, wp)
    rv.enabled_parts = true
end

local function reset_bullet_visual_joints()
    if rv.target and rv.has_rest then
        write_target_local_position(rv.target, rv.target_kind,
            Vector3f.new(rv.rest_x, rv.rest_y, rv.rest_z))
        write_target_local_rotation(rv.target, rv.target_kind,
            Quaternion.new(rv.rest_w, rv.rest_rx, rv.rest_ry, rv.rest_rz))
    end
end

local function snap_swing_joint_to_rest()
    if not rv.swing_joint then return end
    write_target_local_position(rv.swing_joint, rv.swing_kind or "joint",
        Vector3f.new(rv.swing_rest_x or 0.0, rv.swing_rest_y or 0.0, rv.swing_rest_z or 0.0))
    write_target_local_rotation(rv.swing_joint, rv.swing_kind or "joint",
        Quaternion.new(rv.swing_rest_w or 1.0, rv.swing_rest_rx or 0.0,
            rv.swing_rest_ry or 0.0, rv.swing_rest_rz or 0.0))
end

local function get_revolver_weapon_go_token()
    local go = re2.weapon_gameobject
    if go == nil then return nil end
    local ok, addr = pcall(function() return go:get_address() end)
    if ok and addr ~= nil then return tostring(addr) end
    return tostring(go)
end

local function grab_joint_local_offset_from_rest()
    if not rv.target or not rv.has_rest then return nil end
    local cur = read_target_local_position(rv.target, rv.target_kind)
    if not cur then return nil end
    return vec3_dist(cur, Vector3f.new(rv.rest_x, rv.rest_y, rv.rest_z))
end

local function grab_joint_world_rest_mismatch()
    if not rv.target or not rv.has_rest then return nil end
    local parent_tf = get_bullet_parent_transform()
    if not parent_tf then parent_tf = rv.weapon_xform end
    if not parent_tf then return nil end
    local expected = parent_local_pos_to_world(parent_tf,
        Vector3f.new(rv.rest_x, rv.rest_y, rv.rest_z))
    local actual = read_target_world_position(rv.target, rv.target_kind)
    if not expected or not actual then return nil end
    return vec3_dist(expected, actual)
end

local function clear_bullet_freeze()
    if reload_drop then reload_drop.clear_freeze(rv) end
end

local function park_chamber_grab_joint(wp)
    wp = wp or get_weapon_go_name()
    if not uses_chamber_extract_reload(wp) then return end
    if chamber_bullet_pose_busy() then return end
    if not rv.target or not rv.has_rest then return end
    if uses_canister_mag_reload(wp) and rv.chamber_extracted then return end
    if uses_chamber_bullet_cylinder_follow(wp) then
        return
    end
    clear_bullet_freeze()
    write_target_local_position(rv.target, rv.target_kind,
        Vector3f.new(rv.rest_x, rv.rest_y, rv.rest_z))
    write_target_local_rotation(rv.target, rv.target_kind,
        Quaternion.new(rv.rest_w, rv.rest_rx, rv.rest_ry, rv.rest_rz))
end

local function apply_bullet_frozen_pose()
    if not reload_drop then return end
    reload_drop.apply_frozen_pose(rv, rv.target, rv.target_kind,
        write_target_world_position_only, write_target_world_rotation)
end

local function snap_grab_joint_to_weapon_rest()
    clear_bullet_freeze()
    reset_bullet_visual_joints()
    if not rv.cylinder_open and (rv.open_t or 0) <= 0.001 then
        snap_swing_joint_to_rest()
    end
    clear_bullet_freeze()
end

local function grab_joint_world_offset_from_gun()
    if not rv.target or not rv.weapon_xform then return nil end
    local joint_pos = read_target_world_position(rv.target, rv.target_kind)
    local gun_pos = sc(rv.weapon_xform, "get_Position")
    if not joint_pos or not gun_pos then return nil end
    return vec3_dist(joint_pos, gun_pos)
end

local function restore_outgoing_grab_joints()
    clear_bullet_freeze()
    if rv.target and rv.has_rest then
        write_target_local_position(rv.target, rv.target_kind,
            Vector3f.new(rv.rest_x, rv.rest_y, rv.rest_z))
        write_target_local_rotation(rv.target, rv.target_kind,
            Quaternion.new(rv.rest_w, rv.rest_rx, rv.rest_ry, rv.rest_rz))
    end
    snap_swing_joint_to_rest()
    clear_bullet_freeze()
end

local function disable_bullet_visual()
    reset_bullet_visual_joints()
    clear_bullet_freeze()
    local wp = get_weapon_go_name()
    if uses_joint_scale_bullet_visual(wp) then
        rv.enabled_parts = false
        rv.release_chamber_slot = nil
        sync_cylinder_bullet_scales(wp)
        return
    end
    if visual_hide_uses_scale() then
        set_bullet_joint_visible(false)
    elseif rv.enabled_parts then
        set_bullet_mesh_visible(false)
    end
    rv.enabled_parts = false
end

apply_chamber_bullet_cylinder_follow = function(open_t)
    local wp = get_weapon_go_name()
    if not uses_chamber_bullet_cylinder_follow(wp) then return end
    if chamber_bullet_pose_busy() then return end
    if not rv.target or not rv.has_rest then return end

    open_t = math.max(0.0, math.min(1.0, tonumber(open_t) or 0.0))
    local bind = get_chamber_bullet_open_bind(wp)

    local loaded = get_revolver_loaded_count()
    if loaded <= 0 and get_weapon_chamber_bullet_count then
        local raw = get_weapon_chamber_bullet_count()
        if type(raw) == "number" and raw > 0 then
            loaded = math.floor(raw)
            rv.chamber_round_seated = true
        end
    elseif loaded > 0 then
        rv.chamber_round_seated = true
    end
    local show_spent = weapon_keeps_spent_chamber_bullet(wp) and rv.spent_round_in_chamber
    local show_seated = rv.chamber_round_seated == true and not rv.chamber_extracted
    if loaded <= 0 and not show_spent and not show_seated then
        set_bullet_joint_visible(false)
        rv.enabled_parts = false
        return
    end

    set_bullet_joint_visible(true)
    rv.enabled_parts = true

    if open_t <= 0.001 then
        write_target_local_position(rv.target, rv.target_kind,
            Vector3f.new(rv.rest_x, rv.rest_y, rv.rest_z))
        write_target_local_rotation(rv.target, rv.target_kind,
            Quaternion.new(rv.rest_w, rv.rest_rx, rv.rest_ry, rv.rest_rz))
        return
    end

    local tx, ty, tz, q_rest, q_open = resolve_chamber_bullet_open_pose(bind)
    local px = lerp_f(rv.rest_x, tx, open_t)
    local py = lerp_f(rv.rest_y, ty, open_t)
    local pz = lerp_f(rv.rest_z, tz, open_t)
    write_target_local_position(rv.target, rv.target_kind, Vector3f.new(px, py, pz))
    local q = q_open and quat_slerp(q_rest, q_open, open_t) or q_rest
    write_target_local_rotation(rv.target, rv.target_kind, q)
end

sync_canister_bullet_visual = function(wp)
    wp = wp or get_weapon_go_name()
    if not uses_canister_mag_reload(wp) then return end
    if chamber_bullet_pose_busy() then return end
    if not rv.target or not rv.has_rest then return end
    if rv.chamber_extracted then
        set_bullet_joint_visible(false)
        rv.enabled_parts = false
        return
    end
    local loaded = get_revolver_loaded_count()
    if loaded > 0 then
        set_bullet_joint_visible(true)
        rv.enabled_parts = true
        write_target_local_position(rv.target, rv.target_kind,
            Vector3f.new(rv.rest_x, rv.rest_y, rv.rest_z))
        write_target_local_rotation(rv.target, rv.target_kind,
            Quaternion.new(rv.rest_w, rv.rest_rx, rv.rest_ry, rv.rest_rz))
    else
        set_bullet_joint_visible(false)
        rv.enabled_parts = false
    end
end

sync_chamber_bullet_cylinder_pose = function()
    if not M.is_revolver_weapon_active() then return end
    local wp = get_weapon_go_name()
    if uses_canister_mag_reload(wp) then
        sync_canister_bullet_visual(wp)
        return
    end
    if not uses_chamber_bullet_cylinder_follow(wp) then return end
    if chamber_bullet_pose_busy() then return end
    if not rv.target or not rv.has_rest then return end
    apply_chamber_bullet_cylinder_follow(rv.open_t or 0.0)
end

local function repair_grab_joint_if_world_detached(wp)
    wp = wp or get_weapon_go_name()
    if not wp or not M.is_revolver_weapon(wp) then return false end
    if rv.in_hand or rv.anim_active or rv.release_fall_active or rv.pending_insert then return false end
    if not rv.target or not rv.has_rest then
        if not refresh_weapon_refs() then return false end
    end
    if not rv.weapon_xform then return false end
    local world_off = grab_joint_world_offset_from_gun()
    local local_off = grab_joint_local_offset_from_rest()
    local world_mismatch = grab_joint_world_rest_mismatch()
    if (world_off == nil or world_off < 0.35)
        and (local_off == nil or local_off < 0.08)
        and (world_mismatch == nil or world_mismatch < 0.08) then
        return false
    end
    snap_grab_joint_to_weapon_rest()
    sync_chamber_bullet_cylinder_pose()
    return true
end

local function init_active_revolver_weapon_refs()
    if not M.is_revolver_weapon_active() then return end
    local wp = get_weapon_go_name()
    if not wp then return end
    if not refresh_weapon_refs() then return end
    rv.weapon_wp = wp
    sync_canister_extracted_state(wp)
    clear_bullet_freeze()
    snap_grab_joint_to_weapon_rest()
    sync_chamber_bullet_cylinder_pose()
    repair_grab_joint_if_world_detached(wp)
end

local function resolve_dock_anchor(weapon_xform, wp)
    if not weapon_xform then return nil, nil end
    wp = wp or get_weapon_go_name()
    local dock_name = get_dock_joint_name(wp)
    for _, jn in ipairs({ dock_name, "Chamber", "Bullet", "Cylinder" }) do
        if jn then
            local t, k = resolve_bullet_target(weapon_xform, jn)
            if t then return t, k end
        end
    end
    return nil, nil
end

refresh_weapon_refs = function()
    local weapon = re2.weapon
    if not weapon then
        rv.mesh_ref = nil
        rv.gun_tf = nil
        rv.weapon_xform = nil
        rv.dock_joint = nil
        rv.target = nil
        rv.has_rest = false
        return false
    end

    local go = re2.weapon_gameobject or sc(weapon, "get_GameObject")
    if not go then return false end

    local mesh = sc(weapon, "get_Mesh")
    if not mesh then
        pcall(function()
            local td = sdk.find_type_definition("via.render.Mesh")
            if td then mesh = go:call("getComponent(System.Type)", td:get_runtime_type()) end
        end)
    end

    local tf = sc(go, "get_Transform")
    rv.mesh_ref = mesh
    rv.gun_tf = tf
    rv.weapon_xform = tf

    local wp = get_weapon_go_name()
    cache_cylinder_joints(tf, wp)
    rv.dock_joint, rv.dock_kind = resolve_dock_anchor(tf, wp)

    local node_name = get_hand_bullet_node_name(wp)
    rv.node_name = node_name
    rv.insert_chamber_slot = get_next_chamber_slot_index(wp)
    rv.mesh_indices = get_bullet_mesh_indices(wp)

    local go_tok = get_revolver_weapon_go_token()
    local reuse_rest = rv.grab_rest_wp == wp and rv.grab_rest_go == go_tok and rv.has_rest

    local target, kind = resolve_bullet_target(tf, node_name)
    if not target then
        rv.target = nil
        rv.target_kind = nil
        rv.has_rest = false
        log.warn(string.format("[re2_vr_reload] Revolver bullet node '%s' not found on %s", tostring(node_name), tostring(wp)))
        return false
    end

    rv.target = target
    rv.target_kind = kind

    if reuse_rest then
        snap_grab_joint_to_weapon_rest()
    else
        reset_bullet_visual_joints()
        if not rv.cylinder_open and (rv.open_t or 0) <= 0.001 then
            snap_swing_joint_to_rest()
        end
        local pos = read_target_local_position(target, kind)
        local rot = read_target_local_rotation(target, kind)
        if not pos then return false end
        rv.rest_x = pos.x
        rv.rest_y = pos.y
        rv.rest_z = pos.z
        if rot then
            rv.rest_w = rot.w
            rv.rest_rx = rot.x
            rv.rest_ry = rot.y
            rv.rest_rz = rot.z
        end
        local scv = read_target_local_scale(target, kind)
        if scv then
            rv.rest_sx = scv.x
            rv.rest_sy = scv.y
            rv.rest_sz = scv.z
        else
            rv.rest_sx = 1.0
            rv.rest_sy = 1.0
            rv.rest_sz = 1.0
        end
        rv.grab_rest_wp = wp
        rv.grab_rest_go = go_tok
        rv.has_rest = true
    end

    if not rv.has_rest then
        return false
    end
    if uses_joint_scale_bullet_visual(wp) then
        cache_chamber_vis_joints(tf, wp)
        sync_cylinder_bullet_scales(wp)
    end
    return true
end

ensure_cylinder_joints_cached = function()
    local wp = get_weapon_go_name()
    local expected = wp and get_cylinder_joint_name(wp) or nil
    if rv.swing_joint then
        if rv.swing_joint_wp == wp and rv.swing_joint_name == expected then
            return true
        end
        rv.swing_joint = nil
        rv.swing_joint_name = nil
        rv.swing_joint_wp = nil
        rv.swing_kind = nil
        rv.rest_captured = false
    end
    local weapon = re2.weapon
    local go = weapon and sc(weapon, "get_GameObject")
    local tf = go and sc(go, "get_Transform")
    if tf and wp then
        cache_cylinder_joints(tf, wp)
    end
    return rv.swing_joint ~= nil
end

apply_cylinder_open_visual = function(open_t)
    open_t = math.max(0.0, math.min(1.0, tonumber(open_t) or 0.0))
    local wp = get_weapon_go_name()
    if not wp or not M.is_revolver_weapon(wp) then return end
    local revolver_active = M.is_revolver_weapon_active()
    if not rv.swing_joint and not ensure_cylinder_joints_cached() then
        return
    end
    load_cylinder_open_bind(wp)
    if open_t <= 0.001 then
        write_target_local_position(rv.swing_joint, rv.swing_kind or "joint",
            Vector3f.new(rv.swing_rest_x or 0.0, rv.swing_rest_y or 0.0, rv.swing_rest_z or 0.0))
        write_target_local_rotation(rv.swing_joint, rv.swing_kind or "joint",
            Quaternion.new(rv.swing_rest_w or 1.0, rv.swing_rest_rx or 0.0,
                rv.swing_rest_ry or 0.0, rv.swing_rest_rz or 0.0))
        apply_chamber_bullet_cylinder_follow(open_t)
        return
    end
    local px = lerp_f(rv.swing_rest_x or 0.0, rv.open_x or 0.0, open_t)
    local py = lerp_f(rv.swing_rest_y or 0.0, rv.open_y or 0.0, open_t)
    local pz = lerp_f(rv.swing_rest_z or 0.0, rv.open_z or 0.0, open_t)
    write_target_local_position(rv.swing_joint, rv.swing_kind or "joint", Vector3f.new(px, py, pz))
    local q_rest = Quaternion.new(
        rv.swing_rest_w or 1.0, rv.swing_rest_rx or 0.0, rv.swing_rest_ry or 0.0, rv.swing_rest_rz or 0.0)
    local q_open = quat_from_euler_deg(rv.open_pitch or 0.0, rv.open_yaw or 0.0, rv.open_roll or 0.0)
    local q = q_open and quat_slerp(q_rest, q_open, open_t) or q_rest
    write_target_local_rotation(rv.swing_joint, rv.swing_kind or "joint", q)
    apply_chamber_bullet_cylinder_follow(open_t)
end

local function tick_cylinder_animation()
    if not M.is_revolver_weapon_active() then
        if (rv.open_t or 0) > 0.001 then
            rv.open_t = 0.0
        end
        return
    end
    local target = rv.cylinder_open and 1.0 or 0.0
    local cur = rv.open_t or 0.0
    local rate = tonumber(rv_cfg().open_lerp_rate) or 6.0
    local now = os.clock()
    local dt = math.min(0.1, now - (rv.lerp_t or now))
    rv.lerp_t = now
    if cur < target then
        cur = math.min(target, cur + dt * rate)
    elseif cur > target then
        cur = math.max(target, cur - dt * rate)
    end
    rv.open_t = cur
    if cur > 0.0 or rv.cylinder_open then
        apply_cylinder_open_visual(cur)
    elseif cur <= 0.0 then
        apply_cylinder_open_visual(0.0)
    end
end

local function compute_bullet_hand_world_pose()
    local hand = get_left_hand_joint and get_left_hand_joint()
    local hpos, hrot
    if hand then
        hpos = sc(hand, "get_Position")
        hrot = sc(hand, "get_Rotation")
    end
    if not hpos then hpos = get_left_hand_position and get_left_hand_position() end
    if not hrot then hrot = get_left_hand_rotation() end
    if not hpos or not hrot then return nil, nil end

    local wp = get_weapon_go_name()
    local hold = get_bullet_hand_hold_entry(wp)
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
    return target_pos, hrot * off_rot
end

local function drive_bullet_to_hand()
    if not rv.in_hand or not rv.target or not rv.has_rest then return end
    local target_pos, target_rot = compute_bullet_hand_world_pose()
    if not target_pos or not target_rot then return end
    set_bullet_mesh_visible(true)
    rv.enabled_parts = true
    write_target_world_position_only(rv.target, rv.target_kind, target_pos)
    write_target_world_rotation(rv.target, rv.target_kind, target_rot)
    if reload_drop then
        reload_drop.set_frozen_world(rv, target_pos, target_rot)
    end
end

local function measure_bullet_insert_local_distance(wp)
    if not rv.in_hand then return nil end
    local exit_local = get_mag_exit_local(wp)
    local target_pos, target_rot = compute_bullet_hand_world_pose()
    if target_pos and target_rot then
        local parent_tf = get_bullet_parent_transform()
        if not parent_tf then parent_tf = rv.weapon_xform end
        local local_pos = world_pose_to_parent_local(parent_tf, target_pos, target_rot)
        if local_pos then
            return vec3_dist(local_pos, exit_local)
        end
    end
    if rv.target then
        local cur = read_target_local_position(rv.target, rv.target_kind)
        if cur then
            return vec3_dist(cur, exit_local)
        end
    end
    return nil
end

local function commit_pending_bullet_insert()
    local pi = rv.pending_insert
    if not pi then return end
    rv.pending_insert = nil

    local loaded_before, carried_before = 0, 0
    if get_shell_hud_ammo then
        loaded_before, carried_before = get_shell_hud_ammo()
    elseif get_weapon_chamber_bullet_count then
        loaded_before = get_weapon_chamber_bullet_count() or 0
    end

    local wp = get_weapon_go_name()
    local applied = false
    if uses_canister_mag_reload(wp) then
        if commit_reload_ammo then
            commit_reload_ammo()
            applied = true
        end
        rv.chamber_extracted = false
        rv.spent_round_in_chamber = false
        if rv.canister_stash_by_wp then
            rv.canister_stash_by_wp[wp] = nil
        end
    else
        if apply_single_shell_round then
            local ok = apply_single_shell_round()
            applied = ok == true
        end
        if not applied and apply_carried_mag_ammo then
            applied = apply_carried_mag_ammo(loaded_before + 1) == true
        end
        rv.chamber_extracted = false
        rv.spent_round_in_chamber = false
        if applied then
            rv.chamber_round_seated = true
            rv.last_loaded_track_wp = wp
        end
    end

    local loaded_after = loaded_before
    if get_shell_hud_ammo then
        loaded_after = select(1, get_shell_hud_ammo()) or loaded_before
    elseif get_weapon_chamber_bullet_count then
        loaded_after = get_weapon_chamber_bullet_count() or loaded_before
    end
    if applied and not uses_canister_mag_reload(wp) then
        rv.last_loaded_count = math.max(loaded_after, loaded_before + 1, 1)
    end
    log.info(string.format(
        "[re2_vr_reload] Revolver commit loaded %d->%d applied=%s",
        loaded_before, loaded_after, tostring(applied)))
    if arm_left_support_grace then arm_left_support_grace() end
    rv.bullet_source = nil
    rv.shoot_ready_grace_until = os.clock() + 0.65
    sync_cylinder_bullet_scales(get_weapon_go_name())
    if applied and uses_chamber_bullet_cylinder_follow(wp) and not uses_canister_mag_reload(wp) then
        apply_chamber_bullet_cylinder_follow(rv.open_t or 0.0)
    end
end

local function begin_bullet_insert_anim(wp)
    if not rv.target or not rv.has_rest then return false end
    drive_bullet_to_hand()
    local cur = read_target_local_position(rv.target, rv.target_kind)
    if not cur then return false end
    local exit = get_mag_exit_local(wp)
    rv.slide_lx0 = cur.x
    rv.slide_ly0 = cur.y
    rv.slide_lz0 = cur.z
    rv.slide_lx1 = exit.x
    rv.slide_ly1 = exit.y
    rv.slide_lz1 = exit.z
    local cur_rot = read_target_local_rotation(rv.target, rv.target_kind)
    if cur_rot then
        rv.slide_rw0 = cur_rot.w
        rv.slide_rx0 = cur_rot.x
        rv.slide_ry0 = cur_rot.y
        rv.slide_rz0 = cur_rot.z
    else
        rv.slide_rw0 = rv.rest_w
        rv.slide_rx0 = rv.rest_rx
        rv.slide_ry0 = rv.rest_ry
        rv.slide_rz0 = rv.rest_rz
    end
    local q_end = get_bullet_insert_local_quat(wp)
    rv.slide_rw1 = q_end.w
    rv.slide_rx1 = q_end.x
    rv.slide_ry1 = q_end.y
    rv.slide_rz1 = q_end.z
    rv.anim_active = true
    rv.anim_start = os.clock()
    rv.in_hand = false
    rv.grip_prev = false
    -- Keep insert_chamber_slot during insert anim so other rounds stay visible.
    rawset(_G, "__vr_bullet_in_left_hand", true)
    set_bullet_mesh_visible(true)
    rv.enabled_parts = true
    rv.pending_insert = { wp = wp, frames_left = 999999 }
    if uses_canister_mag_reload(wp) then
        rv.chamber_extracted = true
    end
    rv.shoot_ready_grace_until = os.clock() + bullet_anim_duration("insert") + 0.65
    if arm_left_support_grace then arm_left_support_grace() end
    if play_reload_sfx then play_reload_sfx("mag_insert") end
    return true
end

local function tick_bullet_insert_animation()
    if not rv.anim_active or not rv.target then return end
    local elapsed = os.clock() - rv.anim_start
    local duration = bullet_anim_duration("insert")
    local t = math.min(1.0, elapsed / duration)
    local u = bullet_ease(t)
    write_target_local_position(rv.target, rv.target_kind, Vector3f.new(
        rv.slide_lx0 + (rv.slide_lx1 - rv.slide_lx0) * u,
        rv.slide_ly0 + (rv.slide_ly1 - rv.slide_ly0) * u,
        rv.slide_lz0 + (rv.slide_lz1 - rv.slide_lz0) * u))
    local q0 = Quaternion.new(rv.slide_rw0, rv.slide_rx0, rv.slide_ry0, rv.slide_rz0)
    local q1 = Quaternion.new(rv.slide_rw1, rv.slide_rx1, rv.slide_ry1, rv.slide_rz1)
    write_target_local_rotation(rv.target, rv.target_kind, quat_slerp(q0, q1, u))
    if t < 1.0 then return end
    rv.anim_active = false
    rv.insert_chamber_slot = nil
    commit_pending_bullet_insert()
    local wp = get_weapon_go_name()
    if uses_canister_mag_reload(wp) then
        sync_canister_bullet_visual(wp)
    elseif uses_chamber_bullet_cylinder_follow(wp) then
        apply_chamber_bullet_cylinder_follow(rv.open_t or 0.0)
    else
        disable_bullet_visual()
    end
    rawset(_G, "__vr_bullet_in_left_hand", false)
end

local function bullet_release_on_complete()
    local src = rv.release_bullet_source
    rv.release_chamber_slot = nil
    rv.release_bullet_source = nil
    rv.release_local_fall = false
    disable_bullet_visual()
    if play_reload_sfx then play_reload_sfx("mag_floor") end
    if src == "weapon" and uses_chamber_extract_reload(get_weapon_go_name()) then
        local wp_drop = get_weapon_go_name()
        if uses_canister_mag_reload(wp_drop) then
            rv.extract_stash_rounds = nil
        elseif clear_weapon_chamber_ammo then
            clear_weapon_chamber_ammo()
        end
        rv.chamber_extracted = true
        rv.spent_round_in_chamber = false
        rv.chamber_round_seated = false
        rv.bullet_source = nil
        if uses_canister_mag_reload(wp_drop) then
            clear_bullet_freeze()
            snap_grab_joint_to_weapon_rest()
            sync_canister_bullet_visual(wp_drop)
            local carried_drop = get_mag_carried_rounds and get_mag_carried_rounds() or 0
            if carried_drop > 0 then
                rv.canister_stash_by_wp = rv.canister_stash_by_wp or {}
                rv.canister_stash_by_wp[wp_drop] = carried_drop
            end
        else
            sync_chamber_bullet_cylinder_pose()
        end
    end
end

local function begin_bullet_hand_release()
    if not rv.in_hand or not rv.target or rv.anim_active then return end
    clear_bullet_freeze()
    local wp = get_weapon_go_name()
    drive_bullet_to_hand()
    if uses_canister_mag_reload(wp) then
        local pos, hand_rot = compute_bullet_hand_world_pose()
        if not pos then
            pos = read_target_world_position(rv.target, rv.target_kind)
        end
        if not pos then return end
        local rot = read_target_world_rotation(rv.target, rv.target_kind)
        if not rot then rot = hand_rot end
        rv.in_hand = false
        rv.grip_prev = false
        rv.release_chamber_slot = rv.insert_chamber_slot
        rv.release_bullet_source = rv.bullet_source
        rv.release_fall_active = true
        rv.release_local_fall = true
        rv.release_start = os.clock()
        rv.release_sx = pos.x
        rv.release_sy = pos.y
        rv.release_sz = pos.z
        if rot then
            rv.release_rx = rot.x
            rv.release_ry = rot.y
            rv.release_rz = rot.z
            rv.release_rw = rot.w
        end
        rawset(_G, "__vr_bullet_in_left_hand", false)
        ensure_bullet_fall_visible(wp)
        if extend_suppress_window then extend_suppress_window() end
        return
    end
    local pos, hand_rot = compute_bullet_hand_world_pose()
    if not pos then
        pos = read_target_world_position(rv.target, rv.target_kind)
    end
    if not pos then return end
    local rot = read_target_world_rotation(rv.target, rv.target_kind)
    if not rot then rot = hand_rot end
    rv.in_hand = false
    rv.grip_prev = false
    rv.release_chamber_slot = rv.insert_chamber_slot
    rv.release_bullet_source = rv.bullet_source
    rv.release_fall_active = true
    rv.release_local_fall = false
    rv.release_start = os.clock()
    rv.release_sx = pos.x
    rv.release_sy = pos.y
    rv.release_sz = pos.z
    if rot then
        rv.release_rx = rot.x
        rv.release_ry = rot.y
        rv.release_rz = rot.z
        rv.release_rw = rot.w
    end
    rawset(_G, "__vr_bullet_in_left_hand", false)
    ensure_bullet_fall_visible(wp)
    if reload_drop then
        reload_drop.begin_release(rv, pos, rot)
    end
    write_target_world_position_only(rv.target, rv.target_kind, pos)
    if rot then write_target_world_rotation(rv.target, rv.target_kind, rot) end
    apply_bullet_frozen_pose()
    if extend_suppress_window then extend_suppress_window() end
end

local function tick_bullet_hand_release()
    if not rv.release_fall_active or not rv.target then return end
    if rv.release_local_fall then
        local elapsed = os.clock() - rv.release_start
        local duration = bullet_anim_duration("fall")
        local t = math.min(1.0, elapsed / duration)
        local fall = bullet_fall_distance() * (t * t)
        local world_pos = Vector3f.new(
            rv.release_sx,
            (rv.release_sy or 0.0) - fall,
            rv.release_sz)
        local world_rot = Quaternion.new(
            rv.release_rw or 1.0,
            rv.release_rx or 0.0,
            rv.release_ry or 0.0,
            rv.release_rz or 0.0)
        ensure_bullet_fall_visible(get_weapon_go_name())
        local parent_tf = get_bullet_parent_transform() or rv.weapon_xform
        local local_pos, local_rot = world_pose_to_parent_local(parent_tf, world_pos, world_rot)
        if local_pos then
            write_target_local_position(rv.target, rv.target_kind, local_pos)
        end
        if local_rot then
            write_target_local_rotation(rv.target, rv.target_kind, local_rot)
        end
        if t < 1.0 then return end
        rv.release_fall_active = false
        bullet_release_on_complete()
        return
    end
    if not reload_drop then return end
    reload_drop.tick_release(rv, {
        target = rv.target,
        target_kind = rv.target_kind,
        write_world_pos = write_target_world_position_only,
        write_world_rot = write_target_world_rotation,
        ensure_visible = ensure_bullet_fall_visible,
        on_complete = bullet_release_on_complete,
    })
end

local function measure_weapon_chamber_grab_distance(wp)
    wp = wp or get_weapon_go_name()
    if not rv.has_rest and not refresh_weapon_refs() then return nil end
    return measure_chamber_grab_dock_distance(wp)
end

local function tick_dbg_joint_stick_check()
    if not manual_reload_context_active() then
        rv.dbg_stick_wp = nil
        return
    end
    local wp = get_weapon_go_name()
    if not wp or not rv.target or rv.in_hand or rv.anim_active or rv.release_fall_active then
        rv.dbg_stick_wp = nil
        return
    end
    if not M.is_revolver_weapon(wp) and not uses_chamber_extract_reload(wp) then
        rv.dbg_stick_wp = nil
        return
    end
    if not rv.weapon_xform then
        if not refresh_weapon_refs() then return end
    end
    local gun_pos = rv.weapon_xform and sc(rv.weapon_xform, "get_Position")
    local joint_pos = read_target_world_position(rv.target, rv.target_kind)
    if not gun_pos or not joint_pos then return end

    if rv.dbg_stick_wp == wp and rv.dbg_stick_gun_x then
        local gun_move = vec3_dist(gun_pos, Vector3f.new(rv.dbg_stick_gun_x, rv.dbg_stick_gun_y, rv.dbg_stick_gun_z))
        local joint_move = vec3_dist(joint_pos, Vector3f.new(rv.dbg_stick_joint_x, rv.dbg_stick_joint_y, rv.dbg_stick_joint_z))
        if gun_move > 0.02 and joint_move < 0.005 then
        end
    end

    rv.dbg_stick_wp = wp
    rv.dbg_stick_gun_x = gun_pos.x
    rv.dbg_stick_gun_y = gun_pos.y
    rv.dbg_stick_gun_z = gun_pos.z
    rv.dbg_stick_joint_x = joint_pos.x
    rv.dbg_stick_joint_y = joint_pos.y
    rv.dbg_stick_joint_z = joint_pos.z
end

local function on_weapon_chamber_grab_edge()
    local wp = get_weapon_go_name()
    if not chamber_needs_extract(wp) then return false end
    if uses_canister_mag_reload(wp) then
        rv.extract_stash_rounds = get_revolver_loaded_count()
    end
    if detach_mag_hand_for_shell then detach_mag_hand_for_shell() end
    rv.weapon_wp = wp
    rv.bullet_source = "weapon"
    rv.in_hand = true
    rv.grip_prev = true
    rawset(_G, "__vr_bullet_in_left_hand", true)
    local ok = refresh_weapon_refs()
    if ok then
        set_bullet_mesh_visible(true)
        rv.enabled_parts = true
        drive_bullet_to_hand()
        if uses_joint_scale_bullet_visual(wp) then
            sync_cylinder_bullet_scales(wp)
        end
    else
        rv.in_hand = false
        rv.bullet_source = nil
        rv.weapon_wp = nil
        rawset(_G, "__vr_bullet_in_left_hand", nil)
    end
    log.info(string.format(
        "[re2_vr_reload] Chamber extract grab wp=%s ok=%s node=%s",
        tostring(wp), tostring(ok), tostring(rv.node_name)))
    if ok and uses_canister_mag_reload(wp) then
        rv.chamber_extracted = true
        if on_chamber_ammo_to_carried then
            on_chamber_ammo_to_carried(rv.extract_stash_rounds)
        end
        local carried_grab = get_mag_carried_rounds and get_mag_carried_rounds() or 0
        if carried_grab > 0 then
            rv.canister_stash_by_wp = rv.canister_stash_by_wp or {}
            rv.canister_stash_by_wp[wp] = carried_grab
        end
        sync_canister_bullet_visual(wp)
    end
    if ok and play_reload_sfx then play_reload_sfx("mag_grab") end
    if ok and extend_suppress_window then extend_suppress_window() end
    if ok and arm_left_support_grace then arm_left_support_grace() end
    return ok
end

local function tick_weapon_chamber_grab()
    local wp = get_weapon_go_name()
    local block_reason = nil
    local dist, thr, near, grip_now = nil, nil, false, false

    if not M.is_revolver_weapon_active() then
        rv.weapon_chamber_grip_prev = false
        block_reason = "not_revolver_active"
    elseif rv.in_hand or rv.anim_active or rv.release_fall_active or rv.pending_insert then
        rv.weapon_chamber_grip_prev = false
        block_reason = "busy"
    elseif chamber_extract_suppressed() then
        rv.weapon_chamber_grip_prev = false
        block_reason = "insert_grace"
    elseif not uses_chamber_extract_reload(wp) then
        rv.weapon_chamber_grip_prev = false
        block_reason = "not_extract_weapon"
    elseif not rv.cylinder_open then
        rv.weapon_chamber_grip_prev = false
        block_reason = "cylinder_closed"
    elseif not chamber_needs_extract(wp) then
        rv.weapon_chamber_grip_prev = false
        block_reason = "no_extract_need"
    else
        if not rv.target or not rv.has_rest then
            if not refresh_weapon_refs() then
                rv.weapon_chamber_grip_prev = false
                block_reason = "no_target_ref"
            end
        end
        if not block_reason then
            if not uses_chamber_bullet_cylinder_follow(wp) then
                park_chamber_grab_joint(wp)
            end
            dist = measure_weapon_chamber_grab_distance(wp)
            thr = get_weapon_chamber_grab_dist(wp)
            near = dist ~= nil and dist <= thr
            grip_now = is_left_grip_pressed and is_left_grip_pressed() or false
            local grab_edge = near and grip_now and not rv.weapon_chamber_grip_prev
            rv.weapon_chamber_grip_prev = near and grip_now
            if grab_edge then
                if haptic_pulse then haptic_pulse(nil, 0.057, 169.385, 0.99) end
                return on_weapon_chamber_grab_edge()
            end
            if not near then
                block_reason = "too_far"
                rv.weapon_chamber_grip_prev = false
            else
                block_reason = grip_now and "grip_held_no_edge" or "in_range_no_grip"
            end
        end
    end

    return false
end

try_bullet_dock = function(from_grip_release)
    if rv.anim_active or not rv.in_hand or not rv.cylinder_open then return false end
    local wp = get_weapon_go_name()
    if not M.is_revolver_weapon(wp) then return false end
    local reserve = get_main_weapon_reserve_ammo_count and get_main_weapon_reserve_ammo_count() or 0
    if uses_canister_mag_reload(wp) then
        if not rv.chamber_extracted or rv.bullet_source ~= "holster" then return false end
        if not canister_restore_supply_available() then return false end
    else
        if uses_chamber_extract_reload(wp) and rv.bullet_source ~= "holster" then return false end
        local vacancy = get_revolver_vacancy(wp)
        if vacancy <= 0 or reserve <= 0 then return false end
    end

    if not rv.dock_joint and (not rv.target or not rv.has_rest) then refresh_weapon_refs() end

    local cooldown = tonumber(rv_cfg().dock_cooldown) or 0.45
    local now = os.clock()
    if (now - rv.last_dock_t) < cooldown then return false end
    if not from_grip_release then
        if is_left_grip_pressed and not is_left_grip_pressed() then return false end
    end

    local hand_dist = measure_bullet_insert_local_distance(wp)
    if hand_dist == nil or hand_dist > get_bullet_insert_dock_dist(wp) then return false end

    rv.last_dock_t = now
    begin_bullet_insert_anim(wp)
    return true
end

update_bullet_in_hand = function()
    if not rv.in_hand or rv.anim_active then return end
    drive_bullet_to_hand()
    if uses_joint_scale_bullet_visual(get_weapon_go_name()) then
        sync_cylinder_bullet_scales()
    end
    local grip_now = is_left_grip_pressed and is_left_grip_pressed() or false
    if rv.grip_prev and not grip_now then
        if try_bullet_dock(true) then
            rv.grip_prev = false
            return
        end
        begin_bullet_hand_release()
        return
    end
    if grip_now then try_bullet_dock(false) end
    rv.grip_prev = grip_now
end

function M.holster_wants_bullet_grab()
    if not M.is_revolver_weapon_active() then return false end
    if not revolver_cylinder_open_for_reload() then return false end
    if rv.in_hand or rv.anim_active or rv.release_fall_active or rv.pending_insert then return false end
    local wp = get_weapon_go_name()
    if uses_canister_mag_reload(wp) then
        sync_canister_extracted_state(wp)
        if not rv.chamber_extracted then
            return false
        end
        local supply = canister_restore_supply_available(wp)
        if not supply then
            return false
        end
        return supply
    end
    if chamber_needs_extract(wp) then
        return false
    end
    local vacancy = get_revolver_vacancy(wp)
    local reserve = get_main_weapon_reserve_ammo_count and get_main_weapon_reserve_ammo_count() or 0
    local want = vacancy > 0 and reserve > 0
    return want
end

function M.weapon_chamber_wants_grab()
    if not M.is_revolver_weapon_active() then return false end
    if not rv.cylinder_open then return false end
    if rv.in_hand or rv.anim_active or rv.release_fall_active or rv.pending_insert then return false end
    local wp = get_weapon_go_name()
    if not chamber_needs_extract(wp) then return false end
    if not rv.target and not refresh_weapon_refs() then return false end
    local dist = measure_weapon_chamber_grab_distance(wp)
    if dist == nil or dist > get_weapon_chamber_grab_dist(wp) then return false end
    return true
end

function M.holster_context_active()
    if not M.is_revolver_weapon_active() then return false end
    if not CFG.mag_holster or CFG.mag_holster.enabled == false then return false end
    if rv.cylinder_open or rv.in_hand or rv.anim_active or rv.pending_insert then return true end
    return false
end

function M.holster_supply_available()
    if not M.is_revolver_weapon_active() then return nil end
    if rv.in_hand or rv.pending_insert or rv.anim_active or rv.release_fall_active then return true end
    local wp = get_weapon_go_name()
    if uses_canister_mag_reload(wp) then
        if rv.cylinder_open and canister_restore_supply_available() then return true end
        return false
    end
    if rv.cylinder_open and get_main_weapon_reserve_ammo_count and get_main_weapon_reserve_ammo_count() > 0 then
        return true
    end
    return false
end

function M.holster_empty_denial_active()
    if not M.is_revolver_weapon_active() then return false end
    if not rv.cylinder_open then return false end
    if rv.in_hand or rv.pending_insert then return false end
    return not M.holster_wants_bullet_grab()
end

function M.has_bullet_in_hand()
    return rv.in_hand == true or rv.anim_active == true or rv.pending_insert ~= nil
end

function M.aux_input_suppress_wanted()
    if not M.is_revolver_weapon_active() then return false end
    if not manual_reload_context_active or not manual_reload_context_active() then return false end
    if rv.anim_active or rv.pending_insert or rv.release_fall_active then return true end
    local grip = is_left_grip_pressed and is_left_grip_pressed() or false
    if not grip then return false end
    if rv.in_hand then return true end
    if not rv.cylinder_open then return false end
    local wp = get_weapon_go_name()
    if chamber_needs_extract(wp) then
        local dist = measure_weapon_chamber_grab_distance(wp)
        if dist ~= nil and dist <= get_weapon_chamber_grab_dist(wp) then
            return true
        end
    end
    if rawget(_G, "__vr_in_mag_holster_zone") == true then
        return true
    end
    return false
end

function M.shoot_ready_suppress_exempt()
    if not M.is_revolver_weapon_active() then return false end
    if M.blocks_empty_native_reload and M.blocks_empty_native_reload() then return false end
    if M.aux_input_suppress_wanted() then return false end
    if rv.in_hand or rv.anim_active or rv.pending_insert or rv.release_fall_active then return true end
    if rv.cylinder_open then
        local wp = get_weapon_go_name()
        local loaded_open = get_revolver_loaded_count()
        local reserve_open = get_main_weapon_reserve_ammo_count and get_main_weapon_reserve_ammo_count() or 0
        if loaded_open <= 0 and reserve_open > 0 then
            return false
        end
        if get_revolver_vacancy(wp) > 0 and reserve_open > 0 then
            return false
        end
        return true
    end
    return os.clock() < (rv.shoot_ready_grace_until or 0)
end

function M.blocks_empty_native_reload()
    if not M.is_revolver_weapon_active() then return false end
    if not manual_reload_context_active or not manual_reload_context_active() then return false end
    if rv.in_hand or rv.anim_active or rv.pending_insert or rv.release_fall_active then
        return false
    end
    if rv.cylinder_open then
        return true
    end
    local loaded = get_revolver_loaded_count()
    if loaded > 0 then return false end
    local reserve = get_main_weapon_reserve_ammo_count and get_main_weapon_reserve_ammo_count() or 0
    local blocks = reserve > 0
    return blocks
end

function M.on_holster_grab_edge()
    if not M.holster_wants_bullet_grab() then return false end
    local wp = get_weapon_go_name()
    if detach_mag_hand_for_shell then detach_mag_hand_for_shell() end
    rv.weapon_wp = wp
    rv.bullet_source = "holster"
    if uses_canister_mag_reload(wp) then
        rv.chamber_extracted = true
    end
    rv.in_hand = true
    rv.grip_prev = true
    rawset(_G, "__vr_bullet_in_left_hand", true)
    local ok = refresh_weapon_refs()
    if ok then
        set_bullet_mesh_visible(true)
        rv.enabled_parts = true
        drive_bullet_to_hand()
        if uses_joint_scale_bullet_visual(wp) then
            sync_cylinder_bullet_scales(wp)
        end
    else
        rv.in_hand = false
        rv.bullet_source = nil
        rv.weapon_wp = nil
        rawset(_G, "__vr_bullet_in_left_hand", nil)
    end
    log.info(string.format(
        "[re2_vr_reload] Revolver holster grab wp=%s ok=%s node=%s in_hand=%s",
        tostring(wp), tostring(ok), tostring(rv.node_name), tostring(rv.in_hand)))
    if play_reload_sfx then play_reload_sfx("mag_grab") end
    if extend_suppress_window then extend_suppress_window() end
    if arm_left_support_grace then arm_left_support_grace() end
    return ok
end

function M.handle_b_edge()
    if not M.is_revolver_weapon_active() then return false end
    if rv.in_hand or rv.anim_active or rv.pending_insert then
        if extend_suppress_window then extend_suppress_window() end
        return true
    end
    ensure_cylinder_joints_cached()
    if not rv.rest_captured or rv.rest_wp ~= get_weapon_go_name() then
        capture_cylinder_rest_from_joint(get_weapon_go_name())
    end
    load_cylinder_open_bind(get_weapon_go_name())
    rv.cylinder_open = not rv.cylinder_open
    if rv.cylinder_open and prime_main_weapon_reloadable_pool then
        prime_main_weapon_reloadable_pool()
    end
    if rv.cylinder_open and uses_chamber_extract_reload(get_weapon_go_name()) then
        local wp_open = get_weapon_go_name()
        if not uses_canister_mag_reload(wp_open) then
            rv.chamber_extracted = false
        end
        if uses_canister_mag_reload(wp_open) then
            sync_canister_extracted_state(wp_open)
            if not rv.target or not rv.has_rest then refresh_weapon_refs() end
            repair_grab_joint_if_world_detached(wp_open)
            snap_grab_joint_to_weapon_rest()
            sync_canister_bullet_visual(wp_open)
        end
    end
    if play_reload_sfx then
        play_reload_sfx(rv.cylinder_open and "mag_drop" or cylinder_close_sfx_kind())
    end
    if not rv.cylinder_open then
        rv.shoot_ready_grace_until = 0.0
        rv.chamber_extracted = false
        rv.spent_round_in_chamber = false
        rv.chamber_round_seated = true
        if sync_chamber_shoot_ready then sync_chamber_shoot_ready() end
    end
    if extend_suppress_window then extend_suppress_window() end
    return true
end

function M.clear_state(clear_pending)
    cancel_bullet_insert_preview(false)
    rv.anim_active = false
    rv.release_fall_active = false
    rv.release_local_fall = false
    rv.release_chamber_slot = nil
    rv.release_bullet_source = nil
    clear_bullet_freeze()
    disable_bullet_visual()
    rv.in_hand = false
    rv.weapon_wp = nil
    rv.grip_prev = false
    rv.bullet_source = nil
    rv.weapon_chamber_grip_prev = false
    rv.spent_round_in_chamber = false
    rv.chamber_round_seated = false
    rv.extract_stash_rounds = nil
    rv.last_loaded_count = nil
    rv.last_loaded_track_wp = nil
    rv.insert_chamber_slot = nil
    rv.shoot_ready_grace_until = 0.0
    rv.last_dock_t = 0.0
    clear_chamber_vis_cache()
    rawset(_G, "__vr_bullet_in_left_hand", nil)
    if clear_pending ~= false then rv.pending_insert = nil end
end

function M.clear_globals()
    rv.cylinder_open = false
    rv.open_t = 0.0
    clear_close_gesture_tracking()
    rv.close_cooldown_until = 0.0
    M.clear_state(true)
    rawset(_G, "__vr_revolver_cylinder_open", nil)
end

local function weapon_uses_chamber_joint_hiding(wp)
    wp = wp or get_weapon_go_name()
    if not wp then return false end
    if type(CFG.weapons) == "table" then
        local entry = CFG.weapons[wp]
        if entry and entry.use_chamber_joint_hiding == true then return true end
    end
    return uses_joint_scale_bullet_visual(wp) == true
end

local function restore_all_chamber_joint_visuals(wp)
    wp = wp or get_weapon_go_name()
    if not wp or not uses_joint_scale_bullet_visual(wp) then return false end
    if not ensure_chamber_vis_cached(wp) then return false end
    local cv = rv.chamber_vis
    if not cv or not cv.nodes then return false end
    for _, entry in ipairs(cv.nodes) do
        apply_scale_node_entry(entry, true)
    end
    if cv.barrel then
        apply_scale_node_entry(cv.barrel, true)
    end
    return true
end

local function pause_manual_reload_for_change_bullet(wp)
    wp = wp or get_weapon_go_name()
    cancel_bullet_insert_preview(false)
    if rv.in_hand or rv.anim_active or rv.release_fall_active or rv.pending_insert then
        if rv.target and rv.has_rest then
            restore_outgoing_grab_joints()
        end
        rv.in_hand = false
        rv.anim_active = false
        rv.pending_insert = nil
        rv.release_fall_active = false
        rv.release_bullet_source = nil
        rv.release_chamber_slot = nil
        rv.bullet_source = nil
        rv.grip_prev = false
        rv.weapon_chamber_grip_prev = false
        clear_bullet_freeze()
    end
    if rv.cylinder_open or (rv.open_t or 0) > 0.001 then
        rv.cylinder_open = false
        if wp and M.is_revolver_weapon(wp) then
            ensure_cylinder_joints_cached()
            apply_cylinder_open_visual(0.0)
        end
        rv.open_t = 0.0
    end
    rawset(_G, "__vr_revolver_cylinder_open", nil)
    rawset(_G, "__vr_bullet_in_left_hand", nil)
end

function M.begin_native_change_bullet_suspend()
    if rv.change_bullet_suspend == true then return end
    local wp = get_weapon_go_name()
    if not wp or not M.is_revolver_weapon(wp) then return end
    rv.change_bullet_suspend = true
    rv.change_bullet_suspend_wp = wp
    pause_manual_reload_for_change_bullet(wp)
    if weapon_uses_chamber_joint_hiding(wp) then
        restore_all_chamber_joint_visuals(wp)
    end
end

function M.end_native_change_bullet_suspend()
    if rv.change_bullet_suspend ~= true then return end
    local wp = rv.change_bullet_suspend_wp or get_weapon_go_name()
    rv.change_bullet_suspend = false
    rv.change_bullet_suspend_wp = nil
    rv.weapon_xform = nil
    clear_chamber_vis_cache()
    if wp and uses_joint_scale_bullet_visual(wp) then
        sync_cylinder_bullet_scales(wp)
    end
end

function M.on_weapon_swap(prev_wp)
    rv.change_bullet_suspend = false
    rv.change_bullet_suspend_wp = nil
    cancel_bullet_insert_preview(false)
    rv.ammo_prime_wp = nil
    local out_wp = rv.weapon_wp or prev_wp or rv.last_loaded_track_wp
    if out_wp and uses_canister_mag_reload(out_wp) then
        rv.canister_stash_by_wp = rv.canister_stash_by_wp or {}
        local carried_out = get_mag_carried_rounds and get_mag_carried_rounds() or 0
        if carried_out > 0 then
            rv.canister_stash_by_wp[out_wp] = carried_out
        end
    end
    if out_wp and M.is_revolver_weapon(out_wp) and rv.target and rv.has_rest then
        restore_outgoing_grab_joints()
    end
    M.clear_state(true)
    rv.chamber_extracted = false
    rv.chamber_round_seated = false
    rv.cylinder_open = false
    rv.open_t = 0.0
    rv.swing_joint = nil
    rv.swing_kind = nil
    rv.mesh_ref = nil
    rv.gun_tf = nil
    rv.dock_joint = nil
    rv.target = nil
    rv.weapon_xform = nil
    rv.has_rest = false
    rv.mesh_indices = nil
    rv.rest_captured = false
    rv.rest_wp = nil
    clear_chamber_vis_cache()
    clear_close_gesture_tracking()
    rv.close_cooldown_until = 0.0
    rv.dbg_stick_wp = nil
    local new_wp = get_weapon_go_name()
    if new_wp and M.is_revolver_weapon(new_wp) then
        init_active_revolver_weapon_refs()
    end
    reconcile_canister_with_loaded_game()
end

function M.on_frame()
    if not CFG or CFG.enabled ~= true then
        M.clear_globals()
        return
    end
    if change_bullet_suspend_blocks_manual() then return end

    tick_bullet_insert_animation()
    tick_bullet_hand_release()

    if M.is_revolver_weapon_active() then
        local wp_track = get_weapon_go_name()
        tick_spent_chamber_bullet_track(wp_track)
    end

    if M.is_revolver_weapon_active() and (rv.cylinder_open or (rv.open_t or 0) > 0.0) then
        ensure_cylinder_joints_cached()
    end
    tick_cylinder_animation()
    if M.is_revolver_weapon_active() then
        local wp_chk = get_weapon_go_name()
        if not chamber_bullet_pose_busy()
            and (uses_chamber_bullet_cylinder_follow(wp_chk) or uses_canister_mag_reload(wp_chk)) then
            if not rv.target or not rv.has_rest or rv.weapon_wp ~= wp_chk then
                refresh_weapon_refs()
                rv.weapon_wp = wp_chk
            end
            repair_grab_joint_if_world_detached(wp_chk)
        end
    end
    reconcile_canister_with_loaded_game()
    sync_chamber_bullet_cylinder_pose()

    if rv.insert_preview_active then
        tick_bullet_insert_preview()
    end

    rawset(_G, "__vr_revolver_cylinder_open", rv.cylinder_open == true)
    rawset(_G, "__vr_bullet_in_left_hand",
        rv.in_hand == true or rv.anim_active == true or rv.pending_insert ~= nil)

    if not manual_reload_context_active() and not rv.in_hand and not rv.anim_active
        and not rv.pending_insert and not rv.insert_preview_active then
        if rv.cylinder_open then
            rv.cylinder_open = false
            rv.open_t = 0.0
        end
        rawset(_G, "__vr_revolver_cylinder_open", nil)
        rawset(_G, "__vr_bullet_in_left_hand", nil)
        return
    end

    local wp = get_weapon_go_name()
    if rv.in_hand and rv.weapon_wp and wp ~= rv.weapon_wp then
        M.on_weapon_swap(rv.weapon_wp)
    elseif rv.in_hand and (rv.weapon_wp ~= wp or not rv.target or not rv.has_rest) then
        refresh_weapon_refs()
    end
end

function M.on_joint_expression()
    if change_bullet_suspend_blocks_manual() then return end
    tick_bullet_insert_animation()
    tick_bullet_hand_release()
    if rv.insert_preview_active then
        tick_bullet_insert_preview()
        return
    end
    if M.is_revolver_weapon_active() and (rv.cylinder_open or (rv.open_t or 0) > 0.0) then
        ensure_cylinder_joints_cached()
        apply_cylinder_open_visual(rv.open_t or 0.0)
    end
    if M.is_revolver_weapon_active() and uses_joint_scale_bullet_visual(get_weapon_go_name()) then
        sync_cylinder_bullet_scales()
    end
    if rv.in_hand and rv.target and rv.has_rest and not rv.anim_active then
        drive_bullet_to_hand()
        return
    end
    sync_chamber_bullet_cylinder_pose()
    if M.is_revolver_weapon_active() and rv.cylinder_open and not chamber_bullet_pose_busy() then
        park_chamber_grab_joint(get_weapon_go_name())
    end
    if rv.release_fall_active and not rv.release_local_fall then
        apply_bullet_frozen_pose()
    end
end

local function maybe_prime_ammo_pool_on_equip()
    if not M.is_revolver_weapon_active() then return end
    local wp = get_weapon_go_name()
    if not wp or rv.ammo_prime_wp == wp then return end
    rv.ammo_prime_wp = wp
    if prime_main_weapon_reloadable_pool then
        prime_main_weapon_reloadable_pool()
    end
end

function M.on_late_update()
    if change_bullet_suspend_blocks_manual() then return end
    maybe_prime_ammo_pool_on_equip()
    tick_bullet_insert_animation()
    tick_bullet_hand_release()
    tick_close_gesture()
    update_bullet_in_hand()
    tick_weapon_chamber_grab()
    tick_dbg_joint_stick_check()
    if rv.in_hand and rv.target and rv.has_rest and not rv.anim_active then
        apply_bullet_frozen_pose()
    elseif rv.release_fall_active and not rv.release_local_fall then
        apply_bullet_frozen_pose()
    end
    if publish_sub_weapon_suppress then publish_sub_weapon_suppress() end
end

function M.on_prepare_rendering()
    if change_bullet_suspend_blocks_manual() then return end
    tick_bullet_insert_animation()
    tick_bullet_hand_release()
    if rv.insert_preview_active then
        tick_bullet_insert_preview()
        return
    end
    if M.is_revolver_weapon_active() and (rv.cylinder_open or (rv.open_t or 0) > 0.0) then
        apply_cylinder_open_visual(rv.open_t or 0.0)
    end
    if M.is_revolver_weapon_active() and uses_joint_scale_bullet_visual(get_weapon_go_name()) then
        sync_cylinder_bullet_scales()
    end
    if rv.in_hand and rv.target and rv.has_rest and not rv.anim_active then
        drive_bullet_to_hand()
        apply_bullet_frozen_pose()
        return
    end
    sync_chamber_bullet_cylinder_pose()
    if rv.release_fall_active and not rv.release_local_fall then
        apply_bullet_frozen_pose()
    end
end

function M.on_disabled()
    M.clear_globals()
end

function M.on_context_inactive()
    if rv.pending_insert or rv.anim_active or rv.release_fall_active then return end
    if rv.in_hand then M.clear_state(true) end
    rv.cylinder_open = false
end

function M.uses_chamber_bullet_follow(wp)
    return uses_chamber_bullet_cylinder_follow(wp)
end

function M.weapon_keeps_spent_chamber_bullet(wp)
    return weapon_keeps_spent_chamber_bullet(wp)
end

function M.get_bullet_rest_pose()
    if not rv.has_rest then return nil end
    return {
        x = rv.rest_x, y = rv.rest_y, z = rv.rest_z,
        w = rv.rest_w, rx = rv.rest_rx, ry = rv.rest_ry, rz = rv.rest_rz,
    }
end

function M.get_chamber_bullet_open_bind_display(wp)
    wp = wp or get_weapon_go_name()
    local bind = get_chamber_bullet_open_bind(wp)
    local rest = M.get_bullet_rest_pose() or {}
    local rp, ry, rr = 0.0, 0.0, 0.0
    if rest.w then
        rp, ry, rr = quat_to_euler_deg(Quaternion.new(rest.w, rest.rx or 0, rest.ry or 0, rest.rz or 0))
    end
    return {
        x = tonumber(bind.x) or tonumber(rest.x) or 0.0,
        y = tonumber(bind.y) or tonumber(rest.y) or 0.0,
        z = tonumber(bind.z) or tonumber(rest.z) or 0.0,
        pitch = tonumber(bind.pitch) or rp,
        yaw = tonumber(bind.yaw) or ry,
        roll = tonumber(bind.roll) or rr,
    }
end

function M.sync_chamber_bullet_pose()
    sync_chamber_bullet_cylinder_pose()
end

function M.apply_chamber_bullet_follow_open_t(open_t)
    if uses_chamber_bullet_cylinder_follow(get_weapon_go_name()) then
        apply_chamber_bullet_cylinder_follow(open_t)
    end
end

function M.reset_stack_state()
    rv.canister_stash_by_wp = {}
    rv.chamber_extracted = false
    rv.chamber_round_seated = true
    rv.extract_stash_rounds = nil
    M.clear_globals()
end

function M.init(deps)
    CFG = deps.CFG
    sc = deps.sc
    re2 = deps.re2
    reload_drop = deps.reload_drop
    if reload_drop then
        reload_drop.init({ CFG = CFG })
    end
    get_weapon_go_name = deps.get_weapon_go_name
    manual_reload_context_active = deps.manual_reload_context_active
    weapon_display_name = deps.weapon_display_name or function(wp) return tostring(wp) end
    mark_tuning_dirty = deps.mark_tuning_dirty or function() end
    play_reload_sfx = deps.play_reload_sfx
    get_left_hand_position = deps.get_left_hand_position
    get_left_hand_joint = deps.get_left_hand_joint
    get_left_track_position = deps.get_left_track_position
    get_left_track_pos_with_source = deps.get_left_track_pos_with_source
    get_mag_hand_hold_entry = deps.get_mag_hand_hold_entry
    get_mag_dock_dist = deps.get_mag_dock_dist
    is_left_grip_pressed = deps.is_left_grip_pressed
    detach_mag_hand_for_shell = deps.detach_mag_hand_for_shell
    get_weapon_chamber_bullet_count = deps.get_weapon_chamber_bullet_count
    get_main_weapon_reserve_ammo_count = deps.get_main_weapon_reserve_ammo_count
    get_inventory_spare_bullet_count = deps.get_inventory_spare_bullet_count
    prime_main_weapon_reloadable_pool = deps.prime_main_weapon_reloadable_pool
    get_shell_hud_ammo = deps.get_shell_hud_ammo
    apply_carried_mag_ammo = deps.apply_carried_mag_ammo
    apply_single_shell_round = deps.apply_single_shell_round
    extend_suppress_window = deps.extend_suppress_window
    arm_left_support_grace = deps.arm_left_support_grace
    publish_sub_weapon_suppress = deps.publish_sub_weapon_suppress
    clear_weapon_chamber_ammo = deps.clear_weapon_chamber_ammo
    sync_chamber_shoot_ready = deps.sync_chamber_shoot_ready
    on_chamber_ammo_to_carried = deps.on_chamber_ammo_to_carried
    commit_reload_ammo = deps.commit_reload_ammo
    weapon_uses_canister_mag_reload = deps.weapon_uses_canister_mag_reload
    get_mag_carried_rounds = deps.get_mag_carried_rounds
    get_weapon_mag_slot_round_count = deps.get_weapon_mag_slot_round_count
    haptic_pulse = deps.haptic_pulse
    native_change_bullet_suspend_active = deps.native_change_bullet_suspend_active
end

package.loaded["re2_vr_reload_ext_3"] = M
return M
