if reframework:get_game_name() ~= "re2" then
    return {}
end

if not vrmod then
    return {}
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

local CFG_PATH = "re2_vr/re2_vr_recoil.json"

local function imgui_col(r, g, b, a)
    a = a or 255
    return ((a & 0xFF) << 24) | ((b & 0xFF) << 16) | ((g & 0xFF) << 8) | (r & 0xFF)
end

local UI_ACCENT = imgui_col(136, 204, 255)
local UI_MUTED = imgui_col(136, 136, 136)
local UI_ENABLE = imgui_col(0, 255, 0)
local UI_DISABLE = imgui_col(255, 64, 64)

local PI_HALF = math.pi * 0.5
local SUPPORT_HAND_DISTANCE = 0.5

-- Per-weapon default intensity by class (1.0-4.0). Non-firearms get no recoil (intensity 0).
local WEAPON_TYPE_INTENSITY = {
    handgun = 1.22,
    revolver = 1.38,
    smg = 1.75,
    rifle = 1.48,
    shotgun = 2.55,
    magnum = 2.90,
    launcher = 2.45,
    flamethrower = 1.52,
    electric = 1.68,
    rpg = 3.90,
    minigun = 3.20,
}

-- GameObject names at runtime (wp****). Optional type overrides default weapon class.
-- Non-firearm / prop wp ids (no catalog entry, no recoil).
local WEAPON_NO_RECOIL_IDS = {
    ["wp0001"] = true,
    ["wp0500"] = true,
    ["wp1001"] = true,
    ["wp4000"] = true,
    ["wp4110"] = true,
    ["wp4310"] = true,
    ["wp4500"] = true,
    ["wp4510"] = true,
    ["wp4530"] = true,
    ["wp4701"] = true,
    ["wp4901"] = true,
    ["wp6200"] = true,
    ["wp6202"] = true,
    ["wp6300"] = true,
    ["wp6301"] = true,
}

local WEAPON_CATALOG = {
    ["wp0000"] = { name = "Matilda", type = "handgun" },
    ["wp0100"] = { name = "M19", type = "handgun" },
    ["wp0200"] = { name = "JMB Hp3", type = "handgun" },
    ["wp0300"] = { name = "Quickdraw Army", type = "revolver" },
    ["wp0600"] = { name = "MUP", type = "handgun" },
    ["wp0700"] = { name = "Broom Hc", type = "handgun" },
    ["wp0800"] = { name = "SLS 60", type = "handgun" },
    ["wp1000"] = { name = "W-870", type = "shotgun" },
    ["wp2000"] = { name = "MQ 11", type = "smg" },
    ["wp2200"] = { name = "LE 5", type = "smg" },
    ["wp3000"] = { name = "Lightning Hawk", type = "magnum" },
    ["wp4100"] = { name = "GM 79", type = "launcher" },
    ["wp4200"] = { name = "Chemical Flamethrower", type = "flamethrower" },
    ["wp4300"] = { name = "Spark Shot", type = "electric" },
    ["wp4400"] = { name = "ATM-4", type = "rpg" },
    ["wp4600"] = { name = "Anti-Tank Rocket", type = "rpg" },
    ["wp4700"] = { name = "Minigun", type = "minigun" },
    ["wp7000"] = { name = "Samurai Edge", type = "handgun" },
    ["wp7010"] = { name = "Samurai Edge (Chris)", type = "handgun" },
    ["wp7020"] = { name = "Samurai Edge (Jill)", type = "handgun" },
    ["wp7030"] = { name = "Samurai Edge (Albert)", type = "handgun" },
    ["wp8400"] = { name = "ATM-4 Unlimited", type = "rpg" },
    ["wp8700"] = { name = "Minigun Unlimited", type = "minigun" },
}

local WEAPON_AUTO_RECOIL_IDS = {
    ["wp2000"] = true,
    ["wp2200"] = true,
    ["wp4200"] = true,
    ["wp4700"] = true,
    ["wp8700"] = true,
}

-- Per-type one/two-hand modifiers (stack on global one_hand_* / two_hand_scale / auto_scale).
-- kick = impulse mult, spring = stiffness mult, auto = auto_scale mult, sustain = damping mult.
local WEAPON_GRIP_PROFILE = {
    handgun = {
        weight = "light",
        one = { kick = 1.08, spring = 1.10, auto = 1.00, sustain = 1.00 },
        two = { kick = 1.00, spring = 1.00, auto = 1.00, sustain = 1.00 },
    },
    revolver = {
        weight = "light",
        one = { kick = 1.14, spring = 1.15, auto = 1.00, sustain = 1.00 },
        two = { kick = 1.00, spring = 1.00, auto = 1.00, sustain = 1.00 },
    },
    smg = {
        weight = "light",
        one = { kick = 1.10, spring = 1.12, auto = 1.55, sustain = 1.18 },
        two = { kick = 1.00, spring = 1.00, auto = 1.00, sustain = 1.00 },
    },
    rifle = {
        weight = "medium",
        one = { kick = 1.18, spring = 1.20, auto = 1.25, sustain = 1.10 },
        two = { kick = 1.00, spring = 1.00, auto = 1.00, sustain = 1.00 },
    },
    shotgun = {
        weight = "heavy",
        one = { kick = 1.22, spring = 1.48, auto = 1.00, sustain = 1.05 },
        two = { kick = 1.00, spring = 1.00, auto = 1.00, sustain = 1.00 },
    },
    magnum = {
        weight = "heavy",
        one = { kick = 1.26, spring = 1.40, auto = 1.00, sustain = 1.00 },
        two = { kick = 1.00, spring = 1.00, auto = 1.00, sustain = 1.00 },
    },
    launcher = {
        weight = "heavy",
        one = { kick = 1.20, spring = 1.35, auto = 1.00, sustain = 1.00 },
        two = { kick = 1.00, spring = 1.00, auto = 1.00, sustain = 1.00 },
    },
    flamethrower = {
        weight = "medium",
        one = { kick = 1.12, spring = 1.14, auto = 1.35, sustain = 1.15 },
        two = { kick = 1.00, spring = 1.00, auto = 1.00, sustain = 1.00 },
    },
    electric = {
        weight = "medium",
        one = { kick = 1.14, spring = 1.16, auto = 1.20, sustain = 1.08 },
        two = { kick = 1.00, spring = 1.00, auto = 1.00, sustain = 1.00 },
    },
    rpg = {
        weight = "heavy",
        one = { kick = 1.30, spring = 1.38, auto = 1.00, sustain = 1.00 },
        two = { kick = 1.00, spring = 1.00, auto = 1.00, sustain = 1.00 },
    },
    minigun = {
        weight = "heavy",
        one = { kick = 1.15, spring = 1.22, auto = 1.65, sustain = 1.25 },
        two = { kick = 1.00, spring = 1.00, auto = 1.00, sustain = 1.00 },
    },
}

local CFG = {
    enabled = true,
    use_native_recoil = false,
    suppress_native_recoil = true,
    suppress_camera_recoil = true,
    intensity = 1.0,
    attack_duration = 0.022,
    spring_stiffness = 120.0,
    spring_damping = 30.0,
    sustained_damping = 40.0,
    spring_settle_mult = 4.5,
    sustained_window = 0.12,
    substep_dt = 0.008,
    position_intensity = 0.0,
    position_up_ratio = 0.0,
    position_back_ratio = 0.15,
    rotation_intensity = 0.22,
    wrist_pitch_sign = 1.0,
    yaw_intensity = 0.0,
    wrist_yaw_sign = 1.0,
    apply_yaw_rotation = true,
    horizontal_spread = 0.03,
    vertical_spread = 0.0,
    randomness = 0.35,
    mult_exponent = 0.35,
    stack_cap = 2.0,
    auto_scale = 0.25,
    two_hand_scale = 0.55,
    -- 2026-08-13: temporarily lowered from 1.0 to test whether forcing a
    -- full-commit rotation correction every single frame is what's
    -- destabilizing the native IkArmFit solver's own position solve (real
    -- grip's raw_target position jumps ~0.4m/frame despite the real hand
    -- being stationary and recoil.lua never touching position itself -- see
    -- re2_vr_real_weapon_grip_attempt memory). If lowering this calms the
    -- position jitter, that confirms rotation-forcing is feeding back into
    -- position; if not, this isn't the mechanism. Revert to 1.0 (both here
    -- and the clampf fallback below) if this doesn't pan out.
    two_hand_aim_blend = 0.5,
    one_hand_light = 1.18,
    one_hand_heavy = 1.90,
    weapons = {},
}

local m_recoil = {
    spring_pos_y = 0.0,
    spring_pos_z = 0.0,
    spring_vel_y = 0.0,
    spring_vel_z = 0.0,
    spring_pitch = 0.0,
    spring_vel_pitch = 0.0,
    spring_yaw = 0.0,
    spring_vel_yaw = 0.0,
}

local m_attack = {
    active = false,
    t = 0.0,
    pos_y = 0.0,
    pos_z = 0.0,
    pitch = 0.0,
    yaw = 0.0,
}

local m_pending_recoil_shots = 0
local m_recoil_last_shot_t = 0.0
local m_recoil_last_t = 0.0
local m_recoil_active = false

local m_recoil_grip = {
    two_hand = false,
    wtype = "handgun",
    weight = "light",
    global_kick = 1.0,
    kick_mult = 1.0,
    spring_mult = 1.0,
    auto_mult = 1.0,
    sustain_mult = 1.0,
}

local m_recoil_last_weapon = nil
local m_recoil_last_ammo_count = -1

local fire_hooks_installed = false
local camera_recoil_hooks_installed = false
local ik_hook_installed = false
local ik_hook_warned = false
local settings_bootstrapped = false

local survivor_condition_type = nil
local grip_action = nil

local l_arm_wrist_hash = nil
local r_arm_wrist_hash = nil

local frame_apply = {
    weapon_has_ammo = false,
    two_handed = false,
    has_recoil = false,
}

local frame_ik = {
    grip_offset_frame = -1,
    grip_pos_rel = nil,
    grip_rot_rel = nil,
    lh_pre_matrix = nil,
    lh_arm_fit_data = nil,
    lh_field_name = nil,
    rh_ik_pre_matrix = nil,
    grip_dbg_prev_angle_deg = nil,
    grip_dbg_prev_frame = nil,
    grip_dbg_last_log_time = nil,
    grip_dbg_prev_lh = nil,
    grip_dbg_prev_p = nil,
    grip_dbg_wrist_side = nil,
    grip_dbg_wrist_method = nil,
    grip_dbg_arm_fit_id = nil,
    grip_dbg_prev_arm_fit_id = nil,
    grip_dbg_raw_target_pos = nil,
    grip_dbg_prev_raw_target_pos = nil,
}

local motion_get_joint_index = nil
local motion_get_world_position = nil
local motion_get_world_rotation = nil

local sim_frame = 0
local last_physics_frame = -1
local ik_physics_sync_frame = -1

local RECOIL_FADEOUT_DURATION = 0.045

local frame_ik_recoil = {
    frame = -1,
    pitch = 0.0,
    yaw = 0.0,
    pos_y = 0.0,
    pos_z = 0.0,
}

local m_recoil_fadeout = {
    active = false,
    t = 0.0,
    duration = RECOIL_FADEOUT_DURATION,
    pitch = 0.0,
    yaw = 0.0,
    pos_y = 0.0,
    pos_z = 0.0,
}

local ik_calls_this_frame = 0
local wrist_side_call_frame = -1
local wrist_side_call_count = 0
local max_wrist_side_calls_prev_frame = 0
local last_ik_frame = -1
local WEAPON_NEAR_RIGHT_CONTROLLER_DIST = 0.30
local ik_apply_count = 0
local last_ik_side_detected = "none"
local last_ik_side_method = "none"

local ik_arm_fit_type = nil
local target_matrix_field_offset = nil
local target_matrix_field_name = nil
local via_motion_type = sdk.typeof("via.motion.Motion")

local application = sdk.get_native_singleton("via.Application")
local application_type = sdk.find_type_definition("via.Application")
local get_uptime_second_function = application_type and application_type:get_method("get_UpTimeSecond") or nil

local via_murmur_hash_type = sdk.find_type_definition("via.murmur_hash")
local via_murmur_hash_calc32 = via_murmur_hash_type and via_murmur_hash_type:get_method("calc32") or nil

local implement_gun_type = sdk.typeof("app.ropeway.implement.Gun")

local native_suppress = {
    last_weapon_id = "",
    last_gun = nil,
    passes = 0,
    last_suppress_frame = -1,
    last_suppress_ok = false,
}

local implement_gun_cache = { weapon_addr = nil, wid = "", gun = nil, miss = false }

local ik_recoil_pass_state = { frame = -1, idle_after_first = false }

local function get_weapon_object_addr(weapon)
    if weapon == nil then return nil end
    local ok, addr = pcall(function() return weapon:get_address() end)
    if ok and addr ~= nil then return addr end
    return weapon
end

local function uptime_now()
    if application and get_uptime_second_function then
        local ok, t = pcall(function() return get_uptime_second_function:call(application) end)
        if ok and type(t) == "number" then
            return t
        end
    end
    return os.clock()
end

local function save_cfg()
    pcall(function() json.dump_file(CFG_PATH, CFG) end)
end

local function clamp_weapon_intensity(v)
    if type(v) ~= "number" then return 1.0 end
    if v < 1.0 then return 1.0 end
    if v > 4.0 then return 4.0 end
    return v
end

local function weapon_intensity_from_entry(entry)
    if type(entry) == "number" then
        return clamp_weapon_intensity(entry)
    end
    if type(entry) == "table" and entry.intensity ~= nil then
        local v = tonumber(entry.intensity)
        if v ~= nil then
            return clamp_weapon_intensity(v)
        end
    end
    return nil
end

local function weapon_family_type(weapon_id)
    local num = tonumber((weapon_id or ""):match("^wp(%d+)$"))
    if num == nil then
        return nil
    end
    local family = math.floor(num / 1000)
    if family == 0 then
        if num >= 300 and num < 400 then
            return "revolver"
        end
        return "handgun"
    elseif family == 1 then
        return "shotgun"
    elseif family == 2 then
        return "smg"
    elseif family == 3 then
        return "magnum"
    elseif family == 5 then
        return "rifle"
    elseif family == 6 then
        return nil
    elseif family == 7 then
        return "handgun"
    elseif family == 4 then
        if num == 4200 then
            return "flamethrower"
        elseif num == 4300 then
            return "electric"
        elseif num == 4400 or num == 4600 or num == 8400 then
            return "rpg"
        elseif num == 4700 or num == 8700 then
            return "minigun"
        elseif num == 4100 then
            return "launcher"
        end
        return nil
    end
    return nil
end

local function resolve_weapon_type(weapon_id)
    local catalog = WEAPON_CATALOG[weapon_id]
    if catalog ~= nil and type(catalog.type) == "string" then
        return catalog.type
    end
    return weapon_family_type(weapon_id)
end

local function weapon_recoil_supported(weapon_id)
    if type(weapon_id) ~= "string" or weapon_id == "" then
        return false
    end
    if WEAPON_NO_RECOIL_IDS[weapon_id] then
        return false
    end
    local wtype = resolve_weapon_type(weapon_id)
    return wtype ~= nil and WEAPON_TYPE_INTENSITY[wtype] ~= nil
end

local function default_weapon_entry(weapon_id)
    if not weapon_recoil_supported(weapon_id) then
        return nil
    end
    local catalog = WEAPON_CATALOG[weapon_id]
    local wtype = resolve_weapon_type(weapon_id)
    local entry = {
        intensity = WEAPON_TYPE_INTENSITY[wtype],
        type = wtype,
    }
    if catalog ~= nil and type(catalog.name) == "string" then
        entry.name = catalog.name
    end
    return entry
end

local function normalize_weapon_entry(weapon_id, entry)
    if not weapon_recoil_supported(weapon_id) then
        return nil
    end
    if type(entry) ~= "table" then
        return default_weapon_entry(weapon_id)
    end
    if entry.type == "utility" then
        return nil
    end
    local intensity = weapon_intensity_from_entry(entry)
    if intensity == nil then
        return default_weapon_entry(weapon_id)
    end
    local out = {
        intensity = intensity,
        type = type(entry.type) == "string" and entry.type or resolve_weapon_type(weapon_id),
    }
    if type(entry.name) == "string" and entry.name ~= "" then
        out.name = entry.name
    elseif WEAPON_CATALOG[weapon_id] ~= nil and WEAPON_CATALOG[weapon_id].name ~= nil then
        out.name = WEAPON_CATALOG[weapon_id].name
    end
    return out
end

local function import_weapons_into_cfg(weapons_tbl, overwrite)
    if type(weapons_tbl) ~= "table" then
        return false
    end
    local changed = false
    for weapon_id, entry in pairs(weapons_tbl) do
        local normalized = normalize_weapon_entry(weapon_id, entry)
        if normalized ~= nil and (overwrite or CFG.weapons[weapon_id] == nil) then
            CFG.weapons[weapon_id] = normalized
            changed = true
        end
    end
    return changed
end

local function prune_non_recoil_weapons_from_cfg()
    local changed = false
    for weapon_id, _ in pairs(CFG.weapons) do
        if not weapon_recoil_supported(weapon_id) then
            CFG.weapons[weapon_id] = nil
            changed = true
        end
    end
    return changed
end

local function load_cfg_from_disk()
    local data = json.load_file(CFG_PATH)
    if type(data) ~= "table" then
        return
    end
    for k, v in pairs(data) do
        if k == "weapons" then
            if type(v) == "table" then
                CFG.weapons = {}
                import_weapons_into_cfg(v, true)
            end
        elseif CFG[k] ~= nil and type(v) == type(CFG[k]) then
            CFG[k] = v
        end
    end
end

local function ensure_cfg_weapon_defaults()
    local changed = prune_non_recoil_weapons_from_cfg()
    for weapon_id, _ in pairs(WEAPON_CATALOG) do
        if CFG.weapons[weapon_id] == nil then
            local entry = default_weapon_entry(weapon_id)
            if entry ~= nil then
                CFG.weapons[weapon_id] = entry
                changed = true
            end
        end
    end
    return changed
end

local function bootstrap_settings()
    if settings_bootstrapped then
        return
    end
    if ensure_cfg_weapon_defaults() then
        save_cfg()
    end
    settings_bootstrapped = true
end

pcall(load_cfg_from_disk)

local function lua_recoil_active()
    if not CFG.enabled or CFG.use_native_recoil then
        return false
    end
    return true
end

local function vr_active()
    if not lua_recoil_active() then
        return false
    end
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

-- 2026-08-14: raw RG button read, mirrors is_left_grip_active() exactly but
-- for the right controller -- needed because is_weapon_grip_active() (used
-- for the RG+LG latch's "is RG really held" check) turned out to never
-- actually go false across an entire held-LG test that included a real RG
-- release (confirmed live: method=frozen_latch_offset never once appeared in
-- SUPPORT_HAND_DEBUG despite multiple ARM/hold/release cycles). Suspected
-- cause: is_weapon_grip_active()'s underlying signals (is_support_hand_
-- active/is_two_handed) likely reflect the character's CURRENT pose rather
-- than the RG button directly -- and since this mod's own cosmetic system is
-- what's now posing the left arm as two-handed, that pose-based check may be
-- reading its own output back as "still two-handed" even after RG lets go.
-- A raw button read sidesteps that entirely. See
-- re2_vr_real_weapon_grip_attempt memory.
local function is_right_grip_active()
    if not grip_action or grip_action == 0 then
        pcall(function() grip_action = vrmod:get_action_grip() end)
    end
    if not grip_action then return false end
    local right_joy = nil
    pcall(function() right_joy = vrmod:get_right_joystick() end)
    if not right_joy then return false end
    local ok, active = pcall(function()
        return vrmod:is_action_active(grip_action, right_joy)
    end)
    return ok and active == true
end

-- Left grip held counts as two-handed support.
local function is_two_hand_recoil_active()
    if not is_left_grip_active() then
        return false
    end
    if rawget(_G, "__vr_in_holster_zone") == true then
        return false
    end
    if rawget(_G, "__vr_in_head_flashlight_zone") == true then
        return false
    end
    return true
end

local function get_game_frame_id()
    if re.get_frame_count then
        local ok, n = pcall(function() return re.get_frame_count() end)
        if ok and type(n) == "number" then
            return n
        end
    end
    return sim_frame
end

local function vec3_dist(a, b)
    if a == nil or b == nil then return 1e9 end
    if type(a.x) ~= "number" or type(b.x) ~= "number" then return 1e9 end
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- 2026-08-13: two attempts were made and REVERTED this session to prefer a
-- "true" direct controller read over __vr_lh_world/__vr_rh_world here
-- (details in re2_vr_real_weapon_grip_attempt memory), based on the theory
-- that the global's camera-relative reconstruction (get_fp_style_hand_
-- world_pos, in re2_vr_ik_extention.lua) merely "drifts" versus a raw
-- controller read. That theory was WRONG: confirmed live both times (raw
-- vrmod:get_position AND vrc_manager.controllers_list[i].position) that
-- direct controller reads are in VR tracking/room space (near-origin
-- values) while anything compared against them (e.g. the grip anchor) is in
-- game-world space -- different coordinate systems entirely, not
-- comparable. The camera-relative reconstruction isn't an approximation of
-- world position, it IS the way to get world position here (anchors the
-- tracking-space offset to the camera's real world position/orientation).
-- Global-first is back to being correct.
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

local function hands_are_supporting_weapon()
    local lh = get_hand_world_pos("left")
    local rh = get_hand_world_pos("right")
    if lh == nil or rh == nil then return false end
    if type(lh.x) ~= "number" or type(rh.x) ~= "number" then return false end
    local dx = lh.x - rh.x
    local dy = lh.y - rh.y
    local dz = lh.z - rh.z
    return math.sqrt(dx * dx + dy * dy + dz * dz) <= SUPPORT_HAND_DISTANCE
end

local function is_two_handed()
    if player_is_reloading() then
        return true
    end
    if rawget(_G, "__vr_in_holster_zone") == true then
        return false
    end
    if rawget(_G, "__vr_in_head_flashlight_zone") == true then
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

local function is_support_hand_active()
    return is_two_hand_recoil_active()
end

local function is_weapon_grip_active()
    if is_support_hand_active() then
        return true
    end
    if firstpersonmod ~= nil and type(firstpersonmod.was_gripping_weapon) == "function" then
        local ok, gripping = pcall(function() return firstpersonmod:was_gripping_weapon() end)
        if ok and gripping == true then
            return true
        end
    end
    return is_two_handed()
end

-- 2026-08-14: new approach, replaces the real-hand-tracked grip system
-- entirely (re2_vr_cosmetic_dock.lua's proximity/anchor-based real grip,
-- now disabled via its own enabled=false config) after the player found no
-- amount of tuning real-world hand tracking made it feel non-janky or
-- "really held" -- decided the position-tracked approach is fundamentally
-- not going to feel good in this game. New idea: don't track hand position
-- at all. Instead, LATCH the ALREADY-PROVEN native RG-driven cosmetic
-- follow-weapon state (should_support_hand_follow_weapon, used for RG this
-- whole time) so it survives RG being released, as long as LG stays held --
-- i.e. RG+LG held together "catches" the hand on the weapon, then letting go
-- of RG alone keeps it there until LG itself is released. No position/
-- distance math anywhere in this mechanism -- sidesteps the whole HMD-
-- position-affects-detection problem that real hand tracking could never
-- get past. Folded into frame_ik (not a new top-level local) since this file
-- is near Lua's 200-local ceiling -- see feedback_lua_200_local_ceiling
-- memory.
local function update_support_hand_latch()
    local lg = is_left_grip_active()
    -- 2026-08-14: player deliberately held LG for ~2s past RG's release,
    -- twice, and the log both times showed is_left_grip_active() reading
    -- false the instant RG let go -- real data, not a guess, so treat it as
    -- real: likely a brief genuine dip in the LG reading (analog grip easing
    -- slightly, or an OpenXR/binding quirk) exactly during the RG-release
    -- motion, even though the hold felt continuous. Debounce: only actually
    -- clear the latch after LG has read released for a sustained 0.15s, not
    -- on a single frame's reading. Tracked via frame_ik (not a new top-level
    -- local) -- file is near Lua's 200-local ceiling.
    if not lg then
        if frame_ik.lg_released_since == nil then
            frame_ik.lg_released_since = uptime_now()
        end
        local released_for = uptime_now() - frame_ik.lg_released_since
        if released_for >= 0.15 then
            if frame_ik.support_hand_latch then
                log.warn(string.format(
                    "[re2_vr_recoil] LATCH_DEBUG cleared -- LG released for %.2fs (past 0.15s debounce)",
                    released_for))
            end
            frame_ik.support_hand_latch = false
        end
        return
    end
    frame_ik.lg_released_since = nil
    -- 2026-08-14: switched from is_weapon_grip_active() to a raw RG button
    -- read -- see is_right_grip_active()'s own comment for why (native/pose-
    -- based signal never actually went false across a real RG release).
    local rg_held = is_right_grip_active()
    if rg_held then
        if not frame_ik.support_hand_latch then
            log.warn("[re2_vr_recoil] LATCH_DEBUG ARMED -- lg=true rg_held=true")
        end
        frame_ik.support_hand_latch = true
    else
        local now = uptime_now()
        if (frame_ik.latch_dbg_last_log_time or 0) + 0.5 <= now then
            frame_ik.latch_dbg_last_log_time = now
            log.warn(string.format(
                "[re2_vr_recoil] LATCH_DEBUG lg=true rg_held=false current_latch=%s",
                tostring(frame_ik.support_hand_latch)))
        end
    end
    -- else: LG held but RG isn't (yet) held too -- leave the latch as
    -- whatever it already was. This is what
    -- lets a prior RG+LG catch persist through RG's own release, while also
    -- meaning LG alone, without ever having RG held, never arms the latch
    -- in the first place.
end

local function get_equipment_weapon(player)
    if not player then return nil end
    local _, weapon = re2.get_weapon_object(player)
    return weapon
end

local AMMO_FIELD_NAMES = {
    "<RemainBullet>k__BackingField", "RemainBullet", "_RemainBullet",
    "<CurrentBullet>k__BackingField", "CurrentBullet", "Num", "<Num>k__BackingField",
    "RemainNum", "<RemainNum>k__BackingField", "CurrentNum", "<CurrentNum>k__BackingField",
    "WpBulletCounter", "HiddenAmmoNum",
}

local AMMO_METHOD_NAMES = {
    "get_RemainBullet", "get_CurrentBullet", "get_remainBullet",
    "get_RemainNum", "get_CurrentNum", "get_LeftBullet", "get_NumRemain", "get_Num",
    "get_Number", "get_WpBulletCounter",
}

local function try_ammo_on_object(obj)
    if obj == nil then return -1 end
    for _, name in ipairs(AMMO_FIELD_NAMES) do
        local ok, v = pcall(function() return obj:get_field(name) end)
        if ok and type(v) == "number" then
            return math.floor(v)
        end
    end
    for _, method_name in ipairs(AMMO_METHOD_NAMES) do
        local ok, v = pcall(function() return obj:call(method_name) end)
        if ok and type(v) == "number" then
            if method_name == "get_WpBulletCounter" then
                return math.floor(v)
            end
            return math.floor(v)
        end
    end
    return -1
end

local function get_weapon_ammo_count(weapon)
    if weapon == nil then return -1 end
    local v = try_ammo_on_object(weapon)
    if v >= 0 then return v end

    local ok_ud, user_data = pcall(function() return weapon:call("get_UserData") end)
    if ok_ud and user_data then
        v = try_ammo_on_object(user_data)
        if v >= 0 then return v end
    end

    local ok_gun, gun = pcall(function() return weapon:call("get_Gun") end)
    if ok_gun and gun ~= nil and gun ~= weapon then
        v = try_ammo_on_object(gun)
        if v >= 0 then return v end
        local ok_gud, gun_ud = pcall(function() return gun:call("get_UserData") end)
        if ok_gud and gun_ud then
            v = try_ammo_on_object(gun_ud)
            if v >= 0 then return v end
        end
    end

    local ok_work, work = pcall(function() return weapon:call("get_work") end)
    if ok_work and work then
        v = try_ammo_on_object(work)
        if v >= 0 then return v end
    end

    local ok_w2, work2 = pcall(function() return weapon:get_field("<Work>k__BackingField") end)
    if ok_w2 and work2 then
        v = try_ammo_on_object(work2)
        if v >= 0 then return v end
    end

    return -1
end

local function get_weapon_recoil_id(weapon)
    if weapon == nil then return "" end
    local ok_go, go = pcall(function() return weapon:call("get_GameObject") end)
    if ok_go and go then
        local ok_name, name = pcall(function() return go:call("get_Name") end)
        if ok_name and type(name) == "string" and name ~= "" then
            return name
        end
    end
    local tdef = weapon:get_type_definition()
    if tdef then
        local ok_fn, fn = pcall(function() return tdef:get_full_name() end)
        if ok_fn and type(fn) == "string" then
            return fn
        end
    end
    return ""
end

local equip_recoil_cache = { frame = -1, supported = false, weapon = nil, wid = "" }

local function get_equipped_recoil_state()
    local fid = get_game_frame_id()
    if equip_recoil_cache.frame ~= fid then
        equip_recoil_cache.frame = fid
        local weapon = get_equipment_weapon(re2.get_localplayer())
        equip_recoil_cache.weapon = weapon
        equip_recoil_cache.wid = get_weapon_recoil_id(weapon)
        equip_recoil_cache.supported = weapon_recoil_supported(equip_recoil_cache.wid)
    end
    return equip_recoil_cache.supported, equip_recoil_cache.weapon, equip_recoil_cache.wid
end

local function get_per_weapon_intensity(weapon)
    local id = get_weapon_recoil_id(weapon)
    if id == "" then return 1.0 end
    if not weapon_recoil_supported(id) then
        return 0.0
    end
    local entry = CFG.weapons[id]
    if entry == nil then
        return weapon_intensity_from_entry(default_weapon_entry(id)) or 1.0
    end
    local v = weapon_intensity_from_entry(entry)
    if v == nil then return 1.0 end
    return v
end

local function is_auto_weapon(weapon)
    local wid = get_weapon_recoil_id(weapon)
    if wid == "" then
        return false
    end
    return WEAPON_AUTO_RECOIL_IDS[wid] == true
end

local function set_per_weapon_intensity(weapon_id, intensity)
    if type(weapon_id) ~= "string" or weapon_id == "" then return end
    if not weapon_recoil_supported(weapon_id) then return end
    local entry = CFG.weapons[weapon_id]
    if type(entry) ~= "table" then
        entry = default_weapon_entry(weapon_id)
    end
    if entry == nil then return end
    entry.intensity = clamp_weapon_intensity(intensity)
    CFG.weapons[weapon_id] = entry
end

local function weapon_display_name(weapon_id)
    if type(weapon_id) ~= "string" or weapon_id == "" then
        return ""
    end
    local entry = CFG.weapons[weapon_id]
    if type(entry) == "table" and type(entry.name) == "string" and entry.name ~= "" then
        return entry.name
    end
    local catalog = WEAPON_CATALOG[weapon_id]
    if catalog ~= nil and type(catalog.name) == "string" then
        return catalog.name
    end
    return weapon_id
end

-- Native weapon recoil suppression (zeros engine RecoilParam blocks).
local function write_valuetype(parent_obj, offset_or_field_name, value)
    if parent_obj == nil or value == nil then
        return false
    end
    local offset = tonumber(offset_or_field_name)
    if offset == nil then
        local ok_f, field = pcall(function()
            return parent_obj:get_type_definition():get_field(offset_or_field_name)
        end)
        if not ok_f or field == nil then
            return false
        end
        offset = field:get_offset_from_base()
    end
    local value_type = value.type or value:get_type_definition()
    if value_type == nil then
        return false
    end
    local size = value_type:get_valuetype_size()
    for i = 0, size - 1 do
        parent_obj:write_byte(offset + i, value:read_byte(i))
    end
    return true
end

local function zero_recoil_rate_range(recoil_params)
    if recoil_params == nil then
        return
    end
    local ok, range = pcall(function() return recoil_params:get_field("_RecoilRateRange") end)
    if not ok or range == nil then
        return
    end
    pcall(function() range.r = 0.0 end)
    pcall(function() range.s = 0.0 end)
    write_valuetype(recoil_params, "_RecoilRateRange", range)
end

local function zero_recoil_param_object(recoil_params)
    if recoil_params == nil then
        return false
    end
    pcall(function() recoil_params._RecoilRate = 0.0 end)
    pcall(function() recoil_params._RecoilDampRate = 100.0 end)
    zero_recoil_rate_range(recoil_params)
    return true
end

local function zero_recoil_parts_combos(gun_userdata)
    if gun_userdata == nil then
        return
    end
    local ok_combos, combos = pcall(function() return gun_userdata:get_field("_RecoilPartsCombos") end)
    if not ok_combos or combos == nil then
        return
    end
    local ok_elems, elements = pcall(function() return combos:get_elements() end)
    if not ok_elems or elements == nil then
        return
    end
    for i = 1, #elements do
        local part = elements[i]
        if part ~= nil then
            local ok_param, param = pcall(function() return part:get_field("_Param") end)
            if ok_param and param ~= nil then
                zero_recoil_param_object(param)
            end
        end
    end
end

local function get_implement_gun_from_weapon(weapon, weapon_go)
    if implement_gun_type == nil then
        return nil
    end
    local weapon_id = ""
    if weapon ~= nil then
        weapon_id = get_weapon_recoil_id(weapon)
        if weapon_id ~= "" and WEAPON_NO_RECOIL_IDS[weapon_id] then
            return nil
        end
        local weapon_addr = get_weapon_object_addr(weapon)
        if implement_gun_cache.weapon_addr == weapon_addr
            and implement_gun_cache.wid == weapon_id then
            if implement_gun_cache.miss then
                return nil
            end
            return implement_gun_cache.gun
        end
    end
    if weapon_go == nil and weapon ~= nil then
        pcall(function() weapon_go = weapon:call("get_GameObject") end)
    end
    if weapon_go ~= nil then
        local ok, gun = pcall(function()
            return weapon_go:call("getComponent(System.Type)", implement_gun_type)
        end)
        if ok and gun ~= nil then
            if weapon ~= nil and weapon_id ~= "" then
                implement_gun_cache.weapon_addr = get_weapon_object_addr(weapon)
                implement_gun_cache.wid = weapon_id
                implement_gun_cache.gun = gun
                implement_gun_cache.miss = false
            end
            return gun
        end
    end
    if weapon ~= nil then
        local ok_g, gun = pcall(function() return weapon:call("get_Gun") end)
        if ok_g and gun ~= nil then
            if weapon_id ~= "" then
                implement_gun_cache.weapon_addr = get_weapon_object_addr(weapon)
                implement_gun_cache.wid = weapon_id
                implement_gun_cache.gun = gun
                implement_gun_cache.miss = false
            end
            return gun
        end
        if weapon_id ~= "" then
            local ok_scene, scene = pcall(function() return sdk.get_native_singleton("via.Scene") end)
            if ok_scene and scene ~= nil then
                local ok_find, found_go = pcall(function()
                    return scene:call("findGameObject(System.String)", weapon_id)
                end)
                if ok_find and found_go ~= nil and found_go:get_Valid() then
                    local ok_gun, gun = pcall(function()
                        return found_go:call("getComponent(System.Type)", implement_gun_type)
                    end)
                    if ok_gun and gun ~= nil then
                        implement_gun_cache.weapon_addr = get_weapon_object_addr(weapon)
                        implement_gun_cache.wid = weapon_id
                        implement_gun_cache.gun = gun
                        implement_gun_cache.miss = false
                        return gun
                    end
                end
            end
        end
        if weapon_id ~= "" then
            implement_gun_cache.weapon_addr = get_weapon_object_addr(weapon)
            implement_gun_cache.wid = weapon_id
            implement_gun_cache.gun = nil
            implement_gun_cache.miss = true
        end
    end
    return nil
end

local function suppress_native_recoil_on_gun(gun)
    if gun == nil then
        return false
    end
    local ok_main, recoil_params = pcall(function()
        return gun:get_field("<RecoilParam>k__BackingField")
    end)
    if ok_main and recoil_params ~= nil then
        zero_recoil_param_object(recoil_params)
    end
    local ok_ud, user_data = pcall(function() return gun:get_field("_UserData") end)
    if ok_ud and user_data ~= nil then
        local ok_gun, gun_ud = pcall(function() return user_data:get_field("_Gun") end)
        if ok_gun and gun_ud ~= nil then
            zero_recoil_parts_combos(gun_ud)
        end
    end
    return ok_main and recoil_params ~= nil
end

local function should_suppress_native_recoil()
    return lua_recoil_active() and CFG.suppress_native_recoil
end

local function should_suppress_camera_recoil()
    return vr_active() and CFG.suppress_camera_recoil
end

local function make_camera_suppress_prehook()
    return function()
        if should_suppress_camera_recoil() then
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end
end

local function on_pre_update_camera_recoil(args)
    if should_suppress_camera_recoil() then
        local ctrl = sdk.to_managed_object(args[2])
        if ctrl ~= nil then
            pcall(function() ctrl:call("exitRecoil") end)
        end
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
end

local function hook_camera_method(type_def, method_name, pre_fn)
    if not type_def or not method_name then
        return false
    end
    local method = type_def:get_method(method_name)
    if not method then
        return false
    end
    sdk.hook(method, pre_fn, function(retval) return retval end)
    return true
end

local function install_camera_recoil_hooks()
    if camera_recoil_hooks_installed then
        return
    end

    local hooked = 0
    local pcc_t = sdk.find_type_definition(NS("camera.PlayerCameraController"))
    local cam_sys_t = sdk.find_type_definition(NS("camera.CameraSystem"))
    if pcc_t then
        if hook_camera_method(pcc_t, "entryRecoil", make_camera_suppress_prehook()) then
            hooked = hooked + 1
        end
        if hook_camera_method(pcc_t, "updateRecoil", on_pre_update_camera_recoil) then
            hooked = hooked + 1
        end
    end

    if cam_sys_t then
        if hook_camera_method(cam_sys_t, "entryCameraRecoil", make_camera_suppress_prehook()) then
            hooked = hooked + 1
        end
        if hook_camera_method(cam_sys_t, "entryCameraShake", make_camera_suppress_prehook()) then
            hooked = hooked + 1
        end
        if hook_camera_method(cam_sys_t, "applyCameraShakeOffset", make_camera_suppress_prehook()) then
            hooked = hooked + 1
        end
    end

    -- Do NOT hook SurvivorRecoilAction or syncRecoil: logs showed H5 on every shot
    -- (weapon FSM recoil), and syncRecoil may couple weapon animation to the camera rig.

    camera_recoil_hooks_installed = hooked > 0
    if camera_recoil_hooks_installed then
        log.info(string.format("[re2_vr_recoil] Camera recoil/shake hooks installed (%d)", hooked))
    else
        log.warn("[re2_vr_recoil] Camera recoil/shake hooks not installed (types/methods missing)")
    end
end

local function suppress_native_recoil_for_equipped_weapon()
    if not should_suppress_native_recoil() then
        native_suppress.last_weapon_id = ""
        native_suppress.last_gun = nil
        native_suppress.last_suppress_frame = -1
        return false
    end
    local suppress_frame = get_game_frame_id()
    if native_suppress.last_suppress_frame == suppress_frame then
        return native_suppress.last_suppress_ok
    end
    local player = re2.get_localplayer()
    if player == nil then
        return false
    end
    local weapon_go, weapon = re2.get_weapon_object(player)
    if weapon == nil then
        native_suppress.last_weapon_id = ""
        native_suppress.last_gun = nil
        native_suppress.last_suppress_frame = suppress_frame
        native_suppress.last_suppress_ok = false
        return false
    end
    local weapon_id = get_weapon_recoil_id(weapon)
    if not weapon_recoil_supported(weapon_id) then
        native_suppress.last_weapon_id = weapon_id
        native_suppress.last_gun = nil
        native_suppress.last_suppress_frame = suppress_frame
        native_suppress.last_suppress_ok = false
        return false
    end
    local gun = get_implement_gun_from_weapon(weapon, weapon_go)
    if gun == nil then
        native_suppress.last_suppress_frame = suppress_frame
        native_suppress.last_suppress_ok = false
        return false
    end
    if native_suppress.last_gun ~= gun or native_suppress.last_weapon_id ~= weapon_id then
        native_suppress.last_weapon_id = weapon_id
        native_suppress.last_gun = gun
    end
    local ok = false
    if suppress_native_recoil_on_gun(gun) then
        native_suppress.passes = native_suppress.passes + 1
        ok = true
    end
    native_suppress.last_suppress_frame = suppress_frame
    native_suppress.last_suppress_ok = ok
    return ok
end

local function cancel_recoil_state(weapon_for_log, reason)
    m_recoil.spring_pos_y = 0.0
    m_recoil.spring_pos_z = 0.0
    m_recoil.spring_vel_y = 0.0
    m_recoil.spring_vel_z = 0.0
    m_recoil.spring_pitch = 0.0
    m_recoil.spring_vel_pitch = 0.0
    m_recoil.spring_yaw = 0.0
    m_recoil.spring_vel_yaw = 0.0
    m_attack.active = false
    m_attack.t = 0.0
    m_attack.pos_y = 0.0
    m_attack.pos_z = 0.0
    m_attack.pitch = 0.0
    m_attack.yaw = 0.0
    m_recoil_active = false
    m_recoil_last_t = 0.0
    m_recoil_fadeout.active = false
    m_recoil_fadeout.t = 0.0
end

local function get_effective_recoil_offsets()
    if m_recoil_fadeout.active then
        local blend = 1.0 - math.min(1.0, m_recoil_fadeout.t / m_recoil_fadeout.duration)
        return m_recoil_fadeout.pitch * blend, m_recoil_fadeout.yaw * blend,
            m_recoil_fadeout.pos_y * blend, m_recoil_fadeout.pos_z * blend
    end
    if frame_ik_recoil.frame == get_game_frame_id() then
        return frame_ik_recoil.pitch, frame_ik_recoil.yaw, frame_ik_recoil.pos_y, frame_ik_recoil.pos_z
    end
    return m_recoil.spring_pitch, m_recoil.spring_yaw, m_recoil.spring_pos_y, m_recoil.spring_pos_z
end

local function capture_frame_ik_recoil()
    local pitch, yaw, pos_y, pos_z = get_effective_recoil_offsets()
    frame_ik_recoil.frame = get_game_frame_id()
    frame_ik_recoil.pitch = pitch
    frame_ik_recoil.yaw = yaw
    frame_ik_recoil.pos_y = pos_y
    frame_ik_recoil.pos_z = pos_z
end

local function begin_recoil_fadeout()
    if m_recoil_fadeout.active then
        return
    end
    m_recoil_fadeout.pitch = m_recoil.spring_pitch
    m_recoil_fadeout.yaw = m_recoil.spring_yaw
    m_recoil_fadeout.pos_y = m_recoil.spring_pos_y
    m_recoil_fadeout.pos_z = m_recoil.spring_pos_z
    local rot_mag = math.abs(m_recoil_fadeout.pitch) + math.abs(m_recoil_fadeout.yaw)
    local pos_mag = math.abs(m_recoil_fadeout.pos_y) + math.abs(m_recoil_fadeout.pos_z)
    if rot_mag < 1e-7 and pos_mag < 1e-7 then
        -- Spring already settled to zero; nothing to fade. End the recoil cycle cleanly
        -- so update_recoil does not loop on the spring block indefinitely.
        m_recoil_active = false
        return
    end
    m_recoil_fadeout.active = true
    m_recoil_fadeout.t = 0.0
    m_recoil_fadeout.duration = RECOIL_FADEOUT_DURATION
    m_recoil.spring_pos_y = 0.0
    m_recoil.spring_pos_z = 0.0
    m_recoil.spring_vel_y = 0.0
    m_recoil.spring_vel_z = 0.0
    m_recoil.spring_pitch = 0.0
    m_recoil.spring_vel_pitch = 0.0
    m_recoil.spring_yaw = 0.0
    m_recoil.spring_vel_yaw = 0.0
    m_attack.active = false
    m_recoil_active = true
end

local function angle_axis_quat(angle, axis)
    local half = angle * 0.5
    local s = math.sin(half)
    return Quaternion.new(math.cos(half), axis.x * s, axis.y * s, axis.z * s):normalized()
end

local function vec3_normalize(v)
    if v == nil then return nil end
    local len_sq = (v.x * v.x) + (v.y * v.y) + (v.z * v.z)
    if len_sq < 1e-8 then return nil end
    local inv = 1.0 / math.sqrt(len_sq)
    return Vector3f.new(v.x * inv, v.y * inv, v.z * inv)
end

local function vec3_cross(a, b)
    return Vector3f.new(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x)
end

local function vec3_valid(p)
    return p ~= nil and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

local function clampf(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function is_real_grip_active()
    return rawget(_G, "__vr_real_grip_active") == true
end

--- World-space rotation mapping unit vector `from_dir` onto `to_dir`,
--- scaled by `weight` (1.0 = full angle, 0.5 = half, etc). Works regardless
--- of any local axis convention, since both inputs and the result are
--- world-space -- doesn't require knowing which local axis of the target
--- matrix represents "forward".
local function world_look_delta(from_dir, to_dir, weight)
    local a = vec3_normalize(from_dir)
    local b = vec3_normalize(to_dir)
    if not a or not b then return nil end
    local dot = clampf(a.x * b.x + a.y * b.y + a.z * b.z, -1.0, 1.0)
    local raw_angle = math.acos(dot)
    local angle = raw_angle * (weight or 1.0)
    if angle < 1e-5 then return Quaternion.identity(), raw_angle, 0.0 end
    local axis = vec3_cross(a, b)
    local axis_len = math.sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
    if axis_len < 1e-6 then return Quaternion.identity(), raw_angle, axis_len end
    axis = Vector3f.new(axis.x / axis_len, axis.y / axis_len, axis.z / axis_len)
    return angle_axis_quat(angle, axis), raw_angle, axis_len
end

--- Blends the weapon's aim toward the real left hand while a real two-
--- handed grip is engaged (re2_vr_cosmetic_dock.lua's __vr_real_grip_active)
--- -- so the gun actually points based on where the support hand really is,
--- instead of just a cosmetic hand placement with no effect on aim. The
--- target direction is measured from the rotation's own pivot (rh_post's
--- position -- the right/trigger hand's fixed grip point) to the real left
--- hand, NOT from the muzzle: the muzzle sits only a few cm from where the
--- support hand naturally grips, so a muzzle-relative vector is too short
--- to normalize stably against ordinary tracking jitter, whereas the
--- right-hand-to-left-hand distance is always tens of cm and well-behaved.
--- Current forward comes from ground-truth __vr_muzzle_world_fwd (published
--- by that same script every frame a covered weapon is equipped) -- one
--- frame behind since it's read before this frame's IK solve runs, same as
--- recoil's own frame-cached values, stable enough for a smooth continuous
--- blend. Keeps rh_post's position untouched, only rotates it. Falls back
--- to rh_post completely unmodified on ANY failure -- this must never be
--- able to corrupt the matrix or crash, since it runs inside the IK
--- pre-hook.
local function blend_aim_toward_left_hand(rh_post)
    if rh_post == nil then return rh_post end
    local ok, result = pcall(function()
        local muzzle_fwd = rawget(_G, "__vr_muzzle_world_fwd")
        if not vec3_valid(muzzle_fwd) then return rh_post end

        local lh = get_hand_world_pos("left")
        if not vec3_valid(lh) then return rh_post end

        -- 2026-08-13: was measured relative to muzzle_pos (either direction
        -- tried) -- wrong reference point entirely. During a real grip the
        -- support hand sits only a few cm from the muzzle by design (e.g.
        -- wp1000's grip_back_from_muzzle_m persisted at 0.038m), so
        -- normalizing (hand - muzzle_pos) divides by a near-zero-length
        -- vector -- any sub-cm tracking jitter then dominates the result,
        -- which is what a player reported as the weapon "repelling" from
        -- the hand, snapping away the instant grip engaged, and an inverted
        -- hand-to-muzzle mapping (all symptoms of a noise-dominated
        -- direction, not a sign error). Fixed: measure from the rotation's
        -- actual pivot instead -- rh_post's own position (`p` below, which
        -- stays fixed while only rotation changes) is the right/trigger
        -- hand's grip point, always tens of cm from the left hand, so the
        -- vector is stable regardless of tracking noise. This also matches
        -- the real-world model: the barrel should point from the grip
        -- pivot through wherever the support hand actually is.
        local p = rh_post[3]
        local desired_fwd = Vector3f.new(lh.x - p.x, lh.y - p.y, lh.z - p.z)
        local weight = clampf(tonumber(CFG.two_hand_aim_blend) or 1.0, 0.0, 1.0)
        local delta, raw_angle, axis_len = world_look_delta(muzzle_fwd, desired_fwd, weight)
        if not delta then return rh_post end

        -- 2026-08-13: temporary spin-bug diagnostics -- leading suspect is
        -- cross-product axis instability when muzzle_fwd/desired_fwd are
        -- near-parallel or near-antiparallel (axis_len -> 0 with a large
        -- angle). Log only on a large misalignment or a sharp frame-to-frame
        -- jump, throttled to 10/sec, using frame_ik for prev-frame state so
        -- no new top-level locals are added (this file is near Lua's 200-
        -- local ceiling). See re2_vr_real_weapon_grip_attempt memory.
        local angle_deg = math.deg(raw_angle)
        local frame_id = get_game_frame_id()
        local prev_angle = frame_ik.grip_dbg_prev_angle_deg
        local prev_frame = frame_ik.grip_dbg_prev_frame
        local is_adjacent_frame = (prev_frame ~= nil and frame_id == prev_frame + 1)
        local jump_deg = (prev_angle ~= nil and is_adjacent_frame)
            and math.abs(angle_deg - prev_angle) or 0.0
        -- 2026-08-13: "rapidly swaps between two locations" reported again
        -- even after reverting the hand-position source back to the known-
        -- working baseline -- so this time log lh/p themselves (and their
        -- own frame-to-frame jump distance) to see directly which one is
        -- unstable, rather than guessing again. Tightened throttle to
        -- 0.03s (~33/sec) so a fast oscillation isn't mostly missed between
        -- samples.
        local lh_jump_m = (frame_ik.grip_dbg_prev_lh ~= nil and is_adjacent_frame)
            and vec3_dist(lh, frame_ik.grip_dbg_prev_lh) or 0.0
        local p_jump_m = (frame_ik.grip_dbg_prev_p ~= nil and is_adjacent_frame)
            and vec3_dist(p, frame_ik.grip_dbg_prev_p) or 0.0
        -- 2026-08-13: also log wrist-side disambiguation (side/method,
        -- captured in on_pre_update_ik just before patch_ik_target_matrix
        -- runs) and an arm_fit_data identity string -- if these change
        -- between the two bistable states, that confirms wrist-side
        -- misassignment as the cause (recoil.lua's get_wrist_side_for_
        -- ik_call has a fragile call-order fallback for two-handed weapons,
        -- untested against real grip's simultaneous dual-hand engagement).
        local arm_fit_changed = (frame_ik.grip_dbg_prev_arm_fit_id ~= nil
            and frame_ik.grip_dbg_arm_fit_id ~= frame_ik.grip_dbg_prev_arm_fit_id)
        -- 2026-08-13: side/arm_fit_changed came back stable (always "right",
        -- never changing objects) -- rules out wrist-side misassignment.
        -- Now also log the RAW native target_matrix position (captured in
        -- patch_ik_target_matrix before build_recoiled_hand_matrix touches
        -- it) and its own jump, to tell apart "native IK target itself is
        -- unstable" from "recoil's own position-offset processing
        -- introduces the instability".
        local raw_pos = frame_ik.grip_dbg_raw_target_pos
        local raw_jump_m = (raw_pos ~= nil and frame_ik.grip_dbg_prev_raw_target_pos ~= nil and is_adjacent_frame)
            and vec3_dist(raw_pos, frame_ik.grip_dbg_prev_raw_target_pos) or 0.0
        if angle_deg > 90.0 or jump_deg > 45.0 then
            local now = uptime_now()
            if (frame_ik.grip_dbg_last_log_time or 0) + 0.03 <= now then
                frame_ik.grip_dbg_last_log_time = now
                log.warn(string.format(
                    "[re2_vr_recoil] GRIP_DEBUG frame=%d angle=%.1fdeg axis_len=%.5f jump=%.1fdeg weight=%.2f lh=(%.3f,%.3f,%.3f) lh_jump=%.3fm p=(%.3f,%.3f,%.3f) p_jump=%.3fm raw_target=(%.3f,%.3f,%.3f) raw_jump=%.3fm side=%s method=%s arm_fit_changed=%s muzzle_fwd=(%.3f,%.3f,%.3f) desired_fwd=(%.3f,%.3f,%.3f)",
                    frame_id, angle_deg, axis_len or -1.0, jump_deg, weight,
                    lh.x, lh.y, lh.z, lh_jump_m,
                    p.x, p.y, p.z, p_jump_m,
                    raw_pos and raw_pos.x or -999, raw_pos and raw_pos.y or -999, raw_pos and raw_pos.z or -999, raw_jump_m,
                    tostring(frame_ik.grip_dbg_wrist_side), tostring(frame_ik.grip_dbg_wrist_method),
                    tostring(arm_fit_changed),
                    muzzle_fwd.x, muzzle_fwd.y, muzzle_fwd.z,
                    desired_fwd.x, desired_fwd.y, desired_fwd.z))
            end
        end
        frame_ik.grip_dbg_prev_raw_target_pos = raw_pos
        frame_ik.grip_dbg_prev_angle_deg = angle_deg
        frame_ik.grip_dbg_prev_frame = frame_id
        frame_ik.grip_dbg_prev_lh = lh
        frame_ik.grip_dbg_prev_p = p
        frame_ik.grip_dbg_prev_arm_fit_id = frame_ik.grip_dbg_arm_fit_id

        local cur_rot = rh_post:to_quat():normalized()
        local new_rot = (delta * cur_rot):normalized()

        -- 2026-08-13: `delta` above only corrects the forward-pointing axis
        -- (pitch/yaw) -- it's a minimal rotation, so it leaves roll (twist
        -- around the new forward axis) exactly as it was in cur_rot, which
        -- still reflects the right hand's own tracked orientation every
        -- frame. Player asked for aim to be fully position-only (right hand
        -- position + left hand position define the pointing line, not
        -- either hand's individual twist) -- confirmed via player feedback
        -- after testing: RH could still visibly "point" the weapon via
        -- roll. Second corrective delta, restricted to rotation around the
        -- now-fixed forward axis only, so it doesn't undo the first
        -- correction: rotate muzzle_up (ground truth, one frame stale, same
        -- source as muzzle_fwd) by the SAME first delta to get where "up"
        -- ended up after the forward fix, then align that toward world-up
        -- projected perpendicular to desired_fwd. Falls back to no roll
        -- correction (keeps whatever roll fell out of the forward fix) if
        -- muzzle_up is unavailable or desired_fwd is too close to vertical
        -- for a stable world-up projection -- never worth a spin bug over.
        local muzzle_up = rawget(_G, "__vr_muzzle_world_up")
        local final_rot = new_rot
        if vec3_valid(muzzle_up) then
            local fwd_n = vec3_normalize(desired_fwd)
            if fwd_n then
                local world_up = Vector3f.new(0.0, 1.0, 0.0)
                local dot_fu = fwd_n.x * world_up.x + fwd_n.y * world_up.y + fwd_n.z * world_up.z
                local proj = Vector3f.new(
                    world_up.x - fwd_n.x * dot_fu,
                    world_up.y - fwd_n.y * dot_fu,
                    world_up.z - fwd_n.z * dot_fu)
                local desired_up = vec3_normalize(proj)
                local up_after_fwd_fix = delta * muzzle_up
                if desired_up and vec3_valid(up_after_fwd_fix) then
                    local delta2, raw_angle2, axis_len2 = world_look_delta(up_after_fwd_fix, desired_up, weight)
                    -- 2026-08-13: guard against the exact same ill-
                    -- conditioned-axis failure class that caused the
                    -- original spin bug (see re2_vr_real_weapon_grip_attempt
                    -- memory) -- if up_after_fwd_fix and desired_up end up
                    -- nearly anti-parallel (large angle, small axis_len),
                    -- the rotation axis is noise-dominated and can flip
                    -- between two near-opposite results frame to frame.
                    -- Skip the roll correction entirely that frame rather
                    -- than risk it -- near-parallel (small angle) is always
                    -- safe and unaffected by this guard, only the
                    -- near-180-degree case is excluded.
                    if delta2 and not (axis_len2 < 0.2 and raw_angle2 > (math.pi * 0.5)) then
                        final_rot = (delta2 * new_rot):normalized()
                    end
                end
            end
        end

        local new_m = final_rot:to_mat4()
        new_m[3] = Vector4f.new(p.x, p.y, p.z, 1.0)
        return new_m
    end)
    if ok and result then return result end
    return rh_post
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

-- Wrist-local recoil: pitch about +X (muzzle climb), yaw about +Y (horizontal), optional slide in hand space.
local LOCAL_WRIST_RIGHT = Vector3f.new(1.0, 0.0, 0.0)
local LOCAL_WRIST_UP = Vector3f.new(0.0, 1.0, 0.0)

local function get_wrist_axis_sign(cfg_key)
    local s = tonumber(CFG[cfg_key]) or 1.0
    if s >= 0.0 then return 1.0 end
    return -1.0
end

local function get_wrist_recoil_transform(hand_rot, scale)
    if hand_rot == nil then
        return nil, nil, nil
    end
    scale = tonumber(scale) or 1.0
    if scale <= 0.0 then
        return Quaternion.identity(), Vector3f.new(0.0, 0.0, 0.0), Quaternion.identity()
    end

    hand_rot = quat_from_vr_rotation(hand_rot) or Quaternion.identity()

    local eff_pitch, eff_yaw, eff_pos_y, eff_pos_z = get_effective_recoil_offsets()
    local pitch = eff_pitch * scale * get_wrist_axis_sign("wrist_pitch_sign")
    local yaw = eff_yaw * scale * get_wrist_axis_sign("wrist_yaw_sign")
    local local_pitch = angle_axis_quat(pitch, LOCAL_WRIST_RIGHT)
    local local_yaw = angle_axis_quat(yaw, LOCAL_WRIST_UP)
    local local_recoil = (local_pitch * local_yaw):normalized()
    local recoil_rot = (hand_rot * local_recoil):normalized()
    local delta_rot = (recoil_rot * hand_rot:inverse()):normalized()

    local up_ratio = math.max(0.0, tonumber(CFG.position_up_ratio) or 0.0)
    local pos_y = eff_pos_y * scale * up_ratio
    local pos_z = eff_pos_z * scale
    local local_offset = Vector3f.new(0.0, pos_y, pos_z)
    local world_offset = recoil_rot * local_offset

    return recoil_rot, world_offset, delta_rot
end

local function is_block_left_hand_ik()
    if firstpersonmod ~= nil and type(firstpersonmod.get_block_left_hand_ik) == "function" then
        local ok, blocked = pcall(function() return firstpersonmod:get_block_left_hand_ik() end)
        if ok and blocked == true then
            return true
        end
    end
    return false
end

-- Left hand follows weapon hand when gripping or reloading.
-- 2026-08-14: superseded the "reuse this system for real grip too" attempt
-- (which showed no visible effect and killed left-hand aim steering) with
-- the RG+LG latch approach instead -- see update_support_hand_latch above,
-- refreshed unconditionally every frame in on_pre_update_ik before this
-- function is ever reached, so just reading frame_ik.support_hand_latch here
-- is enough (it already only ever becomes/stays true while LG is held, so
-- this doesn't need its own is_left_grip_active() check on top either).
local function should_support_hand_follow_weapon()
    if is_block_left_hand_ik() then
        return false
    end
    if frame_ik.support_hand_latch then
        return true
    end
    if player_is_reloading() then
        return true
    end
    if not is_left_grip_active() then
        return false
    end
    return is_weapon_grip_active()
end

local function reset_frame_ik_state()
    frame_ik.grip_offset_frame = -1
    frame_ik.grip_pos_rel = nil
    frame_ik.grip_rot_rel = nil
    frame_ik.lh_pre_matrix = nil
    frame_ik.lh_arm_fit_data = nil
    frame_ik.lh_field_name = nil
    frame_ik.rh_ik_pre_matrix = nil
end

local function ensure_wrist_hashes()
    if l_arm_wrist_hash ~= nil and r_arm_wrist_hash ~= nil then
        return
    end
    if not via_murmur_hash_calc32 then return end
    local ok_l, lh = pcall(function() return via_murmur_hash_calc32:call(nil, "l_arm_wrist", 0) end)
    local ok_r, rh = pcall(function() return via_murmur_hash_calc32:call(nil, "r_arm_wrist", 0) end)
    if ok_l then l_arm_wrist_hash = lh end
    if ok_r then r_arm_wrist_hash = rh end
end

local function ensure_motion_methods()
    if motion_get_joint_index ~= nil then
        return true
    end
    local motion_t = sdk.find_type_definition("via.motion.Motion")
    if motion_t == nil then
        return false
    end
    motion_get_joint_index = motion_t:get_method("getJointIndexByNameHash")
    motion_get_world_position = motion_t:get_method("getWorldPosition")
    motion_get_world_rotation = motion_t:get_method("getWorldRotation")
    return motion_get_joint_index ~= nil and motion_get_world_position ~= nil and motion_get_world_rotation ~= nil
end

local function get_player_motion()
    local player = re2.get_localplayer()
    if player == nil then
        return nil
    end
    local transform = nil
    pcall(function()
        local go = player:call("get_GameObject")
        if go ~= nil then
            transform = go:call("get_Transform")
        end
    end)
    if transform == nil or via_motion_type == nil then
        return nil
    end
    local motion = nil
    pcall(function()
        motion = transform:call("getComponent(System.Type)", via_motion_type)
    end)
    return motion
end

local function vec4_to_vec3(v)
    if v == nil or type(v.x) ~= "number" then
        return nil
    end
    return Vector3f.new(v.x, v.y, v.z)
end

local function get_motion_wrist_pose(which)
    if not ensure_motion_methods() then
        return nil, nil
    end
    ensure_wrist_hashes()
    local hash = (which == "left") and l_arm_wrist_hash or r_arm_wrist_hash
    if hash == nil then
        return nil, nil
    end
    local motion = get_player_motion()
    if motion == nil then
        return nil, nil
    end

    local idx = nil
    pcall(function() idx = motion_get_joint_index:call(motion, hash) end)
    if idx == nil then
        return nil, nil
    end

    local pos_raw, rot_raw = nil, nil
    pcall(function() pos_raw = motion_get_world_position:call(motion, idx) end)
    pcall(function() rot_raw = motion_get_world_rotation:call(motion, idx) end)
    local pos = vec4_to_vec3(pos_raw)
    local rot = quat_from_vr_rotation(rot_raw)
    return pos, rot
end

-- Skeleton wrist-joint grip offset relative to weapon hand.
local function get_skeleton_grip_offset_relative_to_weapon()
    local frame_id = get_game_frame_id()
    if frame_ik.grip_offset_frame == frame_id and frame_ik.grip_pos_rel ~= nil and frame_ik.grip_rot_rel ~= nil then
        return frame_ik.grip_pos_rel, frame_ik.grip_rot_rel
    end

    local lh_pos, lh_rot = get_motion_wrist_pose("left")
    local rh_pos, rh_rot = get_motion_wrist_pose("right")
    if lh_pos == nil or lh_rot == nil or rh_pos == nil or rh_rot == nil then
        return nil, nil
    end

    local rh_inv = rh_rot:conjugate()
    local delta = Vector3f.new(lh_pos.x - rh_pos.x, lh_pos.y - rh_pos.y, lh_pos.z - rh_pos.z)
    local pos_rel = rh_inv * delta
    local rot_rel = (rh_inv * lh_rot):normalized()

    frame_ik.grip_pos_rel = pos_rel
    frame_ik.grip_rot_rel = rot_rel
    frame_ik.grip_offset_frame = frame_id
    return pos_rel, rot_rel
end

local function matrix_to_pos_rot(mat)
    if mat == nil then return nil, nil end
    local pos = Vector3f.new(mat[3].x, mat[3].y, mat[3].z)
    local ok, rot = pcall(function() return mat:to_quat():normalized() end)
    return pos, ok and rot or nil
end

local function build_matrix_from_pos_rot(pos, rot)
    if pos == nil or rot == nil then
        return nil
    end
    rot = quat_from_vr_rotation(rot) or Quaternion.identity()
    local m = rot:to_mat4()
    m[3] = Vector4f.new(pos.x, pos.y, pos.z, 1.0)
    return m
end

local function compute_hand_offset_relative_to_weapon(lh_mat, rh_mat)
    local lh_pos, lh_rot = matrix_to_pos_rot(lh_mat)
    local rh_pos, rh_rot = matrix_to_pos_rot(rh_mat)
    if lh_pos == nil or lh_rot == nil or rh_pos == nil or rh_rot == nil then
        return nil, nil
    end
    local rh_inv = rh_rot:conjugate()
    local delta = Vector3f.new(lh_pos.x - rh_pos.x, lh_pos.y - rh_pos.y, lh_pos.z - rh_pos.z)
    local pos_rel = rh_inv * delta
    local rot_rel = (rh_inv * lh_rot):normalized()
    return pos_rel, rot_rel
end

-- Invert lh = rh + rh*pos_rel and lh_rot = rh_rot*rot_rel to recover weapon-hand pre-recoil pose.
local function reconstruct_weapon_hand_matrix_from_support(lh_mat, pos_rel, rot_rel)
    local lh_pos, lh_rot = matrix_to_pos_rot(lh_mat)
    if lh_pos == nil or lh_rot == nil or pos_rel == nil or rot_rel == nil then
        return nil
    end
    local rh_rot = (lh_rot * rot_rel:conjugate()):normalized()
    local rh_pos = lh_pos - (rh_rot * pos_rel)
    return build_matrix_from_pos_rot(rh_pos, rh_rot)
end

local function build_support_hand_matrix_from_weapon(rh_post_mat, pos_rel, rot_rel)
    if rh_post_mat == nil or pos_rel == nil or rot_rel == nil then
        return nil
    end
    local rh_pos, rh_rot = matrix_to_pos_rot(rh_post_mat)
    if rh_pos == nil or rh_rot == nil then
        return nil
    end
    local lh_pos = rh_pos + (rh_rot * pos_rel)
    local lh_rot = (rh_rot * rot_rel):normalized()
    local new_m = lh_rot:to_mat4()
    new_m[3] = Vector4f.new(lh_pos.x, lh_pos.y, lh_pos.z, 1.0)
    return new_m
end

local function weapon_has_ammo_for_apply(weapon)
    if weapon == nil then
        return false
    end
    local ammo = get_weapon_ammo_count(weapon)
    if ammo < 0 then
        return true
    end
    return ammo > 0
end

local function refresh_frame_recoil_offsets(weapon_for_log)
    if m_recoil_fadeout.active then
        frame_apply.has_recoil = true
        return
    end
    -- Attack phase: springs are 0 while ramping, but recoil IS active.
    if m_attack.active then
        frame_apply.has_recoil = true
        return
    end
    local pos_mag = math.abs(m_recoil.spring_pos_y) + math.abs(m_recoil.spring_pos_z)
    local rot_mag = math.abs(m_recoil.spring_pitch) + math.abs(m_recoil.spring_yaw)
    if pos_mag < 1e-7 and rot_mag < 1e-7 then
        frame_apply.has_recoil = false
        return
    end
    frame_apply.has_recoil = true
    if not CFG.apply_yaw_rotation then
        m_recoil.spring_yaw = 0.0
        m_recoil.spring_vel_yaw = 0.0
    end
end

local function is_support_hand_active_for_recoil()
    return is_two_hand_recoil_active()
end

local function one_hand_global_kick_scale(weight)
    local light = tonumber(CFG.one_hand_light) or 1.18
    local heavy = tonumber(CFG.one_hand_heavy) or 1.9
    if weight == "heavy" then
        return heavy
    end
    if weight == "medium" then
        return light + (heavy - light) * 0.42
    end
    return light
end

local function get_weapon_grip_profile(wtype)
    if type(wtype) ~= "string" or wtype == "" then
        return WEAPON_GRIP_PROFILE.handgun
    end
    return WEAPON_GRIP_PROFILE[wtype] or WEAPON_GRIP_PROFILE.handgun
end

local function update_recoil_grip_state(weapon)
    local weapon_id = ""
    if weapon ~= nil then
        weapon_id = get_weapon_recoil_id(weapon)
    end
    local wtype = resolve_weapon_type(weapon_id) or "handgun"
    local profile = get_weapon_grip_profile(wtype)
    local two_hand = is_support_hand_active_for_recoil()
    local mods = two_hand and profile.two or profile.one
    m_recoil_grip.two_hand = two_hand
    m_recoil_grip.wtype = wtype
    m_recoil_grip.weight = profile.weight
    m_recoil_grip.kick_mult = mods.kick or 1.0
    m_recoil_grip.spring_mult = mods.spring or 1.0
    m_recoil_grip.auto_mult = mods.auto or 1.0
    m_recoil_grip.sustain_mult = mods.sustain or 1.0
    if two_hand then
        m_recoil_grip.global_kick = tonumber(CFG.two_hand_scale) or 0.55
    else
        m_recoil_grip.global_kick = one_hand_global_kick_scale(profile.weight)
    end
    return m_recoil_grip
end

local function apply_recoil_kickback(weapon_for_id)
    if not vr_active() then return end

    local weapon_base = get_per_weapon_intensity(weapon_for_id)
    if weapon_base <= 0.0 then return end

    local weapon_multiplier = weapon_base * CFG.intensity
    if weapon_multiplier <= 0.0 then return end

    local grip = update_recoil_grip_state(weapon_for_id)

    local random_factor = 1.0 + (math.random() - 0.5) * CFG.randomness
    local exp = math.max(0.1, math.min(1.0, CFG.mult_exponent))
    local total_mult = (weapon_multiplier ^ exp) * random_factor

    local grip_kick = (grip.global_kick or 1.0) * (grip.kick_mult or 1.0)
    if grip_kick > 0.0 then
        total_mult = total_mult * grip_kick
    end

    if is_auto_weapon(weapon_for_id) then
        local auto_mult = math.max(0.05, tonumber(CFG.auto_scale) or 0.25)
        auto_mult = auto_mult * (grip.auto_mult or 1.0)
        total_mult = total_mult * auto_mult
    end

    if total_mult <= 0.0 then return end

    local up_ratio = math.max(0.0, tonumber(CFG.position_up_ratio) or 0.0)
    local back_ratio = math.max(0.0, tonumber(CFG.position_back_ratio) or 0.0)
    local pos_peak = CFG.position_intensity * total_mult
    local new_pos_y = pos_peak * up_ratio
    local new_pos_z = -pos_peak * back_ratio

    local pitch_peak = CFG.rotation_intensity * total_mult
    if CFG.vertical_spread > 0.0 then
        pitch_peak = pitch_peak + (math.random() - 0.5) * CFG.vertical_spread * total_mult
    end
    local yaw_peak = 0.0
    if CFG.apply_yaw_rotation then
        yaw_peak = (tonumber(CFG.yaw_intensity) or 0.0) * total_mult
        if CFG.horizontal_spread > 0.0 then
            yaw_peak = yaw_peak + (math.random() - 0.5) * 2.0 * CFG.horizontal_spread * total_mult
        end
    end

    m_attack.pos_y = m_attack.pos_y + new_pos_y
    m_attack.pos_z = m_attack.pos_z + new_pos_z
    m_attack.pitch = m_attack.pitch + pitch_peak
    m_attack.yaw = m_attack.yaw + yaw_peak

    if CFG.stack_cap > 0.0 then
        local cap_pos = CFG.position_intensity * CFG.stack_cap
        local cap_rot = CFG.rotation_intensity * CFG.stack_cap
        local cap_yaw = math.max(tonumber(CFG.yaw_intensity) or 0.0, CFG.horizontal_spread) * CFG.stack_cap
        m_attack.pos_y = math.min(m_attack.pos_y, cap_pos * up_ratio)
        m_attack.pos_z = math.max(m_attack.pos_z, -cap_pos * back_ratio)
        m_attack.pitch = math.min(m_attack.pitch, cap_rot)
        if m_attack.yaw > cap_yaw then m_attack.yaw = cap_yaw end
        if m_attack.yaw < -cap_yaw then m_attack.yaw = -cap_yaw end
    end

    m_attack.t = 0.0
    m_attack.active = true
    m_recoil_active = true

    local now = uptime_now()
    if m_recoil_last_t == 0.0 then
        m_recoil_last_t = now
    end
    m_recoil_last_shot_t = now
end

local function update_recoil(dt)
    dt = math.min(dt, 0.05)

    local player = re2.get_localplayer()
    local current_weapon = get_equipment_weapon(player)

    if m_recoil_fadeout.active and dt > 0.0 then
        m_recoil_fadeout.t = m_recoil_fadeout.t + dt
        if m_recoil_fadeout.t >= m_recoil_fadeout.duration then
            cancel_recoil_state(current_weapon, "fadeout_done")
        end
        return
    end

    if not m_recoil_active and not m_attack.active then
        return
    end

    local now = uptime_now()
    if m_recoil_last_t > 0.0 then
        dt = math.min(now - m_recoil_last_t, 0.05)
    end
    m_recoil_last_t = now

    local attack_duration = CFG.attack_duration
    if attack_duration < 0.001 then attack_duration = 0.001 end

    local grip = update_recoil_grip_state(current_weapon)
    local k = CFG.spring_stiffness * (grip.spring_mult or 1.0)
    local c_base = CFG.spring_damping * (grip.sustain_mult or 1.0)
    local c_sustained = CFG.sustained_damping * (grip.sustain_mult or 1.0)
    local sustained_window = CFG.sustained_window
    if sustained_window < 0.01 then sustained_window = 0.01 end

    if m_attack.active and dt > 0.0 then
        m_attack.t = m_attack.t + dt

        if m_attack.t >= attack_duration then
            local prev_pitch = m_recoil.spring_pitch
            local peak_pitch = m_attack.pitch
            m_recoil.spring_pos_y = m_attack.pos_y
            m_recoil.spring_pos_z = m_attack.pos_z
            m_recoil.spring_pitch = peak_pitch
            m_recoil.spring_yaw = m_attack.yaw
            m_recoil.spring_vel_y = 0.0
            m_recoil.spring_vel_z = 0.0
            m_recoil.spring_vel_pitch = 0.0
            m_recoil.spring_vel_yaw = 0.0
            m_attack.pos_y = 0.0
            m_attack.pos_z = 0.0
            m_attack.pitch = 0.0
            m_attack.yaw = 0.0
            m_attack.t = 0.0
            m_attack.active = false
        else
            local s = math.sin((m_attack.t / attack_duration) * PI_HALF)
            m_recoil.spring_pos_y = m_attack.pos_y * s
            m_recoil.spring_pos_z = m_attack.pos_z * s
            m_recoil.spring_pitch = m_attack.pitch * s
            m_recoil.spring_yaw = m_attack.yaw * s
            m_recoil.spring_vel_y = 0.0
            m_recoil.spring_vel_z = 0.0
            m_recoil.spring_vel_pitch = 0.0
            m_recoil.spring_vel_yaw = 0.0
        end
    end

    if not m_attack.active and dt > 0.0 then
        local c = c_base
        if m_recoil_last_shot_t > 0.0 then
            local since_last = now - m_recoil_last_shot_t
            if since_last < sustained_window then
                local t_blend = 1.0 - (since_last / sustained_window)
                c = c + (c_sustained - c) * t_blend
            end
        end

        local settle_mult = math.max(1.0, tonumber(CFG.spring_settle_mult) or 4.5)
        local steps = math.max(1, math.floor(dt / CFG.substep_dt))
        local sub = dt / steps

        local function spring_channel_damping(pos, vel, base_c, settle_start, snap_pos, snap_vel)
            local pos_abs = math.abs(pos)
            local c_eff = base_c
            if pos_abs < settle_start then
                local blend = 1.0 - (pos_abs / settle_start)
                c_eff = base_c * (1.0 + blend * (settle_mult - 1.0))
            end
            local accel = -k * pos - c_eff * vel
            vel = vel + accel * sub
            pos = pos + vel * sub
            if math.abs(pos) < snap_pos and math.abs(vel) < snap_vel then
                return 0.0, 0.0
            end
            return pos, vel
        end

        local pitch_before_settle = m_recoil.spring_pitch
        for _ = 1, steps do
            m_recoil.spring_pos_y, m_recoil.spring_vel_y = spring_channel_damping(
                m_recoil.spring_pos_y, m_recoil.spring_vel_y, c, 0.002, 0.00003, 0.0006)
            m_recoil.spring_pos_z, m_recoil.spring_vel_z = spring_channel_damping(
                m_recoil.spring_pos_z, m_recoil.spring_vel_z, c, 0.002, 0.00003, 0.0006)
            m_recoil.spring_pitch, m_recoil.spring_vel_pitch = spring_channel_damping(
                m_recoil.spring_pitch, m_recoil.spring_vel_pitch, c, 0.04, 0.007, 0.06)
            m_recoil.spring_yaw, m_recoil.spring_vel_yaw = spring_channel_damping(
                m_recoil.spring_yaw, m_recoil.spring_vel_yaw, c, 0.025, 0.005, 0.05)
        end

        local pos_mag = math.abs(m_recoil.spring_pos_y) + math.abs(m_recoil.spring_pos_z)
        local rot_mag = math.abs(m_recoil.spring_pitch) + math.abs(m_recoil.spring_yaw)
        local vel_mag = math.abs(m_recoil.spring_vel_y) + math.abs(m_recoil.spring_vel_z)
            + math.abs(m_recoil.spring_vel_pitch) + math.abs(m_recoil.spring_vel_yaw)

        if pos_mag < 0.00003 and rot_mag < 0.00012 and vel_mag < 0.0005 then
            begin_recoil_fadeout()
        end
    end
end

local function process_recoil_physics()
    local frame_id = get_game_frame_id()
    if frame_id == last_physics_frame then
        return
    end
    last_physics_frame = frame_id

    if not vr_active() then
        m_pending_recoil_shots = 0
        frame_apply.weapon_has_ammo = false
        frame_apply.two_handed = false
        frame_apply.has_recoil = false
        return
    end

    local player = re2.get_localplayer()
    local current_weapon = get_equipment_weapon(player)
    local _, cached_weapon = get_equipped_recoil_state()
    if cached_weapon ~= nil then
        current_weapon = cached_weapon
    end
    if not weapon_recoil_supported(get_weapon_recoil_id(current_weapon)) then
        m_pending_recoil_shots = 0
        frame_apply.weapon_has_ammo = false
        frame_apply.two_handed = false
        frame_apply.has_recoil = false
        return
    end
    update_recoil_grip_state(current_weapon)
    local two_handed = is_two_handed()

    local pending = m_pending_recoil_shots
    m_pending_recoil_shots = 0

    local apply_pending = pending > 0
    if apply_pending then
        local n = pending
        if n > 10 then n = 10 end
        for _ = 1, n do
            apply_recoil_kickback(current_weapon)
        end
    end

    if not apply_pending and current_weapon ~= nil then
        -- Recoil is driven entirely by the requestFire hook; ammo-delta detection is
        -- disabled because it fired phantom kickbacks during reload animations when
        -- the ammo field briefly showed a stale intermediate count (e.g. 2→0 on
        -- slide-rack), producing a spurious second recoil animation after the last shot.
        m_recoil_last_weapon = current_weapon
        m_recoil_last_ammo_count = get_weapon_ammo_count(current_weapon)
    else
        -- Pending shots consumed above; reset ammo tracking for next call.
        m_recoil_last_weapon = current_weapon
        m_recoil_last_ammo_count = -1
    end

    local dt = 0.0
    if m_recoil_last_t > 0.0 then
        dt = math.min(uptime_now() - m_recoil_last_t, 0.05)
    else
        dt = 1.0 / 60.0
    end
    update_recoil(dt)

    frame_apply.two_handed = two_handed
    frame_apply.weapon_has_ammo = weapon_has_ammo_for_apply(current_weapon)
    refresh_frame_recoil_offsets(current_weapon)
    capture_frame_ik_recoil()
    suppress_native_recoil_for_equipped_weapon()
end

local function get_arm_fit_data(arm_fit)
    if arm_fit == nil then return nil end

    local arm_fit_list = nil
    pcall(function() arm_fit_list = arm_fit:get_field("ArmFitList") end)
    if arm_fit_list == nil then return nil end

    if type(arm_fit_list.get_element) == "function" then
        local ok, elem = pcall(function() return arm_fit_list:get_element(0) end)
        if ok and elem ~= nil then
            return elem
        end
    end

    local elems = nil
    pcall(function() elems = arm_fit_list:get_elements() end)
    if elems and #elems > 0 then
        return elems[1]
    end
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

    local function side_from_solver(solver)
        if solver == nil then return nil, nil end
        local apply_joint = nil
        pcall(function() apply_joint = solver:get_field("<ApplyJoint>k__BackingField") end)
        if apply_joint == nil then
            pcall(function() apply_joint = solver:get_field("ApplyJoint") end)
        end
        if apply_joint == nil then return nil, nil end

        local joint_hash = nil
        pcall(function() joint_hash = apply_joint:call("get_NameHash") end)
        if joint_hash ~= nil then
            if r_arm_wrist_hash ~= nil and joint_hash == r_arm_wrist_hash then
                return "right", "joint_hash"
            end
            if l_arm_wrist_hash ~= nil and joint_hash == l_arm_wrist_hash then
                return "left", "joint_hash"
            end
        end

        local ok_name, joint_name = pcall(function() return apply_joint:call("get_Name") end)
        if ok_name and type(joint_name) == "string" then
            if joint_name == "r_arm_wrist" then
                return "right", "joint_name"
            end
            if joint_name == "l_arm_wrist" then
                return "left", "joint_name"
            end
        end
        return nil, nil
    end

    if type(raw_list.get_elements) == "function" then
        local elems = nil
        pcall(function() elems = raw_list:get_elements() end)
        if elems then
            for _, solver in ipairs(elems) do
                local side, method = side_from_solver(solver)
                if side ~= nil then
                    return side, method
                end
            end
        end
    end

    if type(raw_list.get_element) == "function" then
        for i = 0, 7 do
            local ok, solver = pcall(function() return raw_list:get_element(i) end)
            if ok and solver ~= nil then
                local side, method = side_from_solver(solver)
                if side ~= nil then
                    return side, method
                end
            end
        end
    end

    return nil, nil
end

local function ensure_target_matrix_field_offset(arm_fit_data)
    if target_matrix_field_offset ~= nil then
        return target_matrix_field_offset, target_matrix_field_name
    end
    if arm_fit_data == nil then return nil, nil end

    local td = arm_fit_data:get_type_definition()
    if td == nil then return nil, nil end

    for _, field_name in ipairs({ "<TargetMatrix>k__BackingField", "TargetMatrix" }) do
        local field = td:get_field(field_name)
        if field ~= nil then
            local ok, offset = pcall(function() return field:get_offset_from_base() end)
            if ok and type(offset) == "number" and offset >= 0 then
                target_matrix_field_offset = offset
                target_matrix_field_name = field_name
                return offset, field_name
            end
        end
    end
    return nil, nil
end

local function read_target_matrix(arm_fit_data)
    if arm_fit_data == nil then return nil, nil end
    local offset, field_name = ensure_target_matrix_field_offset(arm_fit_data)
    if offset ~= nil then
        local mat = Matrix4x4f.new()
        for i = 0, 3 do
            local base = offset + i * 16
            mat[i] = Vector4f.new(
                arm_fit_data:read_float(base + 0),
                arm_fit_data:read_float(base + 4),
                arm_fit_data:read_float(base + 8),
                arm_fit_data:read_float(base + 12))
        end
        return mat, field_name
    end
    for _, name in ipairs({ "<TargetMatrix>k__BackingField", "TargetMatrix" }) do
        local ok, matrix = pcall(function() return arm_fit_data:get_field(name) end)
        if ok and matrix ~= nil then
            return matrix, name
        end
    end
    return nil, nil
end

local function get_wrist_side_from_target_matrix(arm_fit_data)
    local mat = read_target_matrix(arm_fit_data)
    if mat == nil or mat[3] == nil then
        return nil, nil, nil, nil, nil
    end
    local target_pos = Vector3f.new(mat[3].x, mat[3].y, mat[3].z)
    -- 2026-08-14: prefer the right wrist's own last-known native target
    -- (frame_ik.rh_last_known_matrix, populated unconditionally every time
    -- the right branch of patch_ik_target_matrix runs, at most one IK call
    -- stale) over get_hand_world_pos("right")'s camera-relative
    -- reconstruction -- confirmed live this reconstruction drifts enough
    -- under head/body orientation divergence (player looking far off-axis
    -- from the character's facing) to flip which arm_fit_data this function
    -- decides is "right", which snapped the weapon's aim to the support
    -- hand's pose ("aiming backwards") once the RG+LG latch made a genuinely
    -- continuous docked left hand possible for the first time. The native
    -- target is real world-space, not a reconstruction, so it can't drift
    -- with head orientation at all. Falls back to the old method only if the
    -- cache isn't populated yet (e.g. very first IK call of a session). See
    -- re2_vr_real_weapon_grip_attempt memory.
    local rh = nil
    if frame_ik.rh_last_known_matrix ~= nil and frame_ik.rh_last_known_matrix[3] ~= nil then
        local p = frame_ik.rh_last_known_matrix[3]
        rh = Vector3f.new(p.x, p.y, p.z)
    else
        rh = get_hand_world_pos("right")
    end
    local lh = get_hand_world_pos("left")
    if rh == nil or lh == nil then
        return nil, nil, nil, nil, nil
    end
    local dr = vec3_dist(target_pos, rh)
    local dl = vec3_dist(target_pos, lh)
    if math.abs(dr - dl) < 0.03 then
        return nil, nil, dr, dl, target_pos
    end
    if dr < dl then
        return "right", "matrix_near_rh", dr, dl, target_pos
    end
    return "left", "matrix_near_lh", dr, dl, target_pos
end

local function is_left_arm_fit_data(arm_fit_data)
    if arm_fit_data == nil then return nil end
    for _, field_name in ipairs({ "LeftHand", "<LeftHand>k__BackingField" }) do
        local ok, v = pcall(function() return arm_fit_data:get_field(field_name) end)
        if ok and v ~= nil then
            return v == true
        end
    end
    return nil
end

local function get_wrist_side_for_ik_call(arm_fit, arm_fit_data)
    local frame_id = get_game_frame_id()
    if frame_id ~= wrist_side_call_frame then
        max_wrist_side_calls_prev_frame = wrist_side_call_count
        wrist_side_call_count = 0
        wrist_side_call_frame = frame_id
    end
    wrist_side_call_count = wrist_side_call_count + 1

    if frame_id ~= last_ik_frame then
        ik_calls_this_frame = 0
        last_ik_frame = frame_id
    end
    ik_calls_this_frame = ik_calls_this_frame + 1
    local ik_call = wrist_side_call_count

    local side, method = get_wrist_side_from_apply_joint(arm_fit)
    if side ~= nil then
        return side, method
    end

    if is_left_arm_fit_data(arm_fit_data) == false then
        return "right", "arm_fit_right_field"
    end

    local dr, dl, target_pos
    side, method, dr, dl, target_pos = get_wrist_side_from_target_matrix(arm_fit_data)
    if dr ~= nil and dr < WEAPON_NEAR_RIGHT_CONTROLLER_DIST then
        return "right", "near_right_controller"
    end

    -- One-handed: controller-distance mis-labels weapon IK when aiming up/right (call 1 reads as left).
    if not frame_apply.two_handed then
        if max_wrist_side_calls_prev_frame <= 1 and ik_call == 1 then
            return "right", "one_hand_solo_call"
        end
        if ik_call % 2 == 0 then
            return "right", "one_hand_even_call"
        end
        if dr ~= nil and dl ~= nil and math.abs(dr - dl) < 0.03 then
            return "right", "one_hand_ambiguous"
        end
        return "left", "one_hand_odd_call"
    end

    if side ~= nil then
        return side, method
    end

    if ik_call == 1 then
        return "left", "call_order"
    end
    if ik_call == 2 then
        return "right", "call_order"
    end
    return nil, nil
end

local function write_target_matrix_native(arm_fit_data, mat)
    local offset = ensure_target_matrix_field_offset(arm_fit_data)
    if offset == nil or mat == nil then
        return false
    end
    for i = 0, 3 do
        local row = mat[i]
        local base = offset + i * 16
        arm_fit_data:write_float(base + 0, row.x)
        arm_fit_data:write_float(base + 4, row.y)
        arm_fit_data:write_float(base + 8, row.z)
        arm_fit_data:write_float(base + 12, row.w)
    end
    return true
end

local function write_patched_target_matrix(arm_fit_data, field_name, new_m)
    if new_m == nil then
        return false
    end
    local ok_native = write_target_matrix_native(arm_fit_data, new_m)
    if field_name ~= nil then
        pcall(function() arm_fit_data:set_field(field_name, new_m) end)
    end
    return ok_native
end

-- Pitch wrist in local +X so the weapon muzzle kicks up (weapon / one-hand only).
local function build_recoiled_hand_matrix(target_matrix)
    if target_matrix == nil then
        return nil
    end
    local hand_rot = target_matrix:to_quat():normalized()
    local recoil_rot, world_offset = get_wrist_recoil_transform(hand_rot, 1.0)
    if recoil_rot == nil or world_offset == nil then
        return nil
    end

    local pos_v = Vector3f.new(
        target_matrix[3].x + world_offset.x,
        target_matrix[3].y + world_offset.y,
        target_matrix[3].z + world_offset.z)

    local new_m = recoil_rot:to_mat4()
    new_m[3] = Vector4f.new(pos_v.x, pos_v.y, pos_v.z, 1.0)
    return new_m
end

local function patch_support_hand_follow_weapon(rh_post_matrix, pos_rel, rot_rel)
    if pos_rel == nil or rot_rel == nil then
        return nil
    end
    return build_support_hand_matrix_from_weapon(rh_post_matrix, pos_rel, rot_rel)
end

local function get_weapon_hand_pre_for_support(lh_pre_matrix)
    if lh_pre_matrix == nil then
        return nil, nil, nil, "none"
    end
    if frame_ik.rh_ik_pre_matrix ~= nil then
        local pos_rel, rot_rel = compute_hand_offset_relative_to_weapon(lh_pre_matrix, frame_ik.rh_ik_pre_matrix)
        if pos_rel ~= nil then
            return frame_ik.rh_ik_pre_matrix, pos_rel, rot_rel, "same_frame_rh_ik"
        end
    end
    local rh_pos, rh_rot = get_motion_wrist_pose("right")
    if rh_pos ~= nil and rh_rot ~= nil then
        local rh_ref = build_matrix_from_pos_rot(rh_pos, rh_rot)
        if rh_ref ~= nil then
            local pos_rel, rot_rel = compute_hand_offset_relative_to_weapon(lh_pre_matrix, rh_ref)
            if pos_rel ~= nil then
                return rh_ref, pos_rel, rot_rel, "motion_rh_live_offset"
            end
        end
    end
    local sk_pos, sk_rot = get_skeleton_grip_offset_relative_to_weapon()
    if sk_pos == nil then
        return nil, nil, nil, "none"
    end
    local rh_pre = reconstruct_weapon_hand_matrix_from_support(lh_pre_matrix, sk_pos, sk_rot)
    return rh_pre, sk_pos, sk_rot, "skeleton_reconstruct"
end

local function patch_support_hand_ik_target(arm_fit_data, field_name, lh_pre_matrix)
    -- 2026-08-14: while RG is released but the latch still holds (LG
    -- alone), use the WEAPON's own anchor point directly
    -- (re2_vr_cosmetic_dock.lua's __vr_grip_anchor_world_pos/_rot -- muzzle
    -- bone position + a fixed per-weapon offset, republished every frame a
    -- covered weapon is equipped, independent of this file's own now-
    -- superseded engagement logic) as the hand's target pose, instead of a
    -- frozen hand-relative RIGID transform (tried first, reverted here).
    -- The rigid-transform approach assumes the support hand rotates exactly
    -- like a rod fixed to the trigger hand's wrist -- only true very near
    -- the angle it was captured at; a real arm's elbow/shoulder reposition
    -- as the aim swings, so reapplying a frozen rotation across a large aim
    -- change increasingly diverges from a natural pose -- confirmed live:
    -- "the further right I aim, the more my left hand retracts toward my
    -- hip." The weapon anchor has no such problem: it's derived fresh every
    -- frame from the gun's own bone transform, so it rotates correctly with
    -- the gun at any aim angle. See re2_vr_real_weapon_grip_attempt memory.
    if frame_ik.support_hand_latch and not is_right_grip_active() then
        local anchor_pos = rawget(_G, "__vr_grip_anchor_world_pos")
        local anchor_rot = rawget(_G, "__vr_grip_anchor_world_rot")
        if vec3_valid(anchor_pos) and anchor_rot ~= nil then
            local anchor_m = build_matrix_from_pos_rot(anchor_pos, anchor_rot)
            if anchor_m ~= nil then
                local now = uptime_now()
                if (frame_ik.grip_dbg_support_last_log_time or 0) + 0.5 <= now then
                    frame_ik.grip_dbg_support_last_log_time = now
                    log.warn("[re2_vr_recoil] SUPPORT_HAND_DEBUG method=weapon_anchor_direct")
                end
                return write_patched_target_matrix(arm_fit_data, field_name, anchor_m)
            end
        end
        -- anchor unavailable for some reason -- fall through to the normal
        -- path below (imperfect but non-nil) rather than showing nothing.
    end

    local rh_pre, pos_rel, rot_rel, method = get_weapon_hand_pre_for_support(lh_pre_matrix)
    -- 2026-08-14: diagnostic, kept from the real-grip reuse experiment and
    -- retargeted to the new RG+LG latch -- only logs while the latch is
    -- active (never during ordinary RG-only use, since RG alone doesn't
    -- touch the latch at all) so a silent-failure repeat can be told apart
    -- from normal RG behavior. See re2_vr_real_weapon_grip_attempt memory.
    if frame_ik.support_hand_latch then
        local now = uptime_now()
        if (frame_ik.grip_dbg_support_last_log_time or 0) + 0.5 <= now then
            frame_ik.grip_dbg_support_last_log_time = now
            log.warn(string.format(
                "[re2_vr_recoil] SUPPORT_HAND_DEBUG method=%s rh_pre=%s pos_rel=%s rot_rel=%s",
                tostring(method), tostring(rh_pre ~= nil), tostring(pos_rel ~= nil), tostring(rot_rel ~= nil)))
        end
    end

    if rh_pre == nil or pos_rel == nil or rot_rel == nil then
        return write_patched_target_matrix(arm_fit_data, field_name, build_recoiled_hand_matrix(lh_pre_matrix))
    end

    local rh_post = build_recoiled_hand_matrix(rh_pre)
    if rh_post == nil then
        return false
    end

    local lh_post = patch_support_hand_follow_weapon(rh_post, pos_rel, rot_rel)
    local wrote = write_patched_target_matrix(arm_fit_data, field_name, lh_post)
    if frame_ik.support_hand_latch then
        log.warn(string.format("[re2_vr_recoil] SUPPORT_HAND_DEBUG lh_post=%s wrote=%s",
            tostring(lh_post ~= nil), tostring(wrote)))
    end
    return wrote
end

local function resolve_ik_arm_fit_from_args(args)
    if ik_arm_fit_type == nil then
        ik_arm_fit_type = sdk.find_type_definition(NS("IkArmFit"))
    end
    if ik_arm_fit_type == nil then
        return nil
    end

    for i = 2, 10 do
        local obj = sdk.to_managed_object(args[i])
        if obj ~= nil then
            local ok, is_fit = pcall(function() return obj:get_type_definition():is_a(ik_arm_fit_type) end)
            if ok and is_fit then
                return obj
            end
        end
    end
    return nil
end

local function patch_ik_target_matrix(arm_fit_data, wrist_side)
    local target_matrix, field_name = read_target_matrix(arm_fit_data)
    if target_matrix == nil then
        return false
    end

    if is_left_arm_fit_data(arm_fit_data) == false then
        wrist_side = "right"
    end

    -- 2026-08-14: real grip (re2_vr_cosmetic_dock.lua's __vr_real_grip_active)
    -- used to reverse the usual relationship here -- WEAPON's aim blended
    -- toward the real tracked left hand, left hand itself shown untouched or
    -- soft-snapped. Player reported that felt wrong (grip zone effectively
    -- tracked HMD position/gaze rather than the pump handle, no "really
    -- held" feel like RG, still janked while moving) and asked to try zero
    -- real-world-position dependency once gripped. Removed entirely --
    -- should_support_hand_follow_weapon() now returns true whenever real
    -- grip is active (see its definition above), so both branches below are
    -- the SAME unconditional cosmetic-follow path RG already used, no
    -- special-casing needed here anymore. blend_aim_toward_left_hand and the
    -- visual-snap code are left defined but unused (not deleted) in case
    -- this doesn't pan out and needs reverting -- see
    -- re2_vr_real_weapon_grip_attempt memory.

    if wrist_side == "right" then
        frame_ik.rh_ik_pre_matrix = target_matrix
        -- 2026-08-14: also cache into a field reset_frame_ik_state() never
        -- clears (unlike rh_ik_pre_matrix, which gets wiped at the start of
        -- every new frame) -- the frozen-latch-offset path in
        -- patch_support_hand_ik_target needs the right hand's pose
        -- regardless of which wrist's native IK call happens to run first
        -- THIS particular frame, not just when right happens to go before
        -- left. At most one frame stale, imperceptible for a hand pose. See
        -- re2_vr_real_weapon_grip_attempt memory (the "snaps on/off when
        -- moving" symptom this fixes).
        frame_ik.rh_last_known_matrix = target_matrix
        -- 2026-08-13: temporary -- raw native position before
        -- build_recoiled_hand_matrix touches it, so GRIP_DEBUG can tell
        -- whether the pivot instability already exists in the native
        -- target_matrix or gets introduced by recoil's own processing. See
        -- re2_vr_real_weapon_grip_attempt memory.
        frame_ik.grip_dbg_raw_target_pos = target_matrix[3]
        local rh_post = build_recoiled_hand_matrix(target_matrix)
        if rh_post ~= nil and frame_ik.lh_pre_matrix ~= nil and frame_ik.lh_arm_fit_data ~= nil then
            local pos_rel, rot_rel = compute_hand_offset_relative_to_weapon(frame_ik.lh_pre_matrix, target_matrix)
            if pos_rel ~= nil then
                local lh_post = patch_support_hand_follow_weapon(rh_post, pos_rel, rot_rel)
                write_patched_target_matrix(frame_ik.lh_arm_fit_data, frame_ik.lh_field_name, lh_post)
            end
        end
        return write_patched_target_matrix(arm_fit_data, field_name, rh_post)
    end

    if wrist_side == "left" then
        if should_support_hand_follow_weapon() then
            frame_ik.lh_pre_matrix = target_matrix
            frame_ik.lh_arm_fit_data = arm_fit_data
            frame_ik.lh_field_name = field_name
            return patch_support_hand_ik_target(arm_fit_data, field_name, target_matrix)
        end
    end

    local new_m = build_recoiled_hand_matrix(target_matrix)
    return write_patched_target_matrix(arm_fit_data, field_name, new_m)
end

local function sync_recoil_for_ik()
    local frame_id = get_game_frame_id()
    if frame_id ~= ik_physics_sync_frame then
        ik_physics_sync_frame = frame_id
        ik_calls_this_frame = 0
        last_ik_frame = -1
        -- Do NOT reset last_physics_frame here: UpdateMotion may have already run
        -- process_recoil_physics for this frame. Resetting would bypass the gate and
        -- call update_recoil a second time, over-advancing spring physics every frame.
        reset_frame_ik_state()
        process_recoil_physics()
    else
        local _, weapon = get_equipped_recoil_state()
        refresh_frame_recoil_offsets(weapon)
    end
end

-- requestFire can run after the first updateIk in a frame (common when aiming sideways).
-- Apply any pending kick before reading has_recoil so this IK pass can patch TargetMatrix.
-- update_recoil runs here ONLY when a fresh kick was applied mid-frame, then the frame
-- cache is re-captured so all subsequent IK passes in this frame use the same offset.
local function flush_pending_recoil_before_ik()
    local pending = m_pending_recoil_shots
    if pending > 0 then
        m_pending_recoil_shots = 0
        local n = pending
        if n > 10 then n = 10 end
        local weapon = get_equipment_weapon(re2.get_localplayer())
        for _ = 1, n do
            apply_recoil_kickback(weapon)
        end
        -- Reset ammo tracking so the delta-detection path in process_recoil_physics
        -- does not see a stale pre-shot count and fire a second phantom kickback.
        m_recoil_last_weapon = weapon
        m_recoil_last_ammo_count = -1
        -- Seed the frame IK cache with the attack peak so all remaining IK passes
        -- this frame see a stable non-zero offset without calling update_recoil
        -- (which would use dt≈0 because m_recoil_last_t was just set by process_recoil_physics).
        -- Spring physics take over properly from the next frame onwards.
        local fid = get_game_frame_id()
        frame_ik_recoil.frame = fid
        frame_ik_recoil.pitch = m_attack.pitch
        frame_ik_recoil.yaw = m_attack.yaw
        frame_ik_recoil.pos_y = m_attack.pos_y
        frame_ik_recoil.pos_z = m_attack.pos_z
        frame_apply.has_recoil = true
        return
    end

    local _, weapon = get_equipped_recoil_state()
    refresh_frame_recoil_offsets(weapon)
end

local function should_apply_recoil_to_ik_arm(arm_fit, arm_fit_data, side, method)
    last_ik_side_detected = side or "unknown"
    last_ik_side_method = method or "none"

    if is_left_arm_fit_data(arm_fit_data) == false then
        return true
    end

    if side == "right" then
        return true
    end
    if side == "left" then
        return frame_apply.two_handed or is_weapon_grip_active()
    end
    if not frame_apply.two_handed then
        return true
    end
    return true
end

-- Patch ArmFit TargetMatrix before IK runs so the weapon follows recoil.
local function on_pre_update_ik(args)
    if not vr_active() then return end
    if not lua_recoil_active() then return end
    if not get_equipped_recoil_state() then
        rawset(_G, "__vr_recoil_ik_patching", false)
        return
    end

    local ik_frame = get_game_frame_id()
    if ik_frame == ik_recoil_pass_state.frame
        and ik_recoil_pass_state.idle_after_first
        and m_pending_recoil_shots == 0 then
        rawset(_G, "__vr_recoil_ik_patching", false)
        return
    end
    if ik_frame ~= ik_recoil_pass_state.frame then
        ik_recoil_pass_state.frame = ik_frame
        ik_recoil_pass_state.idle_after_first = false
    end

    sync_recoil_for_ik()
    flush_pending_recoil_before_ik()
    suppress_native_recoil_for_equipped_weapon()

    -- 2026-08-14: refresh the RG+LG support-hand latch here unconditionally,
    -- every frame this hook fires, regardless of has_recoil -- the gate
    -- right below needs a fresh read to decide whether to stay open, and
    -- should_support_hand_follow_weapon() (called later, inside
    -- patch_ik_target_matrix) only runs at all if this gate lets it through.
    update_support_hand_latch()

    -- has_recoil is the real IK gate; weapon_has_ammo can read 0 on the same frame as
    -- requestFire (before/at ammo decrement) and was blocking all IK patches while springs ran.
    -- 2026-08-14: also let the RG+LG support-hand latch through this gate
    -- with zero recoil -- the cosmetic follow-weapon patch needs to run
    -- every frame the latch is held, not just the brief window right after a
    -- shot while the recoil spring is still animating. Without this, the
    -- left hand would only stay docked for a few frames after firing.
    -- Formerly gated on is_real_grip_active() (the old real-hand-tracked
    -- system's flag) -- replaced along with that whole system, see
    -- re2_vr_real_weapon_grip_attempt memory.
    if not frame_apply.has_recoil and not frame_ik.support_hand_latch then
        ik_recoil_pass_state.idle_after_first = true
        rawset(_G, "__vr_recoil_ik_patching", false)
        return
    end

    local arm_fit = resolve_ik_arm_fit_from_args(args)
    if arm_fit == nil then return end

    local arm_fit_data = get_arm_fit_data(arm_fit)
    if arm_fit_data == nil then return end

    local side, method = get_wrist_side_for_ik_call(arm_fit, arm_fit_data)
    if not should_apply_recoil_to_ik_arm(arm_fit, arm_fit_data, side, method) then
        return
    end

    -- 2026-08-13: temporary -- captured for GRIP_DEBUG so the next real-grip
    -- test can show whether wrist-side disambiguation (side/method here) is
    -- flip-flopping frame to frame during real grip, which would explain
    -- the pivot-position bistability seen in lh/p diagnostics (real hand
    -- rock steady, pivot alternating between two points every frame). See
    -- re2_vr_real_weapon_grip_attempt memory.
    frame_ik.grip_dbg_wrist_side = side
    frame_ik.grip_dbg_wrist_method = method
    frame_ik.grip_dbg_arm_fit_id = tostring(arm_fit_data)

    rawset(_G, "__vr_recoil_ik_patching", true)
    if patch_ik_target_matrix(arm_fit_data, side) then
        ik_apply_count = ik_apply_count + 1
    end
end

local function on_post_update_ik(retval)
    return retval
end

local function install_ik_hook()
    if ik_hook_installed then return end
    ensure_wrist_hashes()

    ik_arm_fit_type = sdk.find_type_definition(NS("IkArmFit"))
    if not ik_arm_fit_type then
        if not ik_hook_warned then
            log.warn("[re2_vr_recoil] IkArmFit type not found")
            ik_hook_warned = true
        end
        return
    end

    local hooked = 0
    local methods = ik_arm_fit_type:get_methods()
    if methods then
        for _, method in ipairs(methods) do
            if method and method:get_name() == "updateIk" then
                sdk.hook(method, on_pre_update_ik, on_post_update_ik)
                hooked = hooked + 1
            end
        end
    end

    if hooked == 0 then
        local method = ik_arm_fit_type:get_method("updateIk")
        if method then
            sdk.hook(method, on_pre_update_ik, on_post_update_ik)
            hooked = 1
        end
    end

    if hooked == 0 then
        if not ik_hook_warned then
            log.warn("[re2_vr_recoil] IkArmFit.updateIk not found")
            ik_hook_warned = true
        end
        return
    end

    ik_hook_installed = true
    log.info(string.format("[re2_vr_recoil] Hooked IkArmFit.updateIk (%d)", hooked))
end

local function get_chamber_bullet_count()
    local weapon = get_equipment_weapon(re2.get_localplayer())
    if weapon == nil then return -1 end
    local ok, n = pcall(function() return weapon:call("getBulletNumber") end)
    if ok and type(n) == "number" then
        return math.floor(n)
    end
    return -1
end

local function should_cancel_recoil_after_fire()
    if rawget(_G, "__vr_block_fire_when_empty") == true then
        return true
    end
    if rawget(_G, "__vr_manual_reload_enabled") ~= true then
        return false
    end
    if rawget(_G, "__vr_mag_dropped") == true then
        return true
    end
    return get_chamber_bullet_count() <= 0
end

local function should_block_recoil_queue()
    if should_cancel_recoil_after_fire() then
        return true
    end
    -- Block extra kicks while waiting to pump or rack; do not use needs_pump/needs_rack
    -- in post-fire cancel or the shot that just fired loses its queued recoil.
    return rawget(_G, "__vr_needs_pump") == true
        or rawget(_G, "__vr_needs_rack") == true
end

local function should_suppress_recoil_for_fire()
    return should_block_recoil_queue()
end

local function add_pending_recoil_shot()
    if not lua_recoil_active() then return end
    if should_block_recoil_queue() then return end
    suppress_native_recoil_for_equipped_weapon()
    if m_pending_recoil_shots < 20 then
        m_pending_recoil_shots = m_pending_recoil_shots + 1
    end
end

local function on_pre_request_fire(args)
    add_pending_recoil_shot()
end

local function on_post_request_fire(retval)
    local v = retval
    if type(v) == "userdata" or type(v) == "table" then
        pcall(function()
            if v.value__ ~= nil then v = v.value__ end
        end)
    end
    local blocked = should_cancel_recoil_after_fire() or tonumber(v) == 0
    if blocked then
        cancel_recoil_state(get_equipment_weapon(re2.get_localplayer()), "post_fire_blocked")
        m_pending_recoil_shots = 0
    end
    return retval
end

local function try_hook_request_fire(type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then return false end
    local method = td:get_method("requestFire")
    if not method then return false end
    sdk.hook(method, on_pre_request_fire, on_post_request_fire)
    log.info(string.format("[re2_vr_recoil] Hooked %s.requestFire", type_name))
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

-- Lua API only exposes on_pre_application_entry (not post). IK pre-hook syncs physics;
-- pre entries + on_frame cover the rest of the frame.
re.on_pre_application_entry("UpdateMotion", function()
    sim_frame = get_game_frame_id()
    process_recoil_physics()
end)

re.on_pre_application_entry("LateUpdateBehavior", function()
    process_recoil_physics()
end)

re.on_pre_application_entry("UpdateBehavior", function()
    bootstrap_settings()
end)

re.on_frame(function()
    sim_frame = sim_frame + 1
    if lua_recoil_active() and get_equipped_recoil_state() then
        process_recoil_physics()
    end
    ik_apply_count = 0
    if lua_recoil_active() then
        if not fire_hooks_installed then
            install_fire_hooks()
        end
        if not ik_hook_installed then
            install_ik_hook()
        end
        if CFG.suppress_camera_recoil and not camera_recoil_hooks_installed then
            install_camera_recoil_hooks()
        end
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

local function draw_recoil_ui()
    local c, v

    imgui.text_colored("Recoil:", UI_ACCENT)

    do
        c, v = draw_feature_enable_toggle(CFG.enabled, "recoil_enable", "Recoil")
        if c then
            CFG.enabled = v
            save_cfg()
        end
    end

    if CFG.enabled and not CFG.use_native_recoil then
        do
            c, v = imgui.slider_float("Recoil intensity", CFG.intensity, 0.0, 3.0, "%.2f")
            if c then
                CFG.intensity = v
                save_cfg()
            end
        end
        imgui.text_colored("Two-hand grip reduces recoil; ratio is fixed.", UI_MUTED)

        imgui.separator()
        local weapon = get_equipment_weapon(re2.get_localplayer())
        local weapon_id = get_weapon_recoil_id(weapon)
        if weapon_id == "" then
            imgui.text_colored("Current weapon: none", UI_MUTED)
        else
            imgui.text_colored("Current weapon: " .. weapon_display_name(weapon_id), UI_ACCENT)
            if not weapon_recoil_supported(weapon_id) then
                imgui.text_colored("Recoil not applicable for this item.", UI_MUTED)
            else
                local per_weapon = get_per_weapon_intensity(weapon)
                c, v = imgui.slider_float("Weapon recoil", per_weapon, 1.0, 4.0, "%.2f")
                if c then
                    set_per_weapon_intensity(weapon_id, v)
                    save_cfg()
                end
            end
        end
    end

    imgui.separator()
    imgui.separator()
end

_G.__vr_ui_callbacks = _G.__vr_ui_callbacks or {}
table.insert(_G.__vr_ui_callbacks, { order = 42, fn = draw_recoil_ui })

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

bootstrap_settings()
if lua_recoil_active() then
    install_fire_hooks()
    install_ik_hook()
    if CFG.suppress_camera_recoil then
        install_camera_recoil_hooks()
    end
end
log.info(string.format(
    "[re2_vr_recoil] Loaded (mode=%s) cfg=%s",
    CFG.use_native_recoil and "native" or "lua-ik",
    CFG_PATH))

return {}
