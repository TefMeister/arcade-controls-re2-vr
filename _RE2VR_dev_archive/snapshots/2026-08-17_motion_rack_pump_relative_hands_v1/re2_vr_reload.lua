
if reframework:get_game_name() ~= "re2" then
    return {}
end

local re2 = require("utility/RE2")
local statics = require("utility/Statics")
local NS = sdk.game_namespace

local CFG_PATH = "re2_vr/re2_vr_reload.json"

local DEFAULT_CFG = {
    enabled = true,
    block_native_pump = true,
    native_pump = {
        pump_window_sec = 2.5,
        pump_cycle_min_progress = 0.20,
        re2_blowback_min_progress = 0.08,
        re2_player_pump_min_progress = 0.0,
        block_wwise_in_pump_window = true,
        block_wwise_triggers = true,
        scrub_weapon_motion = true,
        scrub_player_motion = true,
        scrub_pump_cycle = true,
        when_equipped = true,
        spoof_is_reload = true,
        default_shotgun_pump = true,
        weapon_motion_layers = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        player_motion_layers = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    },
    manual_pump = {
        enabled = true,
        pull_dist_default = 0.05,
        push_dist_default = 0.03,
        pull_deadzone = 0.004,
        pull_axis_sign = 1.0,
        support_blend_speed = 2.0,
        -- Speed (in "0..1 travel per second") of the eased pump-joint
        -- animation driven by the left trigger. Higher = snappier.
        -- pull_travel_speed:  parked -> pulled-back, on trigger press
        -- push_travel_speed:  pulled-back -> rest,   on trigger release
        pull_travel_speed = 7.0,
        push_travel_speed = 5.0,
        autodock_skip_blend_m = 0.12,
        default_shotgun_pump = true,
        pump_node_by_wp = {
            wp1000 = "_01",
            wp1100 = "_01",
            wp1200 = "_01",
            wp1300 = "_01",
            wp1500 = "_01",
        },
        pump_bind_default = { rest_z = 0.0, parked_z = 0.0, back_z = -0.08 },
        pump_bind_by_wp = {},
    },
    suppress_reload_ik = true,
    mag_node_by_wp = {
        wp0000 = "_04",
        wp0100 = "_01",
        wp0200 = "_04",
        wp0300 = "_04",
        wp0400 = "_01",
        wp0600 = "_01",
        wp3200 = "_04",
    },
    mag_exit_default = { x = 0.0, y = -0.103, z = -0.035, pitch = 0.0, yaw = 0.0, roll = 0.0 },
    mag_exit_by_wp = {
        wp0000 = { x = 0.0, y = -0.11, z = -0.04 },
        -- This is the ACTUAL bullet-insertion dock point (measured against
        -- in measure_bullet_insert_local_distance) -- not bullet_joint_by_wp/
        -- bullet_dock_offset_by_wp, which only affect extracting a spent
        -- shell, a separate feature. wp0800 had no entry here at all before,
        -- so it was using mag_exit_default verbatim. Starting from that
        -- default and nudging left/up/toward-muzzle per the player's ask,
        -- reusing the same sign convention already confirmed for this
        -- weapon (+x = left, +z = toward muzzle) -- not yet confirmed this
        -- local space shares that convention, needs a live test.
        wp0800 = { x = 0.03, y = -0.083, z = -0.015 },
    },
    mesh_parts_by_wp = {
        wp0200 = { 2 },
        wp2000 = { 1 },
    },
    shotgun_shell = {
        enabled = true,
        dock_dist_default = 0.22,
        dock_cooldown = 0.45,
        shell_hand = { ox = 0.0, oy = 0.0, oz = 0.0, yaw = 0.0, pitch = 0.0, roll = 0.0 },
    },
    shell_joint_by_wp = {
        wp1000 = "_04",
        wp1100 = "_04",
        wp1200 = "_04",
        wp1500 = "_04",
    },
    shell_mesh_parts_by_wp = {
        wp1000 = { 31 },
        wp1100 = { 31 },
        wp1200 = { 31 },
        wp1500 = { 31 },
    },
    shell_spawn_by_wp = {},
    revolver_reload = {
        enabled = true,
        open_lerp_rate = 6.0,
        dock_dist_default = 0.20,
        chamber_grab_dist_default = 0.28,
        dock_cooldown = 0.45,
        close_gesture_enabled = true,
        close_gesture_swipe_speed = 0.55,
        close_gesture_swipe_dist = 0.025,
        close_gesture_lateral_ratio = 0.45,
        close_gesture_max_vertical_ratio = 0.45,
        close_gesture_window_min = 0.035,
        close_gesture_window_max = 0.17,
        close_gesture_up_swipe_speed = 0.55,
        close_gesture_up_swipe_dist = 0.025,
        close_gesture_up_ratio = 0.5,
        close_gesture_delay_sec = 0.1,
        close_gesture_cooldown_sec = 0.8,
    },
    cylinder_joint_by_wp = {
        wp0300 = "_04",
        wp3200 = "_04",
        wp0800 = "_01",
    },
    bullet_joint_by_wp = {
        wp0300 = "_04",
        wp3200 = "_04",
        -- Missing entirely before this -- fell back to the hardcoded "_04"
        -- default (see get_bullet_joint's fallback chain in
        -- re2_vr_reload_ext_3.lua), which isn't the cylinder joint on this
        -- weapon's mesh, unlike wp0300/wp3200 where "_04" happens to be
        -- correct for their own meshes.
        -- Attempt 1: "_01" (cylinder_joint_by_wp's value, the pivot joint) --
        -- tested, still landed toward the back of the gun. Makes sense: a
        -- cylinder's pivot/crane attaches at the rear of the frame, not the
        -- drum face.
        -- Attempt 2: one of the individual chamber-slot joints instead
        -- (bullet_chamber_nodes_by_wp.wp0800 = "_10".."_15") -- these should
        -- be the actual bullet positions on the drum face itself.
        wp0800 = "_10",
    },
    -- REVERTED (2026-08-07): this whole detour was tuning a code path SLS60
    -- doesn't actually use for bullet insertion -- get_bullet_chamber_nodes(wp0800)
    -- being non-nil means rv.target resolves via get_hand_bullet_node_name's
    -- chamber-node branch, never touching bullet_joint_by_wp at all. Worse,
    -- since this offset applied unconditionally to rv.rest_x/y/z regardless
    -- of which resolution path set rv.target, it was corrupting the TRUE
    -- chamber joint position that the insert animation fix below now relies
    -- on. Left at zero going forward; the real fix for both the grab-point
    -- and the visual-landing-spot issues lives in mag_exit_by_wp (JSON,
    -- tuned live) and begin_bullet_insert_anim's chamber-aware end target
    -- (see re2_vr_reload_ext_3.lua).
    bullet_dock_offset_by_wp = {
        wp0800 = { x = 0.0, y = 0.0, z = 0.0 },
    },
    bullet_chamber_nodes_by_wp = {
        wp0300 = { "_10", "_11", "_12", "_13", "_14", "_15" },
        wp3200 = { "_10", "_11", "_12", "_13", "_14", "_15" },
        wp0800 = { "_10", "_11", "_12", "_13", "_14", "_15" },
    },
    bullet_barrel_node_by_wp = {
        wp0300 = "_16",
        wp0800 = "_17",
    },
    bullet_mesh_parts_by_wp = {
        wp3200 = { 10, 11, 12, 13, 14, 15 },
    },
    cylinder_open_angle_by_wp = {
        wp0300 = { swing = -90.0, chamber = -30.0 },
        wp3200 = { swing = -90.0, chamber = -30.0 },
    },
    anim = {
        drop_sec = 0.18,
        fall_sec = 0.5,
        fall_distance = 1.2,
        fall_local_y = -0.45,
        insert_sec = 0.18,
        drop_local_y = -0.12,
    },
    visual_hide = {
        mode = "scale",
    },
    mag_holster = {
        enabled = true,
        off_right = 0.0,
        off_up = 0.0,
        off_forward = 0.0,
        trigger_dist = 0.25,
        release_dist = 0.38,
        cooldown = 0.6,
        calibrate_delay_sec = 5.0,
        zone_haptic_enabled = true,
        zone_haptic_continuous = false,
        suppress_ambient_holster_haptics = false,
        zone_haptic_duration = 0.15,
        zone_haptic_frequency = 58.883,
        zone_haptic_amplitude = 0.05,
        zone_haptic_frames = 3,
        grab_haptic_duration = 0.057,
        grab_haptic_frequency = 169.385,
        grab_haptic_amplitude = 0.99,
        suppress_sub_weapon_in_zone = true,
        sub_weapon_grace_sec = 1.0,
        per_profile = {
            leon = { off_right = 0.0, off_up = 0.0, off_forward = 0.0 },
            claire = { off_right = 0.0, off_up = 0.0, off_forward = 0.0 },
            ada = { off_right = 0.0, off_up = 0.0, off_forward = 0.0 },
            hunk = { off_right = 0.0, off_up = 0.0, off_forward = 0.0 },
            tofu = { off_right = 0.0, off_up = 0.0, off_forward = 0.0 },
        },
    },
    mag_hand_hold = {
        ox = 0.0,
        oy = 0.0,
        oz = 0.0,
        yaw = 0.0,
        pitch = 0.0,
        roll = 0.0,
    },
    mag_dock_default = 0.20,
    mag_dock_by_wp = {
        -- Ada's Broom Hc (wp0700) mag/hand model is smaller than the other
        -- characters' -- tuned live down from 0.10 through 0.08 to 0.06
        -- (see re2_vr_ada_chapter_status memory), but only the first
        -- guess (0.10) had ever made it into this default. Corrected here
        -- to match the value actually live in re2_vr_reload.json.
        wp0700 = 0.06,
    },
    slide_dock = {
        enabled = true,
        preview_sec = 6.0,
        dock_dist_default = 0.20,
        dock_blend_speed = 0.10,
        pull_dist_default = 0.05,
        push_dist_default = 0.03,
        pull_deadzone = 0.004,
        pull_axis_sign = 1.0,
        slide_node_by_wp = {
            wp0100 = "_02",
            wp0000 = "_01",
            wp0200 = "_01",
            wp0300 = "_04",
            wp3200 = "_04",
            wp1000 = "_01",
            wp1100 = "_01",
            wp1200 = "_01",
            wp1300 = "_01",
            wp1500 = "_01",
        },
        slide_bind_default = {
            x = 0.0,
            y = 0.0,
            rest_z = 0.06,
            parked_z = 0.04,
            back_z = 0.015,
            open_rot_pitch = 0.0,
            open_rot_yaw = 0.0,
            open_rot_roll = 0.0,
        },
        slide_bind_by_wp = {
            wp0100 = { y = 0.0, rest_z = 0.06, parked_z = 0.04, back_z = 0.015 },
            wp0000 = { y = 0.0, rest_z = 0.06, parked_z = 0.038, back_z = 0.013 },
            wp0200 = { y = 0.0, rest_z = 0.06, parked_z = 0.043, back_z = 0.018 },
            wp1000 = { rest_z = 0.0, parked_z = 0.0, back_z = -0.08 },
            wp1100 = { rest_z = 0.0, parked_z = 0.0, back_z = -0.08 },
            wp1200 = { rest_z = 0.0, parked_z = 0.0, back_z = -0.08 },
            wp1300 = { rest_z = 0.0, parked_z = 0.0, back_z = -0.08 },
            wp1500 = { rest_z = 0.0, parked_z = 0.0, back_z = -0.08 },
        },
        slide_dock_default = {
            dock_off_x = 0.0,
            dock_off_y = 0.0,
            dock_off_z = 0.0,
            hand_pos_x = 0.0,
            hand_pos_y = 0.0,
            hand_pos_z = 0.0,
            hand_rot_pitch = 0.0,
            hand_rot_yaw = 0.0,
            hand_rot_roll = 0.0,
        },
        slide_dock_by_wp = {},
        no_rack_required_by_wp = {},
        dock_dist_by_wp = {},
        slide_ik_twist_default = {
            enabled = true,
            bend_sign = -1.0,
            elbow_pole_mix = 0.58,
            upper_pole_mix = 0.0,
            pole_off_x = 0.0,
            pole_off_y = 0.0,
            pole_off_z = 0.0,
            pole_rot_pitch = 0.0,
            pole_rot_yaw = 0.0,
            pole_rot_roll = 0.0,
            hand_off_x = 0.0,
            hand_off_y = 0.0,
            hand_off_z = 0.0,
            clavicle = { pos_x = 0.0, pos_y = 0.0, pos_z = 0.0, rot_pitch = 0.0, rot_yaw = 0.0, rot_roll = 0.0 },
            upper = { pos_x = 0.0, pos_y = 0.0, pos_z = 0.0, rot_pitch = 0.0, rot_yaw = 0.0, rot_roll = 0.0 },
            lower = { pos_x = 0.0, pos_y = 0.0, pos_z = 0.0, rot_pitch = 0.0, rot_yaw = 0.0, rot_roll = 0.0 },
            wrist = { pos_x = 0.0, pos_y = 0.0, pos_z = 0.0, rot_pitch = 0.0, rot_yaw = 0.0, rot_roll = 0.0 },
        },
        slide_ik_twist_by_wp = {},
    },
    left_hand_pose = {
        apply_enabled = false,
        blend_sec = 0.12,
        preview_sec = 5.0,
        mag_hold = {
            apply_enabled = true,
            pose = {},
        },
        slide_rack = {
            apply_enabled = false,
            pose = {},
        },
        shell_hold = {
            apply_enabled = true,
            pose = {},
        },
        bullet_hold = {
            apply_enabled = true,
            pose = {},
        },
    },
    weapon_sfx = {
        enabled = true,
        master_volume = 1.0,
        spatial = true,
        default_fallback_wp = "wp1000",
        volume_by_kind = {},
        by_wp = {},
    },
    weapons = {
        -- 2026-08-14: motion-tracked pull tested (player's explicit request,
        -- after tonight's camera-relative + grip-debounce fixes to the
        -- shared slide-rack dock system) and confirmed NOT working -- grab/
        -- dock detection worked fine (near=true, joint reaching the anchor
        -- repeatedly per slide_rack_dist_probe logging) but real hand
        -- motion produced no pull at all. Likely cause not confirmed
        -- (didn't chase it down live) -- leading suspect is the pull-axis
        -- resolution or rack.pull_increases_signed sign convention in
        -- compute_controller_delta_pull/update_rack_pull being stale/wrong
        -- for Matilda specifically, since nothing has exercised this
        -- weapon's non-trigger path since the original 2026-07-31
        -- conversion (see [[re2_vr_slide_rack_trigger_status]]). Reverted
        -- to the confirmed-working trigger-driven pull. If revisited, start
        -- with live logging on compute_controller_delta_pull's signed/
        -- pull_ax,ay,az/pull_axis_src output, same instrumentation pattern
        -- used for the other fixes this session.
        wp0000 = { enabled = true, label = "Matilda", trigger_slide_rack = true },
        wp0100 = { enabled = true, label = "M19", trigger_slide_rack = true },
        wp0200 = { enabled = true, label = "JMB Hp3", trigger_slide_rack = true },
        wp0300 = { enabled = false, needs_manual_cylinder_reload = false, no_slide_rack_required = true, label = "Quickdraw Army" },
        wp0400 = { enabled = false, label = "Glock 17", trigger_slide_rack = true },
        wp0600 = { enabled = false, label = "MUP", trigger_slide_rack = true },
        wp0700 = { enabled = true, label = "Broom Hc", trigger_slide_rack = true },
        wp0800 = { enabled = false, label = "SLS 60", chamber_grab_dist = 0.5 }, -- default is 0.28; roughly doubled as a forgiving-radius test
        wp1000 = { enabled = false, label = "W-870", block_native_pump = true, needs_manual_pump = true, needs_manual_shell_reload = true, no_slide_rack_required = true },
        wp1100 = { enabled = false, label = "Remington 870", block_native_pump = true, needs_manual_pump = true, needs_manual_shell_reload = true, no_slide_rack_required = true },
        wp1200 = { enabled = false, label = "M3 Shotgun", block_native_pump = true, needs_manual_pump = true, needs_manual_shell_reload = true, no_slide_rack_required = true },
        wp1300 = { enabled = false, label = "GM 79", block_native_pump = true, needs_manual_pump = true, no_slide_rack_required = true },
        wp1500 = { enabled = false, label = "Lightning Hawk (shotgun)", block_native_pump = true, needs_manual_pump = true, needs_manual_shell_reload = true, no_slide_rack_required = true },
        wp2000 = { enabled = false, label = "MQ 11", trigger_slide_rack = true },
        wp2200 = { enabled = false, label = "LE 5", trigger_slide_rack = true },
        wp3000 = { enabled = true, label = "Lightning Hawk", trigger_slide_rack = true },
        wp3200 = { enabled = false, needs_manual_cylinder_reload = false, no_slide_rack_required = true, label = "Chief Irons Revolver" },
        wp4100 = { enabled = false, label = "GM 79", reload_drop_slots = 1, bullet_follows_cylinder_open = true, keep_spent_chamber_bullet = true },
        wp4200 = { enabled = false, label = "Chemical Flamethrower" },
        wp4300 = { enabled = false, label = "Spark Shot" },
        wp4400 = { enabled = false, label = "ATM-4" },
        wp4600 = { enabled = false, label = "Anti-Tank Rocket" },
        wp4700 = { enabled = false, label = "Minigun" },
        wp7000 = { enabled = false, label = "Samurai Edge" },
        wp7010 = { enabled = false, label = "Samurai Edge (Chris)" },
        wp7020 = { enabled = false, label = "Samurai Edge (Jill)" },
        wp7030 = { enabled = false, label = "Samurai Edge (Albert)" },
    },
}

local CFG = {}
local hooks_installed = false
local reload_hooks_count = 0
local isreload_hook_installed = false
local hooked_signatures = {}

local InputKindEnum = statics.generate(NS("InputDefine.Kind"))
local INPUT_KIND_ATTACK = InputKindEnum.ATTACK or 4

local PetientOrderEnum = statics.generate(NS("SurvivorDefine.ActionOrder.Petient"))
local INPUT_KIND_HOLD = InputKindEnum.HOLD or 64
local INPUT_KIND_SUPPORT_HOLD = InputKindEnum.SUPPORT_HOLD or 128
local INPUT_KIND_UI_SHIFT_LEFT = InputKindEnum.UI_SHIFT_LEFT or 268435456
local INPUT_KIND_UI_SHIFT_RIGHT = InputKindEnum.UI_SHIFT_RIGHT or 536870912
local INPUT_SUPPRESS_LEFT_SUPPORT_MASK = INPUT_KIND_SUPPORT_HOLD | INPUT_KIND_UI_SHIFT_LEFT
local INPUT_SUPPRESS_RIGHT_HOLD_MASK = INPUT_KIND_HOLD | INPUT_KIND_UI_SHIFT_RIGHT
local PATIENT_ORDER_HOLD_WALK = PetientOrderEnum.HOLD_WALK or 64

local player_action_orderer_type = sdk.typeof(NS("survivor.player.PlayerActionOrderer"))
local mag_sub_suppress = { active = false }
local force_clear_mag_holster_left_support_suppress
local vr_input_suppress_hooks_installed = false

local frame_vr_reload_b = false
local frame_vr_grip_trigger = false
local frame_weapon_needs_reload = false
local grip_action_cache = nil
local trigger_action_cache = nil

local BUTTON_FIELD_OFFSET = { Down = 0x10, On = 0x18, Up = 0x20 }

local suppress = {
    until_t = 0.0,
    precede_active = false,
    change_bullet = { active = false, saw_native = false, wp = nil, until_t = 0.0, hold_sec = 6.0 },
}
local ammo = { internal_commit = false }
local frame = {
    vr_reload_b = false,
    weapon_needs_reload = false,
    vr_grip_trigger = false,
    vr_right_trigger = false,
}
local locomotion_state = {
    moving_until = 0.0,
    last_x = nil,
    last_z = nil,
}
local LOCOMOTION_MOVE_THRESH = 0.06
local LOCOMOTION_HOLD_SEC = 0.15
local action_orderer_strip_hook_installed = false
local native_reload_precede_inhibit_active = false
local clear_native_reload_precede_inhibit_now
local prev_frame_vr_reload_b = false
local prev_weapon_wp = nil
local play_session_token = nil
local play_session_unloaded = false
local play_session_pending_save_load = false
local play_session_death_latched = false

local SAVE_LOAD_STEP_LOAD_WAIT = 3
local save_load_watch = {
    saw_load_wait = false,
    saw_load_busy = false,
    saw_main_flow_load = false,
    load_transition_armed = false,
}
local pending_reload_stack_reset = false
local pending_reload_stack_reset_reason = nil
local pending_reload_stack_reset_frames = 0

local function is_load_cleared_reset_reason(reason)
    return reason == "load_busy_cleared"
        or reason == "load_wait_cleared"
        or reason == "main_flow_load_cleared"
        or reason == "player_ready_after_save_load"
end

local function request_reload_stack_reset(reason)
    local was_pending = pending_reload_stack_reset == true
    pending_reload_stack_reset = true
    pending_reload_stack_reset_reason = tostring(reason or "unknown")
    if not was_pending then
        pending_reload_stack_reset_frames = 0
    end
end

local fire_hook_installed = false
local prev_bullet_count = nil


local mesh_type = sdk.typeof("via.render.Mesh")


local function sc(obj, method, ...)
    if not obj then return nil end
    local ok, val = pcall(function(...)
        return obj:call(method, ...)
    end, ...)
    if ok then return val end
    return nil
end

local function get_world_state_fingerprint()
    local parts = {}

    local im = sdk.get_managed_singleton(NS("gamemastering.InventoryManager"))
    if im then
        local ok, cur = pcall(function() return im:call("get_CurrentInventory") end)
        if ok and cur then
            parts[#parts + 1] = "ginv:" .. tostring(cur)
        end
    end

    local inv = re2.inventory
    if inv then
        parts[#parts + 1] = "inv:" .. tostring(inv)
        local slot = sc(inv, "get_MainSlot")
        if slot then
            parts[#parts + 1] = string.format(
                "slot:%s:%s:%s",
                tostring(sc(slot, "get_Number")),
                tostring(sc(slot, "get_BulletID")),
                tostring(sc(slot, "get_VacancyNumber")))
        end
    end

    local weapon = re2.weapon
    if weapon then
        parts[#parts + 1] = "bn:" .. tostring(sc(weapon, "getBulletNumber"))
    end

    if #parts == 0 then return nil end
    return table.concat(parts, "|")
end

local function get_play_session_token()
    local player = re2.get_localplayer()
    if not player then return nil end

    local parts = { "p:" .. tostring(player) }
    if re2.inventory then parts[#parts + 1] = "i:" .. tostring(re2.inventory) end
    if re2.weapon then parts[#parts + 1] = "w:" .. tostring(re2.weapon) end
    if re2.weapon_gameobject then parts[#parts + 1] = "g:" .. tostring(re2.weapon_gameobject) end

    local mfm = sdk.get_managed_singleton(NS("gamemastering.MainFlowManager"))
    if mfm then
        local gid = sc(mfm, "get_GameGUID")
        if gid ~= nil then parts[#parts + 1] = "guid:" .. tostring(gid) end
    end

    return table.concat(parts, "|")
end

local function enum_to_int(v)
    if v == nil then return nil end
    if type(v) == "number" then return math.floor(v) end
    if type(v) == "string" then
        local n = v:match("%((%-?%d+)%)%s*$") or v:match("%((%-?%d+)%)")
        if n then return tonumber(n) end
        return tonumber(v)
    end
    local ok, n = pcall(function() return v:get_field("value__") end)
    if ok and type(n) == "number" then return math.floor(n) end
    ok, n = pcall(function()
        local s = tostring(v)
        return tonumber(s:match("%((%-?%d+)%)%s*$") or s:match("%((%-?%d+)%)"))
    end)
    if ok and type(n) == "number" then return math.floor(n) end
    return nil
end

local function get_save_load_step()
    local mgr = sdk.get_managed_singleton(NS("gamemastering.SaveDataManager"))
    if not mgr then return nil end

    local ok, v = pcall(function() return mgr:call("get_saveLoadStep") end)
    if ok and v ~= nil then
        local n = enum_to_int(v)
        if n ~= nil then return n end
    end

    for _, fname in ipairs({
        "<saveLoadStep>k__BackingField",
        "_saveLoadStep",
        "saveLoadStep",
    }) do
        local ok2, fv = pcall(function() return mgr:get_field(fname) end)
        if ok2 and fv ~= nil then
            local n = enum_to_int(fv)
            if n ~= nil then return n end
        end
    end

    return nil
end

local function is_save_load_busy_active()
    local mgr = sdk.get_managed_singleton(NS("gamemastering.SaveDataManager"))
    if mgr and sc(mgr, "get_IsLoadBusy") == true then
        return true
    end
    local mfm = sdk.get_managed_singleton(NS("gamemastering.MainFlowManager"))
    if mfm and (sc(mfm, "get_IsInLoadGameData") == true or sc(mfm, "get_IsLoadGame") == true) then
        return true
    end
    local step = get_save_load_step()
    if step == SAVE_LOAD_STEP_LOAD_WAIT then
        return true
    end
    return false
end

local function is_load_transition_active()
    return is_save_load_busy_active()
end

local function refresh_re2_weapon_cache()
    local player = re2.get_localplayer()
    if not player then
        re2.weapon = nil
        re2.weapon_gameobject = nil
        re2.inventory = nil
        return false
    end
    local weapon_go, weapon = re2.get_weapon_object(player)
    if not weapon_go or not weapon then
        re2.weapon = nil
        re2.weapon_gameobject = nil
        re2.inventory = re2.get_inventory(player)
        return false
    end
    re2.weapon = weapon
    re2.weapon_gameobject = weapon_go
    re2.inventory = re2.get_inventory(player)
    return true
end

local function is_player_dead_or_incapacitated()
    local player = re2.get_localplayer()
    if not player then return false end

    local eq_type = sdk.typeof(NS("survivor.Equipment"))
    if eq_type then
        local ok, eq = pcall(function()
            return player:call("getComponent(System.Type)", eq_type)
        end)
        if ok and eq and re2.weapon then
            local wt = sc(re2.weapon, "get_WeaponType")
            if wt ~= nil then
                local ratio = sc(eq, "getSlotVitalRatio", wt)
                if type(ratio) == "number" and ratio <= 0.0 then
                    return true
                end
                local vital = sc(eq, "getSlotVital", wt)
                if type(vital) == "number" and vital <= 0 then
                    return true
                end
            end
        end
    end

    local cond_type = sdk.typeof(NS("survivor.SurvivorCondition"))
    if cond_type then
        local ok, cond = pcall(function()
            return player:call("getComponent(System.Type)", cond_type)
        end)
        if ok and cond then
            for _, method in ipairs({ "get_IsDead", "get_IsDamage" }) do
                if sc(cond, method) == true then
                    return true
                end
            end
        end
    end

    return false
end

local function tick_death_stack_reset()
    if is_load_transition_active() then
        play_session_death_latched = false
        return
    end
    local dead = is_player_dead_or_incapacitated()
    if dead then
        play_session_death_latched = true
        return
    end

    if play_session_death_latched and re2.get_localplayer() then
        play_session_death_latched = false
        request_reload_stack_reset("player_death_respawn")
    end
end

local function tick_save_load_watch()
    local mgr = sdk.get_managed_singleton(NS("gamemastering.SaveDataManager"))
    local step_raw = get_save_load_step()
    local step = step_raw
    local busy = false
    local in_load = false
    local mfm = sdk.get_managed_singleton(NS("gamemastering.MainFlowManager"))
    if mfm then
        in_load = sc(mfm, "get_IsInLoadGameData") == true or sc(mfm, "get_IsLoadGame") == true
    end
    if mgr then
        busy = sc(mgr, "get_IsLoadBusy") == true
        if busy then
            save_load_watch.saw_load_busy = true
            if in_load or re2.get_localplayer() then
                save_load_watch.load_transition_armed = true
            end
        elseif save_load_watch.saw_load_busy then
            save_load_watch.saw_load_busy = false
            if save_load_watch.load_transition_armed then
                save_load_watch.load_transition_armed = false
                request_reload_stack_reset("load_busy_cleared")
            end
            if not re2.get_localplayer() then
                play_session_pending_save_load = true
            end
        end
    end

    if step ~= nil then
        if step == SAVE_LOAD_STEP_LOAD_WAIT then
            save_load_watch.saw_load_wait = true
            save_load_watch.load_transition_armed = true
        elseif save_load_watch.saw_load_wait then
            save_load_watch.saw_load_wait = false
            request_reload_stack_reset("load_wait_cleared")
            if not re2.get_localplayer() then
                play_session_pending_save_load = true
            end
        end
    end

    if mfm then
        if in_load then
            save_load_watch.saw_main_flow_load = true
            save_load_watch.load_transition_armed = true
        elseif save_load_watch.saw_main_flow_load then
            save_load_watch.saw_main_flow_load = false
            if save_load_watch.load_transition_armed or re2.get_localplayer() then
                request_reload_stack_reset("main_flow_load_cleared")
            end
        end
    end

    if not is_save_load_busy_active() then
        save_load_watch.saw_load_busy = false
        save_load_watch.saw_load_wait = false
    end
end

local function tick_reload_stack_reset()
    tick_save_load_watch()
    tick_death_stack_reset()

    local token = get_play_session_token()

    if token == nil then
        if play_session_token ~= nil then
            if is_load_transition_active() then
                request_reload_stack_reset("session_exit_deferred")
            else
                play_session_unloaded = true
                request_reload_stack_reset("session_exit")
            end
        end
        play_session_token = nil
        return
    end

    if play_session_unloaded then
        play_session_unloaded = false
        if not is_load_transition_active() then
            request_reload_stack_reset("player_unloaded")
        end
    elseif play_session_pending_save_load then
        play_session_pending_save_load = false
        request_reload_stack_reset("player_ready_after_save_load")
    elseif play_session_token ~= nil and play_session_token ~= token then
        if not is_load_transition_active() then
            if reload_mag and reload_mag.invalidate_weapon_cache then
                reload_mag.invalidate_weapon_cache()
            end
            if reload_slide and reload_slide.invalidate_weapon_cache then
                reload_slide.invalidate_weapon_cache()
            end
        end
    end

    play_session_token = token
end

local function deep_copy(tbl)
    if type(tbl) ~= "table" then return tbl end
    local out = {}
    for k, v in pairs(tbl) do
        out[k] = deep_copy(v)
    end
    return out
end

local function merge_cfg(base, loaded)
    if type(loaded) ~= "table" then return end
    for k, v in pairs(loaded) do
        if k == "weapons" and type(v) == "table" then
            base.weapons = base.weapons or {}
            for wp, entry in pairs(v) do
                if type(entry) == "table" then
                    base.weapons[wp] = base.weapons[wp] or {}
                    for ek, ev in pairs(entry) do
                        base.weapons[wp][ek] = ev
                    end
                end
            end
        elseif k == "mag_node_by_wp" and type(v) == "table" then
            base.mag_node_by_wp = base.mag_node_by_wp or {}
            for wp, node in pairs(v) do
                base.mag_node_by_wp[wp] = node
            end
        elseif k == "mag_exit_by_wp" and type(v) == "table" then
            base.mag_exit_by_wp = base.mag_exit_by_wp or {}
            for wp, exit in pairs(v) do
                if type(exit) == "table" then
                    base.mag_exit_by_wp[wp] = base.mag_exit_by_wp[wp] or {}
                    for ek, ev in pairs(exit) do
                        base.mag_exit_by_wp[wp][ek] = ev
                    end
                end
            end
        elseif k == "mag_dock_by_wp" and type(v) == "table" then
            base.mag_dock_by_wp = base.mag_dock_by_wp or {}
            for wp, dist in pairs(v) do
                if type(dist) == "number" then
                    base.mag_dock_by_wp[wp] = dist
                end
            end
        elseif k == "mesh_parts_by_wp" and type(v) == "table" then
            base.mesh_parts_by_wp = base.mesh_parts_by_wp or {}
            for wp, parts in pairs(v) do
                base.mesh_parts_by_wp[wp] = parts
            end
        elseif k == "left_hand_pose" and type(v) == "table" then
            base.left_hand_pose = base.left_hand_pose or {}
            for sk, sv in pairs(v) do
                if (sk == "mag_hold" or sk == "slide_rack") and type(sv) == "table" then
                    base.left_hand_pose[sk] = base.left_hand_pose[sk] or {}
                    for pk, pv in pairs(sv) do
                        if pk == "by_wp" and type(pv) == "table" then
                            base.left_hand_pose[sk].by_wp = base.left_hand_pose[sk].by_wp or {}
                            for wp, wp_entry in pairs(pv) do
                                if type(wp_entry) == "table" then
                                    base.left_hand_pose[sk].by_wp[wp] = base.left_hand_pose[sk].by_wp[wp] or {}
                                    for prof, prof_entry in pairs(wp_entry) do
                                        if type(prof_entry) == "table" then
                                            base.left_hand_pose[sk].by_wp[wp][prof] = base.left_hand_pose[sk].by_wp[wp][prof] or {}
                                            for ek, ev in pairs(prof_entry) do
                                                if ek == "pose" and type(ev) == "table" then
                                                    base.left_hand_pose[sk].by_wp[wp][prof].pose = base.left_hand_pose[sk].by_wp[wp][prof].pose or {}
                                                    for bone, ang in pairs(ev) do
                                                        base.left_hand_pose[sk].by_wp[wp][prof].pose[bone] = ang
                                                    end
                                                else
                                                    base.left_hand_pose[sk].by_wp[wp][prof][ek] = ev
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        elseif pk == "pose" and type(pv) == "table" then
                            base.left_hand_pose[sk].pose = base.left_hand_pose[sk].pose or {}
                            for bone, ang in pairs(pv) do
                                base.left_hand_pose[sk].pose[bone] = ang
                            end
                        else
                            base.left_hand_pose[sk][pk] = pv
                        end
                    end
                else
                    base.left_hand_pose[sk] = sv
                end
            end
        elseif k == "mag_hand_hold" and type(v) == "table" then
            base.mag_hand_hold = base.mag_hand_hold or {}
            for pk, pv in pairs(v) do
                if pk == "by_wp" and type(pv) == "table" then
                    base.mag_hand_hold.by_wp = base.mag_hand_hold.by_wp or {}
                    for wp, wp_entry in pairs(pv) do
                        if type(wp_entry) == "table" then
                            base.mag_hand_hold.by_wp[wp] = base.mag_hand_hold.by_wp[wp] or {}
                            for prof, prof_entry in pairs(wp_entry) do
                                if type(prof_entry) == "table" then
                                    base.mag_hand_hold.by_wp[wp][prof] = base.mag_hand_hold.by_wp[wp][prof] or {}
                                    for ek, ev in pairs(prof_entry) do
                                        base.mag_hand_hold.by_wp[wp][prof][ek] = ev
                                    end
                                end
                            end
                        end
                    end
                else
                    base.mag_hand_hold[pk] = pv
                end
            end
        elseif type(v) == "table" and type(base[k]) == "table" then
            for sk, sv in pairs(v) do
                base[k][sk] = sv
            end
        else
            base[k] = v
        end
    end
end

local function repair_shotgun_shell_reload_flags(cfg)
    if type(cfg.shell_joint_by_wp) ~= "table" or type(cfg.weapons) ~= "table" then return end
    for wp, joint in pairs(cfg.shell_joint_by_wp) do
        if type(joint) == "string" and joint ~= "" then
            local entry = cfg.weapons[wp]
            if type(entry) == "table" and entry.needs_manual_pump == true
                and entry.needs_manual_shell_reload == false then
                entry.needs_manual_shell_reload = true
            end
        end
    end
end

local function migrate_cfg(cfg)
    repair_shotgun_shell_reload_flags(cfg)
    if type(cfg.weapons) == "table" then
        for _, entry in pairs(cfg.weapons) do
            if type(entry) == "table"
                and entry.needs_manual_revolver_reload == true
                and entry.needs_manual_cylinder_reload ~= true then
                entry.needs_manual_cylinder_reload = true
            end
        end
    end
    local rr = cfg.revolver_reload
    if type(rr) ~= "table" then return end
    if (tonumber(rr.close_gesture_migrate_rev) or 0) >= 2 then return end
    local function bump_num(key, new_val, old_val)
        local v = tonumber(rr[key])
        if v == nil or math.abs(v - old_val) < 1e-6 then
            rr[key] = new_val
        end
    end
    bump_num("close_gesture_swipe_speed", 0.55, 0.75)
    bump_num("close_gesture_swipe_dist", 0.025, 0.035)
    bump_num("close_gesture_lateral_ratio", 0.45, 0.55)
    bump_num("close_gesture_max_vertical_ratio", 0.45, 0.4)
    bump_num("close_gesture_window_min", 0.035, 0.045)
    bump_num("close_gesture_window_max", 0.17, 0.14)
    bump_num("close_gesture_up_swipe_speed", 0.55, 0.75)
    bump_num("close_gesture_up_swipe_dist", 0.025, 0.035)
    bump_num("close_gesture_up_ratio", 0.5, 0.6)
    rr.close_gesture_migrate_rev = 2
end

local function load_cfg()
    CFG = deep_copy(DEFAULT_CFG)
    local loaded = json.load_file(CFG_PATH)
    merge_cfg(CFG, loaded)
    migrate_cfg(CFG)
end

local function save_cfg()
    pcall(function()
        json.dump_file(CFG_PATH, CFG)
    end)
end

local TUNING_CFG_KEYS = {
    "mag_holster",
    "mag_hand_hold",
    "mag_dock_default",
    "mag_dock_by_wp",
    "mag_exit_default",
    "mag_exit_by_wp",
    "slide_dock",
    "left_hand_pose",
    "anim",
    "shotgun_shell",
    "shell_spawn_by_wp",
    "shell_joint_by_wp",
    "shell_mesh_parts_by_wp",
}

local tuning_snapshot = nil
local tuning_ui = {
    dirty = false,
    status = nil,
}

local function snapshot_tuning(cfg)
    local out = {}
    for _, key in ipairs(TUNING_CFG_KEYS) do
        out[key] = deep_copy(cfg[key])
    end
    return out
end

local function apply_tuning_snapshot(cfg, snap)
    if type(snap) ~= "table" then return false end
    for _, key in ipairs(TUNING_CFG_KEYS) do
        if snap[key] ~= nil then
            cfg[key] = deep_copy(snap[key])
        end
    end
    return true
end

local function refresh_tuning_snapshot()
    tuning_snapshot = snapshot_tuning(CFG)
    tuning_ui.dirty = false
end

local function mark_tuning_dirty()
    tuning_ui.dirty = true
    tuning_ui.status = nil
end

local setup_ui = {
    status = nil,
}

local SETUP_TEMPLATE_WP = "wp0100"
local SETUP_TEMPLATE_PROFILE = "leon"

local function get_setup_profile_keys()
    local keys = {}
    local mh = CFG.mag_holster and CFG.mag_holster.per_profile
    if type(mh) == "table" then
        for k, _ in pairs(mh) do
            keys[#keys + 1] = k
        end
    end
    if #keys == 0 then
        keys = { "leon", "claire", "ada", "hunk", "tofu" }
    end
    table.sort(keys)
    return keys
end

local function copy_mag_hand_hold_template(wp)
    local root = CFG.mag_hand_hold
    if type(root) ~= "table" or type(root.by_wp) ~= "table" then return false end
    local tpl = root.by_wp[SETUP_TEMPLATE_WP]
    tpl = tpl and tpl[SETUP_TEMPLATE_PROFILE]
    if type(tpl) ~= "table" then return false end

    root.by_wp[wp] = root.by_wp[wp] or {}
    local created = false
    for _, prof in ipairs(get_setup_profile_keys()) do
        if root.by_wp[wp][prof] == nil then
            root.by_wp[wp][prof] = deep_copy(tpl)
            created = true
        end
    end
    return created
end

local function copy_lhp_context_template(ctx_key, wp)
    local ctx = CFG.left_hand_pose and CFG.left_hand_pose[ctx_key]
    if type(ctx) ~= "table" or type(ctx.by_wp) ~= "table" then return false end
    local tpl_wp = ctx.by_wp[SETUP_TEMPLATE_WP]
    local tpl = tpl_wp and tpl_wp[SETUP_TEMPLATE_PROFILE]
    if type(tpl) ~= "table" then return false end

    ctx.by_wp[wp] = ctx.by_wp[wp] or {}
    local created = false
    for _, prof in ipairs(get_setup_profile_keys()) do
        local ent = ctx.by_wp[wp][prof]
        local needs = ent == nil
        if not needs and type(ent) == "table" and ent.pose == nil then
            needs = true
        end
        if needs then
            ctx.by_wp[wp][prof] = deep_copy(tpl)
            created = true
        end
    end
    return created
end

local function copy_slide_dock_template(wp)
    local sd = CFG.slide_dock
    if type(sd) ~= "table" then return false end
    local created = false

    sd.slide_node_by_wp = sd.slide_node_by_wp or {}
    if sd.slide_node_by_wp[wp] == nil or sd.slide_node_by_wp[wp] == "" then
        local tpl_node = sd.slide_node_by_wp[SETUP_TEMPLATE_WP]
        if tpl_node ~= nil then
            sd.slide_node_by_wp[wp] = tpl_node
            created = true
        end
    end

    sd.slide_bind_by_wp = sd.slide_bind_by_wp or {}
    if type(sd.slide_bind_by_wp[wp]) ~= "table" and type(sd.slide_bind_by_wp[SETUP_TEMPLATE_WP]) == "table" then
        sd.slide_bind_by_wp[wp] = deep_copy(sd.slide_bind_by_wp[SETUP_TEMPLATE_WP])
        created = true
    end

    sd.slide_dock_by_wp = sd.slide_dock_by_wp or {}
    if type(sd.slide_dock_by_wp[wp]) ~= "table" and type(sd.slide_dock_by_wp[SETUP_TEMPLATE_WP]) == "table" then
        sd.slide_dock_by_wp[wp] = deep_copy(sd.slide_dock_by_wp[SETUP_TEMPLATE_WP])
        created = true
    end

    sd.dock_dist_by_wp = sd.dock_dist_by_wp or {}
    if sd.dock_dist_by_wp[wp] == nil then
        local tpl_dist = sd.dock_dist_by_wp[SETUP_TEMPLATE_WP]
        if tpl_dist ~= nil then
            sd.dock_dist_by_wp[wp] = tpl_dist
        else
            sd.dock_dist_by_wp[wp] = tonumber(sd.dock_dist_default) or 0.20
        end
        created = true
    end

    sd.slide_ik_twist_by_wp = sd.slide_ik_twist_by_wp or {}
    if type(sd.slide_ik_twist_by_wp[wp]) ~= "table" and type(sd.slide_ik_twist_by_wp[SETUP_TEMPLATE_WP]) == "table" then
        sd.slide_ik_twist_by_wp[wp] = deep_copy(sd.slide_ik_twist_by_wp[SETUP_TEMPLATE_WP])
        created = true
    end

    return created
end

local function ensure_weapon_setup(wp)
    if type(wp) ~= "string" or wp == "" then return false end

    local created_any = false

    CFG.weapons = CFG.weapons or {}
    if type(CFG.weapons[wp]) ~= "table" then
        CFG.weapons[wp] = { enabled = false, label = wp }
        created_any = true
    else
        local e = CFG.weapons[wp]
        if e.label == nil then e.label = wp; created_any = true end
        if e.enabled == nil then e.enabled = false; created_any = true end
    end

    CFG.mag_node_by_wp = CFG.mag_node_by_wp or {}
    if CFG.mag_node_by_wp[wp] == nil or CFG.mag_node_by_wp[wp] == "" then
        local tpl_node = CFG.mag_node_by_wp[SETUP_TEMPLATE_WP]
        CFG.mag_node_by_wp[wp] = tpl_node or ""
        created_any = true
    end

    CFG.mag_exit_by_wp = CFG.mag_exit_by_wp or {}
    if type(CFG.mag_exit_by_wp[wp]) ~= "table" then
        CFG.mag_exit_default = CFG.mag_exit_default or {}
        CFG.mag_exit_by_wp[wp] = {
            x = tonumber(CFG.mag_exit_default.x) or 0.0,
            y = tonumber(CFG.mag_exit_default.y) or -0.103,
            z = tonumber(CFG.mag_exit_default.z) or -0.035,
            pitch = tonumber(CFG.mag_exit_default.pitch) or 0.0,
            yaw = tonumber(CFG.mag_exit_default.yaw) or 0.0,
            roll = tonumber(CFG.mag_exit_default.roll) or 0.0,
        }
        created_any = true
    end

    CFG.mag_dock_by_wp = CFG.mag_dock_by_wp or {}
    if CFG.mag_dock_by_wp[wp] == nil then
        CFG.mag_dock_by_wp[wp] = tonumber(CFG.mag_dock_default) or 0.20
        created_any = true
    end

    if copy_slide_dock_template(wp) then created_any = true end
    if copy_mag_hand_hold_template(wp) then created_any = true end
    if copy_lhp_context_template("mag_hold", wp) then created_any = true end
    if copy_lhp_context_template("slide_rack", wp) then created_any = true end
    if copy_lhp_context_template("shell_hold", wp) then created_any = true end
    if copy_lhp_context_template("bullet_hold", wp) then created_any = true end

    local entry = CFG.weapons[wp]
    if entry and weapon_needs_manual_cylinder_reload(wp) then
        local drop_slots = weapon_reload_drop_slots(wp)
        local single_shot = drop_slots <= 1
        CFG.cylinder_joint_by_wp = CFG.cylinder_joint_by_wp or {}
        if CFG.cylinder_joint_by_wp[wp] == nil then
            local sd = CFG.slide_dock or {}
            local slide_node = type(sd.slide_node_by_wp) == "table" and sd.slide_node_by_wp[wp]
            if single_shot and type(slide_node) == "string" and slide_node ~= "" then
                CFG.cylinder_joint_by_wp[wp] = slide_node
            else
                CFG.cylinder_joint_by_wp[wp] = "_04"
            end
            created_any = true
        elseif weapon_needs_manual_cylinder_reload(wp) then
            local sd = CFG.slide_dock or {}
            local slide_node = type(sd.slide_node_by_wp) == "table" and sd.slide_node_by_wp[wp]
            if type(slide_node) == "string" and slide_node ~= ""
                and CFG.cylinder_joint_by_wp[wp] ~= slide_node then
                CFG.cylinder_joint_by_wp[wp] = slide_node
                created_any = true
            end
        end
        CFG.bullet_joint_by_wp = CFG.bullet_joint_by_wp or {}
        if CFG.bullet_joint_by_wp[wp] == nil then
            CFG.bullet_joint_by_wp[wp] = CFG.mag_node_by_wp[wp] or "_04"
            created_any = true
        end
        CFG.bullet_mesh_parts_by_wp = CFG.bullet_mesh_parts_by_wp or {}
        if CFG.bullet_mesh_parts_by_wp[wp] == false then
            -- explicit joint-scale drop mode
        elseif type(CFG.bullet_mesh_parts_by_wp[wp]) ~= "table" then
            if single_shot then
                CFG.bullet_mesh_parts_by_wp[wp] = false
            else
                CFG.bullet_mesh_parts_by_wp[wp] = { 10, 11, 12, 13, 14, 15 }
            end
            created_any = true
        elseif single_shot and #CFG.bullet_mesh_parts_by_wp[wp] > 1 then
            CFG.bullet_mesh_parts_by_wp[wp] = false
            created_any = true
        end
        CFG.bullet_chamber_nodes_by_wp = CFG.bullet_chamber_nodes_by_wp or {}
        if CFG.bullet_chamber_nodes_by_wp[wp] == false then
            -- explicit single-joint scale mode
        elseif type(CFG.bullet_chamber_nodes_by_wp[wp]) ~= "table" then
            if single_shot then
                if CFG.bullet_chamber_nodes_by_wp[wp] == nil then
                    CFG.bullet_chamber_nodes_by_wp[wp] = false
                    created_any = true
                end
            else
                CFG.bullet_chamber_nodes_by_wp[wp] = { "_10", "_11", "_12", "_13", "_14", "_15" }
                created_any = true
            end
        elseif single_shot and #CFG.bullet_chamber_nodes_by_wp[wp] > 1 then
            CFG.bullet_chamber_nodes_by_wp[wp] = false
            created_any = true
        end
        if type(CFG.bullet_chamber_nodes_by_wp[wp]) == "table"
            and #CFG.bullet_chamber_nodes_by_wp[wp] > 0
            and CFG.bullet_mesh_parts_by_wp[wp] ~= false then
            CFG.bullet_mesh_parts_by_wp[wp] = false
            created_any = true
        end
        CFG.bullet_barrel_node_by_wp = CFG.bullet_barrel_node_by_wp or {}
        if CFG.bullet_barrel_node_by_wp[wp] == nil and wp == "wp0300" then
            CFG.bullet_barrel_node_by_wp[wp] = "_16"
            created_any = true
        end
        CFG.cylinder_open_angle_by_wp = CFG.cylinder_open_angle_by_wp or {}
        if type(CFG.cylinder_open_angle_by_wp[wp]) ~= "table" then
            CFG.cylinder_open_angle_by_wp[wp] = { swing = -90.0, chamber = -30.0 }
            created_any = true
        end
        CFG.slide_dock = CFG.slide_dock or {}
        CFG.slide_dock.slide_bind_by_wp = CFG.slide_dock.slide_bind_by_wp or {}
        if type(CFG.slide_dock.slide_bind_by_wp[wp]) ~= "table" then
            CFG.slide_dock.slide_bind_by_wp[wp] = {
                parked_z = 0.04,
                open_rot_pitch = 0.0,
                open_rot_yaw = 0.0,
                open_rot_roll = 0.0,
            }
            created_any = true
        end
        if entry.no_slide_rack_required ~= true then
            entry.no_slide_rack_required = true
            created_any = true
        end
    end

    if created_any then
        mark_tuning_dirty()
    end

    return created_any
end

local function get_weapon_go_name()
    local go = re2.weapon_gameobject
    if not go then return nil end
    return sc(go, "get_Name")
end

local function weapon_entry(wp_name)
    if not wp_name or type(CFG.weapons) ~= "table" then return nil end
    return CFG.weapons[wp_name]
end

local function weapon_reload_drop_slots(wp_name)
    local entry = weapon_entry(wp_name)
    if entry and type(entry.reload_drop_slots) == "number" then
        return math.max(1, math.floor(entry.reload_drop_slots))
    end
    if type(CFG.reload_drop_slots_by_wp) == "table" then
        local n = CFG.reload_drop_slots_by_wp[wp_name]
        if type(n) == "number" then return math.max(1, math.floor(n)) end
    end
    return 6
end

local function weapon_needs_manual_cylinder_reload(wp_name)
    local entry = weapon_entry(wp_name)
    if not entry then return false end
    if entry.needs_manual_cylinder_reload == true then return true end
    return entry.needs_manual_revolver_reload == true
end

local function weapon_uses_canister_mag_reload(wp_name)
    local entry = weapon_entry(wp_name)
    return entry ~= nil and entry.canister_mag_reload == true
end

local function weapon_label_for(wp_name)
    if type(wp_name) ~= "string" or wp_name == "" then return "?" end
    local entry = weapon_entry(wp_name)
    if entry and type(entry.label) == "string" and entry.label ~= "" then
        return entry.label
    end
    return wp_name
end

local function weapon_display_name(wp_name)
    if type(wp_name) ~= "string" or wp_name == "" then return "?" end
    local label = weapon_label_for(wp_name)
    if label == wp_name then return wp_name end
    return string.format("%s (%s)", wp_name, label)
end

-- Top per-weapon checkbox: mag holster + slide-rack manual reload (handguns / mag-fed).
local function is_weapon_enabled(wp_name)
    local entry = weapon_entry(wp_name)
    return entry ~= nil and entry.enabled == true
end

-- Any manual reload mode active for this weapon (mag, shell tube, or manual pump).
local function is_manual_reload_weapon(wp_name)
    local entry = weapon_entry(wp_name)
    if not entry then return false end
    if entry.enabled == true then return true end
    if entry.needs_manual_shell_reload == true then return true end
    if entry.needs_manual_pump == true then return true end
    if entry.needs_manual_cylinder_reload == true then return true end
    if entry.needs_manual_revolver_reload == true then return true end
    return false
end

local function weapon_no_slide_rack_required(wp_name)
    if not wp_name then return false end
    local entry = weapon_entry(wp_name)
    if entry and entry.no_slide_rack_required == true then return true end
    local by_wp = (CFG.slide_dock or {}).no_rack_required_by_wp
    return type(by_wp) == "table" and by_wp[wp_name] == true
end

local function weapon_reload_configured(wp_name)
    return weapon_entry(wp_name) ~= nil
end

local function weapon_supports_cylinder_reload(wp_name)
    return weapon_needs_manual_cylinder_reload(wp_name)
end

local function weapon_supports_shell_reload(wp_name)
    local entry = weapon_entry(wp_name)
    return entry ~= nil and entry.needs_manual_shell_reload == true
end

local function weapon_supports_pump_reload(wp_name)
    if reload_pump and reload_pump.is_weapon_pump_capable then
        return reload_pump.is_weapon_pump_capable(wp_name) == true
    end
    local entry = weapon_entry(wp_name)
    if not entry then return false end
    return entry.needs_manual_pump ~= nil or entry.block_native_pump ~= nil
end

local function weapon_supports_mag_reload(wp_name)
    local entry = weapon_entry(wp_name)
    if not entry then return false end
    if entry.needs_manual_shell_reload == true then return false end
    if weapon_needs_manual_cylinder_reload(wp_name) and entry.canister_mag_reload ~= true then
        return false
    end
    if entry.needs_manual_pump == true and entry.enabled ~= true then return false end
    if entry.needs_manual_pump ~= true and not weapon_needs_manual_cylinder_reload(wp_name) then
        return true
    end
    if entry.enabled == true or entry.canister_mag_reload == true then return true end
    return false
end

local function weapon_reload_applicable(wp_name)
    if not weapon_reload_configured(wp_name) then return false end
    return weapon_supports_mag_reload(wp_name)
        or weapon_supports_pump_reload(wp_name)
        or weapon_supports_shell_reload(wp_name)
        or weapon_supports_cylinder_reload(wp_name)
end

local function imgui_col(r, g, b, a)
    a = a or 255
    return ((a & 0xFF) << 24) | ((b & 0xFF) << 16) | ((g & 0xFF) << 8) | (r & 0xFF)
end

local UI_ACCENT = imgui_col(136, 204, 255)
local UI_ENABLE = imgui_col(0, 255, 0)
local UI_DISABLE = imgui_col(255, 64, 64)
local UI_MUTED = imgui_col(136, 136, 136)

local function draw_feature_enable_toggle(enabled, id, label)
    local changed = false
    local new_val = enabled
    if enabled then
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

local function draw_weapon_mode_toggle(current_on, id, label, on_change)
    local changed, new_val = draw_feature_enable_toggle(current_on == true, id, label)
    if changed and on_change then
        on_change(new_val)
        save_cfg()
        update_manual_reload_globals()
    end
end

local function get_enum_value(type_name, field_name, fallback)
    local tdef = sdk.find_type_definition(type_name)
    if tdef == nil then return fallback end
    local field = tdef:get_field(field_name)
    if field == nil or not field:is_static() then return fallback end
    local ok, value = pcall(function() return field:get_data(nil) end)
    if ok and type(value) == "number" then return value end
    return fallback
end

local PRECEDE_ORDER_RELOAD = get_enum_value(
    NS("SurvivorDefine.ActionOrder.Precede"), "RELOAD", 64)
local PRECEDE_ORDER_CHANGE_BULLET = get_enum_value(
    NS("SurvivorDefine.ActionOrder.Precede"), "CHANGE_BULLET", nil)
local PATIENT_ORDER_JOG = get_enum_value(
    NS("SurvivorDefine.ActionOrder.Petient"), "JOG", 256)

local function manual_reload_context_active()
    if CFG.enabled ~= true then return false end
    return is_manual_reload_weapon(get_weapon_go_name())
end

local function native_change_bullet_suspend_active()
    return suppress.change_bullet.active == true
end

local function should_spoof_reload_state()
    if native_change_bullet_suspend_active() then return false end
    if reload_pump and reload_pump.should_spoof_isreload() then return true end
    if CFG.suppress_reload_ik == false then return false end
    if not manual_reload_context_active() then return false end
    if reload_revolver and reload_revolver.is_revolver_weapon_active
        and reload_revolver.is_revolver_weapon_active()
        and reload_revolver.blocks_empty_native_reload
        and reload_revolver.blocks_empty_native_reload() then
        return true
    end
    if reload_mag and reload_mag.is_mag_out_of_gun() then return true end
    if frame.vr_reload_b then return true end
    if reload_mag then
        local mag = reload_mag.get_mag and reload_mag.get_mag()
        if mag and mag.anim_active == true then return true end
    end
    return false
end

local reload_mag = nil
local reload_util = nil
local reload_drop = nil
local reload_slide = nil
local reload_pump = nil
local reload_shell = nil
local reload_revolver = nil

suppress.end_change_bullet_suspend = function()
    if reload_revolver and reload_revolver.end_native_change_bullet_suspend then
        reload_revolver.end_native_change_bullet_suspend()
    end
    local cb = suppress.change_bullet
    if cb.active ~= true and cb.saw_native ~= true then return end
    cb.active = false
    cb.saw_native = false
    cb.wp = nil
    cb.until_t = 0.0
    rawset(_G, "__vr_manual_reload_suspended", false)
    rawset(_G, "__vr_native_change_bullet_active", false)
    if suppress.refresh_precede_inhibit then
        suppress.refresh_precede_inhibit()
    end
end

suppress.tick_change_bullet_suspend = function()
    local cb = suppress.change_bullet
    local is_cb = false
    local pm = sdk.get_managed_singleton(NS("PlayerManager"))
    if pm then
        local cond = sc(pm, "get_CurrentPlayerCondition")
        if cond then
            local ok, v = pcall(function() return cond:call("get_IsChangeBullet") end)
            is_cb = ok and v == true
        end
    end
    if is_cb then
        cb.saw_native = true
        if cb.active ~= true then
            cb.active = true
            cb.wp = get_weapon_go_name()
            rawset(_G, "__vr_manual_reload_suspended", true)
            rawset(_G, "__vr_native_change_bullet_active", true)
            if reload_revolver and reload_revolver.begin_native_change_bullet_suspend then
                reload_revolver.begin_native_change_bullet_suspend()
            end
        end
        cb.until_t = os.clock() + cb.hold_sec
        return
    end
    if cb.active ~= true then return end
    if cb.saw_native then
        suppress.end_change_bullet_suspend()
        return
    end
    if os.clock() > cb.until_t then
        suppress.end_change_bullet_suspend()
    end
end

local blocked_fire_sfx_prev = {
    trigger = false,
    grip_trigger = false,
}

local RELOAD_STACK_GLOBAL_KEYS = {
    "__vr_mag_dropped",
    "__vr_mag_in_left_hand",
    "__vr_mag_insert_active",
    "__vr_mag_blocks_weapon_holster",
    "__vr_mag_ammo_commit_bypass",
    "__vr_manual_reload_active",
    "__vr_manual_reload_enabled",
    "__vr_pending_session_restore",
    "__vr_session_visual_enforce_until",
    "__vr_slide_rack_active",
    "__vr_slide_dock_in_range",
    "__vr_slide_dock_blend_factor",
    "__vr_slide_hand_dock_target",
    "__vr_slide_hand_world_pos",
    "__vr_slide_hand_world_rot",
    "__vr_slide_dock_blend_from_pos",
    "__vr_slide_dock_blend_from_rot",
    "__vr_slide_dock_ik_pole",
    "__vr_slide_dock_ik_twist",
    "__vr_slide_dock_arm_delta",
    "__vr_slide_rack_pull_signed",
    "__vr_slide_rack_ik_done",
    "__vr_slide_pull_dist",
    "__vr_slide_push_dist",
    "__vr_slide_rack_pull_axis_x",
    "__vr_slide_rack_pull_axis_y",
    "__vr_slide_rack_pull_axis_z",
    "__vr_rack_chamber_commit_bypass",
    "__vr_block_left_support_in_mag_holster_zone",
    "__vr_in_mag_holster_zone",
    "__vr_lh_joint",
    "__vr_shotgun_pump_suppress_active",
    "__vr_block_empty_pump_reload_motion",
    "__vr_needs_pump",
    "__vr_pump_active",
    "__vr_pump_pull_signed",
    "__vr_pump_pull_dist",
    "__vr_pump_push_dist",
    "__vr_pump_hand_world_offset",
    "__vr_pump_pull_axis_x",
    "__vr_pump_pull_axis_y",
    "__vr_pump_pull_axis_z",
    "__vr_pump_slide_support",
    "__vr_pump_fp_passthrough",
    "__vr_shell_in_left_hand",
    "__vr_pending_shotgun_insert",
    "__vr_revolver_cylinder_open",
    "__vr_bullet_in_left_hand",
    "__vr_left_hand_pose_bullet_active",
}

local deps = nil

local function clear_reload_stack_globals()
    for _, key in ipairs(RELOAD_STACK_GLOBAL_KEYS) do
        rawset(_G, key, nil)
    end
end

local function reset_main_script_transient_state()
    prev_weapon_wp = nil
    prev_bullet_count = nil
    prev_frame_vr_reload_b = false
    native_reload_precede_inhibit_active = false
    suppress.precede_active = false
    suppress.change_bullet.active = false
    suppress.change_bullet.saw_native = false
    suppress.change_bullet.wp = nil
    suppress.change_bullet.until_t = 0.0
    rawset(_G, "__vr_manual_reload_suspended", false)
    rawset(_G, "__vr_native_change_bullet_active", false)
    blocked_fire_sfx_prev.trigger = false
    blocked_fire_sfx_prev.grip_trigger = false
    suppress.until_t = 0.0
    play_session_token = nil
    play_session_unloaded = false
    play_session_pending_save_load = false
    play_session_death_latched = false
    pending_reload_stack_reset_frames = 0
end

local function init_reload_stack()
    reload_mag = require("re2_vr_reload_ext_1")
    reload_mag.init(deps)
    reload_mag.sync_mag_holster_profile()

    reload_util = require("re2_vr_reload_ext_5")
    reload_util.init({
        CFG = CFG,
        sc = sc,
        re2 = re2,
        get_mag_hand = function() return reload_mag.get_mag_hand() end,
        get_weapon_go_name = get_weapon_go_name,
        weapon_display_name = weapon_display_name,
        is_weapon_enabled = is_weapon_enabled,
        current_profile_key = function() return reload_mag.current_mag_holster_profile_key() end,
        mark_tuning_dirty = mark_tuning_dirty,
        get_vr_controller_world_pos = function(hand)
            return reload_mag and reload_mag.get_vr_controller_world_pos(hand) or nil
        end,
        shell_pose_active = function()
            return reload_shell and reload_shell.has_shell_in_hand
                and reload_shell.has_shell_in_hand() == true
        end,
        revolver_pose_active = function()
            return reload_revolver and reload_revolver.has_bullet_in_hand
                and reload_revolver.has_bullet_in_hand() == true
        end,
    })
    reload_drop = reload_util.drop

    deps.play_reload_sfx = function(kind, opts)
        if reload_util then
            return reload_util.play(kind, opts)
        end
        return false
    end

    reload_slide = require("re2_vr_reload_ext_2")
    local slide_init_ok, slide_init_err = pcall(function()
        reload_slide.init({
            CFG = CFG,
            sc = sc,
            re2 = re2,
            manual_reload_context_active = manual_reload_context_active,
            manual_reload_session_active = manual_reload_session_active,
            is_weapon_enabled = is_weapon_enabled,
            get_weapon_go_name = get_weapon_go_name,
            weapon_display_name = weapon_display_name,
            get_left_hand_position = function() return reload_mag.get_left_hand_position() end,
            get_left_track_position = function() return reload_mag.get_left_track_position() end,
            get_left_track_pos_with_source = function() return reload_mag.get_left_track_pos_with_source() end,
            get_vr_controller_world_pos = function() return reload_mag.get_vr_controller_world_pos() end,
            is_left_grip_pressed = function() return reload_mag.is_left_grip_pressed() end,
            is_left_trigger_pressed = function()
                return reload_mag and reload_mag.is_left_trigger_pressed
                    and reload_mag.is_left_trigger_pressed() or false
            end,
            get_bullet_number = function()
                local weapon = re2.weapon
                if not weapon then return 0 end
                local n = sc(weapon, "getBulletNumber")
                return type(n) == "number" and n or 0
            end,
            haptic_pulse = function(lj, duration, frequency, amplitude)
                if reload_mag then reload_mag.haptic_pulse(lj, duration, frequency, amplitude) end
            end,
            get_haptic_left_joystick = function()
                return reload_mag and reload_mag.get_haptic_left_joystick() or nil
            end,
            get_mag_carried_rounds = function()
                return reload_mag and reload_mag.get_mag_carried_rounds
                    and reload_mag.get_mag_carried_rounds() or 0
            end,
            mark_tuning_dirty = mark_tuning_dirty,
            play_reload_sfx = deps.play_reload_sfx,
            arm_left_support_grace = function(sec)
                if reload_mag and reload_mag.arm_left_support_suppress_grace then
                    reload_mag.arm_left_support_suppress_grace(sec)
                end
            end,
            weapon_uses_manual_cylinder_reload = weapon_needs_manual_cylinder_reload,
            capture_cylinder_rest = function()
                if reload_revolver and reload_revolver.capture_cylinder_rest then
                    return reload_revolver.capture_cylinder_rest()
                end
                return false
            end,
            weapon_uses_chamber_bullet_follow = function(wp)
                if reload_revolver and reload_revolver.uses_chamber_bullet_follow then
                    return reload_revolver.uses_chamber_bullet_follow(wp)
                end
                return false
            end,
            get_chamber_bullet_open_bind_display = function(wp)
                if reload_revolver and reload_revolver.get_chamber_bullet_open_bind_display then
                    return reload_revolver.get_chamber_bullet_open_bind_display(wp)
                end
                return nil
            end,
            sync_chamber_bullet_pose = function()
                if reload_revolver and reload_revolver.sync_chamber_bullet_pose then
                    reload_revolver.sync_chamber_bullet_pose()
                end
            end,
            apply_chamber_bullet_follow_open_t = function(open_t)
                if reload_revolver and reload_revolver.apply_chamber_bullet_follow_open_t then
                    reload_revolver.apply_chamber_bullet_follow_open_t(open_t)
                end
            end,
            revolver_invalidate_cylinder_joint_cache = function()
                if reload_revolver and reload_revolver.invalidate_cylinder_joint_cache then
                    reload_revolver.invalidate_cylinder_joint_cache()
                end
            end,
        })
    end)
    if not slide_init_ok then
        log.error("[re2_vr_reload] slide_ext init failed: " .. tostring(slide_init_err))
    end

    deps.on_mag_insert_complete = function(needs_rack)
        if reload_slide then reload_slide.on_mag_insert_complete(needs_rack) end
    end
    deps.clear_tactical_rack_state = function()
        if reload_slide and reload_slide.clear_tactical_rack_state then
            reload_slide.clear_tactical_rack_state()
        end
    end

    local reload_ballistic = require("re2_vr_reload_ext_4")
    reload_ballistic.init({
        CFG = CFG,
        sc = sc,
        re2 = re2,
        reload_drop = reload_drop,
        get_weapon_go_name = get_weapon_go_name,
        manual_reload_context_active = manual_reload_context_active,
        is_weapon_enabled = is_weapon_enabled,
        weapon_display_name = weapon_display_name,
        mark_tuning_dirty = mark_tuning_dirty,
        play_reload_sfx = deps.play_reload_sfx,
        haptic_pulse = function(lj, duration, frequency, amplitude)
            if reload_mag then reload_mag.haptic_pulse(lj, duration, frequency, amplitude) end
        end,
        get_haptic_left_joystick = function()
            return reload_mag and reload_mag.get_haptic_left_joystick and reload_mag.get_haptic_left_joystick()
        end,
        is_left_grip_pressed = function()
            return reload_mag and reload_mag.is_left_grip_pressed and reload_mag.is_left_grip_pressed()
        end,
        is_left_trigger_pressed = function()
            return reload_mag and reload_mag.is_left_trigger_pressed and reload_mag.is_left_trigger_pressed()
        end,
        get_left_track_position = function()
            return reload_mag and reload_mag.get_left_track_position and reload_mag.get_left_track_position()
        end,
        get_left_track_pos_with_source = function()
            return reload_mag and reload_mag.get_left_track_pos_with_source
                and reload_mag.get_left_track_pos_with_source()
        end,
        get_left_hand_position = function()
            return reload_mag and reload_mag.get_left_hand_position and reload_mag.get_left_hand_position()
        end,
        get_left_hand_joint = function()
            return reload_mag and reload_mag.get_left_hand_joint and reload_mag.get_left_hand_joint()
        end,
        get_mag_hand_hold_entry = function()
            if reload_mag and reload_mag.get_mag_hand_hold_entry then
                return reload_mag.get_mag_hand_hold_entry()
            end
            return nil
        end,
        get_mag_dock_dist = function(wp)
            if reload_mag and reload_mag.get_mag_dock_dist then
                return reload_mag.get_mag_dock_dist(wp)
            end
            return 0.20
        end,
        detach_mag_hand_for_shell = function()
            if reload_mag and reload_mag.detach_mag_hand_for_shell then
                reload_mag.detach_mag_hand_for_shell()
            end
        end,
        get_weapon_chamber_bullet_count = function()
            return reload_mag and reload_mag.get_weapon_chamber_bullet_count
                and reload_mag.get_weapon_chamber_bullet_count() or 0
        end,
        get_main_weapon_reserve_ammo_count = function()
            return reload_mag and reload_mag.get_main_weapon_reserve_ammo_count
                and reload_mag.get_main_weapon_reserve_ammo_count() or 0
        end,
        prime_main_weapon_reloadable_pool = function()
            if reload_mag and reload_mag.prime_main_weapon_reloadable_pool then
                reload_mag.prime_main_weapon_reloadable_pool()
            end
        end,
        get_weapon_reloadable_count = function()
            return reload_mag and reload_mag.get_weapon_reloadable_count
                and reload_mag.get_weapon_reloadable_count() or 0
        end,
        get_imgr_weapon_loaded = function()
            return reload_mag and reload_mag.get_imgr_weapon_loaded
                and reload_mag.get_imgr_weapon_loaded() or nil
        end,
        get_weapon_mag_slot_round_count = function()
            return reload_mag and reload_mag.get_weapon_mag_slot_round_count
                and reload_mag.get_weapon_mag_slot_round_count() or 0
        end,
        get_shell_hud_ammo = function()
            if reload_mag and reload_mag.get_shell_hud_ammo then
                return reload_mag.get_shell_hud_ammo()
            end
            return nil, nil
        end,
        apply_carried_mag_ammo = function(count, opts)
            if reload_mag and reload_mag.apply_carried_mag_ammo then
                return reload_mag.apply_carried_mag_ammo(count, opts)
            end
            return false
        end,
        apply_single_shell_round = function()
            if reload_mag and reload_mag.apply_single_shell_round then
                return reload_mag.apply_single_shell_round()
            end
            return false
        end,
        reload_slide = reload_slide,
        extend_suppress_window = function()
            suppress.until_t = os.clock() + 0.35
        end,
        arm_left_support_grace = function(sec)
            if reload_mag and reload_mag.arm_left_support_suppress_grace then
                reload_mag.arm_left_support_suppress_grace(sec)
            end
        end,
    })
    reload_pump = reload_ballistic.pump
    reload_shell = reload_ballistic.shell

    deps.shell_holster_context_active = function()
        return reload_shell and reload_shell.holster_context_active and reload_shell.holster_context_active()
    end
    deps.shell_holster_supply_available = function()
        return reload_shell and reload_shell.holster_supply_available and reload_shell.holster_supply_available()
    end
    deps.shell_holster_empty_denial_active = function()
        return reload_shell and reload_shell.holster_empty_denial_active and reload_shell.holster_empty_denial_active()
    end
    deps.shell_holster_wants_grab = function()
        return reload_shell and reload_shell.holster_wants_shell_grab and reload_shell.holster_wants_shell_grab()
    end
    deps.shell_has_shell_in_hand = function()
        return reload_shell and reload_shell.has_shell_in_hand and reload_shell.has_shell_in_hand()
    end
    deps.shell_shoot_ready_suppress_exempt = function()
        return reload_shell and reload_shell.shoot_ready_suppress_exempt
            and reload_shell.shoot_ready_suppress_exempt()
    end
    deps.shell_reload_session_active = function()
        return reload_shell and reload_shell.reload_session_active
            and reload_shell.reload_session_active()
    end
    deps.shell_on_holster_grab_edge = function()
        return reload_shell and reload_shell.on_holster_grab_edge and reload_shell.on_holster_grab_edge()
    end
    deps.shell_blocks_mag_b = function()
        return reload_shell and reload_shell.is_shell_weapon_active and reload_shell.is_shell_weapon_active()
    end
    deps.shell_weapon_equipped = function()
        return reload_shell and reload_shell.is_shell_weapon_active and reload_shell.is_shell_weapon_active()
    end

    reload_revolver = require("re2_vr_reload_ext_3")
    reload_revolver.init({
        CFG = CFG,
        sc = sc,
        re2 = re2,
        reload_drop = reload_drop,
        get_weapon_go_name = get_weapon_go_name,
        manual_reload_context_active = manual_reload_context_active,
        weapon_display_name = weapon_display_name,
        mark_tuning_dirty = mark_tuning_dirty,
        play_reload_sfx = deps.play_reload_sfx,
        get_left_hand_position = function()
            return reload_mag and reload_mag.get_left_hand_position and reload_mag.get_left_hand_position()
        end,
        get_left_hand_joint = function()
            return reload_mag and reload_mag.get_left_hand_joint and reload_mag.get_left_hand_joint()
        end,
        get_left_track_position = function()
            return reload_mag and reload_mag.get_left_track_position and reload_mag.get_left_track_position()
        end,
        get_left_track_pos_with_source = function()
            return reload_mag and reload_mag.get_left_track_pos_with_source
                and reload_mag.get_left_track_pos_with_source()
        end,
        get_mag_hand_hold_entry = function()
            if reload_mag and reload_mag.get_mag_hand_hold_entry then
                return reload_mag.get_mag_hand_hold_entry()
            end
            return nil
        end,
        get_mag_dock_dist = function(wp)
            if reload_mag and reload_mag.get_mag_dock_dist then
                return reload_mag.get_mag_dock_dist(wp)
            end
            return 0.20
        end,
        is_left_grip_pressed = function()
            return reload_mag and reload_mag.is_left_grip_pressed and reload_mag.is_left_grip_pressed()
        end,
        detach_mag_hand_for_shell = function()
            if reload_mag and reload_mag.detach_mag_hand_for_shell then
                reload_mag.detach_mag_hand_for_shell()
            end
        end,
        get_weapon_chamber_bullet_count = function()
            return reload_mag and reload_mag.get_weapon_chamber_bullet_count
                and reload_mag.get_weapon_chamber_bullet_count() or 0
        end,
        get_main_weapon_reserve_ammo_count = function()
            return reload_mag and reload_mag.get_main_weapon_reserve_ammo_count
                and reload_mag.get_main_weapon_reserve_ammo_count() or 0
        end,
        get_inventory_spare_bullet_count = function()
            return reload_mag and reload_mag.get_inventory_spare_bullet_count
                and reload_mag.get_inventory_spare_bullet_count() or 0
        end,
        prime_main_weapon_reloadable_pool = function()
            if reload_mag and reload_mag.prime_main_weapon_reloadable_pool then
                reload_mag.prime_main_weapon_reloadable_pool()
            end
        end,
        get_shell_hud_ammo = function()
            if reload_mag and reload_mag.get_shell_hud_ammo then
                return reload_mag.get_shell_hud_ammo()
            end
            return 0, 0
        end,
        apply_carried_mag_ammo = function(count, opts)
            if reload_mag and reload_mag.apply_carried_mag_ammo then
                return reload_mag.apply_carried_mag_ammo(count, opts)
            end
            return false
        end,
        apply_single_shell_round = function()
            if reload_mag and reload_mag.apply_single_shell_round then
                return reload_mag.apply_single_shell_round()
            end
            return false
        end,
        extend_suppress_window = function()
            suppress.until_t = os.clock() + 0.35
        end,
        arm_left_support_grace = function()
            if reload_mag and reload_mag.arm_left_support_suppress_grace then
                reload_mag.arm_left_support_suppress_grace()
            end
        end,
        publish_sub_weapon_suppress = function()
            if reload_mag and reload_mag.publish_sub_weapon_suppress then
                reload_mag.publish_sub_weapon_suppress()
            end
        end,
        clear_weapon_chamber_ammo = function()
            if reload_mag and reload_mag.clear_weapon_chamber_ammo then
                return reload_mag.clear_weapon_chamber_ammo()
            end
            return false
        end,
        sync_chamber_shoot_ready = function()
            if reload_mag and reload_mag.sync_chamber_shoot_ready then
                return reload_mag.sync_chamber_shoot_ready()
            end
            return false
        end,
        on_chamber_ammo_to_carried = function(stash_n)
            if reload_mag and reload_mag.on_chamber_ammo_to_carried then
                reload_mag.on_chamber_ammo_to_carried(stash_n)
            end
        end,
        commit_reload_ammo = function()
            if reload_mag and reload_mag.commit_reload_ammo then
                reload_mag.commit_reload_ammo()
            end
        end,
        get_mag_carried_rounds = function()
            if reload_mag and reload_mag.get_mag_carried_rounds then
                return reload_mag.get_mag_carried_rounds()
            end
            return 0
        end,
        weapon_uses_canister_mag_reload = weapon_uses_canister_mag_reload,
        get_weapon_mag_slot_round_count = function()
            return reload_mag and reload_mag.get_weapon_mag_slot_round_count
                and reload_mag.get_weapon_mag_slot_round_count() or 0
        end,
        haptic_pulse = function(joystick, duration, frequency, amplitude)
            if reload_mag and reload_mag.haptic_pulse then
                reload_mag.haptic_pulse(joystick, duration, frequency, amplitude)
            end
        end,
        native_change_bullet_suspend_active = native_change_bullet_suspend_active,
    })

    deps.revolver_holster_context_active = function()
        return reload_revolver and reload_revolver.holster_context_active
            and reload_revolver.holster_context_active()
    end
    deps.revolver_holster_supply_available = function()
        return reload_revolver and reload_revolver.holster_supply_available
            and reload_revolver.holster_supply_available()
    end
    deps.revolver_holster_empty_denial_active = function()
        return reload_revolver and reload_revolver.holster_empty_denial_active
            and reload_revolver.holster_empty_denial_active()
    end
    deps.revolver_holster_wants_grab = function()
        return reload_revolver and reload_revolver.holster_wants_bullet_grab
            and reload_revolver.holster_wants_bullet_grab()
    end
    deps.revolver_has_bullet_in_hand = function()
        return reload_revolver and reload_revolver.has_bullet_in_hand
            and reload_revolver.has_bullet_in_hand()
    end
    deps.revolver_shoot_ready_suppress_exempt = function()
        return reload_revolver and reload_revolver.shoot_ready_suppress_exempt
            and reload_revolver.shoot_ready_suppress_exempt()
    end
    deps.revolver_aux_input_suppress_wanted = function()
        return reload_revolver and reload_revolver.aux_input_suppress_wanted
            and reload_revolver.aux_input_suppress_wanted() == true
    end
    deps.revolver_on_holster_grab_edge = function()
        return reload_revolver and reload_revolver.on_holster_grab_edge
            and reload_revolver.on_holster_grab_edge()
    end
    deps.revolver_blocks_mag_b = function()
        return reload_revolver and reload_revolver.is_revolver_weapon_active
            and reload_revolver.is_revolver_weapon_active()
    end
    deps.revolver_blocks_empty_native_reload = function()
        return reload_revolver and reload_revolver.blocks_empty_native_reload
            and reload_revolver.blocks_empty_native_reload()
    end
    deps.revolver_weapon_equipped = function()
        return reload_revolver and reload_revolver.is_revolver_weapon_active
            and reload_revolver.is_revolver_weapon_active()
    end

    if reload_mag and reload_mag.set_bullet_insert_preview_handlers then
        reload_mag.set_bullet_insert_preview_handlers({
            extend = function(wp, sec)
                if not reload_revolver or not reload_revolver.extend_bullet_insert_preview then
                    return false, "Revolver module unavailable"
                end
                return reload_revolver.extend_bullet_insert_preview(wp, sec)
            end,
            cancel = function(restore_pose)
                if reload_revolver and reload_revolver.cancel_bullet_insert_preview then
                    reload_revolver.cancel_bullet_insert_preview(restore_pose)
                end
            end,
            is_active = function()
                return reload_revolver and reload_revolver.insert_preview_is_active
                    and reload_revolver.insert_preview_is_active() == true
            end,
            get_remaining = function()
                if reload_revolver and reload_revolver.get_insert_preview_remaining then
                    return reload_revolver.get_insert_preview_remaining()
                end
                return 0.0
            end,
        })
    end
end

local function execute_reload_stack_reset(reason)
    reason = tostring(reason or "unknown")
    log.info(string.format("[re2_vr_reload] Reload stack reset (%s)", reason))

    rawset(_G, "__vr_reload_stack_reset_in_progress", true)

    clear_reload_stack_globals()
    reset_main_script_transient_state()
    refresh_re2_weapon_cache()

    local reset_ok, reset_err = pcall(function()
        if reload_mag and reload_mag.reset_stack_state then
            reload_mag.reset_stack_state()
        end
        if reload_slide and reload_slide.reset_stack_state then
            reload_slide.reset_stack_state()
        end
        if reload_pump and reload_pump.on_weapon_swap then
            reload_pump.on_weapon_swap()
        end
        if reload_pump and reload_pump.clear_globals then
            reload_pump.clear_globals()
        end
        if reload_shell and reload_shell.reset_stack_state then
            reload_shell.reset_stack_state()
        end
        if reload_shell and reload_shell.clear_globals then
            reload_shell.clear_globals()
        end
        if reload_revolver and reload_revolver.reset_stack_state then
            reload_revolver.reset_stack_state()
        end
        if reload_revolver and reload_revolver.clear_globals then
            reload_revolver.clear_globals()
        end
        if reload_util and reload_util.on_weapon_swap then
            reload_util.on_weapon_swap()
        end
    end)
    if not reset_ok then
        log.error(string.format("[re2_vr_reload] Reload stack reset failed: %s", tostring(reset_err)))
    end

    clear_native_reload_precede_inhibit_now()

    refresh_re2_weapon_cache()
    if reload_mag and reload_mag.refresh_weapon_cache then
        pcall(reload_mag.refresh_weapon_cache)
    end
    if reload_slide and reload_slide.refresh_weapon_cache then
        pcall(reload_slide.refresh_weapon_cache)
    end
    if reload_slide and reload_slide.apply_slide_park then
        pcall(reload_slide.apply_slide_park, "stack_reset")
    end

    rawset(_G, "__vr_reload_stack_reset_in_progress", nil)
end

local function try_execute_pending_reload_stack_reset()
    if not pending_reload_stack_reset then return end

    pending_reload_stack_reset_frames = pending_reload_stack_reset_frames + 1
    local reason = pending_reload_stack_reset_reason or "unknown"
    local load_busy = is_save_load_busy_active()
    local has_player = re2.get_localplayer() ~= nil
    local from_load_signal = is_load_cleared_reset_reason(reason)
    local force_ready = pending_reload_stack_reset_frames > 120

    local block_reason = nil
    if not has_player then
        block_reason = "no_player"
    elseif load_busy and not from_load_signal and not force_ready then
        block_reason = "load_busy"
    end

    if block_reason then
        return
    end

    pending_reload_stack_reset = false
    pending_reload_stack_reset_reason = nil
    pending_reload_stack_reset_frames = 0
    local ok, err = pcall(execute_reload_stack_reset, reason)
    if not ok then
        log.error(string.format("[re2_vr_reload] execute_reload_stack_reset crashed: %s", tostring(err)))
    end
end

local function manual_reload_session_active()
    if reload_mag then return reload_mag.manual_reload_session_active() end
    return false
end

local function weapon_needs_reload()
    local weapon = re2.weapon
    if not weapon then return false end
    local n = sc(weapon, "getBulletNumber")
    return type(n) == "number" and n <= 0
end

local function is_vr_reload_button_down()
    if not vrmod then return false end
    local ok, down = pcall(function()
        local action = vrmod:get_action_b_button()
        local rj = vrmod:get_right_joystick()
        if not action or not rj then return false end
        return vrmod:is_action_active(action, rj)
    end)
    return ok and down == true
end

local function get_vr_right_joystick()
    if not vrmod then return nil end
    local rj = nil
    pcall(function() rj = vrmod:get_right_joystick() end)
    return rj
end

local function is_vr_right_trigger_down()
    if not vrmod then return false end
    if not trigger_action_cache or trigger_action_cache == 0 then
        pcall(function() trigger_action_cache = vrmod:get_action_trigger() end)
    end
    local rj = get_vr_right_joystick()
    if not trigger_action_cache or not rj then return false end
    local ok, active = pcall(function()
        return vrmod:is_action_active(trigger_action_cache, rj)
    end)
    return ok and active == true
end

local function is_vr_right_grip_trigger_down()
    if not vrmod then return false end
    if not grip_action_cache or grip_action_cache == 0 then
        pcall(function() grip_action_cache = vrmod:get_action_grip() end)
    end
    if not is_vr_right_trigger_down() then return false end
    if not grip_action_cache then return false end
    local rj = get_vr_right_joystick()
    if not rj then return false end
    local ok, active = pcall(function()
        return vrmod:is_action_active(grip_action_cache, rj)
    end)
    return ok and active == true
end

local function tick_player_locomotion()
    local now = os.clock()
    local moving = now < (locomotion_state.moving_until or 0.0)
    local player = re2.get_localplayer()
    if not player then
        locomotion_state.last_x = nil
        locomotion_state.last_z = nil
        _G.__vr_player_locomoting = moving
        return moving
    end

    local tf = nil
    pcall(function() tf = player:call("get_Transform") end)
    local pos = tf and sc(tf, "get_Position") or nil
    if pos and locomotion_state.last_x ~= nil and locomotion_state.last_z ~= nil then
        local dx = pos.x - locomotion_state.last_x
        local dz = pos.z - locomotion_state.last_z
        if math.sqrt(dx * dx + dz * dz) > LOCOMOTION_MOVE_THRESH then
            locomotion_state.moving_until = now + LOCOMOTION_HOLD_SEC
            moving = true
        end
    end
    if pos then
        locomotion_state.last_x = pos.x
        locomotion_state.last_z = pos.z
    end
    if now < (locomotion_state.moving_until or 0.0) then
        moving = true
    end
    _G.__vr_player_locomoting = moving
    return moving
end

local function is_player_locomoting()
    return rawget(_G, "__vr_player_locomoting") == true
end

local function empty_mag_locomotion_trigger_active()
    if not weapon_needs_reload() then return false end
    if not is_vr_right_trigger_down() then return false end
    return is_player_locomoting()
end

local function refresh_vr_input_cache()
    frame.vr_reload_b = is_vr_reload_button_down()
    frame.weapon_needs_reload = weapon_needs_reload()
    frame.vr_right_trigger = is_vr_right_trigger_down()
    _G.__vr_vr_right_trigger = frame.vr_right_trigger == true
    frame.vr_grip_trigger = is_vr_right_grip_trigger_down()
    frame_vr_reload_b = frame.vr_reload_b
    frame_weapon_needs_reload = frame.weapon_needs_reload
    frame_vr_grip_trigger = frame.vr_grip_trigger
end


local function is_sub_weapon_method_label(method_label)
    if type(method_label) ~= "string" then return false end
    return method_label:find("Sub", 1, true) ~= nil
end

local function should_suppress_empty_native_reload()
    if native_change_bullet_suspend_active() then return false end
    if not manual_reload_context_active() then return false end
    if reload_revolver and reload_revolver.is_revolver_weapon_active
        and reload_revolver.is_revolver_weapon_active()
        and reload_revolver.blocks_empty_native_reload
        and reload_revolver.blocks_empty_native_reload() then
        return true
    end
    return weapon_needs_reload()
end

local function should_block_native_reload_pipeline()
    if native_change_bullet_suspend_active() then return false end
    if ammo.internal_commit then return false end
    if rawget(_G, "__vr_rack_chamber_commit_bypass") == true then return false end
    if rawget(_G, "__vr_mag_ammo_commit_bypass") == true then return false end
    if manual_reload_session_active() then return true end
    if should_suppress_empty_native_reload() then return true end
    return manual_reload_context_active()
end

local function should_block_native_change_bullet()
    if native_change_bullet_suspend_active() then return false end
    if ammo.internal_commit then return false end
    if rawget(_G, "__vr_rack_chamber_commit_bypass") == true then return false end
    if rawget(_G, "__vr_mag_ammo_commit_bypass") == true then return false end
    return should_suppress_empty_native_reload()
end

local function should_block_native_ammo_slot()
    return should_block_native_reload_pipeline()
end

local abort_blocked_native_reload_last_t = 0.0

local function abort_blocked_native_reload(method_label)
    if type(method_label) ~= "string" then return end
    if method_label:find("End", 1, true) then return end
    if not (method_label:find("changeBullet", 1, true)
        or method_label:find("executeChangeBullet", 1, true)
        or method_label:find("executeReload", 1, true)
        or method_label:find("reloadMainWeapon", 1, true)
        or method_label:find("reloadMainSlot", 1, true)
        or method_label:find("requestReload", 1, true)) then
        return
    end
    local now = os.clock()
    if now - abort_blocked_native_reload_last_t < 0.15 then return end
    abort_blocked_native_reload_last_t = now
    -- Block native reload only; do not end-reload after block (clears manual chamber commits).
end

local function should_hard_block_empty_fire()
    if native_change_bullet_suspend_active() then return false end
    if reload_revolver and reload_revolver.cylinder_blocks_fire and reload_revolver.cylinder_blocks_fire() then
        return true
    end
    if reload_pump and reload_pump.should_block_fire and reload_pump.should_block_fire() then return true end
    if not manual_reload_context_active() then return false end
    if reload_mag and reload_mag.is_mag_out_of_gun() then return true end
    if reload_slide and reload_slide.needs_rack() then return true end
    if weapon_needs_reload() then return true end
    return false
end

local function should_block_manual_reload_fire()
    if not manual_reload_context_active() then return false end
    if reload_revolver and reload_revolver.cylinder_blocks_fire and reload_revolver.cylinder_blocks_fire() then
        return true
    end
    if reload_mag and reload_mag.is_mag_out_of_gun() then return true end
    if not weapon_needs_reload() then return false end
    if reload_slide and reload_slide.needs_rack() then return true end
    return true
end

local function update_manual_reload_globals()
    local suspend = native_change_bullet_suspend_active()
    _G.__vr_manual_reload_enabled = manual_reload_context_active() and not suspend
    _G.__vr_manual_reload_active = suspend and false or manual_reload_session_active()
    if manual_reload_context_active() then
        _G.__vr_block_fire_when_empty = should_block_manual_reload_fire()
    else
        _G.__vr_block_fire_when_empty = false
    end
    rawset(_G, "__vr_block_shoot_ready_empty", false)
    if reload_slide then reload_slide.update_globals() end
    if reload_mag then reload_mag.update_globals() end
    if reload_pump then reload_pump.update_globals() end
end

local function get_input_system()
    return sdk.get_managed_singleton(NS("InputSystem"))
end

local function read_u64_field(obj, field_name)
    if not obj then return nil end
    local v = nil
    pcall(function() v = obj:get_field(field_name) end)
    if type(v) == "number" then return v end
    local off = BUTTON_FIELD_OFFSET[field_name]
    if not off then return nil end
    local ok, val = pcall(function() return obj:read_uint64(off) end)
    if ok and type(val) == "number" then return val end
    return nil
end

local function write_u64_field(obj, field_name, value)
    if not obj or type(value) ~= "number" then return end
    pcall(function() obj:set_field(field_name, value) end)
    local off = BUTTON_FIELD_OFFSET[field_name]
    if off then
        pcall(function() obj:write_uint64(off, value) end)
    end
end

local function reload_activity_active()
    if not manual_reload_context_active() then return false end
    if frame_vr_reload_b then return true end
    if frame_vr_grip_trigger and frame_weapon_needs_reload then return true end
    if empty_mag_locomotion_trigger_active() then return true end
    return os.clock() < suppress.until_t
end

local function strip_weapon_anim_input_bits(input_system)
    if not input_system then return end
    local mask = 0
    if should_hard_block_empty_fire() then
        mask = mask | INPUT_KIND_ATTACK
    end
    if mask == 0 then return end
    for _, field_name in ipairs({ "Down", "On", "Up" }) do
        local cur = read_u64_field(input_system, field_name)
        if type(cur) == "number" and (cur & mask) ~= 0 then
            write_u64_field(input_system, field_name, cur & ~mask)
        end
    end
end

local function pump_forend_left_support_active()
    return rawget(_G, "__vr_needs_pump") == true
        or rawget(_G, "__vr_pump_active") == true
        or rawget(_G, "__vr_pump_slide_support") == true
end

local function left_support_suppress_wanted()
    local mag_holster_block = rawget(_G, "__vr_block_left_support_in_mag_holster_zone") == true
    if pump_forend_left_support_active() then
        if mag_holster_block and (
            rawget(_G, "__vr_in_mag_holster_zone") == true
            or rawget(_G, "__vr_shell_reload_blocks_sub_weapon") == true) then
            return true
        end
        return false
    end
    return mag_holster_block
        or rawget(_G, "__vr_block_left_support_in_head_flash_zone") == true
end

local function weapon_hold_suppress_wanted()
    return rawget(_G, "__vr_block_hold_in_holster_zone") == true
end

local function vr_input_suppress_wanted()
    return left_support_suppress_wanted() or weapon_hold_suppress_wanted()
end

local function mag_holster_left_support_suppress_active()
    return rawget(_G, "__vr_block_left_support_in_mag_holster_zone") == true
end

local function get_button_bits(input_system)
    if not input_system then return nil end
    return sc(input_system, "get_ButtonBits")
end

local function strip_input_mask(input_system, mask)
    if not input_system or not mask or mask == 0 then return end
    local bb = get_button_bits(input_system)
    if not bb then return end
    for _, field_name in ipairs({ "Down", "On", "Up" }) do
        local cur = read_u64_field(bb, field_name)
        if type(cur) == "number" and (cur & mask) ~= 0 then
            write_u64_field(bb, field_name, cur & ~mask)
        end
    end
end

local function apply_vr_input_suppress()
    if not vr_input_suppress_wanted() then return end
    local input_system = get_input_system()
    if not input_system then return end
    if left_support_suppress_wanted() then
        strip_input_mask(input_system, INPUT_SUPPRESS_LEFT_SUPPORT_MASK)
    end
    if weapon_hold_suppress_wanted() then
        strip_input_mask(input_system, INPUT_SUPPRESS_RIGHT_HOLD_MASK)
    end
end

local function install_vr_input_suppress_hooks()
    if vr_input_suppress_hooks_installed then return end
    re.on_pre_application_entry("UpdateHID", function()
        rawset(_G, "__vr_left_support_strip_frame",
            (rawget(_G, "__vr_left_support_strip_frame") or 0) + 1)
    end)
    re.on_application_entry("UpdateHID", function()
        apply_vr_input_suppress()
    end)
    re.on_pre_application_entry("UpdateBehavior", function()
        apply_vr_input_suppress()
    end)
    re.on_application_entry("LateUpdateBehavior", function()
        apply_vr_input_suppress()
    end)
    vr_input_suppress_hooks_installed = true
end

local function sync_reload_input_inhibit(input_system)
    if not input_system then return end
    if should_hard_block_empty_fire() then
        pcall(function() input_system:call("setForce", INPUT_KIND_ATTACK, false) end)
    end
end

local function get_component_on(obj, comp_type)
    if not obj or not comp_type then return nil end
    local ok, comp = pcall(function() return obj:call("getComponent(System.Type)", comp_type) end)
    return ok and comp or nil
end

local function get_player_condition()
    local playman = sdk.get_managed_singleton(NS("PlayerManager"))
    if not playman then return nil end
    return sc(playman, "get_CurrentPlayerCondition")
end

local function get_player_action_orderer()
    local cond = get_player_condition()
    if cond then
        local ao = nil
        pcall(function() ao = cond:get_field("<ActionOrderer>k__BackingField") end)
        if ao then return ao end
    end
    local player = re2.get_localplayer()

    if not player then return nil end
    return get_component_on(player, player_action_orderer_type)
end

force_clear_mag_holster_left_support_suppress = function()
    rawset(_G, "__vr_block_left_support_in_mag_holster_zone", false)
    mag_sub_suppress.active = false
end

local function sync_mag_holster_left_support_suppress(want)
    want = want == true
    if want == mag_sub_suppress.active then return end
    mag_sub_suppress.active = want
end

local function is_menu_blocking()
    local fn = rawget(_G, "__vr_is_menu_blocking")
    if type(fn) ~= "function" then return false end
    local ok, blocked = pcall(fn)
    return ok and blocked == true
end

local menu_block_manual_reload_prev = false

local function silence_manual_reload_for_menu()
    sync_mag_holster_left_support_suppress(false)
    force_clear_mag_holster_left_support_suppress()
    rawset(_G, "__vr_in_mag_holster_zone", false)
end

local function clear_mistaken_patient_inhibit(action_orderer)
    if not action_orderer then return end
    pcall(function() action_orderer:call("setInhibitPetient", false, PATIENT_ORDER_HOLD_WALK) end)
    pcall(function() action_orderer:call("setInhibitPetient", false, PATIENT_ORDER_JOG) end)
end

local function apply_native_reload_precede_inhibit(action_orderer, want_reload, want_cb)
    if not action_orderer then return end
    want_reload = want_reload == true
    want_cb = want_cb == true
    pcall(function() action_orderer:call("setInhibitPrecede", want_reload, PRECEDE_ORDER_RELOAD) end)
    if PRECEDE_ORDER_CHANGE_BULLET ~= nil then
        pcall(function() action_orderer:call("setInhibit", want_cb, PRECEDE_ORDER_CHANGE_BULLET) end)
    end
    if not want_reload and not want_cb then
        clear_mistaken_patient_inhibit(action_orderer)
    end
    suppress.precede_active = want_reload or want_cb
    native_reload_precede_inhibit_active = suppress.precede_active
end

local function sync_native_reload_precede_inhibit(action_orderer)
    if not action_orderer then return end
    if native_change_bullet_suspend_active() then
        apply_native_reload_precede_inhibit(action_orderer, false, false)
        return
    end
    local want_reload = manual_reload_context_active()
    local want_cb = should_suppress_empty_native_reload()
    if want_reload then
        clear_mistaken_patient_inhibit(action_orderer)
    end
    apply_native_reload_precede_inhibit(action_orderer, want_reload, want_cb)
end

clear_native_reload_precede_inhibit_now = function()
    local ao = get_player_action_orderer()
    if ao then
        apply_native_reload_precede_inhibit(ao, false, false)
    else
        native_reload_precede_inhibit_active = false
        suppress.precede_active = false
    end
end

suppress.refresh_precede_inhibit = function()
    if CFG.enabled ~= true then
        clear_native_reload_precede_inhibit_now()
        return
    end
    sync_native_reload_precede_inhibit(get_player_action_orderer())
end

local function install_action_orderer_strip_hook()
    if action_orderer_strip_hook_installed then return end

    local td = sdk.find_type_definition(NS("survivor.player.PlayerActionOrderer"))
    if not td then return end

    local update_method = td:get_method("doSurvivorActionOrdererUpdate")
    if not update_method then return end

    local action_orderer_this = nil
    sdk.hook(update_method,
        function(args)
            action_orderer_this = sdk.to_managed_object(args[2])
        end,
        function(retval)
            if action_orderer_this then
                sync_native_reload_precede_inhibit(action_orderer_this)
            end
            apply_vr_input_suppress()
            action_orderer_this = nil
            return retval
        end)

    action_orderer_strip_hook_installed = true
    log.info("[re2_vr_reload] Hooked PlayerActionOrderer (native reload inhibit + VR input suppress)")
end

local function make_suppress_prehook(method_label, extra_gate)
    return function()
        if is_sub_weapon_method_label(method_label) then return end
        local gate = extra_gate and extra_gate() == true
        if not gate then return end
        abort_blocked_native_reload(method_label)
        suppress.until_t = os.clock() + 0.35
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
end

local function method_signature(method)
    if not method then return nil end
    local ok, sig = pcall(function()
        if method.get_signature then
            return method:get_signature()
        end
        return method:get_name()
    end)
    if ok and sig then return tostring(sig) end
    ok, sig = pcall(function() return method:get_name() end)
    if ok and sig then return tostring(sig) end
    return tostring(method)
end

local function hook_method_once(method, method_label, extra_gate)
    if not method then return false end
    local sig = method_signature(method)
    local key = tostring(method_label) .. "|" .. sig
    if hooked_signatures[key] then return false end
    hooked_signatures[key] = true
    sdk.hook(method, make_suppress_prehook(method_label, extra_gate), function(retval)
        return retval
    end)
    return true
end

local function hook_named_methods(type_name, method_names, label_prefix, extra_gate)
    local td = sdk.find_type_definition(type_name)
    if not td then
        log.warn(string.format("[re2_vr_reload] Missing type %s", type_name))
        return 0
    end

    local hooked = 0
    for _, mname in ipairs(method_names or {}) do
        local method = td:get_method(mname)
        if hook_method_once(method, string.format("%s.%s", label_prefix, mname), extra_gate) then
            hooked = hooked + 1
        end
    end
    return hooked
end

local function hook_methods_by_prefix(type_name, prefixes, label_prefix, extra_gate)
    local td = sdk.find_type_definition(type_name)
    if not td then return 0 end

    local ok, methods = pcall(function() return td:get_methods() end)
    if not ok or type(methods) ~= "table" then return 0 end

    local hooked = 0
    for _, method in ipairs(methods) do
        local mname = nil
        pcall(function() mname = method:get_name() end)
        if type(mname) == "string" and not mname:find("Sub", 1, true) then
            for _, prefix in ipairs(prefixes or {}) do
                if mname == prefix or mname:find("^" .. prefix, 1, true) == 1 then
                    if hook_method_once(method, string.format("%s.%s", label_prefix, mname), extra_gate) then
                        hooked = hooked + 1
                    end
                    break
                end
            end
        end
    end
    return hooked
end

local function install_reload_hooks()
    if hooks_installed then return end

    local total = 0
    local eq_type = NS("survivor.Equipment")
    local gun_type = NS("implement.Gun")
    local inv_type = NS("survivor.Inventory")

    total = total + hook_named_methods(eq_type, {
        "requestReload",
        "reloadMainWeapon",
    }, "Equipment", should_block_native_reload_pipeline)

    total = total + hook_methods_by_prefix(eq_type, { "executeReload" }, "Equipment", should_block_native_reload_pipeline)

    total = total + hook_named_methods(eq_type, {
        "requestChangeBullet",
        "changeBulletMainWeapon",
    }, "Equipment", should_block_native_change_bullet)

    total = total + hook_methods_by_prefix(eq_type, { "executeChangeBullet" }, "Equipment", should_block_native_change_bullet)

    total = total + hook_methods_by_prefix(gun_type, { "executeReload" }, "Gun", should_block_native_reload_pipeline)

    total = total + hook_named_methods(gun_type, {
        "createCartridge",
    }, "Gun", should_block_native_change_bullet)

    total = total + hook_methods_by_prefix(gun_type, { "executeChangeBullet" }, "Gun", should_block_native_change_bullet)

    total = total + hook_named_methods(inv_type, {
        "reloadMainSlot",
        "changeBulletMainSlotWithoutReload",
        "changeBulletMainSlot",
    }, "Inventory", should_block_native_reload_pipeline)

    if total <= 0 then
        log.warn("[re2_vr_reload] Reload suppression hooks not ready yet")
        return
    end

    reload_hooks_count = total
    hooks_installed = true
    log.info(string.format("[re2_vr_reload] Installed %d native reload gate hook(s)", total))
end

local function tick_reload_hooks_install()
    if hooks_installed then return end
    install_reload_hooks()
    if not isreload_hook_installed then
        install_isreload_hook()
    end
end

local function install_isreload_hook()
    if isreload_hook_installed then return end

    local td = sdk.find_type_definition(NS("survivor.SurvivorCondition"))
    if not td then
        log.warn("[re2_vr_reload] SurvivorCondition type missing — reload IK spoof unavailable")
        return
    end

    local method = td:get_method("get_IsReload")
    if not method then
        log.warn("[re2_vr_reload] get_IsReload missing — reload IK spoof unavailable")
        return
    end

    sdk.hook(method,
        function() end,
        function(retval)
            if should_spoof_reload_state() then
                return false
            end
            return retval
        end)

    isreload_hook_installed = true
    log.info("[re2_vr_reload] Hooked SurvivorCondition.get_IsReload (spoof false during manual reload)")
end

load_cfg()
refresh_tuning_snapshot()

deps = {
    CFG = CFG,
    sc = sc,
    re2 = re2,
    suppress = suppress,
    ammo = ammo,
    frame = frame,
    save_cfg = save_cfg,
    manual_reload_context_active = manual_reload_context_active,
    is_weapon_enabled = is_weapon_enabled,
    get_weapon_go_name = get_weapon_go_name,
    weapon_label_for = weapon_label_for,
    weapon_display_name = weapon_display_name,
    mark_tuning_dirty = mark_tuning_dirty,
    refresh_tuning_snapshot = refresh_tuning_snapshot,
    on_mag_holster_suppress_change = sync_mag_holster_left_support_suppress,
    clear_native_reload_precede_inhibit_now = clear_native_reload_precede_inhibit_now,
    native_change_bullet_suspend_active = native_change_bullet_suspend_active,
}

init_reload_stack()

_G.__vr_mag_holster_get_cfg = function()
    return CFG.mag_holster
end
_G.__vr_mag_holster_set_cfg_field = function(key, value)
    CFG.mag_holster = CFG.mag_holster or {}
    CFG.mag_holster[key] = value
end
_G.__vr_mag_holster_save_cfg = save_cfg

local function should_play_empty_dry_fire()
    if not manual_reload_context_active() then return false end
    if not weapon_needs_reload() then return false end
    if reload_revolver and reload_revolver.is_revolver_weapon_active
        and reload_revolver.is_revolver_weapon_active() then
        return true
    end
    if reload_shell and reload_shell.is_shell_weapon_active and reload_shell.is_shell_weapon_active() then
        return true
    end
    return false
end

local function notify_dry_fire_sfx()
    if reload_util then
        reload_util.play("dry_fire")
    end
end

local function should_play_shell_empty_dry_fire()
    return should_play_empty_dry_fire()
end

local function play_blocked_fire_sfx_immediate()
    if not reload_util then return end
    if not should_hard_block_empty_fire() then return end
    if not manual_reload_context_active()
        and not (reload_pump and reload_pump.needs_pump()) then
        return
    end
    reload_util.play("dry_fire")
end

local function try_play_blocked_fire_sfx_on_input_edge()
    if not reload_util then return end
    if not manual_reload_context_active()
        and not (reload_pump and reload_pump.needs_pump()) then
        blocked_fire_sfx_prev.trigger = frame.vr_right_trigger == true
        blocked_fire_sfx_prev.grip_trigger = frame.vr_grip_trigger == true
        return
    end

    local trig = frame.vr_right_trigger == true
    local grip_trig = frame.vr_grip_trigger == true
    local trig_edge = trig and not blocked_fire_sfx_prev.trigger
    local grip_trig_edge = grip_trig and not blocked_fire_sfx_prev.grip_trigger
    blocked_fire_sfx_prev.trigger = trig
    blocked_fire_sfx_prev.grip_trigger = grip_trig

    if not trig_edge and not grip_trig_edge then return end
    play_blocked_fire_sfx_immediate()
end

local function tick_reload_fire_sfx()
    if not manual_reload_context_active() then
        blocked_fire_sfx_prev.trigger = frame.vr_right_trigger == true
        blocked_fire_sfx_prev.grip_trigger = frame.vr_grip_trigger == true
        return
    end
    try_play_blocked_fire_sfx_on_input_edge()
end

local function install_dry_fire_hook()
    if fire_hook_installed then return end
    local hooked = false
    local fire_request_blocked = false
    local function on_pre_fire()
        fire_request_blocked = false
        if should_hard_block_empty_fire() then
            play_blocked_fire_sfx_immediate()
            fire_request_blocked = true
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
        if reload_pump and reload_pump.on_pre_weapon_fired then
            reload_pump.on_pre_weapon_fired()
        end
        if should_play_empty_dry_fire() then
            notify_dry_fire_sfx()
        end
        if reload_pump and reload_pump.seal_pump_shot_in_flight then
            reload_pump.seal_pump_shot_in_flight()
        end
    end
    local function on_post_fire(retval)
        if reload_util and reload_pump and reload_pump.should_play_pump_fire_sfx then
            if reload_pump.should_play_pump_fire_sfx(fire_request_blocked) then
                local wp = get_weapon_go_name()
                reload_util.play("pump_fire", { wp = wp })
            end
        end
        if not fire_request_blocked and reload_pump then
            reload_pump.on_weapon_fired()
        end
        if reload_slide then
            local weapon = re2.weapon
            if weapon and reload_slide.is_slide_close_latched and reload_slide.is_slide_close_latched() then
                local n = sc(weapon, "getBulletNumber")
                if type(n) == "number" and n > 0 then
                    reload_slide.on_weapon_fired()
                end
            end
        end
        return retval
    end
    local gun_type = sdk.find_type_definition(NS("implement.Gun"))
    if gun_type then
        local method = gun_type:get_method("requestFire")
        if method then
            sdk.hook(method, on_pre_fire, on_post_fire)
            hooked = true
        end
    end
    local eq_type = sdk.find_type_definition(NS("survivor.Equipment"))
    if eq_type then
        local method = eq_type:get_method("requestFire")
        if method then
            sdk.hook(method, on_pre_fire, on_post_fire)
            hooked = true
        end
    end
    if hooked then
        fire_hook_installed = true
        log.info("[re2_vr_reload] Hooked requestFire for dry-fire rack + fire block")
    end
end

install_reload_hooks()
install_isreload_hook()
install_action_orderer_strip_hook()
install_vr_input_suppress_hooks()
install_dry_fire_hook()

re.on_frame(function()
    tick_reload_hooks_install()
    refresh_vr_input_cache()
    local menu_block = is_menu_blocking()
    if menu_block then
        silence_manual_reload_for_menu()
    elseif menu_block_manual_reload_prev then
        silence_manual_reload_for_menu()
    end
    menu_block_manual_reload_prev = menu_block
    apply_vr_input_suppress()
    update_manual_reload_globals()
    tick_player_locomotion()
    tick_reload_stack_reset()
    local wp = get_weapon_go_name()
    if reload_mag then reload_mag.update_weapon_cache() end
    if wp ~= prev_weapon_wp then
        suppress.end_change_bullet_suspend()
        if prev_weapon_wp ~= nil then
            if reload_slide then reload_slide.on_weapon_swap() end
            if reload_mag and reload_mag.on_weapon_swap then reload_mag.on_weapon_swap() end
            if reload_util then reload_util.on_weapon_swap() end
            if reload_pump then reload_pump.on_weapon_swap() end
            if reload_shell and reload_shell.on_weapon_swap then reload_shell.on_weapon_swap() end
            if reload_revolver and reload_revolver.on_weapon_swap then
                reload_revolver.on_weapon_swap(prev_weapon_wp)
            end
        end
        prev_weapon_wp = wp
        prev_bullet_count = nil
    end

    if not menu_block and not native_change_bullet_suspend_active() then
        if reload_pump then reload_pump.on_frame() end
        if reload_shell then reload_shell.on_frame() end
        if reload_revolver then reload_revolver.on_frame() end
    end

    if suppress.tick_change_bullet_suspend then
        suppress.tick_change_bullet_suspend()
    end

    if not CFG.enabled then
        if reload_mag then reload_mag.on_disabled() end
        if reload_slide then reload_slide.on_disabled() end
        if reload_pump then reload_pump.clear_globals() end
        if reload_shell then reload_shell.on_disabled() end
        if reload_revolver then reload_revolver.on_disabled() end
        sync_mag_holster_left_support_suppress(false)
        clear_native_reload_precede_inhibit_now()
    elseif not manual_reload_context_active() then
        if reload_mag then reload_mag.on_context_inactive() end
        if reload_slide then reload_slide.on_context_inactive() end
        if reload_shell then reload_shell.on_context_inactive() end
        if reload_revolver then reload_revolver.on_context_inactive() end
        sync_mag_holster_left_support_suppress(false)
        clear_native_reload_precede_inhibit_now()
    end

    local b_edge = frame.vr_reload_b and not prev_frame_vr_reload_b
    if not menu_block and not native_change_bullet_suspend_active()
        and b_edge and manual_reload_context_active() then
        suppress.until_t = os.clock() + 0.35
        if reload_revolver and reload_revolver.is_revolver_weapon_active
            and reload_revolver.is_revolver_weapon_active() then
            if reload_revolver.handle_b_edge then reload_revolver.handle_b_edge() end
        elseif reload_shell and reload_shell.is_shell_weapon_active and reload_shell.is_shell_weapon_active() then
            if reload_shell.handle_b_edge then reload_shell.handle_b_edge() end
        elseif reload_mag then
            reload_mag.handle_b_edge()
        end
        if reload_slide and reload_slide.arm_rack_for_reload then
            local skip_rack = reload_revolver and reload_revolver.is_revolver_weapon_active
                and reload_revolver.is_revolver_weapon_active()
            if not skip_rack then
                reload_slide.arm_rack_for_reload()
            end
        end
    end
    prev_frame_vr_reload_b = frame.vr_reload_b

    if not menu_block and manual_reload_context_active() and not native_change_bullet_suspend_active() and (
        frame.vr_reload_b
        or (frame.weapon_needs_reload and frame.vr_right_trigger and is_player_locomoting())) then
        suppress.until_t = os.clock() + 0.35
    end

    if not menu_block and not native_change_bullet_suspend_active() then
        if reload_mag then reload_mag.on_frame() end
        if reload_slide then reload_slide.on_frame() end
    end
    if reload_util then reload_util.update_listener() end
    tick_reload_fire_sfx()
    update_manual_reload_globals()
    if not menu_block and manual_reload_context_active() and not native_change_bullet_suspend_active() then
        sync_mag_holster_left_support_suppress(
            rawget(_G, "__vr_block_left_support_in_mag_holster_zone") == true)
    elseif menu_block then
        sync_mag_holster_left_support_suppress(false)
    end

    if not menu_block and manual_reload_context_active() and not native_change_bullet_suspend_active() and reload_slide then
        local weapon = re2.weapon
        if weapon then
            local n = sc(weapon, "getBulletNumber")
            if type(n) == "number" then
                if prev_bullet_count ~= nil and prev_bullet_count > 0 and n <= 0 then
                    local carried = reload_mag and reload_mag.get_mag_carried_rounds
                        and reload_mag.get_mag_carried_rounds() or 0
                    local slot_rounds = reload_mag and reload_mag.get_weapon_mag_slot_round_count
                        and reload_mag.get_weapon_mag_slot_round_count() or 0
                    if carried <= 0 and slot_rounds <= 0 then
                        reload_slide.on_dry_fire()
                    end
                end
                prev_bullet_count = n
            end
        else
            prev_bullet_count = nil
        end
    elseif menu_block then
        prev_bullet_count = nil
    else
        prev_bullet_count = nil
    end

    update_manual_reload_globals()
    try_execute_pending_reload_stack_reset()
end)

re.on_pre_application_entry("UpdateBehavior", function()
    sync_reload_input_inhibit(get_input_system())
end)

re.on_application_entry("UpdateBehavior", function()
    refresh_vr_input_cache()
    tick_reload_fire_sfx()
    if should_hard_block_empty_fire() then
        strip_weapon_anim_input_bits(get_input_system())
    end
end)

re.on_pre_application_entry("UpdateScene", function()
    if is_menu_blocking() then return end
    if reload_mag then reload_mag.on_update_scene() end
end)

re.on_pre_application_entry("UpdateMotion", function()
    if is_menu_blocking() then return end
    if reload_pump then reload_pump.on_pre_arm_ik() end
    if reload_pump then reload_pump.on_update_motion() end
    -- publish_visual=false: this call's rack.anchor world-matrix read is
    -- stale (engine hasn't recomputed it since our local_z write yet) --
    -- see the comment above update_slide_rack_trigger's publish block.
    if reload_slide and reload_slide.tick_trigger_rack then reload_slide.tick_trigger_rack(false) end
end)

re.on_pre_application_entry("LateUpdateBehavior", function()
    if is_menu_blocking() then return end
    if reload_pump then reload_pump.on_pre_arm_ik() end
    -- publish_visual=true: this call reliably reads a fresh world matrix.
    if reload_slide and reload_slide.tick_trigger_rack then reload_slide.tick_trigger_rack(true) end
end)

re.on_application_entry("LateUpdateBehavior", function()
    if is_menu_blocking() then
        silence_manual_reload_for_menu()
        return
    end
    if reload_mag then reload_mag.on_late_update() end
    if reload_shell then reload_shell.on_late_update() end
    if reload_revolver then reload_revolver.on_late_update() end
    if reload_util then reload_util.on_late_update() end
    if reload_pump then reload_pump.on_late_update() end
    if reload_slide then
        if reload_slide.update_rack_pull then reload_slide.update_rack_pull() end
        if reload_slide.update_slide_rack then reload_slide.update_slide_rack() end
        if reload_slide.sync_rack_motion then reload_slide.sync_rack_motion("LU") end
        if reload_slide.tick_hand_follow then reload_slide.tick_hand_follow() end
    end
end)

re.on_application_entry("PrepareRendering", function()
    if is_menu_blocking() then return end
    if reload_mag then reload_mag.on_prepare_rendering() end
    if reload_shell then reload_shell.on_prepare_rendering() end
    if reload_revolver then reload_revolver.on_prepare_rendering() end
    if reload_util then reload_util.on_prepare_rendering() end
    if reload_slide then
        if reload_slide.sync_rack_motion then reload_slide.sync_rack_motion("PR") end
        if reload_slide.tick_hand_follow then reload_slide.tick_hand_follow() end
    end
    update_manual_reload_globals()
end)

re.on_application_entry("BeginRendering", function()
    if is_menu_blocking() then return end
    if reload_slide then
        if reload_slide.sync_rack_motion then reload_slide.sync_rack_motion("BR") end
        if reload_slide.tick_hand_follow then reload_slide.tick_hand_follow() end
    end
end)

re.on_application_entry("UpdateJointExpression", function()
    if is_menu_blocking() then return end
    if reload_revolver and reload_revolver.on_joint_expression then
        reload_revolver.on_joint_expression()
    end
    if reload_slide and reload_slide.apply_slide_park then
        reload_slide.apply_slide_park("UJE")
    end
end)

local function draw_reload_ui()
    if not imgui.tree_node("Manual Reload") then return end
    local c, v

    c, v = draw_feature_enable_toggle(CFG.enabled == true, "reload_master", "Manual reload")
    if c then
        CFG.enabled = v
        save_cfg()
        update_manual_reload_globals()
    end

    if CFG.enabled ~= true then
        imgui.separator()
        imgui.tree_pop()
        return
    end

    imgui.separator()
    local wp = get_weapon_go_name()
    if type(wp) ~= "string" or wp == "" then
        imgui.text_colored("Current weapon: none", UI_MUTED)
        imgui.separator()
        imgui.tree_pop()
        return
    end

    imgui.text_colored("Current weapon: " .. weapon_display_name(wp), UI_ACCENT)

    if not weapon_reload_configured(wp) then
        imgui.text_colored("Manual reload not configured for this weapon.", UI_MUTED)
        imgui.separator()
        imgui.tree_pop()
        return
    end

    if not weapon_reload_applicable(wp) then
        imgui.text_colored("Manual reload not applicable for this weapon.", UI_MUTED)
        imgui.separator()
        imgui.tree_pop()
        return
    end

    local entry = weapon_entry(wp)
    if not entry then
        imgui.separator()
        imgui.tree_pop()
        return
    end

    if weapon_supports_mag_reload(wp) then
        draw_weapon_mode_toggle(entry.enabled == true, "reload_mag_" .. wp, "Mag manual reload", function(on)
            entry.enabled = on
            CFG.weapons[wp] = entry
        end)
    end

    if weapon_supports_pump_reload(wp) then
        draw_weapon_mode_toggle(entry.needs_manual_pump == true, "reload_pump_" .. wp, "Manual pump", function(on)
            entry.needs_manual_pump = on
            if on then
                if entry.block_native_pump == nil then
                    entry.block_native_pump = true
                end
            else
                entry.block_native_pump = false
            end
            CFG.weapons[wp] = entry
        end)
    end

    if weapon_supports_shell_reload(wp) then
        draw_weapon_mode_toggle(entry.needs_manual_shell_reload == true, "reload_shell_" .. wp, "Manual shell reload", function(on)
            entry.needs_manual_shell_reload = on
            CFG.weapons[wp] = entry
        end)
    end

    if weapon_supports_cylinder_reload(wp) then
        draw_weapon_mode_toggle(weapon_needs_manual_cylinder_reload(wp), "reload_cyl_" .. wp, "Manual cylinder reload", function(on)
            entry.needs_manual_cylinder_reload = on
            entry.needs_manual_revolver_reload = nil
            CFG.weapons[wp] = entry
        end)
    end

    -- Motion racking/pumping (real relative hand motion drives the slide/
    -- pump; LT keeps working as before either way). Master toggles -- they
    -- cover every trigger-rack / manual-pump weapon, shown here only when
    -- the current weapon actually uses the mechanism. Read nil-tolerant
    -- (absent key = enabled): these keys aren't in older saved JSONs, and
    -- merge_cfg replaces the slide_dock/manual_pump tables wholesale.
    if entry.trigger_slide_rack == true then
        draw_weapon_mode_toggle((CFG.slide_dock or {}).motion_rack_enabled ~= false,
            "motion_rack", "Motion slide rack (all slide-rack weapons)", function(on)
                CFG.slide_dock = CFG.slide_dock or {}
                CFG.slide_dock.motion_rack_enabled = on
            end)
        if (CFG.slide_dock or {}).motion_rack_enabled ~= false then
            local mrc, mrv = imgui.slider_float("Motion rack pull scale##motion_rack_scale",
                tonumber((CFG.slide_dock or {}).motion_pull_scale) or 1.0, 0.3, 3.0, "%.2f")
            if mrc then
                CFG.slide_dock = CFG.slide_dock or {}
                CFG.slide_dock.motion_pull_scale = mrv
                save_cfg()
            end
        end
    end

    if weapon_supports_pump_reload(wp) then
        draw_weapon_mode_toggle((CFG.manual_pump or {}).motion_pump_enabled ~= false,
            "motion_pump", "Motion pump action (all pump weapons)", function(on)
                CFG.manual_pump = CFG.manual_pump or {}
                CFG.manual_pump.motion_pump_enabled = on
            end)
        if (CFG.manual_pump or {}).motion_pump_enabled ~= false then
            local mpc, mpv = imgui.slider_float("Motion pump pull scale##motion_pump_scale",
                tonumber((CFG.manual_pump or {}).motion_pull_scale) or 1.0, 0.3, 3.0, "%.2f")
            if mpc then
                CFG.manual_pump = CFG.manual_pump or {}
                CFG.manual_pump.motion_pull_scale = mpv
                save_cfg()
            end
        end
    end

    imgui.separator()
    imgui.tree_pop()
end

_G.__vr_ui_callbacks = _G.__vr_ui_callbacks or {}
table.insert(_G.__vr_ui_callbacks, { order = 41, fn = draw_reload_ui })

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

log.info(string.format("[re2_vr_reload] Loaded cfg=%s", CFG_PATH))

return {}
