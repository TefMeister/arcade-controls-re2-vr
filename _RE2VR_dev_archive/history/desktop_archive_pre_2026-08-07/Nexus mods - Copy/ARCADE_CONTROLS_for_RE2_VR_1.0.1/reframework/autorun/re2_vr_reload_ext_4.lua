if package.loaded["re2_vr_reload_ext_4"] then
    return package.loaded["re2_vr_reload_ext_4"]
end

local M = {}

local Pump = {}

local CFG
local sc
local re2
local get_weapon_go_name
local manual_reload_context_active
local weapon_display_name
local mark_tuning_dirty

local NS = sdk.game_namespace

local SHOTGUN_WP_DEFAULT_PUMP = {
    wp1000 = true,
    wp1100 = true,
    wp1200 = true,
    wp1300 = true,
    wp1500 = true,
}

local PUMP_WWISE_TOKENS = {
    "pump", "reload", "shell", "cycle", "load", "chamber", "cartridge",
    "shotgun", "rack", "cock", "spark", "electric", "blowback",
}

local motion_type = sdk.typeof("via.motion.Motion")
local wwise_app_type = sdk.typeof(NS("WwiseContainerApp"))

local hooked_signatures = {}
local pump_hooks_installed = false

local motion_comp_cache = nil
local motion_comp_check_t = 0.0
local weapon_motion_list = nil
local weapon_motion_list_go = nil
local weapon_motion_check_t = 0.0
local pump_suppress_until = 0.0

local is_left_grip_pressed
local is_left_trigger_pressed
local play_reload_sfx
local haptic_pulse
local get_haptic_left_joystick
local slide_gesture
local get_weapon_chamber_bullet_count
local get_imgr_weapon_loaded
local get_weapon_mag_slot_round_count
local get_shell_hud_ammo

local gesture = {
    needs_pump = false,
    active = false,
    pull_done = false,
    pull_now = 0.0,
    pull_peak_signed = nil,
    pull_start_signed = 0.0,
    pull_increases_signed = true,
    pull_dir_locked = false,
    start_pos = nil,
    pull_ax = nil,
    pull_ay = nil,
    pull_az = nil,
    pull_axis_set = false,
    pull_axis_src = nil,
    pull_smooth = 0.0,
    pull_smooth_init = false,
    peak_play_off_x = nil,
    peak_play_off_y = nil,
    peak_play_off_z = nil,
    start_play_off_x = nil,
    start_play_off_y = nil,
    start_play_off_z = nil,
    pull_play_ax = nil,
    pull_play_ay = nil,
    pull_play_az = nil,
    last_wid = nil,
    pull_span_m = nil,
    push_span_m = nil,
    cached_wp = nil,
    anchor = nil,
    anchor_kind = nil,
    weapon_xform = nil,
    grab_bind_z = nil,
    last_grip = false,
    last_track_src = nil,
    prev_loaded = nil,
    pre_fire_chamber = nil,
    pre_fire_in_gun = nil,
    had_needs_pump_before_fire = false,
    await_pump_on_insert = false,
    pump_shot_in_flight = false,
    pump_await_grip_release = false,
    -- Left trigger hold/release state for the trigger-driven pump cycle.
    trigger_prev = false,
    -- 0.0 = parked/rest, 1.0 = fully pulled back. Ticked over real time
    -- toward a target each frame so the joint eases instead of snapping.
    pump_travel = 0.0,
    -- True once the trigger has been pressed for the current pull, so the
    -- pull-down animation commits to completing even if released early.
    pump_committed = false,
}

-- Shells physically in the weapon (chamber + tube), excluding reserve box ammo.
local function get_in_gun_shell_count()
    if get_shell_hud_ammo then
        local loaded = get_shell_hud_ammo()
        if type(loaded) == "number" then return math.max(0, math.floor(loaded)) end
    end
    if get_imgr_weapon_loaded then
        local n = get_imgr_weapon_loaded()
        if type(n) == "number" then return math.max(0, math.floor(n)) end
    end
    if get_weapon_mag_slot_round_count then
        local n = get_weapon_mag_slot_round_count()
        if type(n) == "number" and n > 0 then return math.max(0, math.floor(n)) end
    end
    return get_weapon_chamber_bullet_count and get_weapon_chamber_bullet_count() or 0
end

local pump_support_blend = 0.0
local pump_support_blend_dir = 0
local pump_origin_latched = false
local pump_fp_passthrough = false

local function vec3_dist(a, b)
    if not a or not b or type(a.x) ~= "number" or type(b.x) ~= "number" then return 1e9 end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function get_frame_id()
    if re.get_frame_count then
        local ok, n = pcall(re.get_frame_count)
        if ok and type(n) == "number" then return n end
    end
    return math.floor(os.clock() * 60.0)
end

local pump_complete_frame = -1

local function mp_cfg()
    return CFG and CFG.manual_pump or {}
end

local function np_cfg()
    return CFG.native_pump or {}
end

local function weapon_entry(wp)
    if not wp or type(CFG.weapons) ~= "table" then return nil end
    return CFG.weapons[wp]
end

function Pump.is_weapon_pump_capable(wp)
    if type(wp) ~= "string" then return false end
    local entry = weapon_entry(wp)
    if entry and (entry.needs_manual_pump ~= nil or entry.block_native_pump ~= nil) then
        return true
    end
    return SHOTGUN_WP_DEFAULT_PUMP[wp] == true
end

function Pump.is_weapon_pump_enabled(wp)
    if CFG.enabled ~= true or CFG.block_native_pump == false then return false end
    if type(wp) ~= "string" then return false end
    local entry = weapon_entry(wp)
    if entry and entry.block_native_pump == false then return false end
    if entry and entry.block_native_pump == true then return true end
    if np_cfg().default_shotgun_pump == false then return false end
    return SHOTGUN_WP_DEFAULT_PUMP[wp] == true
end

local function pump_weapon_equipped()
    return Pump.is_weapon_pump_enabled(get_weapon_go_name())
end

local function pump_suppress_wanted()
    if not pump_weapon_equipped() then return false end
    if np_cfg().when_equipped == false then
        return manual_reload_context_active()
    end
    return true
end

local function pump_window_active()
    return os.clock() < pump_suppress_until
end

local function arm_pump_suppress_window()
    pump_suppress_until = os.clock() + (tonumber(np_cfg().pump_window_sec) or 2.5)
end

local function token_matches(lower_name, tokens)
    if type(lower_name) ~= "string" or lower_name == "" then return false end
    for _, token in ipairs(tokens) do
        if lower_name:find(token, 1, true) ~= nil then return true end
    end
    return false
end

local function motion_name_is_re2_shotgun_weapon_cycle(lower_name)
    if type(lower_name) ~= "string" or lower_name == "" then return false end
    if lower_name:find("idle", 1, true) or lower_name:find("ready", 1, true) then
        return false
    end
    local is_shotgun_mesh = lower_name:find("wp1000", 1, true)
        or lower_name:find("wp1001", 1, true)
        or lower_name:find("wp1100", 1, true)
        or lower_name:find("wp1200", 1, true)
        or lower_name:find("wp1300", 1, true)
        or lower_name:find("wp1500", 1, true)
        or lower_name:find("sg02", 1, true)
        or lower_name:find("_sg0", 1, true)
    if not is_shotgun_mesh then return false end
    return lower_name:find("blowback", 1, true)
        or lower_name:find("pump", 1, true)
        or lower_name:find("cycle", 1, true)
        or lower_name:find("reload", 1, true)
        or lower_name:find("eject", 1, true)
        or lower_name:find("rack", 1, true)
end

local function motion_name_is_re2_spark_weapon_hold_cycle(lower_name)
    if type(lower_name) ~= "string" or lower_name == "" then return false end
    if not lower_name:find("wp4300", 1, true) then return false end
    if lower_name:find("idle", 1, true) then return false end
    return lower_name:find("hold", 1, true) or lower_name:find("pump", 1, true)
end

local function motion_name_is_re2_player_pump_cycle(lower_name)
    if type(lower_name) ~= "string" or lower_name == "" then return false end
    if not lower_name:find("pump", 1, true) then return false end
    if lower_name:find("idle", 1, true) and not lower_name:find("hold_pump", 1, true) then
        return false
    end
    return true
end

local function wwise_name_matches_pump(name)
    if type(name) ~= "string" or name == "" then return false end
    return token_matches(string.lower(name), PUMP_WWISE_TOKENS)
end

local function kill_motion_node(layer, node)
    if not layer or not node then return end
    pcall(function()
        local ef = sc(node, "get_EndFrame")
        if ef then node:call("set_Frame", ef) end
        node:call("set_Weight", 0.0)
    end)
    pcall(function()
        local lef = sc(layer, "get_EndFrame")
        if lef then layer:call("set_Frame", lef) end
        layer:call("set_Weight", 0.0)
        layer:call("set_Speed", 100.0)
    end)
end

local function scrub_motion_layer(mc, layer_index, source)
    if not mc then return end
    local layer = sc(mc, "getLayer", layer_index)
    if not layer then return end
    local node = sc(layer, "get_HighestWeightMotionNode")
    if not node then return end
    local name = sc(node, "get_MotionName")
    if not pump_suppress_wanted() then return end

    local weight = sc(node, "get_Weight") or 0.0
    if weight < 0.05 then return end

    local lower = type(name) == "string" and string.lower(name) or ""
    local np = np_cfg()
    local shotgun_weapon_cycle = source == "weapon"
        and pump_window_active()
        and np.scrub_pump_cycle ~= false
        and motion_name_is_re2_shotgun_weapon_cycle(lower)
    local spark_weapon_hold = source == "weapon"
        and pump_window_active()
        and np.scrub_pump_cycle ~= false
        and motion_name_is_re2_spark_weapon_hold_cycle(lower)
    local player_pump = source == "player"
        and pump_window_active()
        and np.scrub_player_motion ~= false
        and motion_name_is_re2_player_pump_cycle(lower)

    if not (shotgun_weapon_cycle or spark_weapon_hold or player_pump) then return end

    local frame = sc(node, "get_Frame") or 0.0
    local ef = sc(node, "get_EndFrame") or 0.0
    if ef > 0 then
        local progress = frame / ef
        local min_p = tonumber(np.pump_cycle_min_progress) or 0.20
        if player_pump then
            min_p = tonumber(np.re2_player_pump_min_progress) or 0.0
        elseif shotgun_weapon_cycle and lower:find("blowback", 1, true) then
            min_p = tonumber(np.re2_blowback_min_progress) or 0.08
        elseif spark_weapon_hold then
            min_p = tonumber(np.re2_blowback_min_progress) or 0.08
        end
        if progress < min_p then return end
    end

    kill_motion_node(layer, node)
end

local function try_motion_on_go(go)
    if not go or not motion_type then return nil end
    local mc = nil
    pcall(function() mc = go:call("getComponent(System.Type)", motion_type) end)
    return mc
end

local function collect_motion_components(go, out, depth, max_depth)
    if not go or not out or (depth or 0) > (max_depth or 4) then return end
    local mc = try_motion_on_go(go)
    if mc then out[#out + 1] = mc end
    local t = sc(go, "get_Transform")
    if not t then return end
    local n = sc(t, "get_ChildCount") or 0
    for i = 0, math.min(n - 1, 32) do
        local child = sc(t, "get_Child", i)
        local child_go = child and sc(child, "get_GameObject")
        if child_go then
            collect_motion_components(child_go, out, (depth or 0) + 1, max_depth)
        end
    end
end

local function find_player_motion()
    local now = os.clock()
    if motion_comp_cache and (now - motion_comp_check_t) < 1.0 then
        return motion_comp_cache
    end
    motion_comp_check_t = now
    motion_comp_cache = nil
    if not motion_type then return nil end

    local player = re2.get_localplayer()
    motion_comp_cache = try_motion_on_go(player)

    if not motion_comp_cache then
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local ctx = cm and sc(cm, "get_PlayerContextFast")
        local pgo = ctx and sc(ctx, "get_GameObject")
        motion_comp_cache = try_motion_on_go(pgo)
    end

    if not motion_comp_cache then
        local playman = sdk.get_managed_singleton(NS("PlayerManager"))
        local cond = playman and sc(playman, "get_CurrentPlayerCondition")
        local controller = cond and sc(cond, "get_Controller")
        local cgo = controller and sc(controller, "get_GameObject")
        motion_comp_cache = try_motion_on_go(cgo)
    end

    return motion_comp_cache
end

local function find_weapon_motion_components()
    local go = re2.weapon_gameobject
    if not go or not motion_type then return {} end
    local now = os.clock()
    if weapon_motion_list and weapon_motion_list_go == go and (now - weapon_motion_check_t) < 0.5 then
        return weapon_motion_list
    end
    weapon_motion_check_t = now
    weapon_motion_list_go = go
    weapon_motion_list = {}
    collect_motion_components(go, weapon_motion_list, 0, 6)
    if re2.weapon then
        local wm = sc(re2.weapon, "get_Motion")
        if wm then
            local found = false
            for _, mc in ipairs(weapon_motion_list) do
                if mc == wm then found = true; break end
            end
            if not found then weapon_motion_list[#weapon_motion_list + 1] = wm end
        end
    end
    return weapon_motion_list
end

local function scrub_motion_on_components(components, layers, source)
    if type(components) ~= "table" then return end
    for _, mc in ipairs(components) do
        for _, li in ipairs(layers or { 0, 1, 2, 3, 4, 5, 6, 7, 8 }) do
            scrub_motion_layer(mc, li, source)
        end
    end
end

local function scrub_pump_motions()
    if pump_suppress_wanted() ~= true then return end
    local np = np_cfg()
    if np.scrub_weapon_motion ~= false then
        scrub_motion_on_components(find_weapon_motion_components(), np.weapon_motion_layers, "weapon")
    end
    if np.scrub_player_motion ~= false then
        local pmc = find_player_motion()
        if pmc then
            scrub_motion_on_components({ pmc }, np.player_motion_layers, "player")
        end
    end
end

local function get_weapon_wwise_container()
    local go = re2.weapon_gameobject
    if not go then return nil end
    if wwise_app_type then
        local container = nil
        pcall(function() container = go:call("getComponent(System.Type)", wwise_app_type) end)
        if container then return container end
    end
    if re2.weapon then
        return sc(re2.weapon, "get_WwiseContainerApp")
    end
    return nil
end

local function safe_managed_object(arg)
    if arg == nil then return nil end
    local mo = nil
    pcall(function() mo = sdk.to_managed_object(arg) end)
    return mo
end

local function u32_from_arg(args, index)
    local v = nil
    pcall(function() v = sdk.to_int64(args[index]) end)
    if v then return v & 0xFFFFFFFF end
    return nil
end

local function resolve_trigger_name(container, trigger_id)
    if not container or not trigger_id then return nil end
    local id = trigger_id & 0xFFFFFFFF
    local ok, name = pcall(function() return container:call("getName(System.UInt32)", id) end)
    if ok and type(name) == "string" and name ~= "" then return name end
    ok, name = pcall(function() return container:call("getTriggerName(System.UInt32)", id) end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

local function wwise_hook_matches_weapon(mo)
    if not pump_weapon_equipped() then return false end
    local weapon_container = get_weapon_wwise_container()
    if not weapon_container or mo == nil then return false end
    return mo == weapon_container
end

local function should_block_wwise_trigger(trigger_name)
    if not pump_suppress_wanted() then return false end
    local np = np_cfg()
    if np.block_wwise_triggers ~= false and wwise_name_matches_pump(trigger_name) then
        return true
    end
    if np.block_wwise_in_pump_window ~= false
        and pump_window_active()
        and not (trigger_name and (
            trigger_name:find("fire", 1, true)
            or trigger_name:find("shot", 1, true))) then
        return true
    end
    return false
end

local function handle_wwise_trigger(container, trigger_id)
    if not pump_suppress_wanted() then return end
    local trigger_name = resolve_trigger_name(container, trigger_id)
    if should_block_wwise_trigger(trigger_name) then
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
end

local function on_wwise_trigger_u32(args)
    local mo = safe_managed_object(args[2])
    if not wwise_hook_matches_weapon(mo) then return end
    local trigger_id = u32_from_arg(args, 3)
    if not trigger_id then return end
    return handle_wwise_trigger(mo, trigger_id)
end

local function on_wwise_trigger_fsm(args)
    local mo = safe_managed_object(args[2])
    if not wwise_hook_matches_weapon(mo) then return end
    local fsm_idx = u32_from_arg(args, 3)
    if fsm_idx == nil then return end
    local trigger_id = nil
    pcall(function() trigger_id = mo:call("getTriggerIdByFsm", fsm_idx) end)
    if trigger_id then
        return handle_wwise_trigger(mo, trigger_id & 0xFFFFFFFF)
    end
    if pump_window_active() and pump_suppress_wanted()
        and np_cfg().block_wwise_in_pump_window ~= false then
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
end

local function hook_wwise_signature(type_name, signature, handler)
    local td = sdk.find_type_definition(type_name)
    if not td then return false end
    local method = td:get_method(signature)
    if not method then return false end
    local key = "wwise|" .. type_name .. "|" .. signature
    if hooked_signatures[key] then return false end
    hooked_signatures[key] = true
    sdk.hook(method,
        function(args) return handler(args) end,
        function(retval) return retval end)
    return true
end

function Pump.is_weapon_manual_pump_enabled(wp)
    if not CFG or CFG.enabled ~= true then return false end
    if mp_cfg().enabled == false then return false end
    if type(wp) ~= "string" then return false end
    local entry = weapon_entry(wp)
    if entry and entry.needs_manual_pump == false then return false end
    if entry and entry.needs_manual_pump == true then return true end
    if mp_cfg().default_shotgun_pump == false then return false end
    return SHOTGUN_WP_DEFAULT_PUMP[wp] == true
end

local function manual_pump_equipped()
    return Pump.is_weapon_manual_pump_enabled(get_weapon_go_name())
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

local function resolve_pump_anchor(weapon_xform, node_name)
    if not weapon_xform then return nil, nil end
    if not node_name then return weapon_xform, "xform" end
    local joint = sc(weapon_xform, "getJointByName", node_name)
    if joint then return joint, "joint" end
    local child_tf = find_transform_child_by_name(weapon_xform, node_name, 0)
    if child_tf then
        local child_joint = sc(weapon_xform, "getJointByName", node_name)
        if child_joint then return child_joint, "joint" end
        return child_tf, "xform"
    end
    return weapon_xform, "xform"
end

local function get_pump_node_name(wp)
    local mp = mp_cfg()
    if wp and type(mp.pump_node_by_wp) == "table" and mp.pump_node_by_wp[wp] then
        return mp.pump_node_by_wp[wp]
    end
    return "_01"
end

local function get_pump_bind_pose(wp_name)
    if slide_gesture and slide_gesture.gesture_get_bind_pose then
        return slide_gesture.gesture_get_bind_pose(wp_name)
    end
    return {
        x = 0.0,
        y = 0.0,
        rest_z = 0.0,
        parked_z = 0.0,
        back_z = -0.08,
    }
end

local function get_pump_pull_limits(wp_name)
    if slide_gesture and slide_gesture.gesture_get_pull_limits then
        return slide_gesture.gesture_get_pull_limits(wp_name)
    end
    local mp = mp_cfg()
    return tonumber(mp.pull_dist_default) or 0.05, tonumber(mp.push_dist_default) or 0.03
end

local function get_pump_effective_limits(wp_name)
    if slide_gesture and slide_gesture.gesture_effective_pull_dist then
        local pull_d = slide_gesture.gesture_effective_pull_dist(gesture, wp_name)
        local push_d = slide_gesture.gesture_effective_push_dist(gesture, wp_name)
        return pull_d, push_d
    end
    return get_pump_pull_limits(wp_name)
end

local function get_pull_deadzone()
    if slide_gesture and slide_gesture.gesture_get_deadzone then
        return slide_gesture.gesture_get_deadzone()
    end
    return 0.004
end

local function left_hand_fp_autodocked(slide_pos)
    if firstpersonmod ~= nil and type(firstpersonmod.was_gripping_weapon) == "function" then
        local ok, gripping = pcall(function() return firstpersonmod:was_gripping_weapon() end)
        if ok and gripping == true then return true end
    end
    if not slide_pos or type(slide_pos.x) ~= "number" then return false end
    local thresh = tonumber(mp_cfg().autodock_skip_blend_m) or 0.12
    local pos_fn = rawget(_G, "__vr_get_live_left_hand_for_slide_blend")
    local wrist = (type(pos_fn) == "function") and pos_fn() or nil
    if wrist and vec3_dist(wrist, slide_pos) <= thresh then return true end
    if firstpersonmod ~= nil and type(firstpersonmod.get_weapon_support_grip_world_pos) == "function" then
        local ok, grip = pcall(function() return firstpersonmod:get_weapon_support_grip_world_pos() end)
        if ok and grip and vec3_dist(grip, slide_pos) <= thresh then return true end
    end
    return false
end

local function pump_pull_arm_ik_wanted()
    if gesture.needs_pump ~= true or gesture.active ~= true then return false end
    local signed = math.abs(tonumber(gesture.pull_now) or 0.0)
    return signed > get_pull_deadzone()
end

local function resolve_pump_anchor_for_weapon(wp_name)
    local weapon_go = re2.weapon_gameobject
    if not weapon_go then
        gesture.anchor = nil
        gesture.anchor_kind = nil
        gesture.weapon_xform = nil
        return false
    end
    local wtf = sc(weapon_go, "get_Transform")
    if not wtf then return false end
    gesture.weapon_xform = wtf
    gesture.anchor, gesture.anchor_kind = resolve_pump_anchor(wtf, get_pump_node_name(wp_name))
    return gesture.anchor ~= nil
end

local function get_pump_joint()
    if gesture.anchor and gesture.anchor_kind == "joint" then
        return gesture.anchor
    end
    return gesture.anchor
end

local function pump_gesture_ctx()
    return {
        axis_mode = "joint",
        skip_dock = true,
        use_support_hand_start = true,
        preserve_axis = true,
        signed_global = "__vr_pump_pull_signed",
        grab_z_field = "grab_bind_z",
        get_joint = get_pump_joint,
        get_anchor_kind = function() return gesture.anchor_kind or "joint" end,
    }
end

local function prepare_pump_axis_for_weapon(wp)
    if not wp or not slide_gesture or not slide_gesture.gesture_prepare_pump_axis then return end
    resolve_pump_anchor_for_weapon(wp)
    slide_gesture.gesture_prepare_pump_axis(gesture, wp, pump_gesture_ctx())
end

local function compute_pump_hand_world_offset()
    if not gesture.pull_axis_set or not gesture.pull_ax then return nil end
    if not gesture.needs_pump and not gesture.active then return nil end
    local signed = tonumber(gesture.pull_now) or tonumber(rawget(_G, "__vr_pump_pull_signed")) or 0.0
    local along_m
    if gesture.pull_increases_signed then
        along_m = math.max(0.0, signed)
    else
        along_m = math.max(0.0, -signed)
    end
    if along_m < 1e-6 then return nil end
    return Vector3f.new(
        gesture.pull_ax * along_m,
        gesture.pull_ay * along_m,
        gesture.pull_az * along_m)
end

local function publish_pump_hand_joint_offset()
    if not gesture.needs_pump and not gesture.active then
        rawset(_G, "__vr_pump_hand_world_offset", nil)
        return
    end
    local off = compute_pump_hand_world_offset()
    if not off then
        rawset(_G, "__vr_pump_hand_world_offset", nil)
        return
    end
    rawset(_G, "__vr_pump_hand_world_offset", off)
end

local function set_pump_joint_local_z(travel, bp)
    local sj = get_pump_joint()
    if not sj or not bp then return end
    if slide_gesture and slide_gesture.set_bind_travel_local then
        local axis = bp.travel_axis or "z"
        slide_gesture.set_bind_travel_local(sj, travel, bp, axis)
        return
    end
    local saved = sc(sj, "get_LocalPosition")
    local sx = saved and type(saved.x) == "number" and saved.x or bp.x
    local sy = saved and type(saved.y) == "number" and saved.y or bp.y
    pcall(function()
        sj:call("set_LocalPosition", Vector3f.new(sx, sy, travel))
    end)
end

local function clear_gesture_pull_state()
    if slide_gesture and slide_gesture.gesture_reset_pull_fields then
        slide_gesture.gesture_reset_pull_fields(gesture, "__vr_pump_pull_signed")
    else
        gesture.pull_now = 0.0
        rawset(_G, "__vr_pump_pull_signed", nil)
    end
    gesture.pull_done = false
    gesture.pull_dir_locked = false
    gesture.pull_ax = nil
    gesture.pull_ay = nil
    gesture.pull_az = nil
    gesture.pull_axis_set = false
    gesture.pull_axis_src = nil
    rawset(_G, "__vr_pump_hand_world_offset", nil)
end

local function arm_pump_gesture(wp)
    if not wp then return end
    gesture.needs_pump = true
    gesture.cached_wp = wp
    local bp = get_pump_bind_pose(wp)
    if bp then
        gesture.grab_bind_z = bp.parked_z
        set_pump_joint_local_z(bp.parked_z, bp)
        prepare_pump_axis_for_weapon(wp)
    end
end

local function clear_manual_pump_state()
    gesture.needs_pump = false
    gesture.pump_shot_in_flight = false
    gesture.pump_await_grip_release = false
    gesture.active = false
    gesture.grab_bind_z = nil
    gesture.pull_span_m = nil
    gesture.push_span_m = nil
    gesture.pump_travel = 0.0
    gesture.pump_committed = false
    gesture.trigger_prev = false
    clear_gesture_pull_state()
    rawset(_G, "__vr_pump_pull_axis_x", nil)
    rawset(_G, "__vr_pump_pull_axis_y", nil)
    rawset(_G, "__vr_pump_pull_axis_z", nil)
end

local function try_end_chamber_clear()
    local weapon = re2.weapon
    if not weapon then return false end
    local ok = false
    pcall(function()
        weapon:call("endChamberClear")
        ok = true
    end)
    rawset(_G, "__vr_rack_chamber_commit_bypass", true)
    pcall(function() weapon:call("executeEndReload") end)
    pcall(function() weapon:call("executeEndEject") end)
    rawset(_G, "__vr_rack_chamber_commit_bypass", false)
    return ok
end

local function complete_pump_cycle(wp_name)
    local fid = get_frame_id()
    if pump_complete_frame == fid then return end
    pump_complete_frame = fid
    if play_reload_sfx then play_reload_sfx("slide_rack_release") end
    try_end_chamber_clear()
    local bp = get_pump_bind_pose(wp_name)
    set_pump_joint_local_z(bp.rest_z, bp)
    clear_manual_pump_state()
    gesture.await_pump_on_insert = false
    if get_weapon_chamber_bullet_count then
        gesture.prev_loaded = get_weapon_chamber_bullet_count()
    end
    if get_haptic_left_joystick and haptic_pulse then
        local lj = get_haptic_left_joystick()
        if lj then haptic_pulse(lj, 0.06, 200.0, 0.8) end
    end
end

local function apply_pump_bind(wp_name)
    if not wp_name then return end
    if slide_gesture and slide_gesture.gesture_apply_bind then
        slide_gesture.gesture_apply_bind(gesture, wp_name, pump_gesture_ctx(), set_pump_joint_local_z)
    else
        local bp = get_pump_bind_pose(wp_name)
        if bp and get_pump_joint() then
            set_pump_joint_local_z(gesture.needs_pump and bp.parked_z or bp.rest_z, bp)
        end
    end
end

local function pump_support_blocked()
    local mag_block = rawget(_G, "__vr_mag_in_left_hand") == true
        or rawget(_G, "__vr_mag_insert_active") == true
    local holster_block = rawget(_G, "__vr_block_left_support_in_mag_holster_zone") == true
    -- Grace/sub-weapon suppress must not block pump forend arm IK while needs_pump.
    if (gesture.needs_pump or gesture.active) and holster_block and not mag_block then
        holster_block = false
    end
    local grip = is_left_grip_pressed and is_left_grip_pressed() or false
    if gesture.pump_await_grip_release and grip then
        return true
    end
    return mag_block
        or rawget(_G, "__vr_shell_in_left_hand") == true
        or holster_block
        or rawget(_G, "__vr_slide_rack_active") == true
end

local function clear_pump_support_slide_dock()
    pump_support_blend = 0.0
    pump_support_blend_dir = 0
    pump_origin_latched = false
    pump_fp_passthrough = false
    rawset(_G, "__vr_pump_fp_passthrough", nil)
    rawset(_G, "__vr_pump_slide_support", nil)
    rawset(_G, "__vr_slide_left_pose_active", nil)
    if rawget(_G, "__vr_slide_rack_active") ~= true then
        rawset(_G, "__vr_slide_hand_world_pos", nil)
        rawset(_G, "__vr_slide_hand_world_rot", nil)
        rawset(_G, "__vr_slide_dock_blend_factor", 0)
        rawset(_G, "__vr_slide_dock_blend_from_pos", nil)
        rawset(_G, "__vr_slide_dock_blend_from_rot", nil)
        rawset(_G, "__vr_slide_dock_ik_pole", nil)
        rawset(_G, "__vr_slide_dock_ik_twist", nil)
        rawset(_G, "__vr_lh_slide_ik_override", false)
    end
end

local function capture_pump_support_blend_origin()
    if pump_origin_latched then return end
    local pos_fn = rawget(_G, "__vr_get_live_left_hand_for_slide_blend")
    local pos = (type(pos_fn) == "function") and pos_fn() or nil
    if pos and type(pos.x) == "number" then
        rawset(_G, "__vr_slide_dock_blend_from_pos", Vector3f.new(pos.x, pos.y, pos.z))
    end
    local rot_fn = rawget(_G, "__vr_get_live_left_hand_for_slide_blend_rot")
    local rot = (type(rot_fn) == "function") and rot_fn() or nil
    if rot then rawset(_G, "__vr_slide_dock_blend_from_rot", rot) end
    pump_origin_latched = true
end

-- Grouped into one table (instead of 4 separate top-level locals) to stay
-- under this file's 200 local-variable ceiling.
local pump_ease = {
    get_delta_time = function()
        local dt = 1.0 / 60.0
        if re.get_delta_time then
            local ok, d = pcall(function() return re.get_delta_time() end)
            if ok and type(d) == "number" and d > 0 then dt = d end
        end
        return dt
    end,
    smoothstep01 = function(x)
        if x <= 0.0 then return 0.0 end
        if x >= 1.0 then return 1.0 end
        return x * x * (3.0 - 2.0 * x)
    end,
}

local function get_pump_support_blend_speed()
    local mp = mp_cfg()
    return tonumber(mp.support_blend_speed) or 2.0
end

function pump_ease.get_pull_speed()
    local mp = mp_cfg()
    return tonumber(mp.pull_travel_speed) or 7.0
end

function pump_ease.get_push_speed()
    local mp = mp_cfg()
    return tonumber(mp.push_travel_speed) or 5.0
end

local function tick_pump_support_blend(want_on)
    if want_on and not pump_origin_latched and pump_support_blend <= 0.001 then
        capture_pump_support_blend_origin()
    end
    local target = want_on and 1.0 or 0.0
    pump_support_blend_dir = (pump_support_blend < target - 1e-5) and 1
        or ((pump_support_blend > target + 1e-5) and -1 or 0)

    local dt = pump_ease.get_delta_time()
    local speed = get_pump_support_blend_speed()
    if pump_support_blend < target then
        pump_support_blend = math.min(pump_support_blend + speed * dt, target)
    elseif pump_support_blend > target then
        pump_support_blend = math.max(pump_support_blend - speed * dt, target)
    end

    local eased = pump_support_blend * pump_support_blend * (3.0 - 2.0 * pump_support_blend)
    rawset(_G, "__vr_slide_dock_blend_factor", eased)
    if eased <= 0.001 and target <= 0.001 then
        rawset(_G, "__vr_slide_dock_blend_from_pos", nil)
        rawset(_G, "__vr_slide_dock_blend_from_rot", nil)
        pump_support_blend_dir = 0
        pump_origin_latched = false
    end
    return eased
end

local function update_pump_support_slide_dock(wp_name)
    if not wp_name or not manual_pump_equipped() then
        tick_pump_support_blend(false)
        if pump_support_blend <= 0.001 then clear_pump_support_slide_dock() end
        return
    end
    if pump_support_blocked() then
        tick_pump_support_blend(false)
        if pump_support_blend <= 0.001 then clear_pump_support_slide_dock() end
        return
    end

    local grip = is_left_grip_pressed and is_left_grip_pressed() or false
    local want_support = grip
        and gesture.needs_pump
        and resolve_pump_anchor_for_weapon(wp_name)
        and gesture.anchor ~= nil
        and slide_gesture
        and slide_gesture.publish_weapon_support_dock

    if not want_support then
        tick_pump_support_blend(false)
        if pump_support_blend <= 0.001 then clear_pump_support_slide_dock() end
        return
    end

    if not gesture.needs_pump and not gesture.active then
        local bp = get_pump_bind_pose(wp_name)
        if bp then set_pump_joint_local_z(bp.rest_z, bp) end
    end

    -- Hold grip while empty: keep C++ FP autosnap on weapon grip until forend pull starts.
    if not pump_pull_arm_ik_wanted() then
        pump_fp_passthrough = true
        rawset(_G, "__vr_pump_fp_passthrough", true)
        rawset(_G, "__vr_pump_slide_support", nil)
        rawset(_G, "__vr_slide_left_pose_active", nil)
        tick_pump_support_blend(false)
        if pump_support_blend <= 0.001 then
            pump_origin_latched = false
            if rawget(_G, "__vr_slide_rack_active") ~= true then
                rawset(_G, "__vr_slide_hand_world_pos", nil)
                rawset(_G, "__vr_slide_hand_world_rot", nil)
                rawset(_G, "__vr_slide_dock_blend_factor", 0)
                rawset(_G, "__vr_lh_slide_ik_override", false)
            end
        end
        return
    end

    if pump_fp_passthrough or not pump_origin_latched then
        pump_fp_passthrough = false
        rawset(_G, "__vr_pump_fp_passthrough", nil)
        pump_origin_latched = false
        capture_pump_support_blend_origin()
        pump_support_blend = 1.0
    end

    local ok = slide_gesture.publish_weapon_support_dock(
        wp_name, gesture.anchor, gesture.anchor_kind, gesture.weapon_xform)
    if not ok then
        tick_pump_support_blend(false)
        if pump_support_blend <= 0.001 then clear_pump_support_slide_dock() end
        return
    end
    if slide_gesture.publish_slide_dock_ik_twist then
        slide_gesture.publish_slide_dock_ik_twist(wp_name)
    end

    local eased = tick_pump_support_blend(true)
    rawset(_G, "__vr_pump_slide_support", eased > 0.001)
    rawset(_G, "__vr_slide_left_pose_active", eased > 0.001)
end

local function publish_gesture_globals(wp_name)
    rawset(_G, "__vr_needs_pump", gesture.needs_pump == true)
    local dz = get_pull_deadzone()
    local signed = math.abs(tonumber(gesture.pull_now) or 0.0)
    rawset(_G, "__vr_pump_active", gesture.active == true and signed > dz)
    if gesture.weapon_xform and (gesture.needs_pump or gesture.active) then
        local ax = sc(gesture.weapon_xform, "get_AxisX")
        local ay = sc(gesture.weapon_xform, "get_AxisY")
        if ax then
            rawset(_G, "__vr_slide_dock_ik_pole", Vector3f.new(ax.x, ax.y, ax.z))
        elseif ay then
            rawset(_G, "__vr_slide_dock_ik_pole", Vector3f.new(ay.x, ay.y, ay.z))
        end
    end
    if wp_name then
        local pull_d, push_d = get_pump_effective_limits(wp_name)
        rawset(_G, "__vr_pump_pull_dist", pull_d)
        rawset(_G, "__vr_pump_push_dist", push_d)
    end
end

local function latch_pump_after_shell_insert()
    gesture.pump_await_grip_release = true
    gesture.active = false
    clear_gesture_pull_state()
    clear_pump_support_slide_dock()
end

local function update_manual_pump_gesture()
    if not manual_pump_equipped() then
        if gesture.needs_pump or gesture.active then
            clear_manual_pump_state()
        end
        clear_pump_support_slide_dock()
        publish_gesture_globals(nil)
        return
    end
    if rawget(_G, "__vr_shell_in_left_hand") == true then
        clear_pump_support_slide_dock()
        publish_gesture_globals(get_weapon_go_name())
        return
    end
    if not slide_gesture or not slide_gesture.gesture_update_pull then
        publish_gesture_globals(get_weapon_go_name())
        return
    end

    local wp = get_weapon_go_name()
    if wp ~= gesture.cached_wp then
        gesture.cached_wp = wp
        gesture.anchor = nil
        gesture.grab_bind_z = nil
        gesture.pull_span_m = nil
        gesture.push_span_m = nil
    end
    if wp then resolve_pump_anchor_for_weapon(wp) end

    local grip = is_left_grip_pressed and is_left_grip_pressed() or false
    if gesture.pump_await_grip_release and not grip then
        gesture.pump_await_grip_release = false
    end
    local pull_d, push_d = get_pump_effective_limits(wp)

    -- Trigger-driven pump cycle (replaces the tracked-hand pull/push gesture):
    --   left grip  = hold the pump handle (existing dock/support-pose logic, unchanged)
    --   left trigger held   = pump pulled down
    --   left trigger release = pump returns and the cycle completes
    if gesture.needs_pump and grip then
        if not gesture.active then
            if not gesture.pump_await_grip_release then
                gesture.active = true
                gesture.pull_done = false
                gesture.pull_now = 0.0
                gesture.pump_travel = 0.0
                gesture.pump_committed = false
                gesture.trigger_prev = false
                -- pull_ax/ay/az and grab_bind_z were already captured by
                -- arm_pump_gesture() when the weapon became pump-ready, so
                -- the hand-follow offset still works.
            end
        end

        if gesture.active then
            local trig = is_left_trigger_pressed and is_left_trigger_pressed() or false
            local trig_pressed_edge = trig and not gesture.trigger_prev
            gesture.trigger_prev = trig

            if trig_pressed_edge and not gesture.pull_done then
                -- Commit to finishing the pull-down even if the trigger is
                -- released early (a quick tap still fully racks the pump).
                gesture.pump_committed = true
            end

            -- Before a press is registered, stay parked at travel 0. Once
            -- committed, ease to fully pulled regardless of trigger level.
            -- After that, follow the trigger level for the return trip.
            local target
            if not gesture.pull_done then
                target = gesture.pump_committed and 1.0 or 0.0
            else
                target = trig and 1.0 or 0.0
            end

            local speed = (target > gesture.pump_travel) and pump_ease.get_pull_speed()
                or pump_ease.get_push_speed()
            local dt = pump_ease.get_delta_time()
            if gesture.pump_travel < target then
                gesture.pump_travel = math.min(gesture.pump_travel + speed * dt, target)
            elseif gesture.pump_travel > target then
                gesture.pump_travel = math.max(gesture.pump_travel - speed * dt, target)
            end
            local eased = pump_ease.smoothstep01(gesture.pump_travel)
            -- pull_now is treated elsewhere as a real distance in meters
            -- (e.g. the arm-IK support gate), so scale by the configured
            -- pull distance rather than using the raw 0..1 travel value.
            gesture.pull_now = eased * pull_d

            local bp = get_pump_bind_pose(wp)
            if bp then
                if not gesture.pull_done then
                    -- Pulling phase: ease from the parked grab pose to fully back.
                    local base_z = gesture.grab_bind_z or bp.parked_z
                    set_pump_joint_local_z(base_z + eased * (bp.back_z - base_z), bp)
                else
                    -- Held / returning phase: ease between fully back and rest.
                    set_pump_joint_local_z(bp.rest_z + eased * (bp.back_z - bp.rest_z), bp)
                end
            end

            if not gesture.pull_done and gesture.pump_committed and gesture.pump_travel >= 1.0 - 1e-4 then
                gesture.pull_done = true
                if play_reload_sfx then play_reload_sfx("slide_rack_pull") end
                if get_haptic_left_joystick and haptic_pulse then
                    local lj = get_haptic_left_joystick()
                    if lj then haptic_pulse(lj, 0.06, 220.0, 0.7) end
                end
                -- Signal for re2_vr_delayed_shell_eject.lua: the pump
                -- handle has just been fully pulled down (distinct from
                -- complete_pump_cycle(), which only fires after the
                -- handle is released and returns to rest). The spent
                -- shell should eject on the pull-down, not the return.
                rawset(_G, "__vr_pump_pulled_down_wp", wp)
            elseif gesture.pull_done and not trig and gesture.pump_travel <= 1e-4 then
                -- Fully returned after a genuine release: finish the cycle.
                complete_pump_cycle(wp)
                publish_gesture_globals(wp)
                gesture.last_grip = grip
                return
            end
        end
    elseif gesture.active and not grip then
        -- Grip let go before the trigger was released: abort back to parked,
        -- same as letting go mid-cycle did originally.
        gesture.active = false
        gesture.trigger_prev = false
        gesture.pump_travel = 0.0
        gesture.pump_committed = false
        clear_gesture_pull_state()
        local bp = get_pump_bind_pose(wp)
        if bp then set_pump_joint_local_z(bp.parked_z, bp) end
        apply_pump_bind(wp)
    elseif gesture.needs_pump then
        apply_pump_bind(wp)
    end

    gesture.last_grip = grip
    update_pump_support_slide_dock(wp)
    publish_gesture_globals(wp)
end

function Pump.install_hooks()
    if pump_hooks_installed then return end
    local wwise_app = NS("WwiseContainerApp")
    local n = 0
    if hook_wwise_signature(wwise_app, "trigger(System.UInt32)", on_wwise_trigger_u32) then
        n = n + 1
    end
    if hook_wwise_signature(wwise_app,
        "triggerByFsm(System.UInt32, via.wwise.RequestInfo)", on_wwise_trigger_fsm) then
        n = n + 1
    end
    pump_hooks_installed = true
    if n > 0 then
        log.info(string.format("[re2_vr_reload] installed %d Wwise hook(s)", n))
    end
end

function Pump.init_module(deps)
    CFG = deps.CFG
    sc = deps.sc
    re2 = deps.re2
    get_weapon_go_name = deps.get_weapon_go_name
    manual_reload_context_active = deps.manual_reload_context_active
    weapon_display_name = deps.weapon_display_name or function(wp) return tostring(wp) end
    mark_tuning_dirty = deps.mark_tuning_dirty or function() end
    is_left_grip_pressed = deps.is_left_grip_pressed
    is_left_trigger_pressed = deps.is_left_trigger_pressed
    slide_gesture = deps.reload_slide
    play_reload_sfx = deps.play_reload_sfx
    haptic_pulse = deps.haptic_pulse
    get_haptic_left_joystick = deps.get_haptic_left_joystick
    get_weapon_chamber_bullet_count = deps.get_weapon_chamber_bullet_count
    get_imgr_weapon_loaded = deps.get_imgr_weapon_loaded
    get_weapon_mag_slot_round_count = deps.get_weapon_mag_slot_round_count
    get_shell_hud_ammo = deps.get_shell_hud_ammo
    Pump.install_hooks()
    rawset(_G, "__vr_reload_pump", Pump)
end

function Pump.needs_pump()
    return gesture.needs_pump == true
end

function Pump.pump_shot_in_flight()
    return gesture.pump_shot_in_flight == true
end

function Pump.should_block_fire()
    return gesture.needs_pump == true or gesture.pump_shot_in_flight == true
end

local function will_require_pump_from_pre_fire()
    local chamber = tonumber(gesture.pre_fire_chamber)
    local in_gun = tonumber(gesture.pre_fire_in_gun)
    if chamber == nil or in_gun == nil then return false end
    return chamber > 0 and in_gun > 1
end

-- Seal in-flight before post-fire so same-frame follow-up requestFire is blocked without setting needs_pump (recoil).
function Pump.seal_pump_shot_in_flight()
    if gesture.had_needs_pump_before_fire == true then return end
    if not will_require_pump_from_pre_fire() then return end
    gesture.pump_shot_in_flight = true
end

function Pump.reset_stack_state()
    clear_manual_pump_state()
    gesture.cached_wp = nil
    gesture.await_pump_on_insert = false
    pump_suppress_until = 0.0
    Pump.invalidate_weapon_cache()
end

function Pump.invalidate_weapon_cache()
    weapon_motion_list = nil
    weapon_motion_list_go = nil
    motion_comp_cache = nil
end

function Pump.on_weapon_swap()
    Pump.invalidate_weapon_cache()
    pump_suppress_until = 0.0
    clear_manual_pump_state()
    clear_pump_support_slide_dock()
    gesture.cached_wp = nil
    gesture.await_pump_on_insert = false
    if get_weapon_chamber_bullet_count then
        gesture.prev_loaded = get_weapon_chamber_bullet_count()
    else
        gesture.prev_loaded = nil
    end
end

function Pump.on_pre_weapon_fired()
    local wp = get_weapon_go_name()
    if not Pump.is_weapon_manual_pump_enabled(wp) then
        gesture.had_needs_pump_before_fire = false
        gesture.pre_fire_chamber = nil
        gesture.pre_fire_in_gun = nil
        return
    end
    gesture.had_needs_pump_before_fire = gesture.needs_pump == true
    gesture.pre_fire_chamber = get_weapon_chamber_bullet_count and get_weapon_chamber_bullet_count() or 0
    gesture.pre_fire_in_gun = get_in_gun_shell_count()
end

function Pump.should_play_pump_fire_sfx(fire_was_blocked)
    if fire_was_blocked == true then return false end
    local wp = get_weapon_go_name()
    if not Pump.is_weapon_manual_pump_enabled(wp) then return false end
    if gesture.had_needs_pump_before_fire == true then return false end
    local chamber = tonumber(gesture.pre_fire_chamber)
    if chamber == nil or chamber <= 0 then return false end
    return true
end

-- needs_pump rules (tube shell reload interaction):
-- Tube empty / no insert yet: false
-- Shell top-up while needs_pump from a shot: stays true until manual pump
-- Fired with round in chamber AND another shell still in gun (prev_in_gun > 1): true
-- Last shot (only round in gun): false on fire; await_pump_on_insert until shells inserted
-- Dry fire on empty tube: false
-- After manual shell insert when gun was emptied: true (even if native sync chambers)
function Pump.on_weapon_fired()
    local wp = get_weapon_go_name()
    if pump_weapon_equipped() then
        arm_pump_suppress_window()
    end
    if Pump.is_weapon_manual_pump_enabled(wp) then
        gesture.pump_shot_in_flight = false
        local now_chamber = get_weapon_chamber_bullet_count and get_weapon_chamber_bullet_count() or 0

        local prev_chamber = tonumber(gesture.pre_fire_chamber)
        local prev_in_gun = tonumber(gesture.pre_fire_in_gun)
        gesture.pre_fire_chamber = nil
        gesture.pre_fire_in_gun = nil
        gesture.had_needs_pump_before_fire = false

        if prev_chamber == nil then
            prev_chamber = gesture.prev_loaded
            if prev_chamber == nil then
                -- requestFire post-hook: chamber count is already post-shot
                prev_chamber = now_chamber + 1
            end
        end
        prev_chamber = math.max(0, math.floor(prev_chamber))

        if prev_in_gun == nil then
            prev_in_gun = prev_chamber
        else
            prev_in_gun = math.max(0, math.floor(prev_in_gun))
        end

        if prev_chamber > 0 and prev_in_gun > 1 then
            gesture.needs_pump = true
            gesture.await_pump_on_insert = false
        else
            gesture.needs_pump = false
            if prev_chamber > 0 and prev_in_gun <= 1 then
                gesture.await_pump_on_insert = true
            end
        end

        gesture.prev_loaded = now_chamber

        if gesture.needs_pump then
            arm_pump_gesture(wp)
        end
        publish_gesture_globals(wp)
    end
end

function Pump.on_shell_inserted(applied, loaded_before, loaded_after)
    if applied ~= true then return end
    local wp = get_weapon_go_name()
    if not Pump.is_weapon_manual_pump_enabled(wp) then return end

    loaded_before = math.max(0, math.floor(tonumber(loaded_before) or 0))
    loaded_after = math.max(0, math.floor(tonumber(loaded_after) or 0))
    local loaded_increased = loaded_after > loaded_before

    if get_weapon_chamber_bullet_count then
        gesture.prev_loaded = get_weapon_chamber_bullet_count()
    end

    local arm_pump = gesture.needs_pump == true
    if loaded_increased and gesture.await_pump_on_insert then
        arm_pump = true
    end

    if arm_pump then
        latch_pump_after_shell_insert()
        arm_pump_gesture(wp)
        publish_gesture_globals(wp)
    end
end

function Pump.on_pre_arm_ik()
    if not CFG or CFG.enabled ~= true then return end
    update_manual_pump_gesture()
end

function Pump.on_late_update()
    if not CFG or CFG.enabled ~= true then return end
    publish_gesture_globals(get_weapon_go_name())
end

function Pump.should_spoof_isreload()
    if np_cfg().spoof_is_reload == false then return false end
    return pump_suppress_wanted()
end

function Pump.update_globals()
    local want = pump_suppress_wanted()
    rawset(_G, "__vr_shotgun_pump_suppress_active", want)
    rawset(_G, "__vr_block_empty_pump_reload_motion", want and pump_window_active())
    publish_gesture_globals(get_weapon_go_name())
end

function Pump.clear_globals()
    rawset(_G, "__vr_shotgun_pump_suppress_active", nil)
    rawset(_G, "__vr_block_empty_pump_reload_motion", nil)
    rawset(_G, "__vr_needs_pump", nil)
    rawset(_G, "__vr_pump_active", nil)
    rawset(_G, "__vr_pump_pull_signed", nil)
    rawset(_G, "__vr_pump_pull_dist", nil)
    rawset(_G, "__vr_pump_push_dist", nil)
    rawset(_G, "__vr_pump_hand_world_offset", nil)
    rawset(_G, "__vr_pump_pull_axis_x", nil)
    rawset(_G, "__vr_pump_pull_axis_y", nil)
    rawset(_G, "__vr_pump_pull_axis_z", nil)
    rawset(_G, "__vr_pump_fp_base_pos", nil)
    rawset(_G, "__vr_pump_fp_base_rot", nil)
    clear_pump_support_slide_dock()
end

function Pump.on_frame()
    if not CFG or CFG.enabled ~= true then
        Pump.clear_globals()
        return
    end
    if CFG.block_native_pump ~= false then
        scrub_pump_motions()
    end
    Pump.update_globals()
end

function Pump.on_update_motion()
    if not CFG or CFG.enabled ~= true or CFG.block_native_pump == false then return end
    scrub_pump_motions()
end






local Shell = {}

local CFG
local sc
local re2
local get_weapon_go_name
local manual_reload_context_active
local is_weapon_enabled
local weapon_display_name
local mark_tuning_dirty
local play_reload_sfx
local haptic_pulse
local get_haptic_left_joystick
local get_left_hand_position
local get_left_hand_joint
local get_mag_hand_hold_entry
local get_mag_dock_dist
local is_left_grip_pressed
local detach_mag_hand_for_shell
local get_weapon_chamber_bullet_count
local get_main_weapon_reserve_ammo_count
local prime_main_weapon_reloadable_pool
local get_weapon_reloadable_count
local apply_carried_mag_ammo
local get_shell_hud_ammo
local apply_single_shell_round
local reload_pump
local extend_suppress_window
local arm_left_support_grace
local try_shell_dock
local update_shell_in_hand
local reload_drop

local shell = {
    in_hand = false,
    weapon_wp = nil,
    mesh_ref = nil,
    gun_tf = nil,
    weapon_xform = nil,
    dock_joint = nil,
    target = nil,
    target_kind = nil,
    node_name = nil,
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
    tube_top_up_until = 0.0,
    port_rest_valid = false,
    port_wx = 0.0,
    port_wy = 0.0,
    port_wz = 0.0,
    anim_active = false,
    anim_start = 0.0,
    slide_lx0 = 0.0,
    slide_ly0 = 0.0,
    slide_lz0 = 0.0,
    slide_lx1 = 0.0,
    slide_ly1 = 0.0,
    slide_lz1 = 0.0,
    release_fall_active = false,
    release_start = 0.0,
    release_sx = 0.0,
    release_sy = 0.0,
    release_sz = 0.0,
    release_rx = 0.0,
    release_ry = 0.0,
    release_rz = 0.0,
    release_rw = 1.0,
    freeze_pose = false,
    freeze_wx = 0.0,
    freeze_wy = 0.0,
    freeze_wz = 0.0,
    frozen_rot_x = 0.0,
    frozen_rot_y = 0.0,
    frozen_rot_z = 0.0,
    frozen_rot_w = 1.0,
}

local function get_shell_joint_name(wp)
    if reload_drop then
        return reload_drop.resolve_drop_joint_name(CFG, wp)
    end
    if type(CFG.shell_joint_by_wp) == "table" and CFG.shell_joint_by_wp[wp] then
        return CFG.shell_joint_by_wp[wp]
    end
    if type(CFG.mag_node_by_wp) == "table" and CFG.mag_node_by_wp[wp] then
        return CFG.mag_node_by_wp[wp]
    end
    return "_04"
end

local function get_shell_mesh_indices(wp)
    local by_wp = CFG.shell_mesh_parts_by_wp
    if type(by_wp) == "table" and type(by_wp[wp]) == "table" then
        local entry = by_wp[wp]
        if type(entry[1]) == "number" then return entry end
        if type(entry.idx) == "number" then return { entry.idx } end
    end
    return nil
end

local function get_shell_hand_profile(wp)
    local spawn = CFG.shell_spawn_by_wp
    if type(spawn) == "table" and type(spawn[wp]) == "table" and type(spawn[wp].profile) == "table" then
        return spawn[wp].profile
    end
    local mh = CFG.mag_hand_hold
    if type(mh) == "table" and type(mh.by_wp) == "table" and type(mh.by_wp[wp]) == "table" then
        local wp_entry = mh.by_wp[wp]
        for _, prof_entry in pairs(wp_entry) do
            if type(prof_entry) == "table" and prof_entry.ox ~= nil then
                return prof_entry
            end
        end
    end
    if type(mh) == "table" then return mh end
    return sh_cfg().shell_hand or {}
end

local function shell_ease(t)
    if t <= 0.0 then return 0.0 end
    if t >= 1.0 then return 1.0 end
    return t * t * (3.0 - 2.0 * t)
end

local function shell_anim_duration(phase)
    local anim = CFG.anim or {}
    if phase == "insert" then
        return math.max(0.01, tonumber(anim.insert_sec) or 0.18)
    end
    if phase == "fall" then
        return math.max(0.01, tonumber(anim.fall_sec) or 0.5)
    end
    return math.max(0.01, tonumber(anim.drop_sec) or 0.18)
end

local function shell_fall_distance()
    return tonumber((CFG.anim or {}).fall_distance) or 1.2
end

local function get_shell_hand_hold_entry(wp)
    if get_mag_hand_hold_entry then
        local hold = get_mag_hand_hold_entry()
        if type(hold) == "table" then return hold end
    end
    return get_shell_hand_profile(wp)
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

local function resolve_shell_target(weapon_xform, node_name)
    if not weapon_xform or not node_name then return nil, nil end
    local joint = sc(weapon_xform, "getJointByName", node_name)
    if joint then return joint, "joint" end
    local child_tf = find_transform_child_by_name(weapon_xform, node_name, 0)
    if child_tf then
        local child_joint = sc(weapon_xform, "getJointByName", node_name)
        if child_joint then return child_joint, "joint" end
        return child_tf, "xform"
    end
    return nil, nil
end

local function read_target_local_position(target, kind)
    if not target then return nil end
    if kind == "joint" then
        local pos = sc(target, "get_LocalPosition")
        if pos then return pos end
        pos = sc(target, "get_BaseLocalPosition")
        if pos then return pos end
        local tf = sc(target, "get_Transform")
        if tf then
            pos = sc(tf, "get_LocalPosition")
            if pos then return pos end
        end
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

local function visual_hide_uses_scale()
    local vh = CFG and CFG.visual_hide
    if type(vh) ~= "table" then return true end
    return vh.mode ~= "legacy"
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

local function get_shell_parent_transform()
    if shell.target_kind == "joint" and shell.target then
        local tf = sc(shell.target, "get_Transform")
        if tf then
            local parent = sc(tf, "get_Parent")
            if parent then return parent end
        end
    end
    return shell.weapon_xform
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

local SHELL_CAPACITY_FALLBACK = {
    wp1000 = 5,
    wp1100 = 6,
    wp1200 = 7,
    wp1500 = 2,
}

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
    local tf = rawget(_G, "__vr_lh_joint")
    if tf then
        local r = sc(tf, "get_Rotation")
        if r then return r end
    end
    return nil
end

local function cache_shell_port_rest_world()
    if not shell.target or not shell.has_rest then
        shell.port_rest_valid = false
        return
    end
    local parent_tf = get_shell_parent_transform()
    if not parent_tf then
        shell.port_rest_valid = false
        return
    end
    local parent_rot = sc(parent_tf, "get_Rotation")
    local parent_pos = sc(parent_tf, "get_Position")
    if not parent_rot or not parent_pos then
        shell.port_rest_valid = false
        return
    end
    local local_pos = Vector3f.new(shell.rest_x, shell.rest_y, shell.rest_z)
    local world_off = parent_rot * local_pos
    shell.port_wx = parent_pos.x + world_off.x
    shell.port_wy = parent_pos.y + world_off.y
    shell.port_wz = parent_pos.z + world_off.z
    shell.port_rest_valid = true
end

local function get_shell_hand_world_pos_for_dock()
    if shell.in_hand and shell.target then
        local pos = read_target_world_position(shell.target, shell.target_kind)
        if pos then return pos, "shell_visual" end
    end
    local hpos = get_left_hand_position and get_left_hand_position()
    if hpos then return hpos, "hand_track" end
    local tpos = compute_shell_hand_world_pose()
    if tpos then return tpos, "hand_pose" end
    return nil, nil
end

local function sh_cfg()
    return CFG and CFG.shotgun_shell or {}
end

local function weapon_entry(wp)
    if not wp or type(CFG.weapons) ~= "table" then return nil end
    return CFG.weapons[wp]
end

function Shell.is_shell_weapon(wp)
    wp = wp or get_weapon_go_name()
    if not wp then return false end
    if sh_cfg().enabled == false then return false end
    local entry = weapon_entry(wp)
    if not entry then return false end
    if entry.needs_manual_shell_reload == true then return true end
    if (entry.needs_manual_pump == true or entry.block_native_pump == true)
        and type(CFG.shell_joint_by_wp) == "table"
        and CFG.shell_joint_by_wp[wp] then
        return true
    end
    return false
end

function Shell.is_shell_weapon_active()
    if not manual_reload_context_active() then return false end
    return Shell.is_shell_weapon(get_weapon_go_name())
end

local function get_tube_reloadable_slots()
    if get_weapon_reloadable_count then
        local n = get_weapon_reloadable_count()
        if type(n) == "number" then return math.max(0, math.floor(n)) end
    end
    return 0
end

local function get_shell_carried_reserve_for_reload()
    local carried_reserve = 0
    if get_shell_hud_ammo then
        local _, carried = get_shell_hud_ammo()
        if type(carried) == "number" then
            carried_reserve = math.max(0, math.floor(carried))
        end
    end
    if carried_reserve <= 0 and get_main_weapon_reserve_ammo_count then
        carried_reserve = get_main_weapon_reserve_ammo_count() or 0
    end
    return math.max(0, math.floor(carried_reserve))
end

local function shell_sub_weapon_grace_sec()
    local mh = CFG and CFG.mag_holster or {}
    return tonumber(mh.sub_weapon_grace_sec) or 2.0
end

local function arm_shell_reload_grace()
    local until_t = os.clock() + shell_sub_weapon_grace_sec()
    if until_t > (shell.shoot_ready_grace_until or 0) then
        shell.shoot_ready_grace_until = until_t
    end
    if until_t > (shell.tube_top_up_until or 0) then
        shell.tube_top_up_until = until_t
    end
end

local function sync_shell_tube_top_up_state()
    if not Shell.is_shell_weapon_active() then
        shell.tube_top_up_until = 0.0
        return
    end
    if os.clock() >= (shell.tube_top_up_until or 0) then return end
    local reloadable = get_tube_reloadable_slots()
    local reserve = get_shell_carried_reserve_for_reload()
    if reloadable <= 0 or reserve <= 0 then
        shell.tube_top_up_until = 0.0
    end
end

local function get_weapon_shell_capacity(wp)
    wp = wp or get_weapon_go_name()
    local loaded = get_weapon_chamber_bullet_count and get_weapon_chamber_bullet_count() or 0
    local reloadable = get_tube_reloadable_slots()
    local total = loaded + reloadable
    if total > 0 then return total end
    return SHELL_CAPACITY_FALLBACK[wp] or 5
end

local function get_shell_dock_dist(wp)
    local spawn = CFG.shell_spawn_by_wp
    if type(spawn) == "table" and type(spawn[wp]) == "table" and spawn[wp].dock_dist ~= nil then
        return tonumber(spawn[wp].dock_dist)
    end
    return tonumber(sh_cfg().dock_dist_default) or 0.22
end

local function get_mag_exit_local(wp)
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

local function get_shell_insert_dock_dist(wp)
    if get_mag_dock_dist then
        return get_mag_dock_dist(wp)
    end
    if type(CFG.mag_dock_by_wp) == "table" and type(CFG.mag_dock_by_wp[wp]) == "number" then
        return CFG.mag_dock_by_wp[wp]
    end
    return tonumber(CFG.mag_dock_default) or 0.20
end

local function measure_shell_insert_local_distance(wp)
    if not shell.target or not shell.in_hand then return nil end
    local cur = read_target_local_position(shell.target, shell.target_kind)
    if not cur then return nil end
    local exit_local = get_mag_exit_local(wp)
    return vec3_dist(cur, exit_local), cur, exit_local
end

local function get_dock_joint_name(wp)
    local by_wp = CFG.shell_dock_joint_by_wp
    if type(by_wp) == "table" and by_wp[wp] then return by_wp[wp] end
    return "Elevator"
end

local function resolve_dock_anchor(weapon_xform, wp)
    if not weapon_xform then return nil, nil end
    wp = wp or get_weapon_go_name()
    local dock_name = get_dock_joint_name(wp)
    for _, jn in ipairs({ dock_name, "Elevator", "elevator", "C_Attach_Hand_A" }) do
        if jn then
            local t, k = resolve_shell_target(weapon_xform, jn)
            if t then return t, k end
        end
    end
    return nil, nil
end

local function get_shell_dock_world_pos()
    if shell.dock_joint then
        local pos = read_target_world_position(shell.dock_joint, shell.dock_kind)
        if pos then return pos, "dock_joint" end
    end
    if shell.port_rest_valid then
        return Vector3f.new(shell.port_wx, shell.port_wy, shell.port_wz), "port_rest"
    end
    if shell.target and shell.has_rest and not shell.in_hand then
        local pos = read_target_world_position(shell.target, shell.target_kind)
        if pos then return pos, "shell_node" end
    end
    if shell.gun_tf then
        local pos = sc(shell.gun_tf, "get_Position")
        if pos then return pos, "gun_root" end
    end
    return nil, "none"
end

local function set_shell_joint_visible(visible)
    if not shell.target or not shell.has_rest then return end
    if visible then
        write_target_local_scale(shell.target, shell.target_kind,
            Vector3f.new(shell.rest_sx, shell.rest_sy, shell.rest_sz))
    else
        write_target_local_scale(shell.target, shell.target_kind, Vector3f.new(0, 0, 0))
    end
end

local function set_shell_mesh_visible(visible)
    if visual_hide_uses_scale() then
        set_shell_joint_visible(visible)
        return
    end
    if not shell.mesh_indices or #shell.mesh_indices == 0 then return end
    local gun = re2.weapon
    for _, idx in ipairs(shell.mesh_indices) do
        if gun then
            pcall(function() gun:call("setPartsEnable", visible == true, { idx }) end)
        end
        if shell.mesh_ref then
            pcall(function()
                shell.mesh_ref:call("setPartsEnable(System.UInt64, System.Boolean)", idx, visible == true)
            end)
        end
    end
end

local function clear_shell_freeze()
    if reload_drop then reload_drop.clear_freeze(shell) end
end

local function reset_shell_visual_joints()
    clear_shell_freeze()
    if shell.target and shell.has_rest then
        write_target_local_position(shell.target, shell.target_kind,
            Vector3f.new(shell.rest_x, shell.rest_y, shell.rest_z))
        write_target_local_rotation(shell.target, shell.target_kind,
            Quaternion.new(shell.rest_w, shell.rest_rx, shell.rest_ry, shell.rest_rz))
    end
    clear_shell_freeze()
end

local function apply_shell_frozen_pose()
    if not reload_drop then return end
    reload_drop.apply_frozen_pose(shell, shell.target, shell.target_kind,
        write_target_world_position_only, write_target_world_rotation)
end

local function disable_shell_visual()
    reset_shell_visual_joints()
    clear_shell_freeze()
    if visual_hide_uses_scale() then
        set_shell_joint_visible(false)
    elseif shell.enabled_parts then
        set_shell_mesh_visible(false)
    end
    shell.enabled_parts = false
end

local function refresh_weapon_refs()
    local weapon = re2.weapon
    if not weapon then
        shell.mesh_ref = nil
        shell.gun_tf = nil
        shell.weapon_xform = nil
        shell.dock_joint = nil
        shell.target = nil
        shell.target_kind = nil
        shell.has_rest = false
        return false
    end

    local go = re2.weapon_gameobject or sc(weapon, "get_GameObject")
    if not go then return false end

    local mesh = sc(weapon, "get_Mesh")
    if not mesh then
        pcall(function()
            local td = sdk.find_type_definition("via.render.Mesh")
            if td then
                mesh = go:call("getComponent(System.Type)", td:get_runtime_type())
            end
        end)
    end

    local tf = sc(go, "get_Transform")
    shell.mesh_ref = mesh
    shell.gun_tf = tf
    shell.weapon_xform = tf

    local wp = get_weapon_go_name()
    shell.dock_joint = nil
    shell.dock_kind = nil
    if tf then
        shell.dock_joint, shell.dock_kind = resolve_dock_anchor(tf, wp)
    end
    local node_name = get_shell_joint_name(wp)
    shell.node_name = node_name
    shell.mesh_indices = get_shell_mesh_indices(wp)

    local target, kind = resolve_shell_target(tf, node_name)
    if not target then
        shell.target = nil
        shell.target_kind = nil
        shell.has_rest = false
        log.warn(string.format("[re2_vr_reload] Shell node '%s' not found on %s", tostring(node_name), tostring(wp)))
        return false
    end

    local pos = read_target_local_position(target, kind)
    local rot = read_target_local_rotation(target, kind)
    if not pos then return false end

    shell.target = target
    shell.target_kind = kind
    shell.rest_x = pos.x
    shell.rest_y = pos.y
    shell.rest_z = pos.z
    if rot then
        shell.rest_w = rot.w
        shell.rest_rx = rot.x
        shell.rest_ry = rot.y
        shell.rest_rz = rot.z
    end
    local scv = read_target_local_scale(target, kind)
    if scv then
        shell.rest_sx = scv.x
        shell.rest_sy = scv.y
        shell.rest_sz = scv.z
    else
        shell.rest_sx = 1.0
        shell.rest_sy = 1.0
        shell.rest_sz = 1.0
    end
    shell.has_rest = true
    cache_shell_port_rest_world()

    log.info(string.format("[re2_vr_reload] Shell refs ok wp=%s node=%s kind=%s", tostring(wp), tostring(node_name), tostring(kind)))
    return true
end

local function compute_shell_hand_world_pose()
    local hand = get_left_hand_joint and get_left_hand_joint()
    local hpos, hrot
    if hand then
        hpos = sc(hand, "get_Position")
        hrot = sc(hand, "get_Rotation")
    end
    if not hpos then
        hpos = get_left_hand_position and get_left_hand_position()
    end
    if not hrot then
        hrot = get_left_hand_rotation()
    end
    if not hpos or not hrot then return nil, nil end

    local wp = get_weapon_go_name()
    local hold = get_shell_hand_hold_entry(wp)
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

local function drive_shell_to_hand()
    if not shell.in_hand or not shell.target or not shell.has_rest then return end
    local target_pos, target_rot = compute_shell_hand_world_pose()
    if not target_pos or not target_rot then return end

    set_shell_mesh_visible(true)
    shell.enabled_parts = true

    local parent_tf = get_shell_parent_transform()
    local local_pos, local_rot = world_pose_to_parent_local(parent_tf, target_pos, target_rot)
    if local_pos and local_rot then
        write_target_local_position(shell.target, shell.target_kind, local_pos)
        write_target_local_rotation(shell.target, shell.target_kind, local_rot)
    end
end

local function get_bullet_id()
    local inv = re2.inventory
    if not inv then return nil end
    local slot = sc(inv, "get_MainSlot")
    local bullet_id = slot and sc(slot, "get_BulletID")
    if bullet_id == nil then bullet_id = sc(inv, "get_MainSlotSurplusBulletID") end
    return bullet_id
end

local function wp_names_match(a, b)
    if not a or not b then return false end
    return string.lower(tostring(a)) == string.lower(tostring(b))
end

local function commit_pending_shell_insert()
    local pi = shell.pending_insert
    if not pi then return end

    shell.pending_insert = nil
    rawset(_G, "__vr_pending_shotgun_insert", nil)

    local wp = get_weapon_go_name()
    if not wp_names_match(wp, pi.wp) then
        log.warn(string.format(
            "[re2_vr_reload] Shell commit aborted wp mismatch had=%s now=%s",
            tostring(pi.wp), tostring(wp)))
        return
    end

    local loaded_before, carried_before = 0, 0
    if get_shell_hud_ammo then
        loaded_before, carried_before = get_shell_hud_ammo()
    elseif get_weapon_chamber_bullet_count then
        loaded_before = get_weapon_chamber_bullet_count() or 0
    end
    if get_main_weapon_reserve_ammo_count and carried_before <= 0 then
        carried_before = get_main_weapon_reserve_ammo_count() or 0
    end
    local commit_method = "none"
    local applied = false
    if apply_single_shell_round then
        local ok, method = apply_single_shell_round()
        if type(ok) == "boolean" then
            applied = ok
            commit_method = type(method) == "string" and method or "single"
        else
            applied = ok == true
        end
    end
    if not applied and apply_carried_mag_ammo then
        local target = loaded_before + (pi.consume_count or 1)
        applied = apply_carried_mag_ammo(target) == true
        commit_method = "apply_carried_mag_ammo"
    end
    local loaded_after, carried_after = loaded_before, carried_before
    if get_shell_hud_ammo then
        loaded_after, carried_after = get_shell_hud_ammo()
    elseif get_weapon_chamber_bullet_count then
        loaded_after = get_weapon_chamber_bullet_count() or loaded_before
    end
    if not applied and loaded_after > loaded_before then
        applied = true
    end
    log.info(string.format(
        "[re2_vr_reload] Shell commit wp=%s method=%s loaded %d->%d carried %d->%d applied=%s",
        tostring(wp), commit_method, loaded_before, loaded_after, carried_before, carried_after, tostring(applied)))
    if reload_pump and reload_pump.on_shell_inserted then
        reload_pump.on_shell_inserted(applied, loaded_before, loaded_after)
    end
    if arm_left_support_grace then arm_left_support_grace() end
    arm_shell_reload_grace()
end

local function tick_pending_insert()
    if shell.anim_active then return end
    if not shell.pending_insert then return end
    shell.pending_insert.frames_left = (shell.pending_insert.frames_left or 0) - 1
    if shell.pending_insert.frames_left > 0 then return end
    commit_pending_shell_insert()
end

local function begin_shell_insert_anim(add, wp)
    if not shell.target or not shell.has_rest then return false end
    drive_shell_to_hand()
    local cur = read_target_local_position(shell.target, shell.target_kind)
    if not cur then return false end
    local exit = get_mag_exit_local(wp)
    shell.slide_lx0 = cur.x
    shell.slide_ly0 = cur.y
    shell.slide_lz0 = cur.z
    shell.slide_lx1 = exit.x
    shell.slide_ly1 = exit.y
    shell.slide_lz1 = exit.z
    shell.anim_active = true
    shell.anim_start = os.clock()
    shell.in_hand = false
    shell.grip_prev = false
    rawset(_G, "__vr_shell_in_left_hand", true)
    set_shell_mesh_visible(true)
    shell.enabled_parts = true
    shell.pending_insert = {
        wp = wp,
        bullet_id = get_bullet_id(),
        consume_count = add,
        frames_left = 999999,
    }
    rawset(_G, "__vr_pending_shotgun_insert", shell.pending_insert)
    arm_shell_reload_grace()
    if extend_suppress_window then extend_suppress_window() end
    if arm_left_support_grace then arm_left_support_grace() end
    if play_reload_sfx then play_reload_sfx("mag_insert") end
    return true
end

local function tick_shell_insert_animation()
    if not shell.anim_active or not shell.target then return end
    local elapsed = os.clock() - shell.anim_start
    local duration = shell_anim_duration("insert")
    local t = elapsed / duration
    if t > 1.0 then t = 1.0 end
    local u = shell_ease(t)
    write_target_local_position(shell.target, shell.target_kind, Vector3f.new(
        shell.slide_lx0 + (shell.slide_lx1 - shell.slide_lx0) * u,
        shell.slide_ly0 + (shell.slide_ly1 - shell.slide_ly0) * u,
        shell.slide_lz0 + (shell.slide_lz1 - shell.slide_lz0) * u))
    write_target_local_rotation(shell.target, shell.target_kind, Quaternion.new(
        shell.rest_w, shell.rest_rx, shell.rest_ry, shell.rest_rz))
    if t < 1.0 then return end
    shell.anim_active = false
    commit_pending_shell_insert()
    arm_shell_reload_grace()
    disable_shell_visual()
    rawset(_G, "__vr_shell_in_left_hand", false)
end

local function begin_shell_hand_release()
    if not shell.in_hand or not shell.target or shell.anim_active then return end
    drive_shell_to_hand()
    local pos, hand_rot = compute_shell_hand_world_pose()
    if not pos then
        pos = read_target_world_position(shell.target, shell.target_kind)
    end
    if not pos then return end
    local rot = read_target_world_rotation(shell.target, shell.target_kind)
    if not rot then
        rot = hand_rot
    end

    shell.in_hand = false
    shell.grip_prev = false
    shell.release_fall_active = true
    shell.release_start = os.clock()
    shell.release_sx = pos.x
    shell.release_sy = pos.y
    shell.release_sz = pos.z
    if rot then
        shell.release_rx = rot.x
        shell.release_ry = rot.y
        shell.release_rz = rot.z
        shell.release_rw = rot.w
    end
    rawset(_G, "__vr_shell_in_left_hand", false)
    set_shell_mesh_visible(true)
    shell.enabled_parts = true
    write_target_world_position_only(shell.target, shell.target_kind, pos)
    if rot then
        write_target_world_rotation(shell.target, shell.target_kind, rot)
    end
    if reload_drop then reload_drop.begin_release(shell, pos, rot) end
    apply_shell_frozen_pose()
    if extend_suppress_window then extend_suppress_window() end
end

local function tick_shell_hand_release()
    if not shell.release_fall_active or not shell.target or not reload_drop then return end
    reload_drop.tick_release(shell, {
        target = shell.target,
        target_kind = shell.target_kind,
        write_world_pos = write_target_world_position_only,
        write_world_rot = write_target_world_rotation,
        ensure_visible = function()
            set_shell_mesh_visible(true)
            shell.enabled_parts = true
        end,
        on_complete = function()
            clear_shell_freeze()
            reset_shell_visual_joints()
            disable_shell_visual()
            if play_reload_sfx then play_reload_sfx("mag_floor") end
        end,
    })
end

local _shell_dock_refresh_t = 0

try_shell_dock = function()
    if shell.anim_active then return end
    if not shell.in_hand then return end

    local wp = get_weapon_go_name()
    if not Shell.is_shell_weapon(wp) then return end

    local reloadable = get_tube_reloadable_slots()
    local carried_reserve = get_shell_carried_reserve_for_reload()
    if reloadable <= 0 or carried_reserve <= 0 then
        return
    end

    if not shell.dock_joint and (not shell.target or not shell.has_rest) then
        refresh_weapon_refs()
    end

    local cfg = sh_cfg()
    local cooldown = tonumber(cfg.dock_cooldown) or 0.45
    local now = os.clock()
    if (now - shell.last_dock_t) < cooldown then return end

    if is_left_grip_pressed and not is_left_grip_pressed() then return end

    local dist_thr = get_shell_insert_dock_dist(wp)
    local hand_dist = measure_shell_insert_local_distance(wp)

    if hand_dist == nil then
        return
    end

    if hand_dist > dist_thr then return end

    local add = math.min(1, reloadable, carried_reserve)
    if add <= 0 then return end

    shell.last_dock_t = now
    begin_shell_insert_anim(add, wp)
end

update_shell_in_hand = function()
    if not shell.in_hand or shell.anim_active then return end
    drive_shell_to_hand()
    local grip_now = is_left_grip_pressed and is_left_grip_pressed() or false
    if shell.grip_prev and not grip_now then
        begin_shell_hand_release()
        return
    end
    if grip_now then
        try_shell_dock()
    end
    shell.grip_prev = grip_now
end

function Shell.holster_wants_shell_grab()
    if not Shell.is_shell_weapon_active() then return false end
    if shell.in_hand or shell.anim_active or shell.release_fall_active then return false end
    if shell.pending_insert then return false end

    local wp = get_weapon_go_name()
    local reloadable = get_tube_reloadable_slots()
    local reserve = get_shell_carried_reserve_for_reload()
    local wants = reloadable > 0 and reserve > 0
    if not wants then
        log.info(string.format(
            "[re2_vr_reload] Shell grab blocked wp=%s reloadable=%d reserve=%d",
            tostring(wp), reloadable, reserve))
    end
    return wants
end

function Shell.holster_context_active()
    if not Shell.is_shell_weapon_active() then return false end
    if not CFG.mag_holster or CFG.mag_holster.enabled == false then return false end
    return true
end

function Shell.holster_supply_available()
    if not Shell.is_shell_weapon_active() then return nil end
    if shell.in_hand or shell.pending_insert or shell.anim_active or shell.release_fall_active then
        return true
    end
    if get_shell_carried_reserve_for_reload() > 0 then
        return true
    end
    return false
end

function Shell.holster_empty_denial_active()
    if not Shell.is_shell_weapon_active() then return false end
    if shell.in_hand or shell.pending_insert then return false end
    return not Shell.holster_wants_shell_grab()
end

function Shell.has_shell_in_hand()
    return shell.in_hand == true
        or shell.anim_active == true
        or shell.pending_insert ~= nil
        or shell.release_fall_active == true
end

function Shell.shoot_ready_suppress_exempt()
    if not Shell.is_shell_weapon_active() then return false end
    if shell.in_hand or shell.anim_active or shell.pending_insert or shell.release_fall_active then
        return true
    end
    if os.clock() < (shell.shoot_ready_grace_until or 0) then return true end
    if os.clock() < (shell.tube_top_up_until or 0) then
        local reloadable = get_tube_reloadable_slots()
        local reserve = get_shell_carried_reserve_for_reload()
        return reloadable > 0 and reserve > 0
    end
    return false
end

function Shell.reload_session_active()
    return Shell.shoot_ready_suppress_exempt() == true
end

function Shell.on_holster_grab_edge()
    if not Shell.is_shell_weapon_active() then return false end
    if shell.in_hand or shell.anim_active or shell.release_fall_active then return false end
    if shell.pending_insert then return false end

    if prime_main_weapon_reloadable_pool then
        prime_main_weapon_reloadable_pool()
    end
    if not Shell.holster_wants_shell_grab() then return false end

    local wp = get_weapon_go_name()
    if detach_mag_hand_for_shell then detach_mag_hand_for_shell() end

    shell.weapon_wp = wp
    shell.in_hand = true
    shell.grip_prev = true
    rawset(_G, "__vr_shell_in_left_hand", true)

    local ok = refresh_weapon_refs()
    if ok then
        set_shell_mesh_visible(true)
        shell.enabled_parts = true
        drive_shell_to_hand()
    end

    if not ok then
        shell.in_hand = false
        shell.weapon_wp = nil
        rawset(_G, "__vr_shell_in_left_hand", nil)
    end

    log.info(string.format(
        "[re2_vr_reload] Shell holster grab wp=%s ok=%s node=%s",
        tostring(wp), tostring(ok), tostring(shell.node_name)))

    if play_reload_sfx then play_reload_sfx("mag_grab") end
    if extend_suppress_window then extend_suppress_window() end
    if arm_left_support_grace then arm_left_support_grace() end
    arm_shell_reload_grace()
    return ok
end

function Shell.handle_b_edge()
    if not Shell.is_shell_weapon_active() then return false end
    return true
end

function Shell.clear_state(clear_pending)
    shell.anim_active = false
    shell.anim_start = 0.0
    shell.release_fall_active = false
    shell.release_start = 0.0
    disable_shell_visual()
    shell.in_hand = false
    shell.weapon_wp = nil
    shell.grip_prev = false
    shell.shoot_ready_grace_until = 0.0
    shell.tube_top_up_until = 0.0
    shell.last_dock_t = 0.0
    rawset(_G, "__vr_shell_in_left_hand", nil)
    if clear_pending ~= false then
        shell.pending_insert = nil
        rawset(_G, "__vr_pending_shotgun_insert", nil)
    end
end

function Shell.clear_globals()
    Shell.clear_state(true)
end

function Shell.on_weapon_swap()
    reset_shell_visual_joints()
    Shell.clear_state(true)
    shell.mesh_ref = nil
    shell.gun_tf = nil
    shell.dock_joint = nil
    shell.target = nil
    shell.target_kind = nil
    shell.weapon_xform = nil
    shell.has_rest = false
    shell.mesh_indices = nil
end

function Shell.on_frame()
    if not CFG or CFG.enabled ~= true then
        Shell.clear_state(true)
        return
    end

    tick_pending_insert()
    tick_shell_insert_animation()
    tick_shell_hand_release()

    local pending_commit = shell.pending_insert ~= nil
    local shell_busy = shell.in_hand or shell.anim_active or pending_commit or shell.release_fall_active

    if not manual_reload_context_active() and not shell_busy then
        if shell.in_hand then
            Shell.clear_state(true)
        end
        rawset(_G, "__vr_shell_in_left_hand", nil)
        return
    end

    local wp = get_weapon_go_name()
    if shell.in_hand and shell.weapon_wp and wp ~= shell.weapon_wp then
        Shell.on_weapon_swap()
        return
    end

    if shell.in_hand then
        if shell.weapon_wp ~= wp or not shell.target or not shell.has_rest then
            refresh_weapon_refs()
        end
        if not shell.dock_joint then
            local dock_refresh_now = os.clock()
            if dock_refresh_now - _shell_dock_refresh_t >= 0.5 then
                _shell_dock_refresh_t = dock_refresh_now
                refresh_weapon_refs()
            end
        end
    end

    rawset(_G, "__vr_shell_in_left_hand",
        shell.in_hand == true or shell.anim_active == true or shell.pending_insert ~= nil)
    sync_shell_tube_top_up_state()
    rawset(_G, "__vr_shell_reload_blocks_sub_weapon", Shell.reload_session_active())
end

function Shell.on_late_update()
    tick_shell_insert_animation()
    tick_shell_hand_release()
    update_shell_in_hand()
end

function Shell.on_prepare_rendering()
    tick_shell_insert_animation()
    tick_shell_hand_release()
    if shell.in_hand and shell.target and shell.has_rest and not shell.anim_active then
        drive_shell_to_hand()
    elseif shell.release_fall_active then
        apply_shell_frozen_pose()
    end
end

function Shell.on_disabled()
    Shell.clear_globals()
end

function Shell.on_context_inactive()
    if shell.pending_insert or shell.anim_active or shell.release_fall_active then return end
    if shell.in_hand then
        Shell.clear_state(true)
    end
end

function Shell.reset_stack_state()
    Shell.clear_state(true)
end


function Shell.init_module(deps)
    CFG = deps.CFG
    sc = deps.sc
    re2 = deps.re2
    reload_drop = deps.reload_drop
    if reload_drop then
        reload_drop.init({ CFG = CFG })
    end
    get_weapon_go_name = deps.get_weapon_go_name
    manual_reload_context_active = deps.manual_reload_context_active
    is_weapon_enabled = deps.is_weapon_enabled
    weapon_display_name = deps.weapon_display_name or function(wp) return tostring(wp) end
    mark_tuning_dirty = deps.mark_tuning_dirty or function() end
    play_reload_sfx = deps.play_reload_sfx
    haptic_pulse = deps.haptic_pulse
    get_haptic_left_joystick = deps.get_haptic_left_joystick
    get_left_hand_position = deps.get_left_hand_position
    get_left_hand_joint = deps.get_left_hand_joint
    get_mag_hand_hold_entry = deps.get_mag_hand_hold_entry
    get_mag_dock_dist = deps.get_mag_dock_dist
    is_left_grip_pressed = deps.is_left_grip_pressed
    detach_mag_hand_for_shell = deps.detach_mag_hand_for_shell
    get_weapon_chamber_bullet_count = deps.get_weapon_chamber_bullet_count
    get_main_weapon_reserve_ammo_count = deps.get_main_weapon_reserve_ammo_count
    prime_main_weapon_reloadable_pool = deps.prime_main_weapon_reloadable_pool
    get_weapon_reloadable_count = deps.get_weapon_reloadable_count
    get_shell_hud_ammo = deps.get_shell_hud_ammo
    apply_carried_mag_ammo = deps.apply_carried_mag_ammo
    apply_single_shell_round = deps.apply_single_shell_round
    reload_pump = deps.reload_pump
    extend_suppress_window = deps.extend_suppress_window
    arm_left_support_grace = deps.arm_left_support_grace
end





M.pump = Pump
M.shell = Shell

function M.init(deps)
    Pump.init_module(deps)
    local shell_deps = {}
    for k, v in pairs(deps) do
        shell_deps[k] = v
    end
    shell_deps.reload_drop = deps.reload_drop
    shell_deps.reload_pump = Pump
    Shell.init_module(shell_deps)
end

package.loaded["re2_vr_reload_ext_4"] = M
return M
