local M = {}

function M.init(deps)
    local deps_ref = deps
    local CFG = deps.CFG
    local sc = deps.sc
    local re2 = deps.re2
    local manual_reload_context_active = deps.manual_reload_context_active
    local manual_reload_session_active = deps.manual_reload_session_active or function() return false end
    local is_weapon_enabled = deps.is_weapon_enabled
    local get_weapon_go_name = deps.get_weapon_go_name
    local weapon_display_name = deps.weapon_display_name or function(wp) return tostring(wp) end
    local get_left_hand_position = deps.get_left_hand_position
    local get_left_track_position = deps.get_left_track_position
    local get_left_track_pos_with_source = deps.get_left_track_pos_with_source
    local get_vr_controller_world_pos = deps.get_vr_controller_world_pos
    local is_left_grip_pressed = deps.is_left_grip_pressed
    local is_left_trigger_pressed = deps.is_left_trigger_pressed or function() return false end
    local get_bullet_number = deps.get_bullet_number or function()
        local w = re2.weapon
        if not w then return 0 end
        local n = sc(w, "getBulletNumber")
        return type(n) == "number" and n or 0
    end
    local haptic_pulse = deps.haptic_pulse or function() end
    local get_haptic_left_joystick = deps.get_haptic_left_joystick or function() return nil end
    local mark_tuning_dirty = deps.mark_tuning_dirty or function() end
    local get_mag_carried_rounds = deps.get_mag_carried_rounds or function() return 0 end
    local arm_left_support_grace = deps.arm_left_support_grace

    local weapon_uses_manual_cylinder_reload = deps.weapon_uses_manual_cylinder_reload
        or function() return false end
    local weapon_uses_chamber_bullet_follow = deps.weapon_uses_chamber_bullet_follow
        or function() return false end
    local get_chamber_bullet_open_bind_display = deps.get_chamber_bullet_open_bind_display
        or function() return { x = 0, y = 0, z = 0, pitch = 0, yaw = 0, roll = 0 } end
    local sync_chamber_bullet_pose = deps.sync_chamber_bullet_pose or function() end
    local apply_chamber_bullet_follow_open_t = deps.apply_chamber_bullet_follow_open_t
        or function() end
    local capture_cylinder_rest = deps.capture_cylinder_rest or function() return false end
    local revolver_invalidate_cylinder_joint_cache = deps.revolver_invalidate_cylinder_joint_cache
        or function() end

    local function sync_cylinder_joint_from_slide_node(wp)
        if not weapon_uses_manual_cylinder_reload(wp) then return end
        CFG.cylinder_joint_by_wp = CFG.cylinder_joint_by_wp or {}
        local slide_node = CFG.slide_dock.slide_node_by_wp and CFG.slide_dock.slide_node_by_wp[wp]
        if type(slide_node) ~= "string" or slide_node == "" then return end
        if CFG.cylinder_joint_by_wp[wp] ~= slide_node then
            CFG.cylinder_joint_by_wp[wp] = slide_node
        end
        revolver_invalidate_cylinder_joint_cache()
    end

    local hand_follow_frame = -1
    local function get_frame_id()
        if re.get_frame_count then
            local ok, n = pcall(re.get_frame_count)
            if ok and type(n) == "number" then return n end
        end
        return math.floor(os.clock() * 60.0)
    end

    local rack = {
        needs_rack = false,
        active = false,
        armed = true,
        in_range = false,
        hand_dock_blend = 0.0,
        hand_dock_target = 0.0,
        hand_dock_blend_dir = 0,
        cached_wp = nil,
        cached_weapon_go = nil,
        anchor = nil,
        anchor_kind = nil,
        weapon_xform = nil,
        miss_warned = false,
        last_dock_dist = nil,
        last_grip = false,
        dry_fired = false,
        pull_now = 0.0,
        pull_max = 0.0,
        pull_done = false,
        pull_peak_signed = nil,
        pull_start_signed = 0.0,
        peak_play_off_x = nil,
        peak_play_off_y = nil,
        peak_play_off_z = nil,
        pull_increases_signed = true,
        pull_dir_locked = false,
        start_pos = nil,
        pull_baseline = nil,
        pull_smooth = 0.0,
        pull_smooth_init = false,
        pull_ax = nil,
        pull_ay = nil,
        pull_az = nil,
        pull_axis_set = false,
        pull_axis_src = nil,
        was_rack_active = false,
        last_wid = nil,
        last_hand_x = nil,
        last_hand_y = nil,
        last_hand_z = nil,
        grab_slide_z = nil,
        pull_span_m = nil,
        push_span_m = nil,
        hold_rest_until = 0.0,
        latch_slide_closed = false,
        latch_slide_wp = nil,
        tactical_latch = false,
        start_play_off_x = nil,
        start_play_off_y = nil,
        start_play_off_z = nil,
        pull_play_ax = nil,
        pull_play_ay = nil,
        pull_play_az = nil,
        standing_origin = nil,
        standing_origin_set = false,
        -- Trigger-driven rack state (weapon_uses_trigger_rack weapons only).
        trig_travel = 0.0,
        trig_committed = false,
        trigger_prev = false,
        -- Set true the instant LT is released after a completed pull, so
        -- the hand detaches from the slide right there instead of at full
        -- cycle completion (see update_slide_rack_trigger / should_hand_dock).
        hand_released_early = false,
        grip_release_at = nil,
        -- Real controllers occasionally report a brief false grip read even
        -- under a sustained, deliberate squeeze (analog sensor noise /
        -- runtime polling hiccup). This flat window applies unconditionally
        -- to EVERY release (even an obvious one, hand already moving away),
        -- so it's kept short -- just enough to absorb a couple of frames of
        -- noise. Longer sustained false reads are handled by the
        -- grip_release_hard_cap_sec layer below instead, which only keeps
        -- waiting while the hand is corroborated as still at the dock, so it
        -- doesn't cost genuine releases any extra delay. Kept on the rack
        -- table (not a new top-level local) per this file's 200-local
        -- ceiling.
        grip_release_debounce_sec = 0.1,
        -- Past the debounce, keep absorbing a false grip read as long as the
        -- hand is still at the dock (rack.in_range) -- a real release is
        -- almost always followed by the hand moving away, a sensor glitch
        -- isn't. Hard ceiling so a genuine release with the hand left
        -- resting nearby still eventually aborts.
        grip_release_hard_cap_sec = 3.0,
    }

    local slide_preview = {
        active = false,
        until_t = 0.0,
        wp = nil,
        bind_z = "parked",
    }

    local slide_ui = {
        follow_equipped = true,
        edit_wp = nil,
        status = nil,
    }

    local function deep_copy(tbl)
        if type(tbl) ~= "table" then return tbl end
        local out = {}
        for k, v in pairs(tbl) do
            out[k] = deep_copy(v)
        end
        return out
    end

    local slide_clipboard = {
        slide_node = nil, -- string
        dock_entry = nil, -- table
        bind_entry = nil, -- table
        ik_twist_entry = nil, -- table
        source_wp = nil,
    }

    local function vec3_dist(a, b)
        if not a or not b then return 99.0 end
        local dx = a.x - b.x
        local dy = a.y - b.y
        local dz = a.z - b.z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    local function vec3_from_pos(p)
        if not p then return nil end
        if type(p.x) == "number" then
            return Vector3f.new(p.x, p.y, p.z)
        end
        return nil
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

    local function resolve_slide_anchor(weapon_xform, node_name)
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

    local function world_matrix_to_position(wm)
        if not wm or not wm[3] then return nil end
        local p = wm[3]
        if p.to_vec3 then
            local ok, v = pcall(function() return p:to_vec3() end)
            if ok and v then return v end
        end
        return Vector3f.new(p.x, p.y, p.z)
    end

    local function read_anchor_world_matrix(anchor, kind)
        if not anchor then return nil end
        if kind == "joint" then
            local wm = sc(anchor, "get_WorldMatrix")
            if wm then return wm end
            local tf = sc(anchor, "get_Transform")
            if tf then return sc(tf, "get_WorldMatrix") end
            return nil
        end
        return sc(anchor, "get_WorldMatrix")
    end

    local function read_anchor_position(anchor, kind)
        local wm = read_anchor_world_matrix(anchor, kind)
        local pos = world_matrix_to_position(wm)
        if pos then return pos end
        if not anchor then return nil end
        if kind == "joint" then
            local tf = sc(anchor, "get_Transform")
            if tf then return sc(tf, "get_Position") end
            return sc(anchor, "get_Position")
        end
        return sc(anchor, "get_Position")
    end

    local function world_matrix_to_rotation(wm)
        if not wm then return nil end
        local ok, rot = pcall(function() return wm:to_quat() end)
        return ok and rot or nil
    end

    local function read_anchor_rotation(anchor, kind)
        local wm = read_anchor_world_matrix(anchor, kind)
        if wm then
            local rot = world_matrix_to_rotation(wm)
            if rot then return rot end
        end
        if not anchor then return nil end
        if kind == "joint" then
            local rot = sc(anchor, "get_Rotation")
            if rot then return rot end
            local tf = sc(anchor, "get_Transform")
            if tf then return sc(tf, "get_Rotation") end
            return nil
        end
        return sc(anchor, "get_Rotation")
    end

    local function read_anchor_axis(anchor, kind, axis)
        if not anchor then return nil end
        local ax = nil
        if kind == "joint" then
            ax = sc(anchor, "get_" .. axis)
            if ax then return ax end
            local tf = sc(anchor, "get_Transform")
            if tf then return sc(tf, "get_" .. axis) end
            return nil
        end
        return sc(anchor, "get_" .. axis)
    end

    local function add_local_offset_world(pos, anchor, kind, ox, oy, oz)
        if not pos or not anchor then return pos end
        local pv = vec3_from_pos(pos)
        if not pv then return pos end
        local ax = read_anchor_axis(anchor, kind, "AxisX")
        local ay = read_anchor_axis(anchor, kind, "AxisY")
        local az = read_anchor_axis(anchor, kind, "AxisZ")
        if not ax or not ay or not az then return pos end
        return Vector3f.new(
            pv.x + ax.x * ox + ay.x * oy + az.x * oz,
            pv.y + ax.y * ox + ay.y * oy + az.y * oz,
            pv.z + ax.z * ox + ay.z * oy + az.z * oz)
    end

    local function slide_dock_enabled()
        local sd = CFG.slide_dock
        return sd and sd.enabled ~= false
    end

    local function weapon_no_rack_required(wp_name)
        wp_name = wp_name or rack.cached_wp or get_weapon_go_name()
        if not wp_name then return false end
        local entry = type(CFG.weapons) == "table" and CFG.weapons[wp_name] or nil
        if entry and entry.no_slide_rack_required == true then return true end
        local by_wp = (CFG.slide_dock or {}).no_rack_required_by_wp
        return type(by_wp) == "table" and by_wp[wp_name] == true
    end

    -- Trigger-driven slide rack (player request, mirrors the pump-action
    -- shotgun conversion): grip still grabs the slide (unchanged, see
    -- try_start_rack_gesture), but once grabbed, left trigger held = slide
    -- pulled back, release = it returns and completes -- instead of
    -- requiring real hand-tracked pull-back distance. Opt-in per weapon via
    -- CFG.weapons[wp].trigger_slide_rack, so other slide-rack pistols keep
    -- the original hand-tracked gesture until/unless also opted in.
    local function weapon_uses_trigger_rack(wp_name)
        wp_name = wp_name or rack.cached_wp or get_weapon_go_name()
        if not wp_name then return false end
        local entry = type(CFG.weapons) == "table" and CFG.weapons[wp_name] or nil
        return entry ~= nil and entry.trigger_slide_rack == true
    end

    -- Grouped into one table (matches re2_vr_reload_ext_4.lua's pump_ease
    -- pattern) instead of separate top-level locals, to stay under this
    -- file's 200-local-per-chunk ceiling.
    local trig_rack_ease = {
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
        get_pull_speed = function()
            local sd = CFG.slide_dock or {}
            return tonumber(sd.trigger_pull_travel_speed) or 7.0
        end,
        get_push_speed = function()
            local sd = CFG.slide_dock or {}
            return tonumber(sd.trigger_push_travel_speed) or 5.0
        end,
    }

    local function get_slide_node_name(wp_name)
        if not wp_name or type(CFG.slide_dock) ~= "table" then return nil end
        local by_wp = CFG.slide_dock.slide_node_by_wp
        if type(by_wp) == "table" and by_wp[wp_name] then
            return by_wp[wp_name]
        end
        return nil
    end

    local function default_slide_dock_entry()
        local def = (CFG.slide_dock or {}).slide_dock_default or {}
        return {
            dock_off_x = tonumber(def.dock_off_x) or 0.0,
            dock_off_y = tonumber(def.dock_off_y) or 0.0,
            dock_off_z = tonumber(def.dock_off_z) or 0.0,
            hand_pos_x = tonumber(def.hand_pos_x) or 0.0,
            hand_pos_y = tonumber(def.hand_pos_y) or 0.0,
            hand_pos_z = tonumber(def.hand_pos_z) or 0.0,
            hand_rot_pitch = tonumber(def.hand_rot_pitch) or 0.0,
            hand_rot_yaw = tonumber(def.hand_rot_yaw) or 0.0,
            hand_rot_roll = tonumber(def.hand_rot_roll) or 0.0,
            pull_dist = nil,
            push_dist = nil,
        }
    end

    local function get_slide_dock_entry(wp_name)
        CFG.slide_dock = CFG.slide_dock or {}
        CFG.slide_dock.slide_dock_by_wp = CFG.slide_dock.slide_dock_by_wp or {}
        local entry = CFG.slide_dock.slide_dock_by_wp[wp_name]
        if type(entry) ~= "table" then
            entry = default_slide_dock_entry()
            CFG.slide_dock.slide_dock_by_wp[wp_name] = entry
        end
        return entry
    end

    local function default_bone_twist_spec(def)
        def = type(def) == "table" and def or {}
        return {
            pos_x = tonumber(def.pos_x) or 0.0,
            pos_y = tonumber(def.pos_y) or 0.0,
            pos_z = tonumber(def.pos_z) or 0.0,
            rot_pitch = tonumber(def.rot_pitch) or 0.0,
            rot_yaw = tonumber(def.rot_yaw) or 0.0,
            rot_roll = tonumber(def.rot_roll) or 0.0,
        }
    end

    local function default_slide_ik_twist_entry()
        local def = (CFG.slide_dock or {}).slide_ik_twist_default or {}
        return {
            enabled = def.enabled ~= false,
            bend_sign = tonumber(def.bend_sign) or -1.0,
            elbow_pole_mix = tonumber(def.elbow_pole_mix) or 0.58,
            upper_pole_mix = tonumber(def.upper_pole_mix) or 0.0,
            pole_off_x = tonumber(def.pole_off_x) or 0.0,
            pole_off_y = tonumber(def.pole_off_y) or 0.0,
            pole_off_z = tonumber(def.pole_off_z) or 0.0,
            pole_rot_pitch = tonumber(def.pole_rot_pitch) or 0.0,
            pole_rot_yaw = tonumber(def.pole_rot_yaw) or 0.0,
            pole_rot_roll = tonumber(def.pole_rot_roll) or 0.0,
            hand_off_x = tonumber(def.hand_off_x) or 0.0,
            hand_off_y = tonumber(def.hand_off_y) or 0.0,
            hand_off_z = tonumber(def.hand_off_z) or 0.0,
            clavicle = default_bone_twist_spec(def.clavicle),
            upper = default_bone_twist_spec(def.upper),
            lower = default_bone_twist_spec(def.lower),
            wrist = default_bone_twist_spec(def.wrist),
        }
    end

    local function get_slide_ik_twist_entry(wp_name)
        CFG.slide_dock = CFG.slide_dock or {}
        CFG.slide_dock.slide_ik_twist_by_wp = CFG.slide_dock.slide_ik_twist_by_wp or {}
        local entry = CFG.slide_dock.slide_ik_twist_by_wp[wp_name]
        if type(entry) ~= "table" then
            entry = default_slide_ik_twist_entry()
            CFG.slide_dock.slide_ik_twist_by_wp[wp_name] = entry
        end
        return entry
    end

    local function publish_bone_twist_spec(spec)
        spec = type(spec) == "table" and spec or {}
        return {
            pos_x = tonumber(spec.pos_x) or 0.0,
            pos_y = tonumber(spec.pos_y) or 0.0,
            pos_z = tonumber(spec.pos_z) or 0.0,
            pitch = tonumber(spec.rot_pitch) or 0.0,
            yaw = tonumber(spec.rot_yaw) or 0.0,
            roll = tonumber(spec.rot_roll) or 0.0,
        }
    end

    local function publish_slide_dock_ik_twist(wp_name)
        if not wp_name then
            _G.__vr_slide_dock_ik_twist = nil
            return
        end
        local entry = get_slide_ik_twist_entry(wp_name)
        if entry.enabled == false then
            _G.__vr_slide_dock_ik_twist = nil
            return
        end
        _G.__vr_slide_dock_ik_twist = {
            enabled = true,
            bend_sign = tonumber(entry.bend_sign) or -1.0,
            elbow_pole_mix = tonumber(entry.elbow_pole_mix) or 0.58,
            upper_pole_mix = tonumber(entry.upper_pole_mix) or 0.0,
            hand_off = {
                x = tonumber(entry.hand_off_x) or 0.0,
                y = tonumber(entry.hand_off_y) or 0.0,
                z = tonumber(entry.hand_off_z) or 0.0,
            },
            pole_off = {
                x = tonumber(entry.pole_off_x) or 0.0,
                y = tonumber(entry.pole_off_y) or 0.0,
                z = tonumber(entry.pole_off_z) or 0.0,
            },
            pole_rot = {
                pitch = tonumber(entry.pole_rot_pitch) or 0.0,
                yaw = tonumber(entry.pole_rot_yaw) or 0.0,
                roll = tonumber(entry.pole_rot_roll) or 0.0,
            },
            clavicle = publish_bone_twist_spec(entry.clavicle),
            upper = publish_bone_twist_spec(entry.upper),
            lower = publish_bone_twist_spec(entry.lower),
            wrist = publish_bone_twist_spec(entry.wrist),
        }
    end

    local function bind_travel_axis_from_entry(entry)
        if type(entry) ~= "table" then return "z" end
        local ax = entry.travel_axis or entry.bind_travel_axis
        if type(ax) == "string" and ax:lower() == "y" then return "y" end
        return "z"
    end

    local function default_slide_bind_entry()
        local def = (CFG.slide_dock or {}).slide_bind_default or {}
        return {
            x = tonumber(def.x) or 0.0,
            y = tonumber(def.y) or 0.0,
            rest_z = tonumber(def.rest_z) or 0.06,
            parked_z = tonumber(def.parked_z) or 0.04,
            back_z = tonumber(def.back_z) or 0.015,
            travel_axis = bind_travel_axis_from_entry(def),
            open_rot_pitch = tonumber(def.open_rot_pitch) or 0.0,
            open_rot_yaw = tonumber(def.open_rot_yaw) or 0.0,
            open_rot_roll = tonumber(def.open_rot_roll) or 0.0,
        }
    end

    local function get_cylinder_open_bind_pose(wp_name)
        CFG.slide_dock = CFG.slide_dock or {}
        CFG.slide_dock.slide_bind_by_wp = CFG.slide_dock.slide_bind_by_wp or {}
        local entry = CFG.slide_dock.slide_bind_by_wp[wp_name]
        if type(entry) ~= "table" then
            entry = default_slide_bind_entry()
            CFG.slide_dock.slide_bind_by_wp[wp_name] = entry
        end
        local def = default_slide_bind_entry()
        return {
            x = tonumber(entry.open_x) or tonumber(entry.x) or def.x,
            y = tonumber(entry.open_y) or tonumber(entry.y) or def.y,
            z = tonumber(entry.open_z) or tonumber(entry.parked_z) or def.parked_z,
            pitch = tonumber(entry.open_rot_pitch) or tonumber(def.open_rot_pitch) or 0.0,
            yaw = tonumber(entry.open_rot_yaw) or tonumber(def.open_rot_yaw) or 0.0,
            roll = tonumber(entry.open_rot_roll) or tonumber(def.open_rot_roll) or 0.0,
        }
    end

    local function get_chamber_bullet_open_bind_pose(wp_name)
        if get_weapon_go_name() == wp_name then
            local live = get_chamber_bullet_open_bind_display(wp_name)
            if type(live) == "table" then return live end
        end
        CFG.slide_dock.slide_bind_by_wp = CFG.slide_dock.slide_bind_by_wp or {}
        local be = CFG.slide_dock.slide_bind_by_wp[wp_name] or {}
        local cyl = get_cylinder_open_bind_pose(wp_name)
        return {
            x = tonumber(be.bullet_open_x) or cyl.x,
            y = tonumber(be.bullet_open_y) or cyl.y,
            z = tonumber(be.bullet_open_z) or cyl.z,
            pitch = tonumber(be.bullet_open_rot_pitch) or cyl.pitch,
            yaw = tonumber(be.bullet_open_rot_yaw) or cyl.yaw,
            roll = tonumber(be.bullet_open_rot_roll) or cyl.roll,
        }
    end

    local function get_slide_bind_pose(wp_name)
        CFG.slide_dock = CFG.slide_dock or {}
        CFG.slide_dock.slide_bind_by_wp = CFG.slide_dock.slide_bind_by_wp or {}
        local entry = CFG.slide_dock.slide_bind_by_wp[wp_name]
        if type(entry) ~= "table" then
            entry = default_slide_bind_entry()
            CFG.slide_dock.slide_bind_by_wp[wp_name] = entry
        end
        local def = default_slide_bind_entry()
        return {
            x = tonumber(entry.x) or def.x,
            y = tonumber(entry.y) or def.y,
            rest_z = tonumber(entry.rest_z) or def.rest_z,
            parked_z = tonumber(entry.parked_z) or def.parked_z,
            back_z = tonumber(entry.back_z) or def.back_z,
            travel_axis = bind_travel_axis_from_entry(entry),
            open_rot_pitch = tonumber(entry.open_rot_pitch) or def.open_rot_pitch or 0.0,
            open_rot_yaw = tonumber(entry.open_rot_yaw) or def.open_rot_yaw or 0.0,
            open_rot_roll = tonumber(entry.open_rot_roll) or def.open_rot_roll or 0.0,
        }
    end

    local function joint_local_with_bind_travel(joint, travel, bp, axis)
        if not joint or not bp then return false end
        local saved = sc(joint, "get_LocalPosition")
        local x = (saved and type(saved.x) == "number" and saved.x) or (bp.x or 0.0)
        local y = (saved and type(saved.y) == "number" and saved.y) or (bp.y or 0.0)
        local z = (saved and type(saved.z) == "number" and saved.z) or 0.0
        if axis == "y" then
            y = travel
        else
            z = travel
        end
        pcall(function()
            joint:call("set_LocalPosition", Vector3f.new(x, y, z))
        end)
        return true
    end

    local function get_pull_limits(wp_name)
        local sd = CFG.slide_dock or {}
        local entry = wp_name and get_slide_dock_entry(wp_name) or nil
        local pull = entry and tonumber(entry.pull_dist)
        local push = entry and tonumber(entry.push_dist)
        if not pull then pull = tonumber(sd.pull_dist_default) or 0.05 end
        if not push then push = tonumber(sd.push_dist_default) or 0.03 end
        return pull, push
    end

    local function get_pull_deadzone()
        return tonumber((CFG.slide_dock or {}).pull_deadzone) or 0.004
    end

    local function get_pull_smooth_alpha()
        return tonumber((CFG.slide_dock or {}).pull_smooth_alpha) or 0.92
    end

    local function get_effective_pull_dist(wp_name)
        if rack.pull_span_m and rack.pull_span_m > 1e-4 then
            return rack.pull_span_m
        end
        return select(1, get_pull_limits(wp_name))
    end

    local function get_dock_dist(wp_name)
        local sd = CFG.slide_dock or {}
        if wp_name and type(sd.dock_dist_by_wp) == "table" then
            local per = sd.dock_dist_by_wp[wp_name]
            if type(per) == "number" then return per end
        end
        return tonumber(sd.dock_dist_default) or 0.20
    end

    local function get_dock_blend_speed()
        return tonumber((CFG.slide_dock or {}).dock_blend_speed) or 0.10
    end

    local function resolve_slide_weapon_xform()
        local weapon_go = re2.weapon_gameobject
        if not weapon_go then return nil end
        return sc(weapon_go, "get_Transform")
    end

    local function resolve_slide_anchor_for_weapon(wp_name)
        local wtf = resolve_slide_weapon_xform()
        if not wtf then
            rack.anchor = nil
            rack.anchor_kind = nil
            rack.weapon_xform = nil
            return false
        end
        rack.weapon_xform = wtf
        local node = get_slide_node_name(wp_name)
        rack.anchor, rack.anchor_kind = resolve_slide_anchor(wtf, node)
        return rack.anchor ~= nil
    end

    local function get_slide_joint()
        if rack.anchor and rack.anchor_kind == "joint" then
            return rack.anchor
        end
        if rack.anchor then
            return rack.anchor
        end
        return nil
    end

    local function get_hand_dock_pose(wp_name)
        if not rack.anchor then return nil, nil end
        local entry = get_slide_dock_entry(wp_name)
        local sp = read_anchor_position(rack.anchor, rack.anchor_kind)
        if not sp then return nil, nil end

        local wp = add_local_offset_world(sp, rack.anchor, rack.anchor_kind,
            entry.dock_off_x, entry.dock_off_y, entry.dock_off_z)
        if not wp then return nil, nil end
        wp = add_local_offset_world(wp, rack.anchor, rack.anchor_kind,
            entry.hand_pos_x, entry.hand_pos_y, entry.hand_pos_z)
        if not wp then return nil, nil end

        local hand_rot = read_anchor_rotation(rack.anchor, rack.anchor_kind)
        local hp = entry.hand_rot_pitch or 0.0
        local hy = entry.hand_rot_yaw or 0.0
        local hr = entry.hand_rot_roll or 0.0
        if hand_rot and (hp ~= 0.0 or hy ~= 0.0 or hr ~= 0.0) then
            local off_q = quat_from_euler_deg(hp, hy, hr)
            if off_q then hand_rot = quat_mul(hand_rot, off_q) end
        end
        return wp, hand_rot
    end

    local function publish_hand_dock(wp_name)
        local hand_pos, hand_rot = get_hand_dock_pose(wp_name)
        if not hand_pos then return false end

        if rack.weapon_xform then
            local ax = sc(rack.weapon_xform, "get_AxisX")
            local ay = sc(rack.weapon_xform, "get_AxisY")
            if ax then
                _G.__vr_slide_dock_ik_pole = Vector3f.new(ax.x, ax.y, ax.z)
            elseif ay then
                _G.__vr_slide_dock_ik_pole = Vector3f.new(ay.x, ay.y, ay.z)
            end
        end

        _G.__vr_slide_hand_world_pos = hand_pos
        if hand_rot then
            _G.__vr_slide_hand_world_rot = hand_rot
        end
        publish_slide_dock_ik_twist(wp_name)
        return true
    end

    function M.publish_weapon_support_dock(wp_name, anchor, anchor_kind, weapon_xform)
        if not wp_name or not anchor then return false end
        local prev_a, prev_k, prev_w = rack.anchor, rack.anchor_kind, rack.weapon_xform
        rack.anchor = anchor
        rack.anchor_kind = anchor_kind or "joint"
        rack.weapon_xform = weapon_xform
        local ok = publish_hand_dock(wp_name)
        rack.anchor = prev_a
        rack.anchor_kind = prev_k
        rack.weapon_xform = prev_w
        return ok
    end

    local function axis_z_from_world_matrix(wm)
        if not wm or not wm[2] then return nil end
        local ax, ay, az = wm[2].x, wm[2].y, wm[2].z
        local len = math.sqrt(ax * ax + ay * ay + az * az)
        if len < 1e-6 then return nil end
        return ax / len, ay / len, az / len
    end

    local function axis_y_from_world_matrix(wm)
        if not wm or not wm[1] then return nil end
        local ax, ay, az = wm[1].x, wm[1].y, wm[1].z
        local len = math.sqrt(ax * ax + ay * ay + az * az)
        if len < 1e-6 then return nil end
        return ax / len, ay / len, az / len
    end

    local function sample_slide_bind_span(wp_name)
        local bp = get_slide_bind_pose(wp_name)
        local sj = get_slide_joint()
        if not bp or not sj then return nil end

        local saved = sc(sj, "get_LocalPosition")
        if not saved or type(saved.z) ~= "number" then return nil end

        local sx = type(saved.x) == "number" and saved.x or (bp.x or 0.0)
        local sy = type(saved.y) == "number" and saved.y or bp.y

        local function dock_world_at_z(z)
            pcall(function()
                sj:call("set_LocalPosition", Vector3f.new(sx, sy, z))
            end)
            return select(1, get_hand_dock_pose(wp_name))
        end

        local d0 = dock_world_at_z(bp.parked_z)
        local d1 = dock_world_at_z(bp.back_z)
        pcall(function()
            sj:call("set_LocalPosition", Vector3f.new(sx, sy, saved.z))
        end)
        if not d0 or not d1 then return nil end

        local vx = d1.x - d0.x
        local vy = d1.y - d0.y
        local vz = d1.z - d0.z
        local span = math.sqrt(vx * vx + vy * vy + vz * vz)
        if span < 1e-4 then return nil end
        return span, vx / span, vy / span, vz / span
    end

    local function measure_slide_pull_span_m(wp_name)
        local span = sample_slide_bind_span(wp_name)
        return span
    end

    local function measure_slide_push_span_m(wp_name)
        local bp = get_slide_bind_pose(wp_name)
        local sj = get_slide_joint()
        if not bp or not sj then return nil end

        local saved = sc(sj, "get_LocalPosition")
        if not saved or type(saved.z) ~= "number" then return nil end

        local sx = type(saved.x) == "number" and saved.x or (bp.x or 0.0)
        local sy = type(saved.y) == "number" and saved.y or bp.y

        local function dock_world_at_z(z)
            pcall(function()
                sj:call("set_LocalPosition", Vector3f.new(sx, sy, z))
            end)
            return select(1, get_hand_dock_pose(wp_name))
        end

        local d0 = dock_world_at_z(bp.back_z)
        local d1 = dock_world_at_z(bp.rest_z)
        pcall(function()
            sj:call("set_LocalPosition", Vector3f.new(sx, sy, saved.z))
        end)
        if not d0 or not d1 then return nil end

        local dx = d1.x - d0.x
        local dy = d1.y - d0.y
        local dz = d1.z - d0.z
        local span = math.sqrt(dx * dx + dy * dy + dz * dz)
        if span < 1e-4 then return nil end
        return span
    end

    local function get_effective_push_dist(wp_name)
        if rack.push_span_m and rack.push_span_m > 1e-4 then
            return rack.push_span_m
        end
        local span = wp_name and measure_slide_push_span_m(wp_name)
        if span and span > 1e-4 then
            rack.push_span_m = span
            return span
        end
        return select(2, get_pull_limits(wp_name))
    end

    local function capture_grab_slide_state(wp_name)
        local bp = get_slide_bind_pose(wp_name)
        local sj = get_slide_joint()
        local fresh_grab = rack.needs_rack == true
            and rack.pull_done ~= true
            and (rack.pull_now or 0) <= 0
            and (rack.pull_max or 0) <= 0
        if bp and fresh_grab then
            rack.grab_slide_z = bp.parked_z
        elseif sj then
            local pos = sc(sj, "get_LocalPosition")
            if pos and type(pos.z) == "number" then
                rack.grab_slide_z = pos.z
            elseif bp then
                rack.grab_slide_z = bp.parked_z
            end
        elseif bp then
            rack.grab_slide_z = bp.parked_z
        end
        rack.pull_span_m = measure_slide_pull_span_m(wp_name)
        rack.push_span_m = measure_slide_push_span_m(wp_name)
    end

    local function update_rack_arm_delta(hand_pos)
        if not hand_pos or type(hand_pos.x) ~= "number" then
            _G.__vr_slide_dock_arm_delta = nil
            return
        end
        local lx = rack.last_hand_x
        local ly = rack.last_hand_y
        local lz = rack.last_hand_z
        if lx ~= nil and ly ~= nil and lz ~= nil then
            _G.__vr_slide_dock_arm_delta = Vector3f.new(
                hand_pos.x - lx, hand_pos.y - ly, hand_pos.z - lz)
        else
            _G.__vr_slide_dock_arm_delta = nil
        end
        rack.last_hand_x = hand_pos.x
        rack.last_hand_y = hand_pos.y
        rack.last_hand_z = hand_pos.z
    end

    local function clear_pull_globals()
        _G.__vr_slide_rack_pull_signed = 0
    end

    local function clear_rack_pull_axis()
        rack.pull_ax = nil
        rack.pull_ay = nil
        rack.pull_az = nil
        rack.pull_axis_set = false
        rack.pull_axis_src = nil
        _G.__vr_slide_rack_pull_axis_x = nil
        _G.__vr_slide_rack_pull_axis_y = nil
        _G.__vr_slide_rack_pull_axis_z = nil
    end

    local function sync_pull_axis_globals()
        if rack.pull_axis_set and rack.pull_ax then
            _G.__vr_slide_rack_pull_axis_x = rack.pull_ax
            _G.__vr_slide_rack_pull_axis_y = rack.pull_ay
            _G.__vr_slide_rack_pull_axis_z = rack.pull_az
        end
    end

    local function clear_hand_dock_blend_latch()
        rack.hand_dock_blend_dir = 0
        _G.__vr_slide_dock_blend_from_pos = nil
        _G.__vr_slide_dock_blend_from_rot = nil
        local clear_snap = rawget(_G, "__vr_clear_slide_dock_arm_snap")
        if type(clear_snap) == "function" then
            pcall(clear_snap)
        end
    end

    local function capture_hand_dock_blend_origin()
        local capture_fn = rawget(_G, "__vr_capture_slide_dock_blend_origin")
        if type(capture_fn) == "function" then
            pcall(capture_fn)
            return
        end
        local pos_fn = rawget(_G, "__vr_get_live_left_hand_for_slide_blend")
        local pos = (type(pos_fn) == "function") and pos_fn() or nil
        if pos and type(pos.x) == "number" then
            _G.__vr_slide_dock_blend_from_pos = Vector3f.new(pos.x, pos.y, pos.z)
        end
        local rot_fn = rawget(_G, "__vr_get_live_left_hand_for_slide_blend_rot")
        local rot = (type(rot_fn) == "function") and rot_fn() or nil
        if rot then
            _G.__vr_slide_dock_blend_from_rot = rot
        end
    end

    local function clear_hand_globals()
        _G.__vr_slide_hand_world_pos = nil
        _G.__vr_slide_hand_world_rot = nil
        _G.__vr_slide_dock_blend_factor = 0
        _G.__vr_slide_hand_dock_target = 0
        _G.__vr_slide_dock_ik_pole = nil
        _G.__vr_slide_dock_ik_twist = nil
        _G.__vr_slide_rack_ik_done = false
        rack.hand_dock_blend = 0
        rack.hand_dock_target = 0
        clear_hand_dock_blend_latch()
        clear_pull_globals()
    end

    local function publish_rack_globals()
        _G.__vr_needs_rack = rack.needs_rack == true
        _G.__vr_slide_rack_active = rack.active == true
        _G.__vr_slide_dock_in_range = rack.in_range == true
        _G.__vr_block_support_dock =
            rawget(_G, "__vr_mag_in_left_hand") == true
            or rawget(_G, "__vr_mag_insert_active") == true
            or rawget(_G, "__vr_bullet_in_left_hand") == true
            or (rawget(_G, "__vr_block_left_support_in_mag_holster_zone") == true
                and rawget(_G, "__vr_needs_pump") ~= true
                and rawget(_G, "__vr_pump_active") ~= true
                and rawget(_G, "__vr_pump_slide_support") ~= true)
            or rack.needs_rack == true
            or rack.active == true
    end

    local function update_hand_dock_blend(target)
        target = (target and target >= 0.5) and 1.0 or 0.0
        rack.hand_dock_target = target
        _G.__vr_slide_hand_dock_target = target

        local b = rack.hand_dock_blend or 0
        local blend_dir = 0
        if b < target - 1e-5 then
            blend_dir = 1
        elseif b > target + 1e-5 then
            blend_dir = -1
        end
        if blend_dir ~= 0 and blend_dir ~= (rack.hand_dock_blend_dir or 0) then
            if blend_dir > 0 then
                capture_hand_dock_blend_origin()
            else
                local clear_snap = rawget(_G, "__vr_clear_slide_dock_arm_snap")
                if type(clear_snap) == "function" then
                    pcall(clear_snap)
                end
                local pos_fn = rawget(_G, "__vr_get_live_left_hand_for_slide_blend")
                local pos = (type(pos_fn) == "function") and pos_fn() or nil
                if pos and type(pos.x) == "number" then
                    _G.__vr_slide_dock_blend_from_pos = Vector3f.new(pos.x, pos.y, pos.z)
                end
                local rot_fn = rawget(_G, "__vr_get_live_left_hand_for_slide_blend_rot")
                local rot = (type(rot_fn) == "function") and rot_fn() or nil
                if rot then
                    _G.__vr_slide_dock_blend_from_rot = rot
                end
            end
        end
        rack.hand_dock_blend_dir = blend_dir

        local speed = get_dock_blend_speed()
        if b < target then
            b = math.min(b + speed, target)
        elseif b > target then
            b = math.max(b - speed, target)
        end
        rack.hand_dock_blend = b
        local eased = b * b * (3.0 - 2.0 * b)
        _G.__vr_slide_dock_blend_factor = eased

        if b <= 0.001 and target <= 0.001 then
            clear_hand_dock_blend_latch()
        elseif b >= 0.999 and target >= 0.999 then
            local clear_snap = rawget(_G, "__vr_clear_slide_dock_arm_snap")
            if type(clear_snap) == "function" then
                pcall(clear_snap)
            end
        end
    end

    local function snap_hand_dock_off()
        rack.hand_dock_target = 0
        rack.hand_dock_blend = 0
        rack.hand_dock_blend_dir = 0
        _G.__vr_slide_hand_dock_target = 0
        _G.__vr_slide_dock_blend_factor = 0
        clear_hand_dock_blend_latch()
        clear_hand_globals()
    end

    local function is_mag_insert_active()
        return rawget(_G, "__vr_mag_insert_active") == true
    end

    local function slide_rack_context_ok(wp_name)
        if not slide_dock_enabled() then return false end
        if not wp_name or not is_weapon_enabled(wp_name) then return false end
        if not get_slide_node_name(wp_name) and not rack.anchor then return false end
        if rawget(_G, "__vr_mag_in_left_hand") == true then return false end
        if is_mag_insert_active() then return false end
        if rawget(_G, "__vr_in_mag_holster_zone") == true
            and rack.needs_rack ~= true
            and rack.active ~= true then
            return false
        end
        if not manual_reload_context_active() then return false end
        if rack.needs_rack ~= true and rack.active ~= true then return false end
        return true
    end

    local function slide_rack_context_blockers(wp_name)
        local blocks = {}
        if not slide_dock_enabled() then blocks[#blocks + 1] = "disabled" end
        if not wp_name or not is_weapon_enabled(wp_name) then blocks[#blocks + 1] = "weapon" end
        if not get_slide_node_name(wp_name) and not rack.anchor then blocks[#blocks + 1] = "no_anchor" end
        if rawget(_G, "__vr_mag_in_left_hand") == true then blocks[#blocks + 1] = "mag_in_hand" end
        if is_mag_insert_active() then blocks[#blocks + 1] = "mag_insert" end
        if rawget(_G, "__vr_in_mag_holster_zone") == true
            and rack.needs_rack ~= true
            and rack.active ~= true then
            blocks[#blocks + 1] = "holster_zone"
        end
        if not manual_reload_context_active() then blocks[#blocks + 1] = "reload_ctx" end
        if rack.needs_rack ~= true and rack.active ~= true then blocks[#blocks + 1] = "no_needs_rack" end
        return blocks
    end

    local function is_track_near_dock(wp_name, ref_pos, thr)
        if not ref_pos then return false end
        local dock_pos = select(1, get_hand_dock_pose(wp_name))
        if not dock_pos then return false end
        thr = thr or get_dock_dist(wp_name)
        return vec3_dist(ref_pos, dock_pos) <= thr
    end

    local function get_pull_axis_sign()
        local s = tonumber((CFG.slide_dock or {}).pull_axis_sign)
        if s == nil or s == 0 then return 1.0 end
        return s
    end

    local function vec3_subtract(a, b)
        if not a or not b then return nil end
        return Vector3f.new(a.x - b.x, a.y - b.y, a.z - b.z)
    end

    local function vec3_add(a, b)
        if not a or not b then return nil end
        return Vector3f.new(a.x + b.x, a.y + b.y, a.z + b.z)
    end

    local function quat_rotate_vec3(q, v)
        if not q or not v then return nil end
        local ok, r = pcall(function() return q * v end)
        return ok and r or nil
    end

    local function quat_yaw_flat(q)
        if not q then return nil end
        local ok, m = pcall(function() return q:to_mat4() end)
        if not ok or not m then return q end
        m[1].y = 0.0
        m[2].y = 0.0
        m[3].y = 0.0
        local ok2, qf = pcall(function() return m:to_quat():normalized() end)
        return ok2 and qf or q
    end

    local function get_camera_data()
        local cam = sdk.get_primary_camera()
        if not cam then return nil end
        local wm = sc(cam, "get_WorldMatrix")
        if not wm or not wm[3] or type(wm[3].x) ~= "number" then return nil end
        local rot = rawget(_G, "__vr_camera_stored_rot")
        if not rot then
            -- get_GameObject on the camera throws internally while menus
            -- (item box etc.) have it in a transitional state; sc()
            -- swallows the Lua error but REFramework logs each throw --
            -- polled every motion tick that produced a 300+/sec on-screen
            -- error storm. Back off after a failure instead of retrying
            -- every call.
            local now_t = os.clock()
            if rack.cam_go_fail_until and now_t < rack.cam_go_fail_until then
                return nil
            end
            local go = sc(cam, "get_GameObject")
            local tf = go and sc(go, "get_Transform")
            rot = tf and sc(tf, "get_Rotation")
            if not rot then rack.cam_go_fail_until = now_t + 0.5 end
        end
        if not rot then return nil end
        return {
            position = Vector3f.new(wm[3].x, wm[3].y, wm[3].z),
            rotation = rot,
        }
    end

    local function refresh_standing_origin()
        if not vrmod then return end
        local so = nil
        pcall(function() so = vrmod:get_standing_origin() end)
        if so and type(so.x) == "number" then
            rack.standing_origin = Vector3f.new(so.x, so.y, so.z)
            rack.standing_origin_set = true
            return
        end
        if not rack.standing_origin_set then
            local hmd = nil
            pcall(function() hmd = vrmod:get_position(0) end)
            if hmd and type(hmd.x) == "number" then
                rack.standing_origin = Vector3f.new(hmd.x, hmd.y, hmd.z)
                rack.standing_origin_set = true
            end
        end
    end

    -- `which` selects the controller ("left" default, "right" for the
    -- weapon hand); every source below is indexed identically for both so
    -- the two hands come back in the SAME coordinate space -- required by
    -- the motion-rack math, which subtracts one from the other.
    local function get_controller_raw_openxr_pos(which)
        if not vrmod then return nil end
        local li = (which == "right") and 2 or 1
        -- vrmod:get_controllers() + get_position FIRST: the proven
        -- per-hand path (ext_1 and re8_vr both use it successfully).
        -- The VRControllerManager list was tried as the primary source
        -- and produced IDENTICAL positions for both entries in live
        -- 2026-08-17 logs (relative-hands s == 0.0000 exactly), so it's
        -- demoted to a fallback with a zero-vector guard.
        local controllers = nil
        pcall(function() controllers = vrmod:get_controllers() end)
        if controllers then
            local idx = controllers[li]
            if idx == nil then idx = li end
            local ok, pos = pcall(function() return vrmod:get_position(idx) end)
            if ok and pos and type(pos.x) == "number"
                and (pos.x ~= 0.0 or pos.y ~= 0.0 or pos.z ~= 0.0) then
                return pos, "vrmod_raw"
            end
        end
        local vrc_manager = sdk.get_managed_singleton("via.VRControllerManager")
        if vrc_manager then
            local ok_has, has = pcall(function() return vrc_manager:call("has_controllers") end)
            if ok_has and has then
                local p = nil
                pcall(function()
                    local list = vrc_manager.controllers_list
                    local entry = list and list[li]
                    p = entry and entry.position
                end)
                if p and type(p.x) == "number"
                    and (p.x ~= 0.0 or p.y ~= 0.0 or p.z ~= 0.0) then
                    return Vector3f.new(p.x, p.y, p.z), "vrc_list"
                end
            end
        end
        if get_vr_controller_world_pos then
            local cp = get_vr_controller_world_pos((which == "right") and "right" or "left")
            if cp then return cp, "deps_raw" end
        end
        return nil
    end

    local function get_controller_game_world_pos(which)
        local raw, raw_src = get_controller_raw_openxr_pos(which)
        if not raw then return nil, nil end

        local cam = get_camera_data()
        if not cam then return raw, raw_src or "raw_fallback" end

        refresh_standing_origin()
        local rel = raw
        if rack.standing_origin then
            rel = vec3_subtract(raw, rack.standing_origin)
        end
        if not rel then return raw, raw_src end

        local rot_off = nil
        pcall(function() rot_off = vrmod:get_rotation_offset() end)
        if rot_off then
            rel = quat_rotate_vec3(rot_off, rel)
        end
        if not rel then return raw, raw_src end

        local ctrl_world = quat_rotate_vec3(cam.rotation, rel)
        if not ctrl_world then return raw, raw_src end
        ctrl_world = vec3_add(cam.position, ctrl_world)
        -- Tag carries the raw source through (e.g. "vrmod_raw>gw") so the
        -- motion-gesture logs show WHICH provider actually served the pos.
        return ctrl_world, (raw_src or "raw") .. ">gw"
    end

    local function get_hmd_openxr_pos()
        if not vrmod then return nil end
        local ok, pos = pcall(function() return vrmod:get_position(0) end)
        if ok and pos and type(pos.x) == "number" then return pos end
        local cam = get_camera_data()
        return cam and cam.position
    end

    local function get_controller_hmd_offset()
        local ctrl = get_controller_raw_openxr_pos()
        local hmd = get_hmd_openxr_pos()
        if not ctrl or not hmd then return nil end
        return vec3_subtract(ctrl, hmd)
    end

    local function world_dir_to_play_dir(wx, wy, wz)
        local cam = get_camera_data()
        if not cam or not wx then return wx, wy, wz end
        local q = quat_yaw_flat(cam.rotation)
        if not q then return wx, wy, wz end
        local inv = nil
        pcall(function() inv = q:conjugate() end)
        if not inv then return wx, wy, wz end
        local v = quat_rotate_vec3(inv, Vector3f.new(wx, wy, wz))
        if not v then return wx, wy, wz end
        local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        if len < 1e-6 then return wx, wy, wz end
        return v.x / len, v.y / len, v.z / len
    end

    local function body_yaw_axes_from_transform(tf)
        if not tf then return nil end
        local fx, fz = nil, nil
        local rot = sc(tf, "get_Rotation")
        if rot then
            local ok, fwd_v = pcall(function() return rot * Vector3f.new(0, 0, 1) end)
            if ok and fwd_v then fx, fz = fwd_v.x, fwd_v.z end
        end
        if not fx then
            local wm = sc(tf, "get_WorldMatrix")
            if wm then fx, fz = wm[2].x, wm[2].z end
        end
        if not fx then return nil end
        local len = math.sqrt(fx * fx + fz * fz)
        if len < 1e-6 then fx, fz = 0.0, 1.0 else fx, fz = fx / len, fz / len end
        local fwd = { x = fx, y = 0, z = fz }
        local right = { x = fz, y = 0, z = -fx }
        local up = { x = 0, y = 1, z = 0 }
        return right, up, fwd
    end

    local function get_player_flat_yaw_deg()
        local tf = resolve_slide_weapon_xform()
        if not tf then return nil end
        local right, up, fwd = body_yaw_axes_from_transform(tf)
        if not fwd then return nil end
        return math.deg(math.atan(fwd.x, fwd.z))
    end

    local function get_slide_pull_axis_live(wp_name)
        local sj = get_slide_joint()
        if sj then
            local wm = read_anchor_world_matrix(sj, rack.anchor_kind or "xform")
            local ax, ay, az = axis_z_from_world_matrix(wm)
            if ax then return ax, ay, az, "wm_live" end
            local fwd = read_anchor_axis(sj, rack.anchor_kind or "joint", "AxisZ")
            if fwd then
                local len = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z)
                if len > 1e-6 then
                    return fwd.x / len, fwd.y / len, fwd.z / len, "axis_live"
                end
            end
        end
        if rack.pull_axis_set and rack.pull_ax then
            return rack.pull_ax, rack.pull_ay, rack.pull_az, rack.pull_axis_src or "frozen"
        end
        if wp_name then
            local _, ax, ay, az = sample_slide_bind_span(wp_name)
            if ax then return ax, ay, az, "bind_span_sample" end
        end
        return nil
    end

    local function capture_play_pull_axis(wp_name)
        local ax, ay, az = get_slide_pull_axis_live(wp_name)
        if not ax then return false end
        local pax, pay, paz = world_dir_to_play_dir(ax, ay, az)
        rack.pull_play_ax = pax
        rack.pull_play_ay = pay
        rack.pull_play_az = paz
        return true
    end

    local function get_track_pos_for_rack()
        if get_left_track_pos_with_source then
            local pos, track_src = get_left_track_pos_with_source()
            if pos then return pos, track_src or "track" end
        end
        if get_left_track_position then
            local pos = get_left_track_position()
            if pos then return pos, "track_legacy" end
        end
        -- __vr_lh_joint_pos is only kept fresh while __vr_lh_slide_ik_override
        -- is true; the slide-dock system never clears it after docking ends,
        -- so it's only trustworthy while that flag confirms docking is live.
        if rawget(_G, "__vr_lh_slide_ik_override") == true then
            local lh = rawget(_G, "__vr_lh_joint_pos")
            if lh and type(lh.x) == "number" then return lh, "lh_joint" end
        end
        local lw = rawget(_G, "__vr_lh_world")
        if lw and type(lw.x) == "number" then return lw, "lh_world" end
        if get_left_hand_position then
            local pos = get_left_hand_position()
            if pos then return pos, "hand" end
        end
        local gw, src = get_controller_game_world_pos()
        if gw then return gw, src end
        return nil, "nil"
    end

    -- 2026-08-14: diagnostic -- player confirmed the camera-relative
    -- __vr_lh_world fix (above) was real improvement ("feels different
    -- straight away") but two extreme cases STILL loop: looking far left
    -- while gripping (hand may leave the headset's own inside-out tracking
    -- camera view -- possible genuine hardware tracking degradation, a
    -- different category than the software bug just fixed), and pointing
    -- far forward (possible arm IK reach-limit interaction). Rather than
    -- guess a third time, log each individual candidate distance (not just
    -- the winning minimum) so the next reproduction shows exactly which
    -- one spikes -- one candidate spiking alone points back to software;
    -- all of them jumping together points at raw tracking data itself
    -- degrading at the source. Throttled, called from M.tick() (below)
    -- once near/threshold are known, only fires while actively docked/
    -- gripping so it doesn't spam during normal play.
    local function log_dist_candidates(near, threshold)
        if not (rack.active or rawget(_G, "__vr_lh_slide_ik_override") == true) then return end
        local now = os.clock()
        if rack.dist_probe_last_log and (now - rack.dist_probe_last_log) < 0.05 then return end
        rack.dist_probe_last_log = now
        local function f(v) return v or -1 end
        log.info(string.format(
            "[slide_rack_dist_probe] track=%.3f raw=%.3f lh_world=%.3f joint=%.3f hand=%.3f -> best=%.3f threshold=%.3f near=%s",
            f(rack.dbg_dist_track), f(rack.dbg_dist_raw), f(rack.dbg_dist_lh),
            f(rack.dbg_dist_joint), f(rack.dbg_dist_hand), f(rack.last_dock_dist),
            threshold or -1, tostring(near)))
    end

    local function distance_to_dock_for_near(dock_pos)
        rack.dbg_dist_track, rack.dbg_dist_raw, rack.dbg_dist_lh, rack.dbg_dist_joint, rack.dbg_dist_hand = nil, nil, nil, nil, nil
        if not dock_pos then return 99.0 end
        local best = 99.0
        local track_pos = get_track_pos_for_rack()
        if track_pos then
            rack.dbg_dist_track = vec3_dist(track_pos, dock_pos)
            best = math.min(best, rack.dbg_dist_track)
        end
        -- The animated hand_skeleton joint (track_pos above) can glitch to
        -- an outlier value on individual frames (confirmed via track_probe
        -- logging: spikes to ~3x neighboring samples while the raw
        -- controller position stayed smooth). Including the raw, properly
        -- world-transformed controller position here means a single bad
        -- skeleton-joint frame can't block a grab when raw tracking agrees
        -- the hand is actually at the dock.
        local raw_pos = select(1, get_controller_game_world_pos())
        if raw_pos then
            rack.dbg_dist_raw = vec3_dist(raw_pos, dock_pos)
            best = math.min(best, rack.dbg_dist_raw)
        end
        -- 2026-08-14: found live -- player reported the loop being relative
        -- to HMD look direction (stable if looking the same way the whole
        -- hold, loops when turning the head left/right with the real hand
        -- stationary). __vr_lh_world (re2_vr_ik_extention.lua's
        -- publish_vr_hand_globals) is published via
        -- get_fp_style_hand_world_pos -- a tracking-space offset rotated by
        -- the CAMERA'S CURRENT YAW every frame, correct for matching what
        -- the camera sees when rendering the FP hand mesh, but NOT a stable
        -- world-space signal: the same physical hand position produces a
        -- DIFFERENT computed value as soon as the head turns. Unlike the
        -- other candidates here (genuine noise outliers averaged out by the
        -- "take the minimum" design), this one has a real, sustained bias,
        -- not transient noise -- letting it win the minimum comparison
        -- reintroduces exactly the visual-loop symptom the 2026-08-08 fix
        -- targeted, just via head yaw instead of distance-threshold noise.
        -- Only trust it as a fallback when NOT already docked via the
        -- confirmed-stable gated joint below (matches the same gate
        -- get_track_pos_for_rack()/get_left_hand_position() already apply
        -- to their own internal fallback to this same global).
        if rawget(_G, "__vr_lh_slide_ik_override") ~= true then
            local lh = rawget(_G, "__vr_lh_world")
            if lh and type(lh.x) == "number" then
                rack.dbg_dist_lh = vec3_dist(lh, dock_pos)
                best = math.min(best, rack.dbg_dist_lh)
            end
        end
        if rawget(_G, "__vr_lh_slide_ik_override") == true then
            local lj = rawget(_G, "__vr_lh_joint_pos")
            if lj and type(lj.x) == "number" then
                rack.dbg_dist_joint = vec3_dist(lj, dock_pos)
                best = math.min(best, rack.dbg_dist_joint)
            end
        end
        local hp = get_left_hand_position and get_left_hand_position()
        if hp then
            rack.dbg_dist_hand = vec3_dist(hp, dock_pos)
            best = math.min(best, rack.dbg_dist_hand)
        end
        return best
    end

    local function reset_pull_smoothing()
        rack.pull_smooth = 0.0
        rack.pull_smooth_init = false
    end

    local function try_start_rack_gesture(wp, track_pos, near)
        if not rack.needs_rack or is_mag_insert_active() then return false end
        if get_bullet_number() <= 0 then return false end
        if not is_left_grip_pressed() then return false end
        if near == nil then near = is_track_near_dock(wp, track_pos) end
        if not near then return false end
        if rack.active then return true end
        rack.active = true
        rack.armed = false
        rack.pull_done = false
        rack.pull_max = 0.0
        rack.pull_now = 0.0
        -- trig_travel/trig_committed/trigger_prev are trigger-rack-only
        -- state that nothing else resets between cycles (the two places
        -- that clear them inside update_slide_rack_trigger are dead code
        -- or only reachable on an aborted grab, never a normal completion)
        -- -- left stale-true here made the SECOND+ trigger-rack reload in
        -- a session auto-commit to a full pull instantly on grab, with no
        -- LT press at all, since `target = rack.trig_committed and 1.0 or
        -- 0.0` doesn't care what LT is doing. Always start a fresh grab
        -- clean regardless of how the last cycle ended.
        rack.trig_travel = 0.0
        rack.trig_committed = false
        rack.trigger_prev = false
        rack.hand_released_early = false
        rack.grip_release_at = nil
        -- Fresh grab = fresh motion-rack baseline: the relative-hands
        -- pull is always measured against where the hands were at THIS
        -- grab, never a stale one from a previous cycle.
        rack.mo_init = false
        rack.mo_ratio = 0.0
        if track_pos then
            rack.start_pos = Vector3f.new(track_pos.x, track_pos.y, track_pos.z)
        end
        capture_grab_slide_state(wp)
        M.apply_slide_park("gesture_start")
        reset_pull_smoothing()
        M.on_gesture_start(wp)
        return true
    end

    local function project_on_frozen_pull_axis(dx, dy, dz)
        if not rack.pull_axis_set or rack.pull_ax == nil then return nil end
        return -(dx * rack.pull_ax + dy * rack.pull_ay + dz * rack.pull_az) * get_pull_axis_sign()
    end

    local function get_live_slide_signed_pull(dx, dy, dz)
        local frozen = project_on_frozen_pull_axis(dx, dy, dz)
        if frozen ~= nil then return frozen end

        local sj = get_slide_joint()
        local fwd = sj and read_anchor_axis(sj, rack.anchor_kind or "joint", "AxisZ")
        if not fwd and sj then
            local wm = read_anchor_world_matrix(sj, rack.anchor_kind or "xform")
            local ax, ay, az = axis_z_from_world_matrix(wm)
            if ax then fwd = Vector3f.new(ax, ay, az) end
        end
        if not fwd then return 0.0 end
        return -(dx * fwd.x + dy * fwd.y + dz * fwd.z) * get_pull_axis_sign()
    end

    local function compute_dock_relative_pull(dock_world, track_pos)
        if not dock_world or not track_pos then return 0.0 end
        local dx = track_pos.x - dock_world.x
        local dy = track_pos.y - dock_world.y
        local dz = track_pos.z - dock_world.z
        return get_live_slide_signed_pull(dx, dy, dz)
    end

    local function compute_controller_delta_pull(track_pos, wp_name)
        local sign_mul = get_pull_axis_sign()

        if rack.pull_play_ax and rack.start_play_off_x then
            local off = get_controller_hmd_offset()
            if off then
                local dx = off.x - rack.start_play_off_x
                local dy = off.y - rack.start_play_off_y
                local dz = off.z - rack.start_play_off_z
                local signed_play = -(dx * rack.pull_play_ax + dy * rack.pull_play_ay
                    + dz * rack.pull_play_az) * sign_mul
                return signed_play, "play_hmd"
            end
        end

        if not track_pos or not rack.start_pos then return 0.0, "no_start" end
        local dx = track_pos.x - rack.start_pos.x
        local dy = track_pos.y - rack.start_pos.y
        local dz = track_pos.z - rack.start_pos.z
        local ax, ay, az, src = get_slide_pull_axis_live(wp_name)
        if ax then
            return -(dx * ax + dy * ay + dz * az) * sign_mul, src
        end
        return get_live_slide_signed_pull(dx, dy, dz), "frozen_fallback"
    end

    local function capture_pull_peak_anchor()
        local off = get_controller_hmd_offset()
        if off then
            rack.peak_play_off_x = off.x
            rack.peak_play_off_y = off.y
            rack.peak_play_off_z = off.z
        end
    end

    local function get_push_delta_from_peak()
        if not rack.pull_done then return 0.0 end
        if rack.peak_play_off_x and rack.pull_play_ax then
            local off = get_controller_hmd_offset()
            if off then
                local dx = off.x - rack.peak_play_off_x
                local dy = off.y - rack.peak_play_off_y
                local dz = off.z - rack.peak_play_off_z
                local sign_mul = get_pull_axis_sign()
                local d = -(dx * rack.pull_play_ax + dy * rack.pull_play_ay
                    + dz * rack.pull_play_az) * sign_mul
                if rack.pull_increases_signed then
                    return math.max(0.0, -d)
                end
                return math.max(0.0, d)
            end
        end
        if rack.pull_peak_signed == nil then return 0.0 end
        local peak = rack.pull_peak_signed
        local signed = tonumber(_G.__vr_slide_rack_pull_signed) or rack.pull_now or 0.0
        if rack.pull_increases_signed then
            return math.max(0.0, peak - signed)
        end
        return math.max(0.0, signed - peak)
    end

    local function get_push_delta(signed)
        if not rack.pull_done then return 0.0 end
        local peak_push = get_push_delta_from_peak()
        if rack.peak_play_off_x and rack.pull_play_ax then
            return peak_push
        end
        if rack.pull_peak_signed == nil then return 0.0 end
        local peak = rack.pull_peak_signed
        if rack.pull_increases_signed then
            return math.max(0.0, peak - signed)
        end
        return math.max(0.0, signed - peak)
    end

    local function smooth_clamp_rack_pull(signed, pull_d, push_d)
        local alpha = get_pull_smooth_alpha()
        if not rack.pull_smooth_init then
            rack.pull_smooth = signed
            rack.pull_smooth_init = true
        else
            rack.pull_smooth = rack.pull_smooth + (signed - rack.pull_smooth) * alpha
        end

        local s = rack.pull_smooth
        local dz_on = get_pull_deadzone()
        local dz_off = dz_on * 0.5
        local prev = tonumber(_G.__vr_slide_rack_pull_signed) or 0.0
        if math.abs(prev) <= 1e-6 then
            if math.abs(s) < dz_on then s = 0.0 end
        else
            if math.abs(s) < dz_off then s = 0.0 end
        end

        if not rack.pull_done then
            if rack.pull_increases_signed then
                s = math.max(0.0, s)
                if s > pull_d then s = pull_d end
            else
                s = math.min(0.0, s)
                if s < -pull_d then s = -pull_d end
            end
        elseif push_d and push_d > 0 and rack.pull_peak_signed ~= nil then
            local peak = rack.pull_peak_signed
            if rack.pull_increases_signed then
                if s > peak then s = peak end
                if s < peak - push_d then s = peak - push_d end
            else
                if s < peak then s = peak end
                if s > peak + push_d then s = peak + push_d end
            end
        end
        return s
    end

    local function notify_pull_limit_reached(wp_name, signed)
        if rack.pull_done == true then return end
        rack.pull_done = true
        rack.pull_peak_signed = signed
        capture_pull_peak_anchor()
        reset_pull_smoothing()
        if deps_ref.play_reload_sfx then
            deps_ref.play_reload_sfx("slide_rack_pull")
        end
        local lj = get_haptic_left_joystick()
        if lj then haptic_pulse(lj, 0.06, 220.0, 0.7) end
    end

    local function update_rack_pull(track_pos, wp)
        if not rack.active or not is_left_grip_pressed() or not track_pos or not wp then
            return
        end

        if rack.last_wid ~= wp or not rack.pull_axis_set then
            M.on_gesture_start(wp)
        end
        if track_pos and not rack.start_pos then
            rack.start_pos = Vector3f.new(track_pos.x, track_pos.y, track_pos.z)
            capture_grab_slide_state(wp)
        end

        local pull_d = get_effective_pull_dist(wp)
        local effective_pull = pull_d
        local push_d = get_effective_push_dist(wp)
        local signed = compute_controller_delta_pull(track_pos, wp)
        local s = smooth_clamp_rack_pull(signed, effective_pull, push_d)
        _G.__vr_slide_rack_pull_signed = s
        rack.pull_now = s
        _G.__vr_slide_pull_dist = effective_pull
        _G.__vr_slide_push_dist = push_d
        if not rack.pull_done and effective_pull > 1e-5 and math.abs(s) >= effective_pull - 1e-5 then
            notify_pull_limit_reached(wp, s)
        end
    end

    local function capture_rack_pull_axis(wp_name)
        clear_rack_pull_axis()
        wp_name = wp_name or rack.cached_wp

        if wp_name then
            local _, ax, ay, az = sample_slide_bind_span(wp_name)
            if ax then
                rack.pull_ax = ax
                rack.pull_ay = ay
                rack.pull_az = az
                rack.pull_axis_set = true
                rack.pull_axis_src = "bind_span"
                sync_pull_axis_globals()
                return
            end
        end

        local sj = get_slide_joint()
        if sj then
            local wm = read_anchor_world_matrix(sj, rack.anchor_kind or "xform")
            local ax, ay, az = axis_z_from_world_matrix(wm)
            if ax then
                rack.pull_ax = ax
                rack.pull_ay = ay
                rack.pull_az = az
                rack.pull_axis_set = true
                rack.pull_axis_src = "world_matrix"
                sync_pull_axis_globals()
                return
            end
        end

        local slide_fwd = sj and read_anchor_axis(sj, rack.anchor_kind or "joint", "AxisZ")
        if not slide_fwd then return end
        local len = math.sqrt(slide_fwd.x * slide_fwd.x + slide_fwd.y * slide_fwd.y + slide_fwd.z * slide_fwd.z)
        if len < 1e-6 then return end
        rack.pull_ax = slide_fwd.x / len
        rack.pull_ay = slide_fwd.y / len
        rack.pull_az = slide_fwd.z / len
        rack.pull_axis_set = true
        rack.pull_axis_src = "axis_z"
        sync_pull_axis_globals()
    end

    local function should_hand_dock(grip, rack_active)
        if not grip or not rack_active then return false end
        if rack.hand_released_early then return false end
        if not rack.in_range then return false end
        if rawget(_G, "__vr_mag_in_left_hand") == true then return false end
        if is_mag_insert_active() then return false end
        return true
    end

    local function tick_hand_dock_blend(wp_name, grip, rack_active)
        if not slide_rack_context_ok(wp_name) and not rack_active then
            if (rack.hand_dock_blend or 0) > 0.001 then
                update_hand_dock_blend(0)
            end
            if (rack.hand_dock_blend or 0) <= 0.001 then
                clear_hand_globals()
            end
            return false
        end
        local want = should_hand_dock(grip, rack_active) and 1.0 or 0.0
        update_hand_dock_blend(want)
        local blend = rack.hand_dock_blend or 0
        if blend > 0.001 then
            publish_hand_dock(wp_name)
            update_rack_arm_delta(_G.__vr_slide_hand_world_pos)
            return true
        end
        if blend <= 0.001 and want <= 0 and not rack_active then
            if not rack.needs_rack then
                clear_hand_globals()
            else
                _G.__vr_slide_hand_world_pos = nil
                _G.__vr_slide_hand_world_rot = nil
                _G.__vr_slide_dock_blend_factor = 0
            end
        end
        return false
    end

    local function reset_gesture_pull_state()
        rack.pull_now = 0.0
        rack.pull_max = 0.0
        rack.pull_done = false
        rack.pull_peak_signed = nil
        rack.pull_start_signed = 0.0
        rack.peak_play_off_x = nil
        rack.peak_play_off_y = nil
        rack.peak_play_off_z = nil
        rack.pull_increases_signed = true
        rack.pull_dir_locked = false
        rack.start_pos = nil
        rack.pull_baseline = nil
        rack.start_play_off_x = nil
        rack.start_play_off_y = nil
        rack.start_play_off_z = nil
        rack.pull_play_ax = nil
        rack.pull_play_ay = nil
        rack.pull_play_az = nil
        rack.grab_slide_z = nil
        rack.pull_span_m = nil
        rack.push_span_m = nil
        -- Motion-rack (relative-hands) state, see M.gesture_motion_ratio.
        rack.mo_init = false
        rack.mo_ratio = 0.0
        rack.mo_status = nil
        reset_pull_smoothing()
        clear_pull_globals()
    end

    local slide_snapshots = {}

    local function clear_slide_snapshots()
        for k, _ in pairs(slide_snapshots) do
            slide_snapshots[k] = nil
        end
    end

    local function capture_slide_snapshot()
        return {
            needs_rack = rack.needs_rack == true,
            dry_fired = rack.dry_fired == true,
        }
    end

    local function clear_rack_gesture_state()
        rack.active = false
        rack.armed = true
        rack.in_range = false
        reset_gesture_pull_state()
        clear_rack_pull_axis()
        clear_hand_globals()
    end

    local function clear_slide_close_latch()
        rack.latch_slide_closed = false
        rack.latch_slide_wp = nil
        rack.tactical_latch = false
        rack.hold_rest_until = 0.0
    end

    local function clear_rack_state()
        rack.needs_rack = false
        rack.active = false
        rack.armed = true
        rack.in_range = false
        rack.dry_fired = false
        rack.hold_rest_until = 0.0
        rack.latch_slide_closed = false
        rack.latch_slide_wp = nil
        rack.tactical_latch = false
        reset_gesture_pull_state()
        clear_rack_pull_axis()
        clear_hand_globals()
    end

    local function get_weapon_go_token()
        local go = re2.weapon_gameobject
        if go == nil then return nil end
        local ok, addr = pcall(function() return go:get_address() end)
        if ok and addr ~= nil then return tostring(addr) end
        return tostring(go)
    end

    local function should_skip_slide_snapshot_io()
        return rawget(_G, "__vr_reload_stack_reset_in_progress") == true
    end

    local function restore_slide_snapshot(snap)
        clear_rack_gesture_state()
        rack.needs_rack = false
        rack.dry_fired = false
        if snap and snap.needs_rack and not should_skip_slide_snapshot_io() then
            local wp = get_weapon_go_name()
            if not weapon_no_rack_required(wp) then
                rack.needs_rack = true
                rack.dry_fired = snap.dry_fired == true
                M.apply_slide_park("restore")
            end
        end
        publish_rack_globals()
    end

    local function should_latch_slide_rest(wp)
        if rack.needs_rack or rack.active then return false end
        if rack.latch_slide_closed ~= true then return false end
        if rack.latch_slide_wp and wp and rack.latch_slide_wp ~= wp then return false end
        if get_bullet_number() <= 0 and rack.tactical_latch ~= true then return false end
        return true
    end

    local function set_slide_joint_local_z(travel, bp)
        local sj = get_slide_joint()
        if not sj or not bp then return false end
        local axis = bp.travel_axis or "z"
        return joint_local_with_bind_travel(sj, travel, bp, axis)
    end

    local function set_slide_joint_cylinder_pose(bind_pose)
        local sj = get_slide_joint()
        if not sj or not bind_pose then return false end
        pcall(function()
            sj:call("set_LocalPosition", Vector3f.new(
                tonumber(bind_pose.x) or 0.0,
                tonumber(bind_pose.y) or 0.0,
                tonumber(bind_pose.z) or 0.0))
        end)
        local rot = quat_from_euler_deg(
            tonumber(bind_pose.pitch) or 0.0,
            tonumber(bind_pose.yaw) or 0.0,
            tonumber(bind_pose.roll) or 0.0)
        if rot then
            pcall(function() sj:call("set_LocalRotation", rot) end)
        end
        return true
    end

    local function update_weapon_cache()
        local wp = get_weapon_go_name()
        local go_tok = get_weapon_go_token()
        if wp == rack.cached_wp and go_tok == rack.cached_weapon_go then return end

        if rack.latch_slide_wp and wp and rack.latch_slide_wp ~= wp then
            clear_slide_close_latch()
        end

        if rack.cached_wp and not should_skip_slide_snapshot_io() then
            slide_snapshots[rack.cached_wp] = capture_slide_snapshot()
        end

        local restore_snap = wp and slide_snapshots[wp] or nil
        if should_skip_slide_snapshot_io() then
            restore_snap = nil
        end

        rack.cached_wp = wp
        rack.cached_weapon_go = go_tok
        rack.miss_warned = false
        clear_rack_gesture_state()
        rack.needs_rack = false
        rack.dry_fired = false

        if wp and slide_dock_enabled() and is_weapon_enabled(wp) then
            if not resolve_slide_anchor_for_weapon(wp) and not rack.miss_warned then
                rack.miss_warned = true
                log.warn(string.format("[re2_vr_reload] slide anchor not resolved for %s", tostring(wp)))
            end
            restore_slide_snapshot(restore_snap)
        else
            rack.anchor = nil
            rack.anchor_kind = nil
            rack.weapon_xform = nil
            publish_rack_globals()
        end

        if wp and get_bullet_number() > 0 and rack.needs_rack then
            rack.needs_rack = false
            rack.dry_fired = false
            local bp = get_slide_bind_pose(wp)
            local sj = get_slide_joint()
            if bp and sj then
                set_slide_joint_local_z(bp.rest_z, bp)
            end
            publish_rack_globals()
        end
    end

    local function try_end_chamber_clear()
        local weapon = re2.weapon
        if not weapon then return false end
        local ok = false
        pcall(function()
            weapon:call("endChamberClear")
            ok = true
        end)
        _G.__vr_rack_chamber_commit_bypass = true
        pcall(function() weapon:call("executeEndReload") end)
        _G.__vr_rack_chamber_commit_bypass = false
        if ok then return true end
        ok = pcall(function()
            local cleared = sc(weapon, "get_IsChamberCleared")
            if cleared == true then return end
            weapon:call("executeReload", 1)
        end)
        return ok == true
    end

    local function rack_pull_progress_ratio(wp_name)
        local pull_d = get_effective_pull_dist(wp_name)
        if type(pull_d) ~= "number" or pull_d <= 1e-5 then return 0.0 end
        local peak = math.abs(rack.pull_max or 0)
        return math.min(1.0, peak / pull_d)
    end

    local function should_finish_rack_on_release(wp_name)
        if rack.pull_done == true then return true end
        if rack_pull_progress_ratio(wp_name) >= 0.55 then return true end
        return false
    end

    local function complete_rack_cycle(wp_name)
        if deps_ref.play_reload_sfx then deps_ref.play_reload_sfx("slide_rack_release") end
        try_end_chamber_clear()
        local bp = get_slide_bind_pose(wp_name)
        set_slide_joint_local_z(bp.rest_z, bp)
        rack.latch_slide_closed = true
        rack.latch_slide_wp = wp_name
        rack.hold_rest_until = 0.0
        rack.needs_rack = false
        rack.active = false
        rack.armed = true
        rack.dry_fired = false
        reset_gesture_pull_state()
        clear_rack_pull_axis()
        snap_hand_dock_off()
        publish_rack_globals()
        if arm_left_support_grace then arm_left_support_grace() end
        local lj = get_haptic_left_joystick()
        if lj then haptic_pulse(lj, 0.06, 200.0, 0.8) end
    end

    -- Trigger-driven slide-rack cycle (mirrors re2_vr_reload_ext_4.lua's
    -- update_manual_pump_gesture()): the slide grab itself is still
    -- grip+proximity (try_start_rack_gesture, unchanged, runs from
    -- M.tick()), but once grabbed (rack.active == true), grip must stay
    -- held throughout -- like holding the pump handle -- while left
    -- trigger drives the pull. A trigger press commits to a full pull even
    -- if tapped briefly; release lets it ease back and complete. Letting
    -- go of grip at any point before that completes aborts back to parked,
    -- exactly like releasing the pump handle early does.
    local function update_slide_rack_trigger(wp, publish_visual)
        if not rack.active then
            if rack.trig_travel ~= 0.0 or rack.trig_committed or rack.trigger_prev then
                rack.trig_travel = 0.0
                rack.trig_committed = false
                rack.trigger_prev = false
            end
            if rack.mo_init then
                rack.mo_init = false
                rack.mo_ratio = 0.0
            end
            return
        end

        local grip = is_left_grip_pressed()
        if not grip then
            local now = os.clock()
            if not rack.grip_release_at then
                rack.grip_release_at = now
            end
            local held_false_for = now - rack.grip_release_at
            if held_false_for < rack.grip_release_debounce_sec then
                -- Within the debounce grace window: treat as a spurious
                -- single-frame dropout, skip this tick's travel/state
                -- changes entirely and wait for the next frame's read.
                return
            end
            if rack.in_range and held_false_for < rack.grip_release_hard_cap_sec then
                -- Past the debounce but the hand hasn't moved off the dock --
                -- still more likely tremor/locomotion noise on the grip
                -- sensor than a real release. Keep waiting.
                return
            end
            -- Grip genuinely let go before the cycle finished: abort back
            -- to parked, same as letting go of the pump handle early does.
            rack.active = false
            rack.armed = true
            rack.trig_travel = 0.0
            rack.trig_committed = false
            rack.trigger_prev = false
            rack.grip_release_at = nil
            reset_gesture_pull_state()
            M.on_rack_released()
            publish_rack_globals()
            return
        end
        rack.grip_release_at = nil

        local bp = get_slide_bind_pose(wp)
        local trig = is_left_trigger_pressed()
        local trig_pressed_edge = trig and not rack.trigger_prev
        local trig_released_edge = (not trig) and rack.trigger_prev
        rack.trigger_prev = trig

        if trig_pressed_edge and not rack.pull_done then
            rack.trig_committed = true
        end

        -- Let go of the slide at the bottom of the pull, right here, instead
        -- of waiting for the slide to finish easing back to rest. Real
        -- behavior: player releases LT, hand comes off immediately, the
        -- slide snaps forward on its own (like a recoil spring) rather than
        -- looking like the hand is still carrying it forward. Only the
        -- VISUAL hand-dock detaches early -- rack.active/trig_travel keep
        -- running exactly as before, so the completion SFX/haptic/chamber
        -- finalize in complete_rack_cycle() still fire once the slide
        -- actually reaches rest, just without the hand attached for it.
        if rack.pull_done and trig_released_edge and not rack.hand_released_early then
            rack.hand_released_early = true
            snap_hand_dock_off()
        end

        local target
        if not rack.pull_done then
            target = rack.trig_committed and 1.0 or 0.0
        else
            target = trig and 1.0 or 0.0
        end

        local speed = (target > rack.trig_travel) and trig_rack_ease.get_pull_speed()
            or trig_rack_ease.get_push_speed()
        local dt = trig_rack_ease.get_delta_time()
        if rack.trig_travel < target then
            rack.trig_travel = math.min(rack.trig_travel + speed * dt, target)
        elseif rack.trig_travel > target then
            rack.trig_travel = math.max(rack.trig_travel - speed * dt, target)
        end

        -- Motion drive (real hand motion racks the slide), layered ON TOP
        -- of the LT drive above -- whichever is further back wins, so LT
        -- keeps working exactly as before and pure hand motion works with
        -- LT never touched. max() also gives the return trip the right
        -- feel for free: with no trigger held the eased value decays
        -- toward 0 (recoil-spring speed) but can never outrun the hands
        -- -- the slide rides the hands back, then the existing
        -- completion check fires once both are home.
        local mo = nil
        local sd_cfg = CFG.slide_dock or {}
        if sd_cfg.motion_rack_enabled ~= false then
            mo = M.gesture_motion_ratio(rack, wp, {
                axis_mode = "dock",
                get_joint = get_slide_joint,
                get_anchor_kind = function() return rack.anchor_kind or "xform" end,
            }, tonumber(sd_cfg.motion_pull_scale) or 2.0,
                tonumber(sd_cfg.motion_deadzone_m) or 0.012)
            if mo and mo > rack.trig_travel then rack.trig_travel = mo end
        end

        local eased = trig_rack_ease.smoothstep01(rack.trig_travel)
        rack.pull_now = eased * get_effective_pull_dist(wp)

        if bp then
            if not rack.pull_done then
                set_slide_joint_local_z(bp.parked_z + eased * (bp.back_z - bp.parked_z), bp)
            else
                set_slide_joint_local_z(bp.rest_z + eased * (bp.back_z - bp.rest_z), bp)
            end
        end

        -- Drive the hand-follow visual synchronously, right here, instead
        -- of relying on tick_hand_follow()'s separate frame-deduped tick
        -- (LateUpdateBehavior/PrepareRendering/BR hooks). That tick wasn't
        -- staying in sync with this function's higher update frequency,
        -- which made the hand appear to teleport between two positions
        -- instead of gliding with the slide (confirmed live: grab itself
        -- was smooth -- that's the untouched hand-tracked reach animation
        -- -- but pull/release, driven by this function, were not).
        --
        -- This function is called twice per frame (UpdateMotion pre-hook,
        -- then LateUpdateBehavior pre-hook). Debug logging proved the
        -- UpdateMotion-timed call always reads back a STALE cached world
        -- matrix for rack.anchor (the slide joint) -- the engine hasn't
        -- recomputed it since our set_slide_joint_local_z write above --
        -- while the LateUpdateBehavior-timed call reliably reads a fresh
        -- one. Publishing from both alternated the rendered hand between
        -- a frozen stale pose and the correct eased one every frame --
        -- that WAS the teleport. Only publish/apply from the call that's
        -- confirmed fresh; still advance trig_travel/local_z every call
        -- for the higher-frequency easing.
        if publish_visual then
            if publish_hand_dock(wp) then
                update_rack_arm_delta(_G.__vr_slide_hand_world_pos)
            end

            -- Publishing the target position alone wasn't enough -- the
            -- actual arm-IK application (bending the arm bones to reach
            -- it) only ran from M.tick()/M.tick_hand_follow()'s own
            -- once-per-frame-ish ticks, not from this higher-frequency
            -- one, so the rendered arm was still only catching up in
            -- occasional large jumps. Apply it directly here too.
            if (rack.hand_dock_blend or 0) > 0.001 then
                local apply_fn = rawget(_G, "__vr_apply_slide_dock_left_arm")
                if type(apply_fn) == "function" then
                    pcall(apply_fn, 5)
                end
            end
        end

        -- A motion pull that physically reached full travel counts as a
        -- committed pull, same as an LT press does -- the hands actually
        -- performed the rack, no button needed.
        if not rack.pull_done
            and (rack.trig_committed or (mo ~= nil and mo >= 1.0 - 1e-4))
            and rack.trig_travel >= 1.0 - 1e-4 then
            notify_pull_limit_reached(wp, get_effective_pull_dist(wp))
        elseif rack.pull_done and not trig and rack.trig_travel <= 1e-4 then
            complete_rack_cycle(wp)
        end

        publish_rack_globals()
    end

    -- Called from re2_vr_reload.lua's pre-application-entry hooks
    -- (UpdateMotion + LateUpdateBehavior, pre-entry), same timing as
    -- reload_pump.on_pre_arm_ik() -- this higher call frequency (vs. the
    -- once-per-frame post-entry M.update_slide_rack() the hand-tracked
    -- gesture uses) is what makes the eased travel actually look smooth
    -- instead of chunky/abrupt.
    function M.tick_trigger_rack(publish_visual)
        if not slide_dock_enabled() then return end
        local wp = rack.cached_wp
        if not wp or not rack.needs_rack then return end
        if not weapon_uses_trigger_rack(wp) then return end
        if rawget(_G, "__vr_in_mag_holster_zone") == true or is_mag_insert_active() then return end
        if not rack.active then return end
        update_slide_rack_trigger(wp, publish_visual)
    end

    function M.set_needs_rack(_reason)
        if not slide_dock_enabled() then return end
        local wp = get_weapon_go_name()
        if wp and weapon_no_rack_required(wp) then return end
        clear_slide_close_latch()
        rack.hold_rest_until = 0.0
        if not wp or not is_weapon_enabled(wp) then return end
        rack.needs_rack = true
        resolve_slide_anchor_for_weapon(wp)
        publish_rack_globals()
        M.apply_slide_park("set_needs_rack")
    end

    function M.on_dry_fire()
        if not slide_dock_enabled() then return end
        if not manual_reload_context_active() then return end
        local wp = get_weapon_go_name()
        if wp and weapon_no_rack_required(wp) then return end
        rack.dry_fired = true
    end

    function M.clear_tactical_rack_state()
        rack.dry_fired = false
        rack.needs_rack = false
        rack.active = false
        rack.hold_rest_until = 0.0
        clear_rack_gesture_state()
        local wp = get_weapon_go_name()
        if wp and slide_dock_enabled() then
            resolve_slide_anchor_for_weapon(wp)
            local bp = get_slide_bind_pose(wp)
            if bp then
                set_slide_joint_local_z(bp.rest_z, bp)
                rack.latch_slide_closed = true
                rack.latch_slide_wp = wp
                rack.tactical_latch = true
            end
        end
        publish_rack_globals()
    end

    function M.arm_rack_for_reload()
        if not slide_dock_enabled() then return end
        if not manual_reload_context_active() then return end
        local wp = get_weapon_go_name()
        if wp and weapon_no_rack_required(wp) then return end
        local chamber = get_bullet_number()
        local carried = get_mag_carried_rounds()
        if chamber > 0 or carried > 0 then
            return
        end
        if rack.needs_rack then
            M.apply_slide_park("arm_rack_for_reload")
            return
        end
        if rack.dry_fired then
            M.set_needs_rack("reload_start")
        end
    end

    function M.on_mag_insert_complete(needs_rack)
        if not slide_dock_enabled() then return end
        local wp = get_weapon_go_name()
        if wp and weapon_no_rack_required(wp) then
            rack.dry_fired = false
            if get_bullet_number() <= 0 then
                try_end_chamber_clear()
            end
            clear_rack_gesture_state()
            rack.needs_rack = false
            rack.hold_rest_until = 0.0
            local bp = get_slide_bind_pose(wp)
            if bp then
                set_slide_joint_local_z(bp.rest_z, bp)
                rack.latch_slide_closed = true
                rack.latch_slide_wp = wp
            end
            publish_rack_globals()
            return
        end
        if needs_rack == true or rack.dry_fired == true or rack.needs_rack == true then
            M.set_needs_rack("insert")
        else
            rack.needs_rack = false
            rack.dry_fired = false
            rack.tactical_latch = false
            if get_bullet_number() > 0 then
                clear_rack_gesture_state()
                rack.hold_rest_until = 0.0
                local bp = wp and get_slide_bind_pose(wp)
                if bp then
                    set_slide_joint_local_z(bp.rest_z, bp)
                    rack.latch_slide_closed = true
                    rack.latch_slide_wp = wp
                end
            end
            publish_rack_globals()
        end
        rack.dry_fired = false
    end

    function M.on_gesture_start(wp_name)
        local track_pos = select(1, get_track_pos_for_rack())
        if track_pos then
            rack.start_pos = Vector3f.new(track_pos.x, track_pos.y, track_pos.z)
        end
        rack.start_play_off_x = nil
        rack.start_play_off_y = nil
        rack.start_play_off_z = nil
        local hmd_off = get_controller_hmd_offset()
        if hmd_off then
            rack.start_play_off_x = hmd_off.x
            rack.start_play_off_y = hmd_off.y
            rack.start_play_off_z = hmd_off.z
        end
        rack.pull_baseline = nil
        rack.pull_start_signed = 0.0
        rack.pull_dir_locked = false
        rack.pull_increases_signed = true
        rack.last_wid = wp_name
        rack.last_hand_x = nil
        rack.last_hand_y = nil
        rack.last_hand_z = nil
        reset_pull_smoothing()
        clear_pull_globals()
        capture_rack_pull_axis(wp_name)
        capture_play_pull_axis(wp_name)
        local dock_world = wp_name and select(1, get_hand_dock_pose(wp_name)) or nil
        if dock_world and track_pos then
            rack.pull_baseline = compute_dock_relative_pull(dock_world, track_pos)
        end
        local pull_d = get_effective_pull_dist(wp_name)
        local push_d = get_effective_push_dist(wp_name)
        _G.__vr_slide_pull_dist = pull_d
        _G.__vr_slide_push_dist = push_d
    end

    function M.on_rack_released()
        clear_rack_pull_axis()
        rack.pull_baseline = nil
        rack.start_play_off_x = nil
        rack.start_play_off_y = nil
        rack.start_play_off_z = nil
        rack.pull_play_ax = nil
        rack.pull_play_ay = nil
        rack.pull_play_az = nil
        rack.last_hand_x = nil
        rack.last_hand_y = nil
        rack.last_hand_z = nil
        reset_pull_smoothing()
        update_hand_dock_blend(0)
        if (rack.hand_dock_blend or 0) <= 0.001 then
            clear_hand_globals()
        end
        _G.__vr_slide_dock_arm_delta = nil
        _G.__vr_slide_dock_in_range = false
    end

    local function slide_preview_sec()
        return tonumber((CFG.slide_dock or {}).preview_sec) or 6.0
    end

    local function apply_slide_preview_pose(wp_name)
        if not wp_name then return false end
        if get_weapon_go_name() ~= wp_name then return false end
        if not resolve_slide_anchor_for_weapon(wp_name) then return false end
        if not get_slide_joint() then return false end
        if weapon_uses_manual_cylinder_reload(wp_name) then
            local mode = slide_preview.bind_z or "parked"
            if mode == "rest" then
                if slide_preview.cyl_rest_pos and slide_preview.cyl_rest_rot then
                    pcall(function()
                        get_slide_joint():call("set_LocalPosition", slide_preview.cyl_rest_pos)
                        get_slide_joint():call("set_LocalRotation", slide_preview.cyl_rest_rot)
                    end)
                end
            else
                set_slide_joint_cylinder_pose(get_cylinder_open_bind_pose(wp_name))
            end
            if weapon_uses_chamber_bullet_follow(wp_name) then
                local ot = (slide_preview.bind_z == "rest") and 0.0 or 1.0
                apply_chamber_bullet_follow_open_t(ot)
            end
            return true
        end
        local bp = get_slide_bind_pose(wp_name)
        if not bp then return false end
        local mode = slide_preview.bind_z or "parked"
        local z = bp.parked_z
        if mode == "rest" then
            z = bp.rest_z
        elseif mode == "back" then
            z = bp.back_z
        end
        set_slide_joint_local_z(z, bp)
        publish_hand_dock(wp_name)
        _G.__vr_slide_dock_blend_factor = 1.0
        return true
    end

    local function extend_slide_preview(wp_name, bind_z_mode)
        slide_ui.status = nil
        if not wp_name then return end
        if get_weapon_go_name() ~= wp_name then
            slide_ui.status = "Equip " .. tostring(wp_name) .. " for live preview"
            return
        end
        if bind_z_mode == "rest" or bind_z_mode == "parked" or bind_z_mode == "back" then
            slide_preview.bind_z = bind_z_mode
        end
        if not resolve_slide_anchor_for_weapon(wp_name) then
            slide_ui.status = "Slide anchor not resolved"
            return
        end
        if weapon_uses_manual_cylinder_reload(wp_name) then
            local sj = get_slide_joint()
            if sj then
                slide_preview.cyl_rest_pos = sc(sj, "get_LocalPosition")
                slide_preview.cyl_rest_rot = sc(sj, "get_LocalRotation")
            end
        end
        slide_preview.active = true
        slide_preview.wp = wp_name
        slide_preview.until_t = os.clock() + slide_preview_sec()
        apply_slide_preview_pose(wp_name)
    end

    local function bump_slide_preview(wp_name, bind_z_mode)
        if not wp_name then return end
        if slide_preview.active and slide_preview.wp == wp_name and os.clock() < slide_preview.until_t then
            if bind_z_mode == "rest" or bind_z_mode == "parked" or bind_z_mode == "back" then
                slide_preview.bind_z = bind_z_mode
            end
            slide_preview.until_t = os.clock() + slide_preview_sec()
            apply_slide_preview_pose(wp_name)
            return
        end
        extend_slide_preview(wp_name, bind_z_mode)
    end

    local function tick_slide_preview()
        if not slide_preview.active then return false end
        if os.clock() >= slide_preview.until_t then
            slide_preview.active = false
            return false
        end
        local wp = slide_preview.wp or rack.cached_wp
        if wp then
            apply_slide_preview_pose(wp)
        end
        return true
    end

    function M.apply_slide_park(_source)
        if not slide_dock_enabled() then return end
        if tick_slide_preview() then return end
        local wp = rack.cached_wp
        if not wp then return end
        if weapon_uses_manual_cylinder_reload(wp) then return end
        local bp = get_slide_bind_pose(wp)
        if bp and should_latch_slide_rest(wp) then
            set_slide_joint_local_z(bp.rest_z, bp)
            return
        end
        if bp and not rack.needs_rack and not rack.active
            and rack.hold_rest_until and os.clock() < rack.hold_rest_until then
            set_slide_joint_local_z(bp.rest_z, bp)
            return
        end
        if not rack.needs_rack and not rack.active then return end
        if not bp then return end
        if not get_slide_joint() then return end

        -- update_slide_rack_trigger() is the sole owner of the joint's
        -- local_z for the duration of an active trigger-rack cycle --
        -- this function's hand-tracked/push-delta math below (which reads
        -- real controller position once rack.pull_done is true) was still
        -- running unconditionally for these weapons too, fighting the
        -- trigger-driven writes every frame (confirmed live: caused both
        -- the pull snapping instead of easing, and the slide moving with
        -- raw hand motion while LT was held). The park-only logic above
        -- (latch/rest/parked-open display before grab) still applies.
        if rack.active and weapon_uses_trigger_rack(wp) then return end

        local pull_d = get_effective_pull_dist(wp)
        local push_d = get_effective_push_dist(wp)
        local grab_z = rack.grab_slide_z or bp.parked_z
        local slide_travel = bp.back_z - bp.parked_z
        local push_travel = bp.rest_z - bp.back_z
        local z = grab_z
        local signed = tonumber(_G.__vr_slide_rack_pull_signed) or rack.pull_now or 0.0

        if rack.active and pull_d > 1e-5 then
            if rack.pull_done and push_d > 1e-5 then
                local push_delta = get_push_delta(signed)
                local frac = math.min(push_delta / push_d, 1.0)
                z = bp.back_z + frac * push_travel
            else
                local hand_m
                if rack.pull_increases_signed then
                    hand_m = math.max(0.0, signed)
                else
                    hand_m = math.max(0.0, -signed)
                end
                local frac = math.min(hand_m / pull_d, 1.0)
                z = grab_z + frac * slide_travel
            end
        elseif rack.needs_rack then
            z = bp.parked_z
        end
        set_slide_joint_local_z(z, bp)
    end

    function M.sync_rack_motion(_source)
        if not slide_dock_enabled() then return end
        local wp = rack.cached_wp
        if not wp then return end

        M.apply_slide_park(_source)
        if rack.active or (rack.hand_dock_blend or 0) > 0.001 then
            publish_hand_dock(wp)
            update_rack_arm_delta(_G.__vr_slide_hand_world_pos)
        end
        publish_rack_globals()
    end

    function M.invalidate_weapon_cache()
        rack.cached_weapon_go = nil
        rack.cached_wp = nil
    end

    function M.refresh_weapon_cache()
        update_weapon_cache()
    end

    function M.reset_stack_state()
        clear_slide_snapshots()
        clear_slide_close_latch()
        rack.cached_wp = nil
        rack.cached_weapon_go = nil
        clear_rack_state()
        publish_rack_globals()
        update_weapon_cache()
    end

    function M.tick()
        if not slide_dock_enabled() then
            clear_rack_state()
            return
        end

        tick_slide_preview()

        update_weapon_cache()
        local wp = rack.cached_wp
        if not wp then
            rack.in_range = false
            publish_rack_globals()
            return
        end

        if not rack.anchor then
            resolve_slide_anchor_for_weapon(wp)
        end

        local track_pos, track_src = get_track_pos_for_rack()
        rack.last_track_src = track_src or "nil"
        local grip = is_left_grip_pressed()
        rack.last_grip = grip == true

        -- 2026-08-14: found live -- same bug CLASS as the 2026-08-08 slide-
        -- rack visual-loop fix (see re2_vr_slide_rack_visual_loop_fix
        -- memory), on a DIFFERENT signal that fix never covered. Player
        -- held LG continuously for ~10s and still saw the hand looping.
        -- update_slide_rack_trigger() reads its OWN separate grip sample
        -- and debounces it (grip_release_debounce_sec/hard_cap) before
        -- letting a release abort rack.active -- but tick_hand_dock_blend()
        -- below (via should_hand_dock()) was being fed this RAW, per-frame
        -- `grip` local with no debounce at all, so a single noisy false
        -- frame eased the visual dock blend out and immediately back in,
        -- looping the hand even while rack.active stayed perfectly stable.
        -- Debounce it here too, reusing the same short flat window as the
        -- state-machine's own debounce (grip_release_debounce_sec) so a
        -- momentary false reading doesn't flip the visual gate.
        if grip then
            rack.visual_grip_release_at = nil
            rack.grip_debounced = true
        else
            local now = os.clock()
            if not rack.visual_grip_release_at then
                rack.visual_grip_release_at = now
            end
            if now - rack.visual_grip_release_at >= (rack.grip_release_debounce_sec or 0.1) then
                rack.grip_debounced = false
            end
            -- else: still within the debounce window, keep grip_debounced
            -- at whatever it already was (sticky true through a brief drop).
        end

        local dock_pos = select(1, get_hand_dock_pose(wp))
        local near = false
        rack.last_dock_dist = nil
        if rack.needs_rack and dock_pos then
            rack.last_dock_dist = distance_to_dock_for_near(dock_pos)
            -- Hysteresis: use a wider exit threshold than the entry
            -- threshold once already docked. should_hand_dock() gates the
            -- visual hand-dock blend directly on rack.in_range with no
            -- debounce of its own, so a hard single threshold let ordinary
            -- boundary noise flip it rapidly, easing the hand toward the
            -- dock and back over and over even while rack.active (the
            -- actual grab cycle) stayed perfectly stable.
            local enter_dist = get_dock_dist(wp)
            local exit_dist = enter_dist + 0.03
            local threshold = (rack.in_range == true) and exit_dist or enter_dist
            near = rack.last_dock_dist <= threshold
            log_dist_candidates(near, threshold)
        end
        rack.in_range = near

        -- Trigger-gated weapons: once grabbed, grip alone governs (matching
        -- the pump handle's behavior) -- don't abort just because the hand
        -- wandered from the dock zone while still gripping.
        if rack.active and rack.needs_rack and not near and not rack.pull_done
            and not weapon_uses_trigger_rack(wp) then
            rack.active = false
            rack.armed = true
            reset_gesture_pull_state()
            M.on_rack_released()
        end

        if rack.needs_rack and grip and not rack.active and not is_mag_insert_active()
            and get_bullet_number() > 0 and near then
            try_start_rack_gesture(wp, track_pos, near)
        end

        if is_mag_insert_active() and rack.active then
            rack.active = false
            reset_gesture_pull_state()
            M.on_rack_released()
        end

        local pull_d, push_d = get_pull_limits(wp)
        _G.__vr_slide_pull_dist = pull_d
        _G.__vr_slide_push_dist = push_d

        if rack.was_rack_active and not rack.active then
            M.on_rack_released()
        end

        if not rack.active then
            reset_pull_smoothing()
            clear_pull_globals()
            rack.pull_now = 0.0
        end

        _G.__vr_slide_dock_in_range = near == true

        if rack.active and rack.pull_done and not grip then
            snap_hand_dock_off()
        end

        tick_hand_dock_blend(wp, rack.grip_debounced, rack.active)
        rack.was_rack_active = rack.active
        publish_rack_globals()

        if rack.active and (rack.hand_dock_blend or 0) > 0.001 then
            local apply_fn = rawget(_G, "__vr_apply_slide_dock_left_arm")
            if type(apply_fn) == "function" then
                pcall(apply_fn, 5)
            end
        end
    end

    function M.update_slide_rack()
        if not slide_dock_enabled() then return end
        local wp = rack.cached_wp
        if not wp or not rack.needs_rack then return end

        if rawget(_G, "__vr_in_mag_holster_zone") == true or is_mag_insert_active() then
            if rack.active then
                rack.active = false
                rack.armed = true
                reset_gesture_pull_state()
                M.on_rack_released()
            end
            return
        end

        if not rack.active and rawget(_G, "__vr_mag_dropped") == true
            and rawget(_G, "__vr_mag_in_left_hand") ~= true then
            rack.armed = true
            return
        end

        if weapon_uses_trigger_rack(wp) then
            -- Handled by M.tick_trigger_rack(), called from higher-frequency
            -- pre-application-entry hooks (matching the pump-action gesture's
            -- timing) instead of this once-per-frame post-entry tick, since
            -- that's what actually made the pump's motion feel smooth.
            local pd, psd = get_effective_pull_dist(wp), get_effective_push_dist(wp)
            _G.__vr_slide_pull_dist = pd
            _G.__vr_slide_push_dist = psd
            if not rack.active and not is_left_grip_pressed() then rack.armed = true end
            return
        end

        local grip = is_left_grip_pressed()
        local pull_d = get_effective_pull_dist(wp)
        local push_d = get_effective_push_dist(wp)
        _G.__vr_slide_pull_dist = pull_d
        _G.__vr_slide_push_dist = push_d

        if not rack.active then
            if not grip then
                rack.armed = true
            end
            return
        end

        local signed = tonumber(_G.__vr_slide_rack_pull_signed) or rack.pull_now or 0.0
        rack.pull_now = signed
        if signed > rack.pull_max then rack.pull_max = signed end

        if not grip then
            if should_finish_rack_on_release(wp) then
                complete_rack_cycle(wp)
            else
                rack.active = false
                rack.armed = true
                reset_gesture_pull_state()
                M.on_rack_released()
            end
            publish_rack_globals()
            return
        end

        if not rack.pull_done then
            if not rack.pull_dir_locked and math.abs(signed) > get_pull_deadzone() then
                rack.pull_increases_signed = signed > (rack.pull_start_signed or 0.0)
                rack.pull_dir_locked = true
            end
            local pull_complete = false
            if rack.pull_increases_signed and signed >= pull_d then
                pull_complete = true
            elseif not rack.pull_increases_signed and signed <= -pull_d then
                pull_complete = true
            end
            if pull_complete then
                notify_pull_limit_reached(wp, signed)
            end
        end

        if rack.pull_done and push_d > 1e-5 then
            local push_delta = get_push_delta(signed)
            if push_delta >= push_d * 0.98 then
                complete_rack_cycle(wp)
                publish_rack_globals()
                return
            end
        end
    end

    function M.on_frame()
        M.tick()
    end

    function M.tick_hand_follow()
        if not slide_dock_enabled() then return end
        local frame_id = get_frame_id()
        if hand_follow_frame == frame_id then return end
        hand_follow_frame = frame_id

        if tick_slide_preview() then
            local apply_fn = rawget(_G, "__vr_apply_slide_dock_left_arm")
            if type(apply_fn) == "function" then
                pcall(apply_fn, 5)
            end
            return
        end
        local wp = rack.cached_wp
        if not wp then return end
        if rack.active or (rack.hand_dock_blend or 0) > 0.001 then
            publish_hand_dock(wp)
            update_rack_arm_delta(_G.__vr_slide_hand_world_pos)
        end
    end

    function M.update_rack_pull()
        local wp = rack.cached_wp
        if not wp or not rack.active then return end
        if weapon_uses_trigger_rack(wp) then return end
        local track_pos = get_track_pos_for_rack()
        if track_pos then
            update_rack_pull(track_pos, wp)
        end
    end

    function M.on_weapon_swap()
        update_weapon_cache()
    end

    function M.is_slide_close_latched()
        return rack.latch_slide_closed == true
    end

    function M.on_weapon_fired()
        clear_slide_close_latch()
    end

    function M.on_context_inactive()
        clear_rack_state()
    end

    function M.on_disabled()
        clear_rack_state()
        clear_slide_snapshots()
        rack.cached_wp = nil
    end

    function M.update_globals()
        publish_rack_globals()
    end

    function M.needs_rack()
        return rack.needs_rack == true
    end

    function M.is_no_rack_weapon(wp_name)
        return weapon_no_rack_required(wp_name)
    end

    function M.rack_active()
        return rack.active == true
    end

    function M.get_rack()
        return rack
    end

    function M.on_tuning_restored()
        slide_ui.status = nil
        slide_preview.active = false
        local wp = rack.cached_wp or get_weapon_go_name()
        if wp then resolve_slide_anchor_for_weapon(wp) end
    end


    -- Shared pull/push gesture: slide rack (dock axis) + manual pump (joint axis, no hand dock).
    local function sample_joint_bind_span(joint, anchor_kind, bp)
        if not joint or not bp then return nil end
        local saved = sc(joint, "get_LocalPosition")
        if not saved then return nil end
        local axis = bp.travel_axis or "z"
        if axis == "y" and type(saved.y) ~= "number" then return nil end
        if axis ~= "y" and type(saved.z) ~= "number" then return nil end
        local sx = type(saved.x) == "number" and saved.x or (bp.x or 0.0)
        local sy = type(saved.y) == "number" and saved.y or bp.y
        local sz = type(saved.z) == "number" and saved.z or 0.0

        local function pos_at_travel(travel)
            if axis == "y" then
                joint_local_with_bind_travel(joint, travel, bp, "y")
            else
                joint_local_with_bind_travel(joint, travel, bp, "z")
            end
            local wm = read_anchor_world_matrix(joint, anchor_kind or "joint")
            return world_matrix_to_position(wm)
        end

        local d0 = pos_at_travel(bp.parked_z)
        local d1 = pos_at_travel(bp.back_z)
        pcall(function()
            joint:call("set_LocalPosition", Vector3f.new(sx, sy, sz))
        end)
        if not d0 or not d1 then return nil end

        local vx = d1.x - d0.x
        local vy = d1.y - d0.y
        local vz = d1.z - d0.z
        local span = math.sqrt(vx * vx + vy * vy + vz * vz)
        if span < 1e-4 then return nil end
        return span, vx / span, vy / span, vz / span
    end

    local function measure_joint_push_span_m(joint, anchor_kind, bp)
        if not joint or not bp then return nil end
        local saved = sc(joint, "get_LocalPosition")
        if not saved then return nil end
        local axis = bp.travel_axis or "z"
        if axis == "y" and type(saved.y) ~= "number" then return nil end
        if axis ~= "y" and type(saved.z) ~= "number" then return nil end
        local sx = type(saved.x) == "number" and saved.x or (bp.x or 0.0)
        local sy = type(saved.y) == "number" and saved.y or bp.y
        local sz = type(saved.z) == "number" and saved.z or 0.0

        local function pos_at_travel(travel)
            if axis == "y" then
                joint_local_with_bind_travel(joint, travel, bp, "y")
            else
                joint_local_with_bind_travel(joint, travel, bp, "z")
            end
            local wm = read_anchor_world_matrix(joint, anchor_kind or "joint")
            return world_matrix_to_position(wm)
        end

        local d0 = pos_at_travel(bp.back_z)
        local d1 = pos_at_travel(bp.rest_z)
        pcall(function()
            joint:call("set_LocalPosition", Vector3f.new(sx, sy, sz))
        end)
        if not d0 or not d1 then return nil end
        local dx = d1.x - d0.x
        local dy = d1.y - d0.y
        local dz = d1.z - d0.z
        local span = math.sqrt(dx * dx + dy * dy + dz * dz)
        if span < 1e-4 then return nil end
        return span
    end

    local function gesture_get_pull_axis_sign()
        return tonumber((CFG.slide_dock or {}).pull_axis_sign) or 1.0
    end

    local function gesture_reset_pull_smoothing(g)
        g.pull_smooth = 0.0
        g.pull_smooth_init = false
    end

    local function gesture_effective_pull_dist(g, wp_name)
        if g.pull_span_m and g.pull_span_m > 1e-4 then
            return g.pull_span_m
        end
        return select(1, get_pull_limits(wp_name))
    end

    local function gesture_effective_push_dist(g, wp_name)
        if g.push_span_m and g.push_span_m > 1e-4 then
            return g.push_span_m
        end
        local span = wp_name and measure_slide_push_span_m(wp_name)
        if span and span > 1e-4 then
            g.push_span_m = span
            return span
        end
        return select(2, get_pull_limits(wp_name))
    end

    local function gesture_get_pull_axis_live(g, wp_name, ctx)
        local sj = ctx.get_joint and ctx.get_joint()
        local kind = (ctx.get_anchor_kind and ctx.get_anchor_kind()) or "joint"
        local bp = wp_name and get_slide_bind_pose(wp_name) or nil
        local travel_axis = bp and bp.travel_axis or "z"
        if sj then
            local wm = read_anchor_world_matrix(sj, kind)
            local ax, ay, az
            if travel_axis == "y" then
                ax, ay, az = axis_y_from_world_matrix(wm)
            else
                ax, ay, az = axis_z_from_world_matrix(wm)
            end
            if ax then return ax, ay, az, "wm_live" end
            local axis_name = travel_axis == "y" and "AxisY" or "AxisZ"
            local fwd = read_anchor_axis(sj, kind, axis_name)
            if fwd then
                local len = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z)
                if len > 1e-6 then
                    return fwd.x / len, fwd.y / len, fwd.z / len, "axis_live"
                end
            end
        end
        if g.pull_axis_set and g.pull_ax then
            return g.pull_ax, g.pull_ay, g.pull_az, g.pull_axis_src or "frozen"
        end
        if wp_name and ctx.axis_mode == "joint" and sj then
            local bp = get_slide_bind_pose(wp_name)
            local span, ax, ay, az = sample_joint_bind_span(sj, kind, bp)
            if ax then return ax, ay, az, "bind_span_sample" end
        elseif wp_name and ctx.axis_mode == "dock" then
            local _, ax, ay, az = sample_slide_bind_span(wp_name)
            if ax then return ax, ay, az, "bind_span_sample" end
        end
        return nil
    end

    local function gesture_capture_play_pull_axis(g, wp_name, ctx)
        local ax, ay, az = gesture_get_pull_axis_live(g, wp_name, ctx)
        if not ax then return false end
        local pax, pay, paz = world_dir_to_play_dir(ax, ay, az)
        g.pull_play_ax = pax
        g.pull_play_ay = pay
        g.pull_play_az = paz
        return true
    end

    local function gesture_capture_pull_axis(g, wp_name, ctx)
        g.pull_ax = nil
        g.pull_ay = nil
        g.pull_az = nil
        g.pull_axis_set = false
        g.pull_axis_src = nil

        if wp_name and ctx.axis_mode == "joint" then
            local sj = ctx.get_joint and ctx.get_joint()
            local kind = (ctx.get_anchor_kind and ctx.get_anchor_kind()) or "joint"
            local bp = get_slide_bind_pose(wp_name)
            if sj and bp then
                local _, ax, ay, az = sample_joint_bind_span(sj, kind, bp)
                if ax then
                    g.pull_ax = ax
                    g.pull_ay = ay
                    g.pull_az = az
                    g.pull_axis_set = true
                    g.pull_axis_src = "bind_span"
                    return
                end
            end
        elseif wp_name and ctx.axis_mode == "dock" then
            local _, ax, ay, az = sample_slide_bind_span(wp_name)
            if ax then
                g.pull_ax = ax
                g.pull_ay = ay
                g.pull_az = az
                g.pull_axis_set = true
                g.pull_axis_src = "bind_span"
                return
            end
        end

        local sj = ctx.get_joint and ctx.get_joint()
        local kind = (ctx.get_anchor_kind and ctx.get_anchor_kind()) or "joint"
        if sj then
            local bp = wp_name and get_slide_bind_pose(wp_name) or nil
            local travel_axis = bp and bp.travel_axis or "z"
            local wm = read_anchor_world_matrix(sj, kind)
            local ax, ay, az
            if travel_axis == "y" then
                ax, ay, az = axis_y_from_world_matrix(wm)
            else
                ax, ay, az = axis_z_from_world_matrix(wm)
            end
            if ax then
                g.pull_ax = ax
                g.pull_ay = ay
                g.pull_az = az
                g.pull_axis_set = true
                g.pull_axis_src = "world_matrix"
                return
            end
        end
    end

    local function gesture_compute_delta_pull(g, track_pos, wp_name, ctx)
        local sign_mul = gesture_get_pull_axis_sign()

        if g.pull_play_ax and g.start_play_off_x then
            local off = get_controller_hmd_offset()
            if off then
                local dx = off.x - g.start_play_off_x
                local dy = off.y - g.start_play_off_y
                local dz = off.z - g.start_play_off_z
                local signed_play = -(dx * g.pull_play_ax + dy * g.pull_play_ay
                    + dz * g.pull_play_az) * sign_mul
                return signed_play, "play_hmd"
            end
        end

        if not track_pos or not g.start_pos then return 0.0, "no_start" end
        local dx = track_pos.x - g.start_pos.x
        local dy = track_pos.y - g.start_pos.y
        local dz = track_pos.z - g.start_pos.z
        local ax, ay, az, src = gesture_get_pull_axis_live(g, wp_name, ctx)
        if ax then
            return -(dx * ax + dy * ay + dz * az) * sign_mul, src
        end
        return 0.0, "no_axis"
    end

    local function gesture_smooth_clamp(g, signed, pull_d, push_d, signed_global)
        local alpha = get_pull_smooth_alpha()
        if not g.pull_smooth_init then
            g.pull_smooth = signed
            g.pull_smooth_init = true
        else
            g.pull_smooth = g.pull_smooth + (signed - g.pull_smooth) * alpha
        end

        local s = g.pull_smooth
        local dz_on = get_pull_deadzone()
        local dz_off = dz_on * 0.5
        local prev = signed_global and tonumber(rawget(_G, signed_global)) or 0.0
        if math.abs(prev) <= 1e-6 then
            if math.abs(s) < dz_on then s = 0.0 end
        else
            if math.abs(s) < dz_off then s = 0.0 end
        end

        if not g.pull_done then
            if g.pull_increases_signed then
                s = math.max(0.0, s)
                if s > pull_d then s = pull_d end
            else
                s = math.min(0.0, s)
                if s < -pull_d then s = -pull_d end
            end
        elseif push_d and push_d > 0 and g.pull_peak_signed ~= nil then
            local peak = g.pull_peak_signed
            if g.pull_increases_signed then
                if s > peak then s = peak end
                if s < peak - push_d then s = peak - push_d end
            else
                if s < peak then s = peak end
                if s > peak + push_d then s = peak + push_d end
            end
        end

        if signed_global then
            rawset(_G, signed_global, s)
        end
        return s
    end

    local function gesture_get_push_delta(g, signed)
        if not g.pull_done then return 0.0 end
        if g.peak_play_off_x and g.pull_play_ax then
            local off = get_controller_hmd_offset()
            if off then
                local dx = off.x - g.peak_play_off_x
                local dy = off.y - g.peak_play_off_y
                local dz = off.z - g.peak_play_off_z
                local sign_mul = gesture_get_pull_axis_sign()
                local d = -(dx * g.pull_play_ax + dy * g.pull_play_ay
                    + dz * g.pull_play_az) * sign_mul
                if g.pull_increases_signed then
                    return math.max(0.0, -d)
                end
                return math.max(0.0, d)
            end
        end
        if g.pull_peak_signed == nil then return 0.0 end
        local peak = g.pull_peak_signed
        if g.pull_increases_signed then
            return math.max(0.0, peak - signed)
        end
        return math.max(0.0, signed - peak)
    end

    local function gesture_pull_magnitude(g, signed)
        if g.pull_increases_signed then
            return math.max(0.0, signed)
        end
        return math.max(0.0, -signed)
    end

    -- Motion-driven rack/pump: relative-hands pull ratio (0 = parked,
    -- 1 = fully pulled). Shared by the trigger-rack cycle here and
    -- ext_4's manual pump cycle (via the slide_gesture module handoff).
    --
    -- Measures dot(P_left - P_right, pull_dir) against a baseline captured
    -- at grab time, so ALL of these register as the same pull:
    --   - left hand pulls back, right hand still
    --   - right hand pushes forward, left hand still
    --   - both at once (left back+down, right up/forward)
    -- because only the hands' separation along the barrel axis matters,
    -- not either hand's own world motion (the weapon translating with the
    -- right hand cancels out of the subtraction entirely).
    --
    -- Direction/sign is taken from the bind-span sample: the world vector
    -- from the slide/pump joint's parked_z pose to its back_z pose IS the
    -- pull direction by construction -- no guessed axis-sign convention.
    -- (The original mod's motion pump could invert front-to-back because
    -- it projected on a raw joint axis whose sign vs. "back" was assumed;
    -- this can't, which is the whole reason this helper exists instead of
    -- reviving the old tracked-gesture path.) Each tick the LIVE joint
    -- axis is re-read so the direction follows the weapon's rotation, but
    -- its sign is locked to agree with the grab-time span vector.
    --
    -- Both hands are read via get_controller_game_world_pos -- the RAW
    -- controllers transformed into game world -- NEVER __vr_lh_world,
    -- which the slide-dock override feeds the DOCKED joint position while
    -- racking (the hand is glued to the slide there: reading it back
    -- would measure our own output, not the player's input).
    function M.gesture_motion_ratio(g, wp_name, ctx, scale, deadzone)
        -- Pull direction is derived WITHOUT moving the joint: earlier
        -- versions sampled the parked/back world poses (write local_z,
        -- read world matrix back), but the engine serves a STALE cached
        -- world matrix for a joint written the same frame (documented at
        -- update_slide_rack_trigger's publish_visual block) -- the sample
        -- reads a zero span and the whole drive silently never arms.
        -- Instead: the joint's LIVE travel axis in world (a plain read,
        -- always fresh enough for a direction) times the LOCAL sign of
        -- back_z - parked_z from the bind pose. That sign is per-weapon
        -- ground truth for which way along the axis "racked back" lies --
        -- no guessed convention, no sampling.
        local bp = wp_name and get_slide_bind_pose(wp_name) or nil
        if not bp then
            g.mo_status = "no bind pose"
            return g.mo_init and (g.mo_ratio or 0.0) or nil
        end
        local s_sign = (((tonumber(bp.back_z) or 0.0)
            - (tonumber(bp.parked_z) or 0.0)) >= 0.0) and 1.0 or -1.0

        local sj = ctx.get_joint and ctx.get_joint()
        local kind = (ctx.get_anchor_kind and ctx.get_anchor_kind()) or "joint"
        local ax, ay, az
        local axis_src = "none"
        if sj then
            -- The rack/pump animation writes the node's LOCAL POSITION,
            -- which moves it in the PARENT's frame -- so the world
            -- direction of that travel is the PARENT's axis column, not
            -- the node's own (they only coincide when the node's local
            -- rotation is identity, which weapon slide/pump nodes are not
            -- guaranteed to have). Projecting on the node's own axis is
            -- the prime suspect for every "axis projection reads ~zero
            -- pull" failure in this system's history, this feature's
            -- first version included.
            local parent = sc(sj, "get_Parent")
            if parent then
                local pwm = sc(parent, "get_WorldMatrix")
                local c = pwm and ((bp.travel_axis == "y") and pwm[1] or pwm[2])
                if c and type(c.x) == "number" then
                    local len = math.sqrt(c.x * c.x + c.y * c.y + c.z * c.z)
                    if len > 1e-6 then
                        ax, ay, az = c.x / len, c.y / len, c.z / len
                        axis_src = "parent_wm"
                    end
                end
            end
            if not ax then
                local wm = read_anchor_world_matrix(sj, kind)
                if bp.travel_axis == "y" then
                    ax, ay, az = axis_y_from_world_matrix(wm)
                else
                    ax, ay, az = axis_z_from_world_matrix(wm)
                end
                if ax then axis_src = "own_wm" end
            end
            if not ax then
                local fwd = read_anchor_axis(sj, kind,
                    bp.travel_axis == "y" and "AxisY" or "AxisZ")
                if fwd then
                    local len = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z)
                    if len > 1e-6 then
                        ax, ay, az = fwd.x / len, fwd.y / len, fwd.z / len
                        axis_src = "own_axis"
                    end
                end
            end
        end
        if ax then
            ax, ay, az = ax * s_sign, ay * s_sign, az * s_sign
        elseif g.mo_init then
            -- Live axis briefly unreadable mid-gesture: keep the grab-time
            -- direction rather than dropping the pull.
            ax, ay, az = g.mo_dir_x, g.mo_dir_y, g.mo_dir_z
            axis_src = "held"
        else
            g.mo_status = "no axis (joint unresolved)"
            if g.mo_log_last == nil or (os.clock() - g.mo_log_last) > 0.25 then
                g.mo_log_last = os.clock()
                log.info(string.format("[motion_gesture] wp=%s NO AXIS kind=%s joint=%s",
                    tostring(wp_name), tostring(kind), tostring(sj ~= nil)))
            end
            return nil
        end

        local lp, lsrc = get_controller_game_world_pos("left")
        local rp, rsrc = get_controller_game_world_pos("right")
        if not lp or not rp then
            g.mo_status = lp and "no RIGHT controller pos" or "no LEFT controller pos"
            if g.mo_log_last == nil or (os.clock() - g.mo_log_last) > 0.25 then
                g.mo_log_last = os.clock()
                log.info(string.format("[motion_gesture] wp=%s %s",
                    tostring(wp_name), g.mo_status))
            end
            -- Tracking dropout mid-gesture: hold the last ratio rather
            -- than snapping the slide anywhere.
            return g.mo_init and (g.mo_ratio or 0.0) or nil
        end

        -- Self-diagnosing guard for the exact failure seen twice on
        -- 2026-08-17: a position source returning the SAME point for
        -- both hands makes the relative pull identically zero -- flag it
        -- loudly instead of silently measuring nothing.
        local hx, hy, hz = lp.x - rp.x, lp.y - rp.y, lp.z - rp.z
        -- Source X-ray, every 2s while the gesture polls: every candidate
        -- controller provider's values side by side, so ONE live test says
        -- which provider is lying (identical L/R, frozen, zero, etc.)
        -- instead of another blind reorder of the fallback chain.
        if g.mo_dump_last == nil or (os.clock() - g.mo_dump_last) > 2.0 then
            g.mo_dump_last = os.clock()
            local parts = {}
            pcall(function()
                local cs = vrmod and vrmod:get_controllers()
                if cs then
                    for i, c in ipairs(cs) do
                        local p = vrmod:get_position(c)
                        parts[#parts + 1] = string.format(
                            "vm[%d]=idx%s(%.3f,%.3f,%.3f)", i, tostring(c),
                            p and p.x or -99, p and p.y or -99, p and p.z or -99)
                    end
                end
            end)
            pcall(function()
                local mgr = sdk.get_managed_singleton("via.VRControllerManager")
                local list = mgr and mgr.controllers_list
                for i = 1, 2 do
                    local e = list and list[i]
                    local p = e and e.position
                    if p then
                        parts[#parts + 1] = string.format(
                            "sg[%d]=(%.3f,%.3f,%.3f)", i, p.x, p.y, p.z)
                    end
                end
            end)
            pcall(function()
                if get_vr_controller_world_pos then
                    local dl = get_vr_controller_world_pos("left")
                    local dr = get_vr_controller_world_pos("right")
                    if dl then parts[#parts + 1] = string.format(
                        "dp[L]=(%.3f,%.3f,%.3f)", dl.x, dl.y, dl.z) end
                    if dr then parts[#parts + 1] = string.format(
                        "dp[R]=(%.3f,%.3f,%.3f)", dr.x, dr.y, dr.z) end
                end
            end)
            log.info(string.format(
                "[motion_gesture] DUMP wp=%s L=%s R=%s lp=(%.3f,%.3f,%.3f) rp=(%.3f,%.3f,%.3f) dlen=%.4f %s",
                tostring(wp_name), tostring(lsrc), tostring(rsrc),
                lp.x, lp.y, lp.z, rp.x, rp.y, rp.z,
                math.sqrt(hx * hx + hy * hy + hz * hz),
                table.concat(parts, " ")))
        end
        if (hx * hx + hy * hy + hz * hz) < 1e-6 then
            g.mo_status = "hands read IDENTICAL (bad controller source)"
            if g.mo_log_last == nil or (os.clock() - g.mo_log_last) > 0.25 then
                g.mo_log_last = os.clock()
                log.info(string.format(
                    "[motion_gesture] wp=%s HANDS IDENTICAL lp=(%.3f,%.3f,%.3f)",
                    tostring(wp_name), lp.x, lp.y, lp.z))
            end
            return g.mo_init and (g.mo_ratio or 0.0) or nil
        end

        local s = hx * ax + hy * ay + hz * az
        if not g.mo_init then
            g.mo_dir_x, g.mo_dir_y, g.mo_dir_z = ax, ay, az
            g.mo_base_s = s
            g.mo_ratio = 0.0
            g.mo_init = true
            g.mo_status = "armed"
            log.info(string.format(
                "[motion_gesture] ARMED wp=%s axis_src=%s sign=%.0f dir=(%.2f,%.2f,%.2f) base_s=%.4f L=%s R=%s",
                tostring(wp_name), axis_src, s_sign, ax, ay, az, s,
                tostring(lsrc), tostring(rsrc)))
            return 0.0
        end
        g.mo_status = "armed"

        local pull_m = (s - g.mo_base_s) - (deadzone or 0.0)
        -- Required hand travel = the same tuned pull distance the LT/
        -- tracked paths use (meters), times the UI scale.
        local span = gesture_effective_pull_dist(g, wp_name) or 0.05
        span = span * (tonumber(scale) or 1.0)
        if span < 0.005 then span = 0.005 end

        local ratio = pull_m / span
        if ratio < 0.0 then ratio = 0.0 elseif ratio > 1.0 then ratio = 1.0 end
        -- Light EMA to absorb tracking jitter (runs 2x/frame at headset
        -- rate, so this converges in a few ms -- damping, not lag).
        local prev = g.mo_ratio or 0.0
        ratio = prev + (ratio - prev) * 0.4
        -- Snap the endpoints so the cycle's >= 1.0-1e-4 latch and
        -- <= 1e-4 completion thresholds are actually reachable through
        -- the EMA's asymptote.
        if ratio > 0.985 then ratio = 1.0 elseif ratio < 0.01 then ratio = 0.0 end
        g.mo_ratio = ratio
        if g.mo_log_last == nil or (os.clock() - g.mo_log_last) > 0.25 then
            g.mo_log_last = os.clock()
            log.info(string.format(
                "[motion_gesture] wp=%s src=%s pull_m=%.4f span=%.3f ratio=%.2f s=%.4f base=%.4f dlen=%.3f L=%s R=%s",
                tostring(wp_name), axis_src, pull_m, span, ratio, s, g.mo_base_s,
                math.sqrt(hx * hx + hy * hy + hz * hz),
                tostring(lsrc), tostring(rsrc)))
        end
        return ratio
    end

    function M.gesture_capture_grab_span(g, wp_name, ctx)
        local bp = get_slide_bind_pose(wp_name)
        local joint = ctx.get_joint and ctx.get_joint()
        local grab_field = ctx.grab_z_field or "grab_bind_z"
        local travel_axis = bp and bp.travel_axis or "z"
        if joint then
            local pos = sc(joint, "get_LocalPosition")
            if pos then
                if travel_axis == "y" and type(pos.y) == "number" then
                    g[grab_field] = pos.y
                elseif type(pos.z) == "number" then
                    g[grab_field] = pos.z
                elseif bp then
                    g[grab_field] = bp.parked_z
                end
            elseif bp then
                g[grab_field] = bp.parked_z
            end
        elseif bp then
            g[grab_field] = bp.parked_z
        end
        if ctx.axis_mode == "joint" and joint and bp then
            local kind = (ctx.get_anchor_kind and ctx.get_anchor_kind()) or "joint"
            g.pull_span_m = sample_joint_bind_span(joint, kind, bp)
            g.push_span_m = measure_joint_push_span_m(joint, kind, bp)
        elseif ctx.axis_mode == "dock" and wp_name then
            g.pull_span_m = measure_slide_pull_span_m(wp_name)
            g.push_span_m = measure_slide_push_span_m(wp_name)
        end
    end

    function M.gesture_prepare_pump_axis(g, wp_name, ctx)
        gesture_capture_pull_axis(g, wp_name, ctx)
        gesture_capture_play_pull_axis(g, wp_name, ctx)
        M.gesture_capture_grab_span(g, wp_name, ctx)
    end

    function M.gesture_begin(g, wp_name, ctx)
        if ctx.use_support_hand_start then
            local lh = rawget(_G, "__vr_lh_joint_pos")
            if lh and type(lh.x) == "number" then
                g.start_pos = Vector3f.new(lh.x, lh.y, lh.z)
            else
                local track_pos = select(1, get_track_pos_for_rack())
                if track_pos then
                    g.start_pos = Vector3f.new(track_pos.x, track_pos.y, track_pos.z)
                end
            end
        else
            local track_pos = select(1, get_track_pos_for_rack())
            if track_pos then
                g.start_pos = Vector3f.new(track_pos.x, track_pos.y, track_pos.z)
            end
        end
        g.start_play_off_x = nil
        g.start_play_off_y = nil
        g.start_play_off_z = nil
        local hmd_off = get_controller_hmd_offset()
        if hmd_off then
            g.start_play_off_x = hmd_off.x
            g.start_play_off_y = hmd_off.y
            g.start_play_off_z = hmd_off.z
        end
        g.pull_baseline = nil
        g.pull_start_signed = 0.0
        g.pull_dir_locked = false
        g.pull_increases_signed = true
        g.last_wid = wp_name
        gesture_reset_pull_smoothing(g)
        if ctx.signed_global then
            rawset(_G, ctx.signed_global, 0)
        end
        if not ctx.preserve_axis or not g.pull_axis_set then
            gesture_capture_pull_axis(g, wp_name, ctx)
            gesture_capture_play_pull_axis(g, wp_name, ctx)
        end
        if not ctx.preserve_axis or not g.pull_span_m then
            M.gesture_capture_grab_span(g, wp_name, ctx)
        end
        if not ctx.skip_dock and wp_name then
            local dock_world = select(1, get_hand_dock_pose(wp_name))
            local track_pos = g.start_pos
            if dock_world and track_pos then
                g.pull_baseline = compute_dock_relative_pull(dock_world, track_pos)
            end
        end
    end

    function M.gesture_update_pull(g, wp_name, ctx)
        if not g.active or not is_left_grip_pressed() or not wp_name then
            return nil, nil
        end
        local track_pos, track_src = get_track_pos_for_rack()
        if not track_pos then return nil, track_src end

        if g.last_wid ~= wp_name or not g.pull_axis_set then
            M.gesture_begin(g, wp_name, ctx)
        end
        if track_pos and not g.start_pos then
            if ctx.use_support_hand_start then
                local lh = rawget(_G, "__vr_lh_joint_pos")
                if lh and type(lh.x) == "number" then
                    g.start_pos = Vector3f.new(lh.x, lh.y, lh.z)
                else
                    g.start_pos = Vector3f.new(track_pos.x, track_pos.y, track_pos.z)
                end
            else
                g.start_pos = Vector3f.new(track_pos.x, track_pos.y, track_pos.z)
            end
            M.gesture_capture_grab_span(g, wp_name, ctx)
        end

        local pull_d = gesture_effective_pull_dist(g, wp_name)
        local push_d = gesture_effective_push_dist(g, wp_name)
        local signed_raw = gesture_compute_delta_pull(g, track_pos, wp_name, ctx)
        local signed = gesture_smooth_clamp(g, signed_raw, pull_d, push_d, ctx.signed_global)
        g.pull_now = signed
        return signed, track_src
    end

    function M.gesture_apply_bind(g, wp_name, ctx, set_joint_z_fn)
        if not wp_name or type(set_joint_z_fn) ~= "function" then return end
        local bp = get_slide_bind_pose(wp_name)
        local joint = ctx.get_joint and ctx.get_joint()
        if not bp or not joint then return end
        if not g.needs_pump and not g.needs_rack and not g.active then
            set_joint_z_fn(bp.rest_z, bp)
            return
        end

        local pull_d = gesture_effective_pull_dist(g, wp_name)
        local push_d = gesture_effective_push_dist(g, wp_name)
        local grab_field = ctx.grab_z_field or "grab_bind_z"
        local grab_z = g[grab_field] or bp.parked_z
        local slide_travel = bp.back_z - bp.parked_z
        local push_travel = bp.rest_z - bp.back_z
        local z = grab_z
        local signed = g.pull_now or 0.0

        if g.active and pull_d > 1e-5 then
            if g.pull_done and push_d > 1e-5 then
                local push_delta = gesture_get_push_delta(g, signed)
                local frac = math.min(push_delta / push_d, 1.0)
                z = bp.back_z + frac * push_travel
            else
                local hand_m = gesture_pull_magnitude(g, signed)
                local frac = math.min(hand_m / pull_d, 1.0)
                z = grab_z + frac * slide_travel
            end
        elseif g.needs_pump or g.needs_rack then
            z = bp.parked_z
        end
        set_joint_z_fn(z, bp)
    end

    function M.gesture_capture_pull_peak(g)
        local off = get_controller_hmd_offset()
        if off then
            g.peak_play_off_x = off.x
            g.peak_play_off_y = off.y
            g.peak_play_off_z = off.z
        end
    end

    function M.gesture_reset_pull_fields(g, signed_global)
        g.pull_now = 0.0
        g.pull_done = false
        g.pull_peak_signed = nil
        g.pull_start_signed = 0.0
        g.pull_increases_signed = true
        g.pull_dir_locked = false
        g.start_pos = nil
        g.peak_play_off_x = nil
        g.peak_play_off_y = nil
        g.peak_play_off_z = nil
        g.start_play_off_x = nil
        g.start_play_off_y = nil
        g.start_play_off_z = nil
        g.pull_play_ax = nil
        g.pull_play_ay = nil
        g.pull_play_az = nil
        gesture_reset_pull_smoothing(g)
        if signed_global then
            rawset(_G, signed_global, nil)
        end
    end

    M.gesture_get_track_pos = get_track_pos_for_rack
    M.gesture_get_bind_pose = get_slide_bind_pose
    M.gesture_get_pull_limits = get_pull_limits
    M.gesture_get_push_delta = gesture_get_push_delta
    M.gesture_get_deadzone = get_pull_deadzone
    M.gesture_get_pull_axis_sign = gesture_get_pull_axis_sign
    M.publish_slide_dock_ik_twist = publish_slide_dock_ik_twist
    M.set_bind_travel_local = joint_local_with_bind_travel
    M.gesture_effective_pull_dist = gesture_effective_pull_dist
    M.gesture_effective_push_dist = gesture_effective_push_dist

    _G.__vr_reload_slide_dock = {
        tick = M.tick,
        tick_hand_follow = M.tick_hand_follow,
        update_slide_rack = M.update_slide_rack,
        update_rack_pull = M.update_rack_pull,
        sync_rack_motion = M.sync_rack_motion,
        apply_slide_park = M.apply_slide_park,
        on_gesture_start = M.on_gesture_start,
        on_rack_released = M.on_rack_released,
        set_needs_rack = M.set_needs_rack,
        slide_rack_context_ok = slide_rack_context_ok,
        is_weapon_enabled = is_weapon_enabled,
        get_dock_dist = get_dock_dist,
        is_track_near_dock = is_track_near_dock,
        on_weapon_swap = M.on_weapon_swap,
        clear = clear_rack_state,
        gesture_begin = M.gesture_begin,
        gesture_update_pull = M.gesture_update_pull,
        gesture_apply_bind = M.gesture_apply_bind,
        gesture_reset_pull_fields = M.gesture_reset_pull_fields,
        gesture_capture_grab_span = M.gesture_capture_grab_span,
        gesture_get_bind_pose = M.gesture_get_bind_pose,
    }
end

return M
