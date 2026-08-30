-- Two-handed grip owner for hand-picked long weapons -- decides WHEN a real
-- grip engages, and owns the cosmetic fallback hand placement for when it
-- doesn't. Gated on LG alone, not LG+RG -- RG is normally already held just
-- for regular two-handed aiming, so requiring both would make this active
-- almost the entire time the player aims rather than a distinct deliberate
-- action.
--
-- 2026-08-12: LG's rising edge (press moment) is checked ONCE against the
-- real left hand's distance from the weapon's foregrip anchor -- close
-- enough = commit to a REAL grip for the whole hold (published as
-- __vr_real_grip_active; re2_vr_recoil.lua blends the weapon's actual aim
-- toward the real left-hand position while this is true, and this script
-- stops overriding the left hand's cosmetic position/rotation entirely so
-- the real tracked hand shows through -- see re2_vr_recoil.lua's
-- blend_aim_toward_left_hand). Not close enough = not a grip; LG behaves as
-- pure sub-weapon-equip, completely untouched, same as always. This is a
-- ONE-TIME decision at the press edge, not continuous re-evaluation, which
-- is what makes it reliable -- see the 2026-08-11 history below for why a
-- continuously-reevaluated proximity check was abandoned as unreliable.
--
-- Also publishes __vr_muzzle_world_pos/__vr_muzzle_world_fwd every frame a
-- covered weapon is equipped -- ground-truth muzzle position/forward read
-- straight off the rendered weapon mesh, which re2_vr_recoil.lua needs and
-- would otherwise have to duplicate the MuzzleJoint reflection lookup for.
--
-- 2026-08-11 history (superseded, kept for context): originally a pure
-- hand-proximity dock, continuously comparing real hand distance to the
-- anchor every frame with enter/exit hysteresis. Live VR testing found that
-- unreliable -- inconsistent snap timing, apparent dependence on gaze/
-- camera-recenter, unreliable release (sometimes needing an extreme pose,
-- sometimes releasing on its own), and a real leak where RG-held-alone (no
-- deliberate grab) could still nudge the rendered hand if it happened to be
-- near the anchor. A hand-tracked distance check can only ever measure
-- proximity, never intent -- the same reason this mod's actual weapon
-- gestures (pump-action, slide-rack) were long since converted from
-- tracked-distance to discrete trigger presses. First replaced with a pure
-- LG-button gate (still cosmetic-only, hand locked to a fixed anchor, no
-- real influence on the weapon) -- then the player asked to go further:
-- real physical holding, not just a cosmetic pose. This is that.
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
    grip_zone_radius_m = 0.22,
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

local function vec3_dist(a, b)
    if not vec3_valid(a) or not vec3_valid(b) then return 1e9 end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Real tracked left-hand world position -- only used for the ONE-TIME
--- rising-edge grip-zone check (see file header), never for continuous
--- proximity re-evaluation. __vr_lh_world is kept published by other
--- scripts (re2_vr_haptics.lua/re2_vr_recoil.lua share this same global
--- convention); falls back to a raw controller read if unset.
local function get_real_left_hand_pos()
    local p = rawget(_G, "__vr_lh_world")
    if vec3_valid(p) then return p end
    local ok_c, controllers = pcall(function() return vrmod:get_controllers() end)
    if not ok_c or not controllers or not controllers[1] then return nil end
    local ok_p, pos = pcall(function() return vrmod:get_position(controllers[1]) end)
    return (ok_p and vec3_valid(pos)) and pos or nil
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

local grip = { real_active = false, wp_id = nil, prev_lg = false }

--- Ground-truth muzzle position/forward/up, republished every frame a
--- covered weapon is equipped so re2_vr_recoil.lua can blend aim toward the
--- real left hand without duplicating the MuzzleJoint reflection lookup.
--- 2026-08-13: muzzle_up added so recoil.lua can also correct roll (twist
--- around the barrel axis) independent of the right hand's own tracked
--- orientation -- see re2_vr_real_weapon_grip_attempt memory.
local function publish_muzzle_globals(muzzle_pos, muzzle_fwd, muzzle_up)
    rawset(_G, "__vr_muzzle_world_pos", vec3_valid(muzzle_pos) and Vector3f.new(muzzle_pos.x, muzzle_pos.y, muzzle_pos.z) or nil)
    rawset(_G, "__vr_muzzle_world_fwd", vec3_valid(muzzle_fwd) and Vector3f.new(muzzle_fwd.x, muzzle_fwd.y, muzzle_fwd.z) or nil)
    rawset(_G, "__vr_muzzle_world_up", vec3_valid(muzzle_up) and Vector3f.new(muzzle_up.x, muzzle_up.y, muzzle_up.z) or nil)
end

--- Grip anchor position/rotation, republished every frame a covered weapon
--- is equipped (not just at the LG rising edge) so re2_vr_recoil.lua can use
--- it continuously for a proximity-based visual snap of the rendered left
--- hand while a real grip is held, without re-deciding whether the grip
--- itself should stay engaged (that stays rising-edge-only, unchanged).
local function publish_grip_anchor_globals(anchor_pos, anchor_rot)
    rawset(_G, "__vr_grip_anchor_world_pos", vec3_valid(anchor_pos) and Vector3f.new(anchor_pos.x, anchor_pos.y, anchor_pos.z) or nil)
    rawset(_G, "__vr_grip_anchor_world_rot", anchor_rot)
end

local function set_real_grip(active, wp_id)
    active = active == true
    if grip.real_active == active and grip.wp_id == wp_id then return end
    grip.real_active = active
    grip.wp_id = active and wp_id or nil
    rawset(_G, "__vr_real_grip_active", active)
    rawset(_G, "__vr_real_grip_wp", grip.wp_id)
    log.info(string.format("[re2_vr_cosmetic_dock] real grip %s (wp=%s)",
        active and "engaged" or "released", tostring(wp_id)))
end

re.on_frame(function()
    if not vr_active() or blocked_by_other_system() then
        publish_muzzle_globals(nil, nil, nil)
        publish_grip_anchor_globals(nil, nil)
        set_real_grip(false, nil)
        grip.prev_lg = false
        return
    end

    local wp_id = get_equipped_weapon_id()
    if not wp_id or not COSMETIC_DOCK_WEAPONS[wp_id] then
        publish_muzzle_globals(nil, nil, nil)
        publish_grip_anchor_globals(nil, nil)
        set_real_grip(false, nil)
        grip.prev_lg = false
        return
    end

    local muzzle_pos, muzzle_fwd, _, muzzle_up = get_weapon_muzzle_pos_fwd()
    publish_muzzle_globals(muzzle_pos, muzzle_fwd, muzzle_up)

    local profile = get_active_profile()
    local anchor_pos, anchor_rot = get_weapon_support_grip_world_pos(wp_id, profile)
    publish_grip_anchor_globals(anchor_pos, anchor_rot)

    local lg = is_left_grip_pressed()

    -- Rising edge only: decide ONCE, at the moment of the press, whether the
    -- real left hand is close enough to the foregrip anchor to count as a
    -- real grip -- not re-evaluated continuously while held (see file
    -- header for why continuous proximity was unreliable). If the equipped
    -- weapon changes mid-hold, drop the grip.
    if lg and not grip.prev_lg then
        local anchor = anchor_pos
        local real_lh = get_real_left_hand_pos()
        local radius = clampf(tonumber(CFG.grip_zone_radius_m) or 0.22, 0.05, 0.30)
        local dist = vec3_dist(anchor, real_lh)
        local close_enough = vec3_valid(anchor) and vec3_valid(real_lh) and dist <= radius
        log.info(string.format(
            "[re2_vr_cosmetic_dock] LG rising edge wp=%s anchor=%s lh=%s dist=%.3f radius=%.3f -> %s",
            tostring(wp_id),
            vec3_valid(anchor) and string.format("%.3f,%.3f,%.3f", anchor.x, anchor.y, anchor.z) or "invalid",
            vec3_valid(real_lh) and string.format("%.3f,%.3f,%.3f", real_lh.x, real_lh.y, real_lh.z) or "invalid",
            dist, radius, tostring(close_enough)))
        set_real_grip(close_enough, wp_id)
    elseif not lg or (grip.real_active and grip.wp_id ~= wp_id) then
        set_real_grip(false, nil)
    end
    grip.prev_lg = lg
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
    imgui.text("Weapon grip -- equipped: " .. tostring(wp_id) .. "  character: " .. tostring(profile))

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

    local changed_radius, new_radius = imgui.slider_float(
        "Grip zone radius (m)", tonumber(CFG.grip_zone_radius_m) or 0.22, 0.05, 0.30, "%.3f")
    if changed_radius then
        CFG.grip_zone_radius_m = new_radius
        save_cfg()
    end

    imgui.text("LG: " .. tostring(is_left_grip_pressed()) .. "  RG: " .. tostring(is_right_grip_pressed())
        .. "  real grip active: " .. tostring(grip.real_active))

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

log.info("[re2_vr_cosmetic_dock] Started. LG-gated real weapon grip active for "
    .. tostring((function() local n = 0 for _ in pairs(COSMETIC_DOCK_WEAPONS) do n = n + 1 end return n end)())
    .. " weapon ids.")
