-- Purely cosmetic left-hand dock for hand-picked long weapons.
--
-- Snaps the rendered left hand onto the weapon's foregrip while BOTH LG and
-- RG are held (two-handing), and releases the instant either is let go. It
-- never lets the real hand move/steer the weapon: the dock target is
-- derived purely from the weapon's own muzzle joint (offset back along the
-- barrel axis), never from where the left hand actually is.
--
-- 2026-08-11: switched from hand-proximity triggering to this LG+RG gate,
-- after live VR testing found proximity unreliable -- inconsistent snap
-- timing, apparent dependence on gaze/camera-recenter, unreliable release
-- (sometimes needing an extreme pose, sometimes releasing on its own), and
-- a real leak where RG-held-alone (no deliberate grab) could still nudge
-- the rendered hand if it happened to be near the anchor. A hand-tracked
-- distance check can only ever measure proximity, never intent -- the same
-- reason this mod's actual weapon gestures (pump-action, slide-rack) were
-- long since converted from tracked-distance to discrete trigger presses.
-- This dock now follows the same proven pattern instead of being the one
-- proximity-based holdout.
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
local vr_char = require("utility/RE2Character")
local vrc_manager = require("vr/VRControllerManager")

local CFG_PATH = "re2_vr/re2_vr_cosmetic_dock.json"

local CFG = {
    enabled = true,
    blend_speed = 2.0,
    grip_back_from_muzzle_m = 0.14,
    grip_right_offset_m = 0.0,
    grip_up_offset_m = 0.0,
    grip_rot_pitch_deg = 0.0,
    grip_rot_yaw_deg = 0.0,
    grip_rot_roll_deg = 0.0,
}

-- Per-weapon overrides, keyed by weapon id string (e.g. "wp1000"). Each
-- falls back to the matching CFG default when a weapon has no entry yet.
-- Legacy/shared tier -- kept as the fallback for any character that doesn't
-- have its own per-character override yet (see GRIP_*_BY_CHAR_WP below).
local GRIP_BACK_BY_WP = {}
local GRIP_RIGHT_BY_WP = {}
local GRIP_UP_BY_WP = {}
local GRIP_ROT_PITCH_BY_WP = {}
local GRIP_ROT_YAW_BY_WP = {}
local GRIP_ROT_ROLL_BY_WP = {}

-- Per-character-per-weapon overrides: [profile_key][wp_id] = value, profile_key
-- from utility/RE2Character.lua (leon/claire/ada/hunk/tofu/...), same lookup
-- re2_vr_holster.lua already uses. Checked first; falls back to the weapon-only
-- tier above, then to the CFG default. This is what makes the grip independent
-- per character instead of shared across whoever's holding the weapon --
-- different characters' rigs (arm length, hand size) can want a different fit
-- on the exact same gun. Tuned live via the slider UI below (always writes into
-- the current character's own slot) and persisted to CFG_PATH.
local GRIP_BACK_BY_CHAR_WP = {}
local GRIP_RIGHT_BY_CHAR_WP = {}
local GRIP_UP_BY_CHAR_WP = {}
local GRIP_ROT_PITCH_BY_CHAR_WP = {}
local GRIP_ROT_YAW_BY_CHAR_WP = {}
local GRIP_ROT_ROLL_BY_CHAR_WP = {}

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
    if type(data.grip_rot_pitch_by_wp) == "table" then
        for wp_id, deg in pairs(data.grip_rot_pitch_by_wp) do
            if type(wp_id) == "string" and type(deg) == "number" then
                GRIP_ROT_PITCH_BY_WP[wp_id] = deg
            end
        end
    end
    if type(data.grip_rot_yaw_by_wp) == "table" then
        for wp_id, deg in pairs(data.grip_rot_yaw_by_wp) do
            if type(wp_id) == "string" and type(deg) == "number" then
                GRIP_ROT_YAW_BY_WP[wp_id] = deg
            end
        end
    end
    if type(data.grip_rot_roll_by_wp) == "table" then
        for wp_id, deg in pairs(data.grip_rot_roll_by_wp) do
            if type(wp_id) == "string" and type(deg) == "number" then
                GRIP_ROT_ROLL_BY_WP[wp_id] = deg
            end
        end
    end

    local function load_char_wp(src_key, dest)
        local src = data[src_key]
        if type(src) ~= "table" then return end
        for profile, per_wp in pairs(src) do
            if type(profile) == "string" and type(per_wp) == "table" then
                dest[profile] = dest[profile] or {}
                for wp_id, val in pairs(per_wp) do
                    if type(wp_id) == "string" and type(val) == "number" then
                        dest[profile][wp_id] = val
                    end
                end
            end
        end
    end
    load_char_wp("grip_back_by_char_wp", GRIP_BACK_BY_CHAR_WP)
    load_char_wp("grip_right_by_char_wp", GRIP_RIGHT_BY_CHAR_WP)
    load_char_wp("grip_up_by_char_wp", GRIP_UP_BY_CHAR_WP)
    load_char_wp("grip_rot_pitch_by_char_wp", GRIP_ROT_PITCH_BY_CHAR_WP)
    load_char_wp("grip_rot_yaw_by_char_wp", GRIP_ROT_YAW_BY_CHAR_WP)
    load_char_wp("grip_rot_roll_by_char_wp", GRIP_ROT_ROLL_BY_CHAR_WP)
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
        out.grip_rot_pitch_by_wp = GRIP_ROT_PITCH_BY_WP
        out.grip_rot_yaw_by_wp = GRIP_ROT_YAW_BY_WP
        out.grip_rot_roll_by_wp = GRIP_ROT_ROLL_BY_WP
        out.grip_back_by_char_wp = GRIP_BACK_BY_CHAR_WP
        out.grip_right_by_char_wp = GRIP_RIGHT_BY_CHAR_WP
        out.grip_up_by_char_wp = GRIP_UP_BY_CHAR_WP
        out.grip_rot_pitch_by_char_wp = GRIP_ROT_PITCH_BY_CHAR_WP
        out.grip_rot_yaw_by_char_wp = GRIP_ROT_YAW_BY_CHAR_WP
        out.grip_rot_roll_by_char_wp = GRIP_ROT_ROLL_BY_CHAR_WP
        json.dump_file(CFG_PATH, out)
    end)
end

local via_murmur_hash_type = sdk.find_type_definition("via.murmur_hash")
local via_murmur_hash_calc32 = via_murmur_hash_type and via_murmur_hash_type:get_method("calc32") or nil
local vfx_muzzle1_hash = via_murmur_hash_calc32 and via_murmur_hash_calc32:call(nil, "vfx_muzzle1") or nil
local vfx_muzzle2_hash = via_murmur_hash_calc32 and via_murmur_hash_calc32:call(nil, "vfx_muzzle2") or nil

local function clampf(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function vec3_valid(p)
    return p ~= nil and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

local function deg2rad(d) return (d or 0.0) * math.pi / 180.0 end

--- Same technique re2_vr_holster.lua already uses (vrc_manager first, raw
--- vrmod action-check as fallback) -- the trigger condition for this dock,
--- replacing the old hand-proximity check (see file header for why).
local function is_left_grip_pressed()
    if not vrmod then return false end
    if vrc_manager:has_controllers() then
        local lc = vrc_manager.controllers_list[1]
        if lc then
            return lc:is_action_active(vrc_manager.Actions.GRIP) == true
        end
    end
    local ok_lj, lj = pcall(function() return vrmod:get_left_joystick() end)
    if not ok_lj or not lj then return false end
    local ok_a, action = pcall(function() return vrmod:get_action_grip() end)
    if not ok_a or not action then return false end
    local ok_v, v = pcall(function() return vrmod:is_action_active(action, lj) end)
    return ok_v and v == true
end

local function is_right_grip_pressed()
    if not vrmod then return false end
    if vrc_manager:has_controllers() then
        local rc = vrc_manager.controllers_list[2]
        if rc then
            return rc:is_action_active(vrc_manager.Actions.GRIP) == true
        end
    end
    local ok_rj, rj = pcall(function() return vrmod:get_right_joystick() end)
    if not ok_rj or not rj then return false end
    local ok_a, action = pcall(function() return vrmod:get_action_grip() end)
    if not ok_a or not action then return false end
    local ok_v, v = pcall(function() return vrmod:is_action_active(action, rj) end)
    return ok_v and v == true
end

--- Same technique already proven for the real slide-dock hand rotation
--- (re2_vr_reload_ext_2.lua) -- a per-weapon Euler offset applied on top of
--- the anchor's own base rotation, tuned live via sliders.
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
    local ok_rot, rot = pcall(function() return muzzle_joint:call("get_Rotation") end)
    if not ok_rot then rot = nil end
    return pos, fwd, right, up, source, rot
end

--- Current character profile key (leon/claire/ada/...), same lookup
--- re2_vr_holster.lua already uses. Cheap enough to call every frame.
local function get_active_profile()
    local ok, profile = pcall(function() return vr_char.get_active_profile_key() end)
    return (ok and type(profile) == "string") and profile or nil
end

--- Shared 3-tier resolver for all 6 grip axes: per-character-per-weapon
--- override, falling back to the weapon-only override, falling back to the
--- global CFG default.
local function resolve_grip_value(char_wp_tbl, wp_tbl, cfg_default, wp_id, profile, lo, hi)
    if wp_id and profile and char_wp_tbl[profile] and type(char_wp_tbl[profile][wp_id]) == "number" then
        return clampf(char_wp_tbl[profile][wp_id], lo, hi)
    end
    if wp_id and type(wp_tbl[wp_id]) == "number" then
        return clampf(wp_tbl[wp_id], lo, hi)
    end
    return clampf(tonumber(cfg_default) or 0.0, lo, hi)
end

local function get_grip_back_for_weapon(wp_id, profile)
    return resolve_grip_value(GRIP_BACK_BY_CHAR_WP, GRIP_BACK_BY_WP, CFG.grip_back_from_muzzle_m, wp_id, profile, -0.30, 1.0)
end

local function get_grip_right_for_weapon(wp_id, profile)
    return resolve_grip_value(GRIP_RIGHT_BY_CHAR_WP, GRIP_RIGHT_BY_WP, CFG.grip_right_offset_m, wp_id, profile, -0.20, 0.20)
end

local function get_grip_up_for_weapon(wp_id, profile)
    return resolve_grip_value(GRIP_UP_BY_CHAR_WP, GRIP_UP_BY_WP, CFG.grip_up_offset_m, wp_id, profile, -0.20, 0.20)
end

local function get_grip_rot_pitch_for_weapon(wp_id, profile)
    return resolve_grip_value(GRIP_ROT_PITCH_BY_CHAR_WP, GRIP_ROT_PITCH_BY_WP, CFG.grip_rot_pitch_deg, wp_id, profile, -180.0, 180.0)
end

local function get_grip_rot_yaw_for_weapon(wp_id, profile)
    return resolve_grip_value(GRIP_ROT_YAW_BY_CHAR_WP, GRIP_ROT_YAW_BY_WP, CFG.grip_rot_yaw_deg, wp_id, profile, -180.0, 180.0)
end

local function get_grip_rot_roll_for_weapon(wp_id, profile)
    return resolve_grip_value(GRIP_ROT_ROLL_BY_CHAR_WP, GRIP_ROT_ROLL_BY_WP, CFG.grip_rot_roll_deg, wp_id, profile, -180.0, 180.0)
end

--- Rotation to freeze the hand at while docked: the muzzle joint's own base
--- rotation (so it stays weapon-relative, same as the position anchor) with
--- an optional per-weapon pitch/yaw/roll offset on top, tuned live via
--- sliders -- same technique as the real slide-dock hand rotation.
local function get_weapon_support_grip_world_rot(wp_id, profile, muzzle_rot)
    if not muzzle_rot then return nil end
    local pitch = get_grip_rot_pitch_for_weapon(wp_id, profile)
    local yaw = get_grip_rot_yaw_for_weapon(wp_id, profile)
    local roll = get_grip_rot_roll_for_weapon(wp_id, profile)
    if pitch == 0.0 and yaw == 0.0 and roll == 0.0 then return muzzle_rot end
    local off_q = quat_from_euler_deg(pitch, yaw, roll)
    if not off_q then return muzzle_rot end
    return quat_mul(muzzle_rot, off_q)
end

--- Foregrip anchor = a fixed distance back from the muzzle along the
--- barrel's own axis, plus optional lateral/vertical nudges along the
--- muzzle joint's own right/up axes. Purely weapon-mesh-relative --
--- independent of the left hand's real position, which is what makes it
--- safe to use as a dock target without letting the player steer the
--- weapon. Also returns a locked rotation (see get_weapon_support_grip_world_rot)
--- so the hand's orientation freezes too, not just its position. `profile`
--- (from get_active_profile()) selects the per-character override tier.
local function get_weapon_support_grip_world_pos(wp_id, profile)
    local muzzle_pos, muzzle_fwd, muzzle_right, muzzle_up, _, muzzle_rot = get_weapon_muzzle_pos_fwd()
    if not vec3_valid(muzzle_pos) or not vec3_valid(muzzle_fwd) then return nil end
    local back = get_grip_back_for_weapon(wp_id, profile)
    local anchor = Vector3f.new(
        muzzle_pos.x - muzzle_fwd.x * back,
        muzzle_pos.y - muzzle_fwd.y * back,
        muzzle_pos.z - muzzle_fwd.z * back)

    local right_off = get_grip_right_for_weapon(wp_id, profile)
    if right_off ~= 0.0 and vec3_valid(muzzle_right) then
        anchor = Vector3f.new(
            anchor.x + muzzle_right.x * right_off,
            anchor.y + muzzle_right.y * right_off,
            anchor.z + muzzle_right.z * right_off)
    end

    local up_off = get_grip_up_for_weapon(wp_id, profile)
    if up_off ~= 0.0 and vec3_valid(muzzle_up) then
        anchor = Vector3f.new(
            anchor.x + muzzle_up.x * up_off,
            anchor.y + muzzle_up.y * up_off,
            anchor.z + muzzle_up.z * up_off)
    end

    return anchor, get_weapon_support_grip_world_rot(wp_id, profile, muzzle_rot)
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

local dock = { blend = 0.0, active = false }

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

local function publish(eased, anchor, rot)
    rawset(_G, "__vr_cosmetic_dock_blend_factor", eased)
    if eased > 0.001 and vec3_valid(anchor) then
        rawset(_G, "__vr_cosmetic_dock_hand_world_pos", Vector3f.new(anchor.x, anchor.y, anchor.z))
        rawset(_G, "__vr_cosmetic_dock_hand_world_rot", rot)
    else
        rawset(_G, "__vr_cosmetic_dock_hand_world_pos", nil)
        rawset(_G, "__vr_cosmetic_dock_hand_world_rot", nil)
    end
end

local function log_transition(wp_id, want_on)
    if dock.active == want_on then return end
    dock.active = want_on
    log.info(string.format("[re2_vr_cosmetic_dock] %s (wp=%s)",
        want_on and "engaged" or "released", tostring(wp_id)))
end

re.on_frame(function()
    if not vr_active() or blocked_by_other_system() then
        local eased = tick_dock_blend(false)
        publish(eased, nil)
        log_transition(nil, false)
        return
    end

    local wp_id = get_equipped_weapon_id()
    if not wp_id or not COSMETIC_DOCK_WEAPONS[wp_id] then
        local eased = tick_dock_blend(false)
        publish(eased, nil)
        log_transition(wp_id, false)
        return
    end

    -- Deliberate two-handing gesture (LG + RG both held), not hand proximity
    -- -- see file header for why. Nothing here can move the hand at all
    -- unless BOTH are held, closing the old "gun nudges a little with just
    -- RG held" leak.
    local want_on = is_left_grip_pressed() and is_right_grip_pressed()
    log_transition(wp_id, want_on)

    local eased = tick_dock_blend(want_on)
    if eased <= 0.001 then
        publish(eased, nil)
        return
    end

    local anchor, anchor_rot = get_weapon_support_grip_world_pos(wp_id, get_active_profile())
    publish(eased, anchor, anchor_rot)
end)

--- Writes into this character's own slot for one grip axis, creating the
--- per-character sub-table on first use. Live-tuning always writes here
--- (never the legacy weapon-only tier) so each character's fit stays
--- independent once tuned -- the weapon-only tier remains untouched as the
--- fallback for any character that hasn't been tuned yet.
local function set_char_wp_value(tbl, profile, wp_id, val)
    tbl[profile] = tbl[profile] or {}
    tbl[profile][wp_id] = val
end

--- Live tuning: adjust the grip position/rotation per equipped weapon AND
--- per current character, without code edits or relaunches. Shows up under
--- REFramework's "Script Generated UI" section for this script. Changes
--- save to CFG_PATH immediately.
re.on_draw_ui(function()
    local wp_id = get_equipped_weapon_id()
    local profile = get_active_profile()
    imgui.text("Cosmetic dock -- equipped: " .. tostring(wp_id) .. "  character: " .. tostring(profile))

    if wp_id and profile and COSMETIC_DOCK_WEAPONS[wp_id] then
        local cur = get_grip_back_for_weapon(wp_id, profile)
        local changed, new_val = imgui.slider_float(
            "Grip back from muzzle (m) [" .. wp_id .. " / " .. profile .. "]", cur, -0.30, 0.60, "%.3f")
        if changed then
            set_char_wp_value(GRIP_BACK_BY_CHAR_WP, profile, wp_id, new_val)
            save_cfg()
        end

        local cur_r = get_grip_right_for_weapon(wp_id, profile)
        local changed_r, new_r = imgui.slider_float(
            "Grip left/right (m) [" .. wp_id .. " / " .. profile .. "]", cur_r, -0.20, 0.20, "%.3f")
        if changed_r then
            set_char_wp_value(GRIP_RIGHT_BY_CHAR_WP, profile, wp_id, new_r)
            save_cfg()
        end

        local cur_u = get_grip_up_for_weapon(wp_id, profile)
        local changed_u, new_u = imgui.slider_float(
            "Grip up/down (m) [" .. wp_id .. " / " .. profile .. "]", cur_u, -0.20, 0.20, "%.3f")
        if changed_u then
            set_char_wp_value(GRIP_UP_BY_CHAR_WP, profile, wp_id, new_u)
            save_cfg()
        end

        local cur_p = get_grip_rot_pitch_for_weapon(wp_id, profile)
        local changed_p, new_p = imgui.slider_float(
            "Grip pitch (deg) [" .. wp_id .. " / " .. profile .. "]", cur_p, -180.0, 180.0, "%.1f")
        if changed_p then
            set_char_wp_value(GRIP_ROT_PITCH_BY_CHAR_WP, profile, wp_id, new_p)
            save_cfg()
        end

        local cur_y = get_grip_rot_yaw_for_weapon(wp_id, profile)
        local changed_y, new_y = imgui.slider_float(
            "Grip yaw (deg) [" .. wp_id .. " / " .. profile .. "]", cur_y, -180.0, 180.0, "%.1f")
        if changed_y then
            set_char_wp_value(GRIP_ROT_YAW_BY_CHAR_WP, profile, wp_id, new_y)
            save_cfg()
        end

        local cur_ro = get_grip_rot_roll_for_weapon(wp_id, profile)
        local changed_ro, new_ro = imgui.slider_float(
            "Grip roll (deg) [" .. wp_id .. " / " .. profile .. "]", cur_ro, -180.0, 180.0, "%.1f")
        if changed_ro then
            set_char_wp_value(GRIP_ROT_ROLL_BY_CHAR_WP, profile, wp_id, new_ro)
            save_cfg()
        end

        if GRIP_BACK_BY_WP[wp_id] ~= nil and not (GRIP_BACK_BY_CHAR_WP[profile] and GRIP_BACK_BY_CHAR_WP[profile][wp_id]) then
            imgui.text_colored("(currently using the shared/legacy value tuned before per-character support -- move any slider above to give " .. profile .. " its own)", 0xFF50C0E0)
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

    local changed_def_p, new_def_p = imgui.slider_float(
        "Default pitch (deg)", tonumber(CFG.grip_rot_pitch_deg) or 0.0, -180.0, 180.0, "%.1f")
    if changed_def_p then
        CFG.grip_rot_pitch_deg = new_def_p
        save_cfg()
    end

    local changed_def_y, new_def_y = imgui.slider_float(
        "Default yaw (deg)", tonumber(CFG.grip_rot_yaw_deg) or 0.0, -180.0, 180.0, "%.1f")
    if changed_def_y then
        CFG.grip_rot_yaw_deg = new_def_y
        save_cfg()
    end

    local changed_def_ro, new_def_ro = imgui.slider_float(
        "Default roll (deg)", tonumber(CFG.grip_rot_roll_deg) or 0.0, -180.0, 180.0, "%.1f")
    if changed_def_ro then
        CFG.grip_rot_roll_deg = new_def_ro
        save_cfg()
    end

    imgui.text("LG: " .. tostring(is_left_grip_pressed()) .. "  RG: " .. tostring(is_right_grip_pressed())
        .. "  active: " .. tostring(dock.active) .. "  blend: " .. string.format("%.2f", dock.blend))

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
        local anchor = get_weapon_support_grip_world_pos(wp_id, profile)
        if vec3_valid(anchor) then
            imgui.text(string.format("anchor: %.3f, %.3f, %.3f", anchor.x, anchor.y, anchor.z))
        else
            imgui.text("anchor: invalid")
        end
    end
end)

log.info("[re2_vr_cosmetic_dock] Started. LG+RG cosmetic dock active for "
    .. tostring((function() local n = 0 for _ in pairs(COSMETIC_DOCK_WEAPONS) do n = n + 1 end return n end)())
    .. " weapon ids.")
