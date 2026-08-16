-- Purely cosmetic left-hand proximity dock for hand-picked long weapons.
--
-- Snaps the rendered left hand onto the weapon's foregrip whenever the
-- weapon is equipped/drawn and the real left hand is near that point --
-- no RG, no LG, no aiming required -- and releases the moment the hand
-- moves away. It never lets the real hand move/steer the weapon: the dock
-- target is derived purely from the weapon's own muzzle joint (offset back
-- along the barrel axis), never from where the left hand actually is.
--
-- This does NOT touch the real slide-rack/pump-rack gesture's globals
-- (__vr_slide_dock_blend_factor / __vr_slide_hand_world_pos): that pipeline
-- resets those to 0/nil every single frame it isn't actively engaged, so
-- writing into them here would just get stomped. Instead this publishes its
-- own __vr_cosmetic_dock_* globals, and re2_vr_ik_extention.lua's
-- slide.get_dock_state() falls back to them only when the real gesture is
-- idle -- so the real gesture always wins on the weapons that have both
-- (W-870, MQ 11, LE 5).

if reframework:get_game_name() ~= "re2" then
    return {}
end

if not vrmod then
    return {}
end

local re2 = require("utility/RE2")

local CFG_PATH = "re2_vr/re2_vr_cosmetic_dock.json"

local CFG = {
    enabled = true,
    enter_dist_m = 0.10,
    exit_dist_m = 0.18,
    blend_speed = 2.0,
    grip_back_from_muzzle_m = 0.14,
    grip_right_offset_m = 0.0,
    grip_up_offset_m = 0.0,
}

-- Per-weapon overrides, keyed by weapon id string (e.g. "wp1000"). Each
-- falls back to the matching CFG default when a weapon has no entry yet.
-- Tuned live via the slider UI below and persisted to CFG_PATH -- no code
-- edits/relaunches needed per weapon.
local GRIP_BACK_BY_WP = {}
local GRIP_RIGHT_BY_WP = {}
local GRIP_UP_BY_WP = {}

local COSMETIC_DOCK_WEAPONS = {
    wp1000 = true, wp1100 = true, -- W-870
    wp4100 = true,                -- GM 79
    wp4400 = true, wp8400 = true, -- ATM-4 (+ unlimited)
    wp4600 = true,                -- Anti-Tank Rocket
    wp4700 = true, wp8700 = true, -- Minigun (+ unlimited)
    wp2000 = true,                -- MQ 11
    wp2200 = true,                -- LE 5
    wp4200 = true,                -- Chemical Flamethrower
    wp4300 = true,                -- Spark Shot
}

local function load_cfg()
    local data = json.load_file(CFG_PATH)
    if type(data) ~= "table" then return end
    for k, v in pairs(data) do
        if CFG[k] ~= nil and type(v) == type(CFG[k]) then
            CFG[k] = v
        end
    end
    if type(data.weapons) == "table" and #data.weapons > 0 then
        local t = {}
        for _, wp_id in ipairs(data.weapons) do
            if type(wp_id) == "string" and wp_id ~= "" then
                t[wp_id] = true
            end
        end
        COSMETIC_DOCK_WEAPONS = t
    end
    if type(data.grip_back_by_wp) == "table" then
        for wp_id, dist in pairs(data.grip_back_by_wp) do
            if type(wp_id) == "string" and type(dist) == "number" then
                GRIP_BACK_BY_WP[wp_id] = dist
            end
        end
    end
    if type(data.grip_right_by_wp) == "table" then
        for wp_id, dist in pairs(data.grip_right_by_wp) do
            if type(wp_id) == "string" and type(dist) == "number" then
                GRIP_RIGHT_BY_WP[wp_id] = dist
            end
        end
    end
    if type(data.grip_up_by_wp) == "table" then
        for wp_id, dist in pairs(data.grip_up_by_wp) do
            if type(wp_id) == "string" and type(dist) == "number" then
                GRIP_UP_BY_WP[wp_id] = dist
            end
        end
    end
end
pcall(load_cfg)

local function save_cfg()
    pcall(function()
        local out = {}
        for k, v in pairs(CFG) do out[k] = v end
        local wlist = {}
        for wp_id, _ in pairs(COSMETIC_DOCK_WEAPONS) do wlist[#wlist + 1] = wp_id end
        out.weapons = wlist
        out.grip_back_by_wp = GRIP_BACK_BY_WP
        out.grip_right_by_wp = GRIP_RIGHT_BY_WP
        out.grip_up_by_wp = GRIP_UP_BY_WP
        json.dump_file(CFG_PATH, out)
    end)
end

local via_murmur_hash_type = sdk.find_type_definition("via.murmur_hash")
local via_murmur_hash_calc32 = via_murmur_hash_type and via_murmur_hash_type:get_method("calc32") or nil
local vfx_muzzle1_hash = via_murmur_hash_calc32 and via_murmur_hash_calc32:call(nil, "vfx_muzzle1") or nil
local vfx_muzzle2_hash = via_murmur_hash_calc32 and via_murmur_hash_calc32:call(nil, "vfx_muzzle2") or nil

-- OpenXR hand offsets (first-person arm IK) -- same values used throughout
-- this mod's other VR scripts (re2_vr_ik_extention.lua, re2_vr_haptics.lua).
local FP_HAND_POS_OFFSET = {
    left = Vector3f.new(-0.052, 0.084, 0.02),
    right = Vector3f.new(0.052, 0.084, 0.02),
}

local function clampf(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function vec3_valid(p)
    return p ~= nil and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

local function vec3_dist(a, b)
    if not vec3_valid(a) or not vec3_valid(b) then return 1e9 end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function vec3_add(a, b)
    return Vector3f.new(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function quat_rotate_vec3(q, v)
    if q == nil or v == nil then return v end
    local ok, out = pcall(function() return q * v end)
    return ok and out or v
end

--- Raw controller / published-global fallback (matches re2_vr_haptics.lua's chain).
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

local function get_vr_controller_world_pos(hand)
    local controllers = nil
    pcall(function() controllers = vrmod:get_controllers() end)
    if not controllers then return get_hand_world_pos(hand) end
    local idx = (hand == "right") and controllers[2] or controllers[1]
    if idx == nil then return get_hand_world_pos(hand) end
    local ok, pos = pcall(function() return vrmod:get_position(idx) end)
    if ok and vec3_valid(pos) then return pos end
    return get_hand_world_pos(hand)
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

--- Approximate FirstPerson calculate_joint_pos_rot world target (camera-relative controller).
local function get_fp_style_hand_world_pos(hand)
    local cam = sdk.get_primary_camera()
    if not cam then return nil end
    local ok_wm, wm = pcall(function() return cam:call("get_WorldMatrix") end)
    if not ok_wm or not wm then return nil end

    local cam_pos = Vector3f.new(wm[3].x, wm[3].y, wm[3].z)
    local look_rot = get_camera_look_quat()
    if look_rot == nil then return nil end

    local ctrl_pos = get_vr_controller_world_pos(hand)
    if not vec3_valid(ctrl_pos) then return nil end

    local hmd_pos = nil
    pcall(function() hmd_pos = vrmod:get_position(0) end)
    if not vec3_valid(hmd_pos) then hmd_pos = cam_pos end

    local offset = Vector3f.new(ctrl_pos.x - hmd_pos.x, ctrl_pos.y - hmd_pos.y, ctrl_pos.z - hmd_pos.z)
    local hand_pos = vec3_add(cam_pos, quat_rotate_vec3(look_rot, offset))
    local fp_off = FP_HAND_POS_OFFSET[hand]
    if fp_off then
        hand_pos = vec3_add(hand_pos, quat_rotate_vec3(look_rot, fp_off))
    end
    return hand_pos
end

--- Weapon-mesh-relative anchor: the muzzle joint's position/forward, same
--- lookup re2_vr_crosshair.lua and re2_vr_melee.lua already use (MuzzleJoint
--- field, falling back to the vfx_muzzle1/vfx_muzzle2 hash on the weapon's
--- own Transform). Computed fresh every frame here rather than reusing
--- re2.last_muzzle_pos -- that global only refreshes while the native
--- reticle GUI element is actually drawn (i.e. only while aiming), which
--- would go stale exactly when this feature needs to keep working (idle
--- carry, running, no aim).
local function get_weapon_muzzle_pos_fwd()
    local weapon = re2.weapon
    if not weapon then return nil, nil, "no_weapon" end

    local muzzle_joint = nil
    local source = "none"
    local ok_mj, mj = pcall(function() return weapon:get_field("<MuzzleJoint>k__BackingField") end)
    if ok_mj and mj then
        local ok_p, p = pcall(function() return mj:get_field("_Parent") end)
        if ok_p and p then
            muzzle_joint = p
            source = "MuzzleJoint"
        end
    end

    if muzzle_joint == nil then
        local go = re2.weapon_gameobject
        if go then
            local ok_tf, transform = pcall(function() return go:call("get_Transform") end)
            if ok_tf and transform then
                if vfx_muzzle1_hash then
                    local ok_j, j = pcall(function() return transform:call("getJointByHash", vfx_muzzle1_hash) end)
                    if ok_j and j then muzzle_joint = j; source = "vfx_muzzle1" end
                end
                if muzzle_joint == nil and vfx_muzzle2_hash then
                    local ok_j2, j2 = pcall(function() return transform:call("getJointByHash", vfx_muzzle2_hash) end)
                    if ok_j2 and j2 then muzzle_joint = j2; source = "vfx_muzzle2" end
                end
            end
        end
    end

    if muzzle_joint == nil then return nil, nil, nil, nil, "not_found" end
    local ok_pos, pos = pcall(function() return muzzle_joint:call("get_Position") end)
    local ok_fwd, fwd = pcall(function() return muzzle_joint:call("get_AxisZ") end)
    local ok_right, right = pcall(function() return muzzle_joint:call("get_AxisX") end)
    local ok_up, up = pcall(function() return muzzle_joint:call("get_AxisY") end)
    if not ok_pos or not vec3_valid(pos) or not ok_fwd or not vec3_valid(fwd) then
        return nil, nil, nil, nil, source .. "_bad_data"
    end
    if not ok_right or not vec3_valid(right) then right = nil end
    if not ok_up or not vec3_valid(up) then up = nil end
    return pos, fwd, right, up, source
end

local function get_grip_back_for_weapon(wp_id)
    if wp_id and type(GRIP_BACK_BY_WP[wp_id]) == "number" then
        return GRIP_BACK_BY_WP[wp_id]
    end
    return clampf(tonumber(CFG.grip_back_from_muzzle_m) or 0.14, -0.30, 1.0)
end

local function get_grip_right_for_weapon(wp_id)
    if wp_id and type(GRIP_RIGHT_BY_WP[wp_id]) == "number" then
        return GRIP_RIGHT_BY_WP[wp_id]
    end
    return clampf(tonumber(CFG.grip_right_offset_m) or 0.0, -0.20, 0.20)
end

local function get_grip_up_for_weapon(wp_id)
    if wp_id and type(GRIP_UP_BY_WP[wp_id]) == "number" then
        return GRIP_UP_BY_WP[wp_id]
    end
    return clampf(tonumber(CFG.grip_up_offset_m) or 0.0, -0.20, 0.20)
end

--- Foregrip anchor = a fixed distance back from the muzzle along the
--- barrel's own axis, plus optional lateral/vertical nudges along the
--- muzzle joint's own right/up axes. Purely weapon-mesh-relative --
--- independent of the left hand's real position, which is what makes it
--- safe to use as a dock target without letting the player steer the
--- weapon.
local function get_weapon_support_grip_world_pos(wp_id)
    local muzzle_pos, muzzle_fwd, muzzle_right, muzzle_up = get_weapon_muzzle_pos_fwd()
    if not vec3_valid(muzzle_pos) or not vec3_valid(muzzle_fwd) then return nil end
    local back = get_grip_back_for_weapon(wp_id)
    local anchor = Vector3f.new(
        muzzle_pos.x - muzzle_fwd.x * back,
        muzzle_pos.y - muzzle_fwd.y * back,
        muzzle_pos.z - muzzle_fwd.z * back)

    local right_off = get_grip_right_for_weapon(wp_id)
    if right_off ~= 0.0 and vec3_valid(muzzle_right) then
        anchor = Vector3f.new(
            anchor.x + muzzle_right.x * right_off,
            anchor.y + muzzle_right.y * right_off,
            anchor.z + muzzle_right.z * right_off)
    end

    local up_off = get_grip_up_for_weapon(wp_id)
    if up_off ~= 0.0 and vec3_valid(muzzle_up) then
        anchor = Vector3f.new(
            anchor.x + muzzle_up.x * up_off,
            anchor.y + muzzle_up.y * up_off,
            anchor.z + muzzle_up.z * up_off)
    end

    return anchor
end

local function get_equipped_weapon_id()
    local go = re2.weapon_gameobject
    if not go then return nil end
    local ok_name, name = pcall(function() return go:call("get_Name") end)
    if ok_name and type(name) == "string" then return name end
    return nil
end

local function vr_active()
    if not CFG.enabled then return false end
    if firstpersonmod ~= nil and type(firstpersonmod.will_be_used) == "function" then
        local ok_fp, fp_active = pcall(function() return firstpersonmod:will_be_used() end)
        if not ok_fp or not fp_active then return false end
    end
    local ok_hmd, hmd = pcall(function() return vrmod:is_hmd_active() end)
    local ok_ctrl, ctrl = pcall(function() return vrmod:is_using_controllers() end)
    return ok_hmd and hmd and ok_ctrl and ctrl
end

--- Real gesture systems (slide-rack, pump-rack, mag/shell-in-hand, holster
--- zones) always take priority -- this dock backs off whenever any of them
--- are in play so it can never fight a hand-won, already-debugged feature.
local function blocked_by_other_system()
    local real_blend = tonumber(rawget(_G, "__vr_slide_dock_blend_factor")) or 0
    if real_blend > 0.001 then return true end
    if rawget(_G, "__vr_mag_in_left_hand") == true then return true end
    if rawget(_G, "__vr_shell_in_left_hand") == true then return true end
    if rawget(_G, "__vr_in_holster_zone") == true then return true end
    if rawget(_G, "__vr_in_head_flashlight_zone") == true then return true end
    if rawget(_G, "__vr_block_left_support_in_mag_holster_zone") == true then return true end
    return false
end

local dock = { blend = 0.0, docked = false, last_logged = false }

local function get_delta_time()
    local dt = 1.0 / 60.0
    if re.get_delta_time then
        local ok, d = pcall(function() return re.get_delta_time() end)
        if ok and type(d) == "number" and d > 0 then dt = d end
    end
    return dt
end

local function smoothstep01(x)
    if x <= 0.0 then return 0.0 end
    if x >= 1.0 then return 1.0 end
    return x * x * (3.0 - 2.0 * x)
end

local function tick_dock_blend(want_on)
    local target = want_on and 1.0 or 0.0
    local dt = get_delta_time()
    local speed = tonumber(CFG.blend_speed) or 2.0
    if dock.blend < target then
        dock.blend = math.min(dock.blend + speed * dt, target)
    elseif dock.blend > target then
        dock.blend = math.max(dock.blend - speed * dt, target)
    end
    return smoothstep01(dock.blend)
end

local function publish(eased, anchor)
    rawset(_G, "__vr_cosmetic_dock_blend_factor", eased)
    if eased > 0.001 and vec3_valid(anchor) then
        rawset(_G, "__vr_cosmetic_dock_hand_world_pos", Vector3f.new(anchor.x, anchor.y, anchor.z))
    else
        rawset(_G, "__vr_cosmetic_dock_hand_world_pos", nil)
    end
end

local function log_transition(wp_id, dist)
    if dock.docked == dock.last_logged then return end
    dock.last_logged = dock.docked
    log.info(string.format("[re2_vr_cosmetic_dock] %s (wp=%s dist=%.3f)",
        dock.docked and "docked" or "undocked", tostring(wp_id), dist or -1.0))
end

re.on_frame(function()
    if not vr_active() or blocked_by_other_system() then
        local eased = tick_dock_blend(false)
        publish(eased, nil)
        if eased <= 0.001 and dock.docked then
            dock.docked = false
            log_transition(nil, nil)
        end
        return
    end

    local wp_id = get_equipped_weapon_id()
    if not wp_id or not COSMETIC_DOCK_WEAPONS[wp_id] then
        local eased = tick_dock_blend(false)
        publish(eased, nil)
        if eased <= 0.001 and dock.docked then
            dock.docked = false
            log_transition(wp_id, nil)
        end
        return
    end

    local anchor = get_weapon_support_grip_world_pos(wp_id)
    local lh = get_fp_style_hand_world_pos("left") or get_hand_world_pos("left")
    if not vec3_valid(anchor) or not vec3_valid(lh) then
        local eased = tick_dock_blend(false)
        publish(eased, nil)
        return
    end

    local d = vec3_dist(lh, anchor)

    local enter_d = clampf(tonumber(CFG.enter_dist_m) or 0.06, 0.01, 0.30)
    local exit_d = clampf(tonumber(CFG.exit_dist_m) or 0.11, enter_d, 0.40)

    if dock.docked then
        if d > exit_d then dock.docked = false end
    else
        if d <= enter_d then dock.docked = true end
    end
    log_transition(wp_id, d)

    local eased = tick_dock_blend(dock.docked)
    publish(eased, anchor)
end)

--- Live tuning: adjust the muzzle-back distance per equipped weapon without
--- code edits or relaunches. Shows up under REFramework's "Script Generated
--- UI" section for this script. Changes save to CFG_PATH immediately.
re.on_draw_ui(function()
    local wp_id = get_equipped_weapon_id()
    imgui.text("Cosmetic dock -- equipped: " .. tostring(wp_id))

    if wp_id and COSMETIC_DOCK_WEAPONS[wp_id] then
        local cur = get_grip_back_for_weapon(wp_id)
        local changed, new_val = imgui.slider_float(
            "Grip back from muzzle (m) [" .. wp_id .. "]", cur, -0.30, 0.60, "%.3f")
        if changed then
            GRIP_BACK_BY_WP[wp_id] = new_val
            save_cfg()
        end

        local cur_r = get_grip_right_for_weapon(wp_id)
        local changed_r, new_r = imgui.slider_float(
            "Grip left/right (m) [" .. wp_id .. "]", cur_r, -0.20, 0.20, "%.3f")
        if changed_r then
            GRIP_RIGHT_BY_WP[wp_id] = new_r
            save_cfg()
        end

        local cur_u = get_grip_up_for_weapon(wp_id)
        local changed_u, new_u = imgui.slider_float(
            "Grip up/down (m) [" .. wp_id .. "]", cur_u, -0.20, 0.20, "%.3f")
        if changed_u then
            GRIP_UP_BY_WP[wp_id] = new_u
            save_cfg()
        end
    else
        imgui.text("(not one of the picked weapons)")
    end

    local changed_def, new_def = imgui.slider_float(
        "Default grip back (m)", tonumber(CFG.grip_back_from_muzzle_m) or 0.14, -0.30, 0.60, "%.3f")
    if changed_def then
        CFG.grip_back_from_muzzle_m = new_def
        save_cfg()
    end

    local changed_def_r, new_def_r = imgui.slider_float(
        "Default left/right (m)", tonumber(CFG.grip_right_offset_m) or 0.0, -0.20, 0.20, "%.3f")
    if changed_def_r then
        CFG.grip_right_offset_m = new_def_r
        save_cfg()
    end

    local changed_def_u, new_def_u = imgui.slider_float(
        "Default up/down (m)", tonumber(CFG.grip_up_offset_m) or 0.0, -0.20, 0.20, "%.3f")
    if changed_def_u then
        CFG.grip_up_offset_m = new_def_u
        save_cfg()
    end

    local changed_en, new_en = imgui.slider_float(
        "Enter distance (m)", tonumber(CFG.enter_dist_m) or 0.06, 0.02, 0.20, "%.3f")
    if changed_en then
        CFG.enter_dist_m = new_en
        save_cfg()
    end

    local changed_ex, new_ex = imgui.slider_float(
        "Exit distance (m)", tonumber(CFG.exit_dist_m) or 0.11, 0.03, 0.30, "%.3f")
    if changed_ex then
        CFG.exit_dist_m = new_ex
        save_cfg()
    end

    if wp_id and COSMETIC_DOCK_WEAPONS[wp_id] then
        local mpos, mfwd, _, _, msrc = get_weapon_muzzle_pos_fwd()
        imgui.text("muzzle source: " .. tostring(msrc))
        if vec3_valid(mpos) then
            imgui.text(string.format("muzzle pos: %.3f, %.3f, %.3f", mpos.x, mpos.y, mpos.z))
        else
            imgui.text("muzzle pos: invalid")
        end
        if vec3_valid(mfwd) then
            imgui.text(string.format("muzzle fwd: %.3f, %.3f, %.3f", mfwd.x, mfwd.y, mfwd.z))
        else
            imgui.text("muzzle fwd: invalid")
        end
        local anchor = get_weapon_support_grip_world_pos(wp_id)
        if vec3_valid(anchor) then
            imgui.text(string.format("anchor: %.3f, %.3f, %.3f", anchor.x, anchor.y, anchor.z))
        else
            imgui.text("anchor: invalid")
        end
        local lh = get_fp_style_hand_world_pos("left") or get_hand_world_pos("left")
        if vec3_valid(lh) then
            imgui.text(string.format("left hand: %.3f, %.3f, %.3f", lh.x, lh.y, lh.z))
        else
            imgui.text("left hand: invalid")
        end
        local player = re2.get_localplayer()
        if player then
            local ok_tf, ptf = pcall(function() return player:call("get_Transform") end)
            local ok_p, ppos = false, nil
            if ok_tf and ptf then
                ok_p, ppos = pcall(function() return ptf:call("get_Position") end)
            end
            if ok_p and vec3_valid(ppos) then
                imgui.text(string.format("player pos: %.3f, %.3f, %.3f", ppos.x, ppos.y, ppos.z))
            end
        end
        if vec3_valid(anchor) and vec3_valid(lh) then
            imgui.text(string.format("distance: %.3f", vec3_dist(lh, anchor)))
        end
        imgui.text("docked: " .. tostring(dock.docked) .. "  blend: " .. string.format("%.2f", dock.blend))
    end
end)

log.info("[re2_vr_cosmetic_dock] Started. Cosmetic proximity dock active for "
    .. tostring((function() local n = 0 for _ in pairs(COSMETIC_DOCK_WEAPONS) do n = n + 1 end return n end)())
    .. " weapon ids.")
