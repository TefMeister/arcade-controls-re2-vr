if reframework:get_game_name() ~= "re2" then
    return {}
end

if not vrmod then
    return {}
end

local re2 = require("utility/RE2")
local statics = require("utility/Statics")
local vr_char = require("utility/RE2Character")
local vrc_manager = require("vr/VRControllerManager")

local CFG_PATH = "re2_vr/re2_vr_holster.json"

local function imgui_col(r, g, b, a)
    a = a or 255
    return ((a & 0xFF) << 24) | ((b & 0xFF) << 16) | ((g & 0xFF) << 8) | (r & 0xFF)
end

local UI_ACCENT = imgui_col(136, 204, 255)
local UI_BTN = imgui_col(64, 224, 208)
local UI_ENABLE = imgui_col(0, 255, 0)
local UI_DISABLE = imgui_col(255, 64, 64)
local UI_MUTED = imgui_col(136, 136, 136)

local NS = sdk.game_namespace

local WeaponTypeEnum = statics.generate(NS("EquipmentDefine.WeaponType"))
local EquipCategoryEnum = statics.generate(NS("EquipmentDefine.EquipCategory"))
local WeaponPartsEnum = statics.generate(NS("EquipmentDefine.WeaponParts"))

local equipment_type = sdk.typeof(NS("survivor.Equipment"))
local inventory_type = sdk.typeof(NS("survivor.Inventory"))

local WP = { id_by_enum = nil, enum_by_id = nil }

local function enum_value(o)
    if o == nil then return nil end
    if type(o) == "number" then return o end
    local ok, v = pcall(function() return o:get_field("value__") end)
    if ok and type(v) == "number" then return v end
    return nil
end

local function block_weapon_inputs_active()
    return rawget(_G, "__vr_block_weapon_inputs") == true
end

local function manual_reload_blocks_holster()
    -- Allow weapon holsters during manual reload when mag is dropped/out.
    -- Block only when mag workflow physically conflicts (hand, insert, release fall).
    if rawget(_G, "__vr_mag_blocks_weapon_holster") == true then return true end
    if rawget(_G, "__vr_mag_in_left_hand") == true then return true end
    return false
end

local PISTOL_IDS = {
    [0] = true, [100] = true, [200] = true, [300] = true, [400] = true,
    [600] = true, [700] = true, [800] = true,
}

local LONGARM_IDS = {
    [1000] = true, [1100] = true, [2200] = true,
    [4100] = true, [4000] = true,
}

--- wp2000 (MQ 11) intentionally lives here, not LONGARM_IDS -- player wants
--- it drawn/stowed at the chest/left-hip slot instead of the shoulder.
local CHEST_IDS = {
    [3000] = true, [3200] = true, [2000] = true,
}

--- Heavy/special weapons: Chemical Flamethrower, Spark Shot, Anti-Tank
--- Rocket, Minigun. Drawn/stowed at the head position (RG reach), same
--- mechanic as the other 3 holster slots.
local SPECIAL_IDS = {
    [4200] = true, [4300] = true, [4600] = true, [4700] = true,
}

local EXCLUDED_IDS = {
    [4500] = true, [4510] = true, [4530] = true,
    [4400] = true, [4900] = true,
}
for gid = 6200, 6310 do
    EXCLUDED_IDS[gid] = true
end

local function is_pistol_category(wid)
    return wid and PISTOL_IDS[wid] == true
end

local function is_longarm_category(wid)
    return wid and LONGARM_IDS[wid] == true
end

local function is_chest_slot_weapon(wid)
    return wid and CHEST_IDS[wid] == true
end

local function is_special_slot_weapon(wid)
    return wid and SPECIAL_IDS[wid] == true
end

--- Hip = pistols only; shoulder = longarms only; chest = magnums / grenade-slot weapons; special = heavy weapons (head position).
local function holster_slot_for_weapon_id(wid)
    if not wid then return nil end
    if is_pistol_category(wid) then return "pistol" end
    if is_longarm_category(wid) then return "longarm" end
    if is_chest_slot_weapon(wid) then return "chest" end
    if is_special_slot_weapon(wid) then return "special" end
    return nil
end

local function weapon_id_matches_holster_slot(wid, slot)
    if not wid or not slot then return false end
    return holster_slot_for_weapon_id(wid) == slot
end

--- wp0000 uses id 0; use guid/wp key, not `last_pistol ~= 0`.
local function profile_has_stowed_pistol(P)
    return (type(P.last_pistol_guid) == "string" and P.last_pistol_guid ~= "")
        or (type(P.last_pistol_wp) == "string" and P.last_pistol_wp ~= "")
end

local function profile_has_stowed_longarm(P)
    return (type(P.last_longarm_wp) == "string" and P.last_longarm_wp ~= "")
        or P.last_longarm ~= 0
end

local function profile_has_stowed_chest(P)
    return (type(P.last_revolver_wp) == "string" and P.last_revolver_wp ~= "")
        or P.last_revolver ~= 0
end

local function profile_has_stowed_special(P)
    return (type(P.last_special_wp) == "string" and P.last_special_wp ~= "")
        or P.last_special ~= 0
end

local function profile_has_stowed_for_slot(P, slot)
    if slot == "pistol" then return profile_has_stowed_pistol(P) end
    if slot == "longarm" then return profile_has_stowed_longarm(P) end
    if slot == "chest" or slot == "revolver" then return profile_has_stowed_chest(P) end
    if slot == "special" then return profile_has_stowed_special(P) end
    return false
end

local HOLSTER_DISABLED_WEAPONS = {}

local function build_weapon_type_maps()
    if WP.enum_by_id and next(WP.enum_by_id) then
        return true
    end
    WP.id_by_enum = {}
    WP.enum_by_id = {}
    local td = sdk.find_type_definition(NS("EquipmentDefine.WeaponType"))
    if not td then
        WP.id_by_enum = nil
        WP.enum_by_id = nil
        return false
    end
    for _, field in ipairs(td:get_fields()) do
        if field:is_static() then
            local fn = field:get_name()
            local num = fn:match("^WP(%d+)$")
            if num then
                local wid = tonumber(num)
                local data = field:get_data(nil)
                if data and wid then
                    WP.enum_by_id[wid] = data
                    local ev = enum_value(data)
                    if type(ev) == "number" then
                        WP.id_by_enum[ev] = wid
                    end
                    WP.id_by_enum[data] = wid
                end
            end
        end
    end
    if WeaponTypeEnum then
        for k, v in pairs(WeaponTypeEnum) do
            local num = tostring(k):match("^WP(%d+)$")
            if num then
                local wid = tonumber(num)
                WP.enum_by_id[wid] = v
                WP.id_by_enum[v] = wid
            end
        end
    end
    return true
end

local function weapon_type_to_wp_id(wt)
    if wt == nil then return nil end
    build_weapon_type_maps()
    if WP.id_by_enum[wt] then return WP.id_by_enum[wt] end
    local ev = enum_value(wt)
    if ev and WP.id_by_enum[ev] then return WP.id_by_enum[ev] end
    return nil
end

--- Canonical display / config key: wp0000, wp0100, ...
local function wp_id_to_key(wp_id)
    if type(wp_id) ~= "number" or wp_id < 0 then return nil end
    return string.format("wp%04d", wp_id)
end

--- Parse wp0000 / WP0000 / 100 -> numeric weapon id (nil if invalid).
local function wp_key_to_id(key)
    if key == nil then return nil end
    if type(key) == "number" then
        if key >= 0 and not EXCLUDED_IDS[key] then return key end
        return nil
    end
    if type(key) ~= "string" then return nil end
    key = key:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if key == "" then return nil end
    local wp = key:match("^wp(%d+)$")
    if wp then
        local n = tonumber(wp)
        if n and n >= 0 and not EXCLUDED_IDS[n] then return n end
        return nil
    end
    local n = tonumber(key)
    if n and n >= 0 and not EXCLUDED_IDS[n] then return n end
    return nil
end

local function is_valid_wp_id(wp_id)
    return type(wp_id) == "number" and wp_id >= 0 and not EXCLUDED_IDS[wp_id]
end

local function make_weapon_type_enum(wp_id_or_key)
    local wp_id = type(wp_id_or_key) == "string" and wp_key_to_id(wp_id_or_key) or wp_id_or_key
    if not is_valid_wp_id(wp_id) then return nil end
    build_weapon_type_maps()
    local wt = WP.enum_by_id[wp_id]
    if wt then return wt end
    local enum_name = string.format("WP%04d", wp_id)
    if WeaponTypeEnum and WeaponTypeEnum[enum_name] then
        return WeaponTypeEnum[enum_name]
    end
    return nil
end

local function sync_profile_wp_key(P, slot, wp_id)
    local key = wp_id_to_key(wp_id)
    if slot == "pistol" then
        P.last_pistol_wp = key or ""
    elseif slot == "longarm" then
        P.last_longarm_wp = key or ""
    elseif slot == "chest" or slot == "revolver" then
        P.last_revolver_wp = key or ""
    elseif slot == "special" then
        P.last_special_wp = key or ""
    end
end

local function resolve_profile_weapon_id(P, slot)
    local wid, guid, wp_key = 0, "", ""
    if slot == "pistol" then
        wid, guid, wp_key = P.last_pistol, P.last_pistol_guid, P.last_pistol_wp or ""
    elseif slot == "longarm" then
        wid, guid, wp_key = P.last_longarm, P.last_longarm_guid, P.last_longarm_wp or ""
    elseif slot == "chest" or slot == "revolver" then
        wid, guid, wp_key = P.last_revolver, P.last_revolver_guid, P.last_revolver_wp or ""
    elseif slot == "special" then
        wid, guid, wp_key = P.last_special, P.last_special_guid, P.last_special_wp or ""
    end
    if type(wp_key) == "string" and wp_key ~= "" then
        local from_key = wp_key_to_id(wp_key)
        if from_key ~= nil then wid = from_key end
    end
    return wid, guid
end

local CFG = {
    enabled = true,
    hip_pistol_enabled = true,
    shoulder_enabled = true,
    chest_enabled = true,
    special_enabled = true,
    block_swap_anims = true,
    suppress_motion_layers = { 0, 2, 3, 5 },
    use_holster_sfx = false,
    zone_haptic_enabled = true,
    hip_zone_haptic_enabled = true,
    hip_zone_haptic_continuous = false,
    shoulder_zone_haptic_enabled = true,
    shoulder_zone_haptic_continuous = false,
    chest_zone_haptic_enabled = true,
    chest_zone_haptic_continuous = false,
    special_zone_haptic_enabled = true,
    special_zone_haptic_continuous = false,
    zone_haptic_duration = 0.08,
    zone_haptic_frequency = 180.0,
    zone_haptic_amplitude = 0.45,
    zone_haptic_frames = 3,
    haptic_intensity = 1.0,
    grab_haptic_duration = 0.06,
    grab_haptic_frequency = 200.0,
    grab_haptic_amplitude = 0.7,
    suppress_shoot_ready_after_holster_equip = true,
    suppress_shoot_ready_after_holster_s = 0.45,
    suppress_shoot_ready_in_holster_zone = true,
    head_flashlight_enabled = true,
}

local PROFILE_KEYS = {
    "hip_pistol_off_right", "hip_pistol_off_up", "hip_pistol_off_forward",
    "hip_pistol_trigger_dist", "hip_pistol_release_dist", "hip_pistol_cooldown",
    "shoulder_off_x", "shoulder_off_y", "shoulder_off_z",
    "shoulder_trigger_dist", "shoulder_release_dist", "shoulder_cooldown",
    "chest_off_x", "chest_off_y", "chest_off_z",
    "chest_trigger_dist", "chest_release_dist", "chest_cooldown",
    "last_pistol", "last_longarm", "last_revolver", "last_special",
    "last_pistol_wp", "last_longarm_wp", "last_revolver_wp", "last_special_wp",
    "last_pistol_guid", "last_longarm_guid", "last_revolver_guid", "last_special_guid",
    "special_off_x", "special_off_y", "special_off_z",
    "special_trigger_dist", "special_release_dist", "special_cooldown",
}

local function make_default_profile()
    return {
        hip_pistol_off_right = 0.0,
        hip_pistol_off_up = 0.0,
        hip_pistol_off_forward = 0.0,
        hip_pistol_trigger_dist = 0.25,
        hip_pistol_release_dist = 0.38,
        hip_pistol_cooldown = 0.6,
        shoulder_off_x = 0.0,
        shoulder_off_y = 0.0,
        shoulder_off_z = 0.0,
        shoulder_trigger_dist = 0.40,
        shoulder_release_dist = 0.50,
        shoulder_cooldown = 0.6,
        chest_off_x = 0.0,
        chest_off_y = 0.0,
        chest_off_z = 0.0,
        chest_trigger_dist = 0.40,
        chest_release_dist = 0.50,
        chest_cooldown = 0.6,
        last_pistol = 0,
        last_longarm = 0,
        last_revolver = 0,
        last_special = 0,
        last_pistol_wp = "",
        last_longarm_wp = "",
        last_revolver_wp = "",
        last_special_wp = "",
        last_pistol_guid = "",
        last_longarm_guid = "",
        last_revolver_guid = "",
        last_special_guid = "",
        special_off_x = 0.0,
        special_off_y = 0.27,
        special_off_z = 0.0,
        special_trigger_dist = 0.22,
        special_release_dist = 0.34,
        special_cooldown = 0.5,
    }
end

--- Leon's holster positions tuned via live in-headset testing (2026-08-02):
--- pistol/longarm pushed further right for reach, chest slot repositioned
--- to a low left-hip spot (via the in-game Calibrate button) to stop it
--- swinging into RG's reach when the body turns to follow the HMD. Baked
--- in here so a fresh install (no persisted JSON yet) still starts Leon
--- with a good fit instead of raw 0.0 offsets.
local function make_leon_default_profile()
    local P = make_default_profile()
    P.hip_pistol_off_right = -0.448550288748239
    P.shoulder_off_x = -0.34600842420778977
    P.shoulder_off_z = 0.00858026132993757
    P.chest_off_x = 0.19062482810372117
    P.chest_off_y = -0.06965267461799048
    P.chest_off_z = 0.20812607422779672
    return P
end

local PROFILES = {
    leon = make_leon_default_profile(),
    claire = make_default_profile(),
    ada = make_default_profile(),
    hunk = make_default_profile(),
    tofu = make_default_profile(),
    carlos = make_default_profile(),
    jill = make_default_profile(),
}

local function safe_call(obj, m, ...)
    if not obj then return nil end
    local ok, a, b, c = pcall(function(...) return obj:call(m, ...) end, ...)
    if not ok then return nil end
    return a, b, c
end

local function managed_type_has_field(obj, field_name)
    if not obj or type(field_name) ~= "string" then return false end
    local ok, td = pcall(function() return obj:get_type_definition() end)
    if not ok or not td then return false end
    local ok2, f = pcall(function() return td:get_field(field_name) end)
    return ok2 and f ~= nil
end

--- set_field logs REFramework errors even inside pcall; only call when the field exists on the runtime type.
local function safe_set_managed_field(obj, field_name, value)
    if not managed_type_has_field(obj, field_name) then return false end
    local ok = pcall(function() obj:set_field(field_name, value) end)
    return ok
end

local function normalize_guid_str(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return string.lower(s)
end

local function arm_instance_key(arm)
    if not arm then return "" end
    local ok, addr = pcall(function() return string.format("%016x", arm:get_address()) end)
    return ok and addr or ""
end

local function coerce_weapon_id(v)
    if v == nil then return 0 end
    if type(v) == "number" then return v >= 0 and v or 0 end
    if type(v) == "string" then
        local id = wp_key_to_id(v)
        if id ~= nil then return id end
    end
    return 0
end

local function normalize_profile_name(name)
    return vr_char.normalize_profile_name(name)
end

local function ensure_profile(key)
    key = normalize_profile_name(key)
    if not PROFILES[key] then
        PROFILES[key] = make_default_profile()
    end
    return PROFILES[key]
end

local function merge_profile_fields(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then return end
    for _, k in ipairs(PROFILE_KEYS) do
        if src[k] ~= nil and dst[k] ~= nil then
            if k:find("^last_") and k:find("guid") then
                if type(src[k]) == "string" then dst[k] = src[k] end
            elseif k:find("^last_") and k:find("_wp$") then
                if type(src[k]) == "string" then dst[k] = src[k]:lower() end
            elseif k:find("^last_") then
                dst[k] = coerce_weapon_id(src[k])
            elseif type(src[k]) == type(dst[k]) then
                dst[k] = src[k]
            end
        end
    end
end

local function profile_key_from_player(player)
    return vr_char.get_active_profile_key(player)
end

local function current_profile_key()
    return profile_key_from_player(re2.get_localplayer())
end

local function get_profile()
    local k = current_profile_key()
    return ensure_profile(k)
end

local function save_cfg()
    pcall(function()
        local data = {}
        for k, v in pairs(CFG) do
            if type(v) ~= "table" then data[k] = v end
        end
        data.suppress_motion_layers = CFG.suppress_motion_layers
        data.profiles = PROFILES
        json.dump_file(CFG_PATH, data)
    end)
end

local function apply_loaded_cfg(data, loaded_profile_keys)
    if type(data) ~= "table" then return end
    for k, v in pairs(data) do
        if CFG[k] ~= nil and type(v) == type(CFG[k]) then CFG[k] = v end
    end
    if type(data.suppress_motion_layers) == "table" and #data.suppress_motion_layers > 0 then
        CFG.suppress_motion_layers = data.suppress_motion_layers
    end
    if type(data.profiles) == "table" then
        for char_key, char_data in pairs(data.profiles) do
            local pk = normalize_profile_name(char_key)
            loaded_profile_keys[pk] = true
            if type(char_data) == "table" then
                merge_profile_fields(ensure_profile(pk), char_data)
            end
        end
    end
end

local function load_cfg_from_disk()
    local data = json.load_file(CFG_PATH)
    if type(data) == "table" then
        apply_loaded_cfg(data, {})
    end
    if type(data) == "table" and type(data.hip_zone_haptic_enabled) ~= "boolean" then
        local base = CFG.zone_haptic_enabled ~= false
        CFG.hip_zone_haptic_enabled = base
        CFG.shoulder_zone_haptic_enabled = base
        CFG.chest_zone_haptic_enabled = base
        CFG.special_zone_haptic_enabled = base
    end
    for _, P in pairs(PROFILES) do
        if P.last_pistol ~= 0 and not is_pistol_category(P.last_pistol) then
            P.last_pistol = 0
            P.last_pistol_guid = ""
            P.last_pistol_wp = ""
        end
        if P.last_longarm ~= 0 and not is_longarm_category(P.last_longarm) then
            P.last_longarm = 0
            P.last_longarm_guid = ""
            P.last_longarm_wp = ""
        end
        if P.last_revolver ~= 0 and not is_chest_slot_weapon(P.last_revolver) then
            P.last_revolver = 0
            P.last_revolver_guid = ""
            P.last_revolver_wp = ""
        end
        if P.last_special ~= 0 and not is_special_slot_weapon(P.last_special) then
            P.last_special = 0
            P.last_special_guid = ""
            P.last_special_wp = ""
        end
    end
end

load_cfg_from_disk()

local function get_player()
    return re2.get_localplayer()
end

local function get_player_transform()
    local player = get_player()
    if not player then return nil end
    return safe_call(player, "get_Transform")
end

local function get_player_equipment()
    local player = get_player()
    if not player or not equipment_type then return nil end
    local ok, eq = pcall(function() return player:call("getComponent(System.Type)", equipment_type) end)
    return ok and eq or nil
end

local function get_inventory()
    local eq = get_player_equipment()
    if eq then
        local inv = safe_call(eq, "get_Inventory")
        if inv then return inv end
    end
    local player = get_player()
    if not player or not inventory_type then return nil end
    local ok, inv = pcall(function() return player:call("getComponent(System.Type)", inventory_type) end)
    return ok and inv or nil
end

local function is_bare_hands()
    local eq = get_player_equipment()
    if not eq then return true end
    local wt = safe_call(eq, "get_EquipType")
    if wt == nil then
        wt = safe_call(eq, "get_ActivateType")
    end
    if wt == nil then return get_current_weapon_id() == nil end
    if WeaponTypeEnum and wt == WeaponTypeEnum.BareHand then return true end
    return weapon_type_to_wp_id(wt) == nil
end

local function get_current_weapon_id()
    local eq = get_player_equipment()
    if not eq then return nil end
    local wt = safe_call(eq, "get_EquipType")
    if wt == nil then
        wt = safe_call(eq, "get_ActivateType")
    end
    local wid = weapon_type_to_wp_id(wt)
    if wid == nil then return nil end
    if WeaponTypeEnum and wt == WeaponTypeEnum.BareHand then return nil end
    return wid
end

local function slot_row_key(slot)
    if not slot then return "" end
    local idx = safe_call(slot, "get_Index")
    if idx ~= nil then return tostring(idx) end
    local ok, s = pcall(function() return slot:call("ToString") end)
    return ok and s or ""
end

local function inventory_weapon_rows(inv)
    if not inv then return {} end
    local out = {}
    local slots = safe_call(inv, "get_Slots")
    if slots then
        local n = safe_call(slots, "get_Count") or 0
        for i = 0, n - 1 do
            local slot = safe_call(slots, "get_Item", i)
            if slot then
                local is_wep = safe_call(slot, "get_IsWeapon")
                if is_wep == true or is_wep == 1 then
                    local wt = safe_call(slot, "get_WeaponType")
                    local wid = weapon_type_to_wp_id(wt)
                    if wid ~= nil and is_valid_wp_id(wid) then
                        out[#out + 1] = {
                            slot = slot,
                            wp_id = wid,
                            wp_key = wp_id_to_key(wid),
                            guid_str = slot_row_key(slot),
                        }
                    end
                end
            end
        end
    end
    if #out > 0 then return out end
    local weapon_list = safe_call(inv, "getWeaponList")
    if not weapon_list then return out end
    local wn = safe_call(weapon_list, "get_Count") or 0
    for i = 0, wn - 1 do
        local wt = safe_call(weapon_list, "get_Item", i)
        local wid = weapon_type_to_wp_id(wt)
        if wid ~= nil and is_valid_wp_id(wid) then
            local slot_list = safe_call(inv, "getSlots", wt)
            if slot_list then
                local sn = safe_call(slot_list, "get_Count") or 0
                for j = 0, sn - 1 do
                    local slot = safe_call(slot_list, "get_Item", j)
                    if slot then
                        out[#out + 1] = {
                            slot = slot,
                            wp_id = wid,
                            wp_key = wp_id_to_key(wid),
                            guid_str = slot_row_key(slot),
                        }
                    end
                end
            end
        end
    end
    return out
end

local function find_row_for_weapon(inv, wp_id, prefer_guid, prefer_wp_key)
    if not inv or wp_id == nil then return nil end
    local want = normalize_guid_str(prefer_guid)
    local want_wp = type(prefer_wp_key) == "string" and prefer_wp_key:lower() or nil
    local rows = inventory_weapon_rows(inv)
    if want then
        for _, row in ipairs(rows) do
            if normalize_guid_str(row.guid_str) == want then return row end
        end
    end
    if want_wp and want_wp ~= "" then
        for _, row in ipairs(rows) do
            if row.wp_key == want_wp then return row end
        end
    end
    for _, row in ipairs(rows) do
        if row.wp_id == wp_id then return row end
    end
    return nil
end

local function get_equipped_main_slot_key(inv)
    if not inv then return "" end
    local main = safe_call(inv, "get_MainSlot")
    return slot_row_key(main)
end

local function equipment_has_method(equipment, method_name)
    if not equipment or type(method_name) ~= "string" then return false end
    local ok, td = pcall(function() return equipment:get_type_definition() end)
    if not ok or not td then return false end
    local ok2, m = pcall(function() return td:get_method(method_name) end)
    return ok2 and m ~= nil
end

local function inventory_has_method(inv, method_name)
    if not inv or type(method_name) ~= "string" then return false end
    local ok, td = pcall(function() return inv:get_type_definition() end)
    if not ok or not td then return false end
    local ok2, m = pcall(function() return td:get_method(method_name) end)
    return ok2 and m ~= nil
end

local function managed_object_alive(obj)
    if not obj then return false end
    local ok, addr = pcall(function() return obj:get_address() end)
    return ok and addr ~= nil and addr ~= 0
end

-- Cross-holster swap only (requestHolster + immediate equip crashes).
local function native_inventory_unequip_for_swap(inv, wp_id)
    if not inv or wp_id == nil then return false end
    local wt = make_weapon_type_enum(wp_id_to_key(wp_id) or wp_id)
    if not wt or not inventory_has_method(inv, "unequipEquipedWeapon") then return false end
    local ok = pcall(function() inv:call("unequipEquipedWeapon", wt) end)
    return ok == true
end

--- Stow to bare hands: unequip + requestHolster (hip/shoulder toggle-off only).
local function native_holster_stow(equipment, inv, wp_id)
    if not equipment then return false end
    local wt = make_weapon_type_enum(wp_id_to_key(wp_id) or wp_id)
    if inv and wt and inventory_has_method(inv, "unequipEquipedWeapon") then
        pcall(function() inv:call("unequipEquipedWeapon", wt) end)
    end
    if equipment_has_method(equipment, "requestHolster") then
        pcall(function() equipment:call("requestHolster") end)
    end
    return is_bare_hands()
end

--- Draw: changeWeapon first, then equipMainSlot (all pcall).
local function native_equip_row(inv, row)
    if not inv or not row or not managed_object_alive(row.slot) then return false end
    local equipment = get_player_equipment()
    if managed_object_alive(equipment) and row.wp_id ~= nil then
        local wt = make_weapon_type_enum(row.wp_key or row.wp_id)
        if wt and equipment_has_method(equipment, "changeWeapon") then
            local parts = WeaponPartsEnum and WeaponPartsEnum.None or 0
            local cat = EquipCategoryEnum and EquipCategoryEnum.Main or 1
            local ok = pcall(function()
                equipment:call("changeWeapon", cat, wt, parts)
            end)
            if ok then
                local cur = get_current_weapon_id()
                if cur == row.wp_id then return true end
            end
        end
    end
    if inventory_has_method(inv, "equipMainSlot") then
        local ok, result = pcall(function() return inv:call("equipMainSlot", row.slot) end)
        if ok and result == true then
            return true
        end
    end
    return false
end

local function cache_weapon_to_holster_profile(P, wid)
    if not wid then return end
    local inv = get_inventory()
    local wp_key = wp_id_to_key(wid) or ""
    local row = inv and find_row_for_weapon(inv, wid, nil, wp_key) or nil
    local gstr = row and row.guid_str or (inv and get_equipped_main_slot_key(inv) or "")
    if is_pistol_category(wid) then
        P.last_pistol = wid
        P.last_pistol_guid = gstr
        P.last_pistol_wp = row and row.wp_key or wp_key
    elseif is_longarm_category(wid) then
        P.last_longarm = wid
        P.last_longarm_guid = gstr
        P.last_longarm_wp = row and row.wp_key or wp_key
    elseif is_chest_slot_weapon(wid) then
        P.last_revolver = wid
        P.last_revolver_guid = gstr
        P.last_revolver_wp = row and row.wp_key or wp_key
    elseif is_special_slot_weapon(wid) then
        P.last_special = wid
        P.last_special_guid = gstr
        P.last_special_wp = row and row.wp_key or wp_key
    end
end

local function snapshot_holstered_weapon(P)
    cache_weapon_to_holster_profile(P, get_current_weapon_id())
end

local function reconcile_holster_slot_cache(P, slot)
    if profile_has_stowed_for_slot(P, slot) then return end
    local inv = get_inventory()
    if not inv then return end
    for _, row in ipairs(inventory_weapon_rows(inv)) do
        local wid = row.wp_id
        if slot == "pistol" and is_pistol_category(wid) then
            P.last_pistol = wid
            P.last_pistol_guid = row.guid_str
            P.last_pistol_wp = row.wp_key or wp_id_to_key(wid) or ""
            return
        elseif slot == "longarm" and is_longarm_category(wid) then
            P.last_longarm = wid
            P.last_longarm_guid = row.guid_str
            P.last_longarm_wp = row.wp_key or wp_id_to_key(wid) or ""
            return
        elseif (slot == "chest" or slot == "revolver") and is_chest_slot_weapon(wid) then
            P.last_revolver = wid
            P.last_revolver_guid = row.guid_str
            P.last_revolver_wp = row.wp_key or wp_id_to_key(wid) or ""
            return
        elseif slot == "special" and is_special_slot_weapon(wid) then
            P.last_special = wid
            P.last_special_guid = row.guid_str
            P.last_special_wp = row.wp_key or wp_id_to_key(wid) or ""
            return
        end
    end
end

--- phase: 1 = full cross-swap attempt, 2 = equip only (next frame after inventory unequip).
local function equip_weapon_from_profile(P, slot, phase)
    local inv = get_inventory()
    if not inv then return false end
    reconcile_holster_slot_cache(P, slot)
    if not profile_has_stowed_for_slot(P, slot) then return false end
    local wid, guid = resolve_profile_weapon_id(P, slot)
    local wp_key = ""
    if slot == "pistol" then wp_key = P.last_pistol_wp or ""
    elseif slot == "longarm" then wp_key = P.last_longarm_wp or ""
    elseif slot == "special" then wp_key = P.last_special_wp or ""
    else wp_key = P.last_revolver_wp or ""
    end
    if wp_key == "" then wp_key = wp_id_to_key(wid) or "" end
    if wid == nil or (wid == 0 and wp_key == "" and (not guid or guid == "")) then return false end
    if not weapon_id_matches_holster_slot(wid, slot) then return false end
    local cur = get_current_weapon_id()
    if cur == wid then return true end
    local row = find_row_for_weapon(inv, wid, guid, wp_key)
    if not row then
        reconcile_holster_slot_cache(P, slot)
        wid, guid = resolve_profile_weapon_id(P, slot)
        if slot == "pistol" then wp_key = P.last_pistol_wp or wp_key
        elseif slot == "longarm" then wp_key = P.last_longarm_wp or wp_key
        elseif slot == "special" then wp_key = P.last_special_wp or wp_key
        else wp_key = P.last_revolver_wp or wp_key
        end
        row = find_row_for_weapon(inv, wid, guid, wp_key)
    end
    if not row or not managed_object_alive(row.slot) then return false end

    if phase == 2 then
        return native_equip_row(inv, row)
    end

    if cur and holster_slot_for_weapon_id(cur) ~= slot then
        cache_weapon_to_holster_profile(P, cur)
        if native_equip_row(inv, row) then return true end
        if native_inventory_unequip_for_swap(inv, cur) then
            return "defer"
        end
    end
    return native_equip_row(inv, row)
end

local function unequip_current_to_bare_hands()
    local equipment = get_player_equipment()
    local inv = get_inventory()
    if not equipment or not inv then return false end
    local wid = get_current_weapon_id()
    if not wid then return false end
    snapshot_holstered_weapon(get_profile())
    return native_holster_stow(equipment, inv, wid)
end

local validate_last_t = 0
local function validate_cached_weapons(P)
    local now = os.clock()
    if (now - validate_last_t) < 1.0 then return end
    validate_last_t = now
    local inv = get_inventory()
    if not inv then return end
    if #inventory_weapon_rows(inv) == 0 then return end
    local function still_has(wid, gstr, wp_key)
        if wid == nil and (not wp_key or wp_key == "") then return true end
        if find_row_for_weapon(inv, wid, gstr, wp_key) then return true end
        if type(wp_key) == "string" and wp_key ~= "" then
            local id = wp_key_to_id(wp_key)
            if id ~= nil and find_row_for_weapon(inv, id, nil, wp_key) then return true end
        end
        if wid ~= nil and find_row_for_weapon(inv, wid, nil, nil) then return true end
        return false
    end
    if not still_has(P.last_pistol, P.last_pistol_guid, P.last_pistol_wp) then
        P.last_pistol = 0
        P.last_pistol_guid = ""
        P.last_pistol_wp = ""
    end
    if not still_has(P.last_longarm, P.last_longarm_guid, P.last_longarm_wp) then
        P.last_longarm = 0
        P.last_longarm_guid = ""
        P.last_longarm_wp = ""
    end
    if not still_has(P.last_revolver, P.last_revolver_guid, P.last_revolver_wp) then
        P.last_revolver = 0
        P.last_revolver_guid = ""
        P.last_revolver_wp = ""
    end
    if not still_has(P.last_special, P.last_special_guid, P.last_special_wp) then
        P.last_special = 0
        P.last_special_guid = ""
        P.last_special_wp = ""
    end
end

local function bootstrap_last_weapons(P)
    if profile_has_stowed_pistol(P) and P.last_longarm ~= 0 and P.last_revolver ~= 0 and P.last_special ~= 0 then return end
    local inv = get_inventory()
    if not inv then return end
    for _, row in ipairs(inventory_weapon_rows(inv)) do
        local wid = row.wp_id
        if wid and wid >= 0 then
            if not profile_has_stowed_pistol(P) and is_pistol_category(wid) then
                P.last_pistol = wid
                P.last_pistol_guid = row.guid_str
                P.last_pistol_wp = row.wp_key or wp_id_to_key(wid) or ""
            end
            if P.last_longarm == 0 and is_longarm_category(wid) then
                P.last_longarm = wid
                P.last_longarm_guid = row.guid_str
                P.last_longarm_wp = row.wp_key or wp_id_to_key(wid) or ""
            end
            if P.last_revolver == 0 and is_chest_slot_weapon(wid) then
                P.last_revolver = wid
                P.last_revolver_guid = row.guid_str
                P.last_revolver_wp = row.wp_key or wp_id_to_key(wid) or ""
            end
            if P.last_special == 0 and is_special_slot_weapon(wid) then
                P.last_special = wid
                P.last_special_guid = row.guid_str
                P.last_special_wp = row.wp_key or wp_id_to_key(wid) or ""
            end
        end
    end
end

local function track_weapon()
    local P = get_profile()
    validate_cached_weapons(P)
    local prev_p, prev_l, prev_r, prev_s = P.last_pistol, P.last_longarm, P.last_revolver, P.last_special
    local prev_pg, prev_lg, prev_rg, prev_sg = P.last_pistol_guid, P.last_longarm_guid, P.last_revolver_guid, P.last_special_guid
    local prev_pw, prev_lw, prev_rw, prev_sw = P.last_pistol_wp, P.last_longarm_wp, P.last_revolver_wp, P.last_special_wp

    local wep = get_current_weapon_id()
    local inv = get_inventory()
    local gstr = ""
    if inv then
        gstr = get_equipped_main_slot_key(inv)
    end

    if wep then
        cache_weapon_to_holster_profile(P, wep)
    end

    if not profile_has_stowed_pistol(P) or P.last_longarm == 0 or P.last_revolver == 0 or P.last_special == 0 then
        bootstrap_last_weapons(P)
    end

    if P.last_pistol ~= prev_p or P.last_longarm ~= prev_l or P.last_revolver ~= prev_r or P.last_special ~= prev_s
        or P.last_pistol_guid ~= prev_pg or P.last_longarm_guid ~= prev_lg or P.last_revolver_guid ~= prev_rg or P.last_special_guid ~= prev_sg
        or P.last_pistol_wp ~= prev_pw or P.last_longarm_wp ~= prev_lw or P.last_revolver_wp ~= prev_rw or P.last_special_wp ~= prev_sw then
        save_cfg()
    end
end

local HOLSTER_ACTION = { pending = nil, shoot_until = 0 }
local is_menu_blocking

local function tick_shoot_ready_suppress()
    if HOLSTER_ACTION.shoot_until <= 0 then return end
    if not CFG.suppress_shoot_ready_after_holster_equip then
        HOLSTER_ACTION.shoot_until = 0
        rawset(_G, "__vr_block_shoot_ready", false)
        return
    end
    local now = os.clock()
    if now >= HOLSTER_ACTION.shoot_until then
        HOLSTER_ACTION.shoot_until = 0
        rawset(_G, "__vr_block_shoot_ready", false)
    else
        rawset(_G, "__vr_block_shoot_ready", true)
    end
end

local function arm_shoot_ready_suppress_after_holster_action()
    if not CFG.suppress_shoot_ready_after_holster_equip then return end
    local dur = tonumber(CFG.suppress_shoot_ready_after_holster_s) or 0.45
    if dur < 0.05 then dur = 0.05 end
    HOLSTER_ACTION.shoot_until = os.clock() + dur
    rawset(_G, "__vr_block_shoot_ready", true)
end

local function execute_pending_action()
    local pa = HOLSTER_ACTION.pending
    if not pa then return end
    if is_menu_blocking() then
        HOLSTER_ACTION.pending = nil
        return
    end
    if manual_reload_blocks_holster() then
        HOLSTER_ACTION.pending = nil
        return
    end

    if pa.kind == "unequip" then
        HOLSTER_ACTION.pending = nil
        if unequip_current_to_bare_hands() then
            arm_shoot_ready_suppress_after_holster_action()
        end
        return
    end

    if pa.kind == "equip" and pa.slot then
        local equip_phase = pa.phase or 1
        local ok = equip_weapon_from_profile(get_profile(), pa.slot, equip_phase)
        if ok == "defer" then
            HOLSTER_ACTION.pending = { kind = "equip", slot = pa.slot, phase = 2 }
            return
        end
        HOLSTER_ACTION.pending = nil
        if ok == true then
            arm_shoot_ready_suppress_after_holster_action()
        end
        return
    end

    HOLSTER_ACTION.pending = nil
end

do
    local installed = false
    local td = sdk.find_type_definition("share.Startup")
    if td then
        local m = td:get_method("updateOnFrameHead")
        if m then
            sdk.hook(m, function() end, function(retval)
                pcall(execute_pending_action)
                return retval
            end)
            installed = true
        end
    end
    if not installed then
        log.warn("[re2_vr_holster] share.Startup.updateOnFrameHead hook missing; using on_frame defer only")
    end
end

local last_menu_gui_time = 0.0
local GUI_STATE_NONE = 0

local BLOCKING_GUI_NAMES = {
    "GUIInventory",
    "GUIInventoryMenu",
    "GUIInventoryTreasure",
    "GUIInventoryCraft",
    "GUIInventoryKeyItem",
    "GUIMap",
    "GUIShopBg",
    "GUIPause",
    "GUISaveLoad",
    "GUIFile",
    "GUIFileList",
    "GUIFileMenu",
    "GUISave",
    "GUISaveMenu",
    "GUIMainMenu",
    "GUIPhotoMode",
    "GUIBinder",
    "Gui_ui3030",
    "Gui_ui3040",
    "Gui_ui3050",
    "Gui_ui3060",
    -- Found via re2_vr_itembox_probe.lua: the item storage box's real
    -- element name (was wrongly assumed to be GUIInventoryTreasure, which
    -- is a different screen -- this is why closing the item box with X
    -- was accidentally toggling the flashlight, confirmed via live debug
    -- trace: is_menu_blocking() never once detected it as open before).
    "GUI_ItemBox",
}
for i, v in ipairs(BLOCKING_GUI_NAMES) do
    BLOCKING_GUI_NAMES[v] = true
end

local BLOCKING_GUI_REF_FIELDS = {
    "RefInventoryUI",
    "RefMapUI",
    "RefPauseUI",
    "RefItemBoxUI",
    "RefItemLockerUI",
    "RefOptionUI",
    "RefFileUI",
    "RefShortcutUI",
    "RefMenuMainUI",
}

local GUI_BUSY_GETTERS = {
    "get_IsGuiOpenRestrict",
    "isBusyFile",
    "isBusySave",
    "isBusyOpenedRecords",
    "isBusyAutoSaveIcon",
}

re.on_pre_gui_draw_element(function(element, context)
    local go = safe_call(element, "get_GameObject")
    if not go then return true end
    local name = safe_call(go, "get_Name")
    if type(name) == "string" and BLOCKING_GUI_NAMES[name] then
        local active = false
        pcall(function() active = go:read_byte(0x10) == 1 end)
        if active then
            last_menu_gui_time = os.clock()
        end
    end
    return true
end)

local function gui_master_bool(gm, getter_name)
    if not gm then return false end
    local ok, v = pcall(function() return gm:call(getter_name) end)
    return ok and v == true
end

local function gui_master_state(gm)
    if not gm then return GUI_STATE_NONE end
    local state = nil
    pcall(function() state = gm:get_field("<State_>k__BackingField") end)
    if type(state) == "number" then return state end
    state = safe_call(gm, "get_State")
    local ev = enum_value(state)
    if type(ev) == "number" then return ev end
    if type(state) == "number" then return state end
    return GUI_STATE_NONE
end

local function gameobject_ref_is_active(gm, field_name)
    if not gm or not field_name then return false end
    local ref = nil
    pcall(function() ref = gm:get_field(field_name) end)
    if not ref then return false end
    local is_empty = safe_call(ref, "get_IsEmpty")
    if is_empty == true then return false end
    local target = safe_call(ref, "get_Target")
    if not target then
        pcall(function() target = ref:get_field("Target") end)
    end
    if not target then return false end
    local active = false
    pcall(function() active = target:read_byte(0x10) == 1 end)
    return active
end

local CAM_BLOCK = { EVENT = 6, ACTION = 5 }

local function cinematic_bool(obj, getter)
    if not obj then return false end
    local ok, v = pcall(function() return obj:call(getter) end)
    return ok and v == true
end

local function cinematic_enum(o)
    if o == nil then return nil end
    if type(o) == "number" then return o end
    local ok, v = pcall(function() return o:get_field("value__") end)
    if ok and type(v) == "number" then return v end
    return nil
end

function is_cinematic_blocking()
    local tem = sdk.get_managed_singleton("app.ropeway.gamemastering.TimelineEventManager")
    if tem and cinematic_bool(tem, "get_InCameraEvent") then
        return true
    end

    local pm = sdk.get_managed_singleton(NS("PlayerManager"))
    if pm then
        local cond = nil
        pcall(function() cond = pm:call("get_CurrentPlayerCondition") end)
        if cond and cinematic_bool(cond, "get_IsEvent") then
            return true
        end
    end

    local cam = sdk.get_managed_singleton("app.ropeway.camera.CameraSystem")
    if cam then
        local busy = nil
        pcall(function() busy = cam:call("get_BusyCameraType") end)
        local n = cinematic_enum(busy)
        -- EVENT only — ACTION (5) also fires during normal aim/locomotion.
        if n == CAM_BLOCK.EVENT then
            return true
        end
    end

    local csm = sdk.get_managed_singleton("app.ropeway.CutSceneManager")
    if csm then
        local owner = nil
        pcall(function() owner = csm:call("get_TimelineOwnerObject") end)
        if owner ~= nil then return true end
    end

    return false
end

function is_menu_blocking()
    if (os.clock() - last_menu_gui_time) < 0.35 then
        return true
    end
    local gm = sdk.get_managed_singleton(sdk.game_namespace("gui.GUIMaster"))
    if not gm then return false end

    if gui_master_state(gm) ~= GUI_STATE_NONE then
        return true
    end

    if gui_master_bool(gm, "get_IsOpenInventory")
        or gui_master_bool(gm, "get_IsOpenMap")
        or gui_master_bool(gm, "get_IsOpenPause")
        or gui_master_bool(gm, "get_IsOpenPauseForEvent")
        or gui_master_bool(gm, "isBusyItemBox")
        or gui_master_bool(gm, "getItemBoxEnable") then
        return true
    end

    for _, getter in ipairs(GUI_BUSY_GETTERS) do
        if gui_master_bool(gm, getter) then
            return true
        end
    end

    local sdm = sdk.get_managed_singleton(NS("gamemastering.SaveDataManager"))
    if sdm and gui_master_bool(sdm, "get_IsBusy") then
        return true
    end

    for _, field in ipairs(BLOCKING_GUI_REF_FIELDS) do
        if gameobject_ref_is_active(gm, field) then
            return true
        end
    end

    return false
end

rawset(_G, "__vr_is_menu_blocking", is_menu_blocking)
rawset(_G, "__vr_is_cinematic_blocking", is_cinematic_blocking)

local flashlight_power = false
local illumination_manager = nil

local survivor_condition_type = sdk.typeof(NS("survivor.SurvivorCondition"))
local player_action_orderer_type = sdk.typeof(NS("survivor.player.PlayerActionOrderer"))
local flash_light_type = sdk.typeof(NS("FlashLight"))

local vr_flash = {
    condition = nil,
    action_orderer = nil,
    light_timer = nil,
    last_scan_frame = -9999,
    pending_pulses = 0,
    pulse_cooldown = 0,
    ready = false,
    frame = 0,
    -- Left trigger (LT) flashlight toggle state. Suppressed while either
    -- grip (LG or RG) is held -- LT already means something in those
    -- contexts (slide-rack/pump trigger-pull mechanics while LG grips the
    -- handle), and it's a sensible safety margin against incidental
    -- trigger contact while two-handing/gripping generally. Folded into
    -- this existing table rather than new top-level locals -- this file
    -- was already at 199/200 top-level locals (Lua's per-chunk ceiling).
    lt_action = nil,
    lt_prev = false,
}

local function get_component_on(obj, comp_type)
    if not obj or not comp_type then return nil end
    local ok, comp = pcall(function() return obj:call("getComponent(System.Type)", comp_type) end)
    return ok and comp or nil
end

local function get_transform_children(xform)
    local out = {}
    if not xform then return out end
    local child = safe_call(xform, "get_Child")
    while child do
        out[#out + 1] = child
        child = safe_call(child, "get_Next")
    end
    return out
end

local function find_flashlight_on_transform(xform, depth)
    if not xform or (depth ~= nil and depth < 0) then return nil, nil end
    local go = safe_call(xform, "get_GameObject")
    if go and flash_light_type then
        local comp = get_component_on(go, flash_light_type)
        if comp then return go, comp end
    end
    for _, child in ipairs(get_transform_children(xform)) do
        local fgo, fcomp = find_flashlight_on_transform(child, (depth or 10) - 1)
        if fcomp then return fgo, fcomp end
    end
    return nil, nil
end

local function vr_flash_read_is_light(condition)
    if not condition then return nil end
    local ok, v = pcall(function() return condition:get_field("<IsLight>k__BackingField") end)
    if ok and v ~= nil then return v == true end
    local m = safe_call(condition, "get_IsLight")
    if m ~= nil then return m == true end
    return nil
end

local function vr_flash_set_manually_light(condition, enabled)
    if not condition then return end
    pcall(function() condition:call("set_ManuallyLight", enabled == true) end)
end

local function vr_flash_extend_light_timer(timer, seconds)
    if not timer or not seconds then return end
    pcall(function() timer._TimeLimit = seconds end)
    pcall(function() timer:set_field("_TimeLimit", seconds) end)
end

--- PlayerActionOrderer PrecedeBits.Accept(64) simulates the manual flashlight switch input.
local function vr_flash_pulse_toggle(action_orderer)
    if not action_orderer then return false end
    local bits = nil
    pcall(function() bits = action_orderer:get_field("<PrecedeBits>k__BackingField") end)
    if not bits then return false end
    local ok = pcall(function() bits:set_Accept(64) end)
    return ok == true
end

local function refresh_vr_flash_surfaces(force)
    vr_flash.frame = (vr_flash.frame or 0) + 1
    if not force and (vr_flash.frame - vr_flash.last_scan_frame) < 30 then
        return vr_flash.ready
    end
    vr_flash.last_scan_frame = vr_flash.frame
    vr_flash.condition = nil
    vr_flash.action_orderer = nil
    vr_flash.light_timer = nil
    vr_flash.ready = false

    local player = get_player()
    if not player then return false end

    vr_flash.action_orderer = get_component_on(player, player_action_orderer_type)
    vr_flash.condition = get_component_on(player, survivor_condition_type)

    local _, flash_comp = find_flashlight_on_transform(safe_call(player, "get_Transform"), 12)
    if flash_comp then
        local cond = nil
        pcall(function() cond = flash_comp:get_field("<Condition>k__BackingField") end)
        if cond then vr_flash.condition = cond end
    end

    if vr_flash.condition then
        vr_flash.light_timer = nil
        pcall(function() vr_flash.light_timer = vr_flash.condition:get_field("<LightSwitchTimer>k__BackingField") end)
        if not vr_flash.action_orderer then
            pcall(function()
                vr_flash.action_orderer = vr_flash.condition:get_field("<ActionOrderer>k__BackingField")
            end)
        end
    end

    vr_flash.ready = vr_flash.action_orderer ~= nil and vr_flash.condition ~= nil
    return vr_flash.ready
end

local function apply_vr_head_flashlight_fallback_illumination()
    if not illumination_manager then
        pcall(function()
            illumination_manager = sdk.get_managed_singleton(sdk.game_namespace("IlluminationManager"))
        end)
    end
    if not illumination_manager then return false end
    local on = flashlight_power and 1 or 0
    if not safe_set_managed_field(illumination_manager, "shouldUseFlashlight", on) then
        pcall(function() illumination_manager:write_uint32(0x60, on) end)
    end
    if not safe_set_managed_field(illumination_manager, "someCounter", on) then
        pcall(function() illumination_manager:write_uint32(0x64, on) end)
    end
    if managed_type_has_field(illumination_manager, "shouldUseFlashlight2") then
        safe_set_managed_field(illumination_manager, "shouldUseFlashlight2", flashlight_power == true)
    else
        pcall(function() illumination_manager:write_byte(0x68, on) end)
    end
    return true
end

local function tick_vr_flashlight_pending()
    if vr_flash.pending_pulses <= 0 then return end
    if vr_flash.pulse_cooldown > 0 then
        vr_flash.pulse_cooldown = vr_flash.pulse_cooldown - 1
        return
    end
    if not refresh_vr_flash_surfaces(false) or not vr_flash.action_orderer then
        vr_flash.pending_pulses = 0
        return
    end
    local is_light = vr_flash_read_is_light(vr_flash.condition)
    local want_on = flashlight_power == true
    if (want_on and is_light == true) or (not want_on and is_light ~= true) then
        vr_flash.pending_pulses = 0
        return
    end
    if vr_flash_pulse_toggle(vr_flash.action_orderer) then
        vr_flash.pending_pulses = vr_flash.pending_pulses - 1
        vr_flash.pulse_cooldown = 2
    else
        vr_flash.pending_pulses = 0
    end
end

local function apply_vr_head_flashlight_toggle()
    if not CFG.head_flashlight_enabled then return end
    if not refresh_vr_flash_surfaces(true) or not vr_flash.action_orderer then
        apply_vr_head_flashlight_fallback_illumination()
        return
    end

    local want_on = flashlight_power == true
    local is_light = vr_flash_read_is_light(vr_flash.condition)

    if want_on then
        vr_flash_set_manually_light(vr_flash.condition, true)
        vr_flash_extend_light_timer(vr_flash.light_timer, 999.0)
        if is_light ~= true then
            vr_flash_pulse_toggle(vr_flash.action_orderer)
            vr_flash.pending_pulses = 12
            vr_flash.pulse_cooldown = 0
        end
    else
        vr_flash_set_manually_light(vr_flash.condition, false)
        if is_light == true then
            vr_flash_pulse_toggle(vr_flash.action_orderer)
            vr_flash.pending_pulses = 12
            vr_flash.pulse_cooldown = 0
        end
    end
end

local function maintain_vr_head_flashlight_state()
    if not CFG.head_flashlight_enabled then return end
    tick_vr_flashlight_pending()
    if not flashlight_power then return end
    if not refresh_vr_flash_surfaces(false) or not vr_flash.condition then return end
    vr_flash_set_manually_light(vr_flash.condition, true)
end

local ANIM = {
    motion_type = sdk.typeof("via.motion.Motion"),
    comp = nil,
    check_t = 0,
    layers = {},
    dbg_name = "-",
    dbg_count = 0,
}

local function find_player_motion()
    local now = os.clock()
    if ANIM.comp and (now - ANIM.check_t) < 2.0 then
        return ANIM.comp
    end
    ANIM.check_t = now
    ANIM.comp = nil
    local player = get_player()
    if not player or not ANIM.motion_type then return nil end
    pcall(function()
        ANIM.comp = player:call("getComponent(System.Type)", ANIM.motion_type)
    end)
    return ANIM.comp
end

local function suppress_scan_layer(mc, li)
    local layer = safe_call(mc, "getLayer", li)
    if not layer then return end
    local node = safe_call(layer, "get_HighestWeightMotionNode")
    local name = node and safe_call(node, "get_MotionName")
    local matched = false
    if type(name) == "string" and name ~= "" then
        local lower = string.lower(name)
        matched = (lower:find("holstertomove", 1, true) ~= nil)
            or (lower:find("movetoholster", 1, true) ~= nil)
    end
    if matched then
        ANIM.dbg_name = name
        ANIM.dbg_count = ANIM.dbg_count + 1
        pcall(function()
            local ef = node:call("get_EndFrame")
            if ef then node:call("set_Frame", ef) end
        end)
        pcall(function()
            local lef = layer:call("get_EndFrame")
            if lef then layer:call("set_Frame", lef) end
        end)
        pcall(function() layer:call("set_Speed", 100.0) end)
        ANIM.layers[li] = true
    else
        if ANIM.layers[li] then
            pcall(function() layer:call("set_Speed", 1.0) end)
            ANIM.layers[li] = false
        end
    end
end

local function suppress_holster_anims()
    if not CFG.enabled or not CFG.block_swap_anims then return end
    local mc = find_player_motion()
    if not mc then return end
    for _, li in ipairs(CFG.suppress_motion_layers or { 0, 3, 5 }) do
        suppress_scan_layer(mc, li)
    end
end

re.on_pre_application_entry("UpdateScene", suppress_holster_anims)

local function vec3_dist(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function haptic_pulse(joystick, duration, frequency, amplitude)
    if not joystick then return end
    pcall(function()
        vrmod:trigger_haptic_vibration(0.0, duration, frequency, amplitude, joystick)
    end)
end

local function holster_haptic_intensity()
    local v = tonumber(CFG.haptic_intensity)
    if v == nil then return 1.0 end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function holster_haptic_pulse(joystick, duration, frequency, amplitude)
    local base = tonumber(amplitude) or 0
    haptic_pulse(joystick, duration, frequency, base * holster_haptic_intensity())
end

local PLAYER_JOINT = {
    hip = { "r_Prop_Hip_A", "spine_0" },
    shoulder = { "l_Prop_BackWepOffset_A", "spine_2" },
    -- Tried repointing this to a mirrored "l_Prop_Hip_A" prop bone
    -- (2026-08-02) to keep it away from RG's reach, but that bone either
    -- doesn't exist on this skeleton or has a very different orientation
    -- than r_Prop_Hip_A -- made the zone completely unreachable (no
    -- haptics at all). Reverted to spine_2; repositioning handled via
    -- off_x/off_y/off_z instead, same as before.
    chest = { "spine_2" },
    left_wrist = { "l_arm_wrist" },
    right_wrist = { "r_arm_wrist" },
}

local function find_player_joint(tf, joint_names)
    if not tf then return nil end
    for _, joint_name in ipairs(joint_names or {}) do
        local joint = safe_call(tf, "getJointByName", joint_name)
        if joint then return joint end
    end
    return nil
end

local function make_holster_state()
    return {
        joint = nil,
        in_zone = false,
        last_grab_t = -1.0,
        last_dist = 0.0,
        trigger_count = 0,
        grab_ready_prev = false,
        haptic_pending_frames = 0,
        zone_enter_pulse = false,
        suppress_prev = false,
        sub_weapon_grip_block = false,
    }
end

local hip = make_holster_state()
local shoulder = make_holster_state()
local chest = make_holster_state()
local special = make_holster_state()
local GRIP = { action = nil, aim_prev = false, holster_prev = false, right_joint = nil, suppress_haptics_for_aim = false }

local function get_left_joystick()
    if not vrmod then return nil end
    if vrc_manager:has_controllers() then
        local lc = vrc_manager.controllers_list[1]
        if lc and lc.joystick then return lc.joystick end
    end
    local lj = nil
    pcall(function() lj = vrmod:get_left_joystick() end)
    if lj then return lj end
    local ok, val = pcall(vrmod.get_left_joystick, vrmod)
    return ok and val or nil
end

local function get_right_joystick()
    if not vrmod then return nil end
    local rj = nil
    pcall(function() rj = vrmod:get_right_joystick() end)
    if rj then return rj end
    local ok, val = pcall(vrmod.get_right_joystick, vrmod)
    return ok and val or nil
end

local function is_left_grip_pressed()
    if not vrmod then return false end
    if vrc_manager:has_controllers() then
        local lc = vrc_manager.controllers_list[1]
        if lc then
            return lc:is_action_active(vrc_manager.Actions.GRIP) == true
        end
    end
    local lj = get_left_joystick()
    if not lj then return false end
    local action = nil
    pcall(function() action = vrmod:get_action_grip() end)
    if not action then return false end
    local ok, v = pcall(function() return vrmod:is_action_active(action, lj) end)
    return ok and v == true
end

local function is_right_grip_pressed()
    if not vrmod then return false end
    if vrc_manager:has_controllers() then
        local rc = vrc_manager.controllers_list[2]
        if rc then
            return rc:is_action_active(vrc_manager.Actions.GRIP) == true
        end
    end
    local rj = get_right_joystick()
    if not rj then return false end
    local action = nil
    pcall(function() action = vrmod:get_action_grip() end)
    if not action then return false end
    local ok, v = pcall(function() return vrmod:is_action_active(action, rj) end)
    return ok and v == true
end

local function sync_weapon_hold_suppress(in_zone)
    local zone_active = in_zone == true
    local suppress = CFG.enabled
        and CFG.suppress_shoot_ready_in_holster_zone
        and zone_active
    rawset(_G, "__vr_in_holster_zone", zone_active)
    rawset(_G, "__vr_block_hold_in_holster_zone", suppress)
end

local function clear_weapon_hold_suppress()
    rawset(_G, "__vr_in_holster_zone", false)
    rawset(_G, "__vr_block_hold_in_holster_zone", false)
end

local apply_holster_vr_input_suppress
do
    local KIND = statics.generate(NS("InputDefine.Kind"))
    local STRIP_LEFT = (KIND.SUPPORT_HOLD or 128) | (KIND.UI_SHIFT_LEFT or 268435456)
    local STRIP_RIGHT = (KIND.HOLD or 64) | (KIND.UI_SHIFT_RIGHT or 536870912)
    local BUTTON_OFF = { Down = 0x10, On = 0x18, Up = 0x20 }
    local hooks_installed = false

    local function read_u64_field(obj, field_name)
        if not obj then return nil end
        local v = nil
        pcall(function() v = obj:get_field(field_name) end)
        if type(v) == "number" then return v end
        local off = BUTTON_OFF[field_name]
        if not off then return nil end
        local ok, val = pcall(function() return obj:read_uint64(off) end)
        if ok and type(val) == "number" then return val end
        return nil
    end

    local function write_u64_field(obj, field_name, value)
        if not obj or type(value) ~= "number" then return end
        pcall(function() obj:set_field(field_name, value) end)
        local off = BUTTON_OFF[field_name]
        if off then
            pcall(function() obj:write_uint64(off, value) end)
        end
    end

    local function strip_input_mask(input_system, mask)
        if not input_system or not mask or mask == 0 then return end
        local ok, bb = pcall(function() return input_system:call("get_ButtonBits") end)
        if not ok or not bb then return end
        for _, field_name in ipairs({ "Down", "On", "Up" }) do
            local cur = read_u64_field(bb, field_name)
            if type(cur) == "number" and (cur & mask) ~= 0 then
                write_u64_field(bb, field_name, cur & ~mask)
            end
        end
    end

    -- Always false now: this used to strip native left-hand support-hold
    -- input while reaching near the head for the flashlight (dropped,
    -- player request -- the head position is now the "special" weapon
    -- holster instead). Kept as a stub/hook point in case a future
    -- feature needs to strip left-support input again.
    local function left_support_strip_wanted()
        return false
    end

    apply_holster_vr_input_suppress = function()
        local left_want = left_support_strip_wanted()
        local right_want = rawget(_G, "__vr_block_hold_in_holster_zone") == true
        if not left_want and not right_want then return end
        local input_system = sdk.get_managed_singleton(NS("InputSystem"))
        if not input_system then return end
        if left_want then
            strip_input_mask(input_system, STRIP_LEFT)
        end
        if right_want then
            strip_input_mask(input_system, STRIP_RIGHT)
        end
    end

    if not hooks_installed then
        re.on_application_entry("UpdateHID", apply_holster_vr_input_suppress)
        re.on_pre_application_entry("UpdateBehavior", apply_holster_vr_input_suppress)
        re.on_application_entry("LateUpdateBehavior", apply_holster_vr_input_suppress)
        hooks_installed = true
    end
end

local function silence_all_zones()
    hip.in_zone = false
    shoulder.in_zone = false
    chest.in_zone = false
    special.in_zone = false
end

local function vec3_dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function body_yaw_axes_from_transform(tf)
    if not tf then return nil end
    local fx, fz = nil, nil
    local ok_r, rot = pcall(function() return tf:call("get_Rotation") end)
    if ok_r and rot then
        local ok_f, fwd_v = pcall(function() return rot * Vector3f.new(0, 0, 1) end)
        if ok_f and fwd_v then fx, fz = fwd_v.x, fwd_v.z end
    end
    if not fx then
        local cam = sdk.get_primary_camera()
        if cam then
            local ok, wm = pcall(function() return cam:call("get_WorldMatrix") end)
            if ok and wm then fx, fz = wm[2].x, wm[2].z end
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

--- Body-locked anchor (spine/root). Yaw-only basis — stable when pitching the HMD.
local function get_body_pose_yaw()
    local tf = get_player_transform()
    if not tf then return nil end
    local right, up, fwd = body_yaw_axes_from_transform(tf)
    if not right then return nil end

    local pos = nil
    for _, joint_name in ipairs({ "spine_2", "spine_1", "spine_0", "pelvis" }) do
        local joint = safe_call(tf, "getJointByName", joint_name)
        if joint then
            pos = safe_call(joint, "get_Position")
            if pos then break end
        end
    end
    if not pos then pos = safe_call(tf, "get_Position") end
    if not pos then return nil end
    return pos, right, up, fwd
end

local function normalize_axis_vec(v)
    if not v or type(v.x) ~= "number" then return nil end
    local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if len < 1e-6 then return nil end
    return { x = v.x / len, y = v.y / len, z = v.z / len }
end

local function axes_from_world_matrix(wm)
    if not wm then return nil end
    local right = normalize_axis_vec({ x = wm[0].x, y = wm[0].y, z = wm[0].z })
    local up = normalize_axis_vec({ x = wm[1].x, y = wm[1].y, z = wm[1].z })
    local fwd = normalize_axis_vec({ x = wm[2].x, y = wm[2].y, z = wm[2].z })
    if not right or not up or not fwd then return nil end
    return right, up, fwd
end

local function vec3_add(a, b)
    return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

local function vec3_sub(a, b)
    return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

local function quat_rotate_vec3(q, v)
    if not q or not v then return nil end
    local ok, out = pcall(function()
        if type(v.x) == "number" then
            return q * Vector3f.new(v.x, v.y, v.z)
        end
        return q * v
    end)
    if ok and out and type(out.x) == "number" then
        return { x = out.x, y = out.y, z = out.z }
    end
    return nil
end

--- Game-world camera pose (includes artificial locomotion; not raw play-space tracking).
local function get_game_world_camera_pose()
    local cam = sdk.get_primary_camera()
    if not cam then return nil end
    local ok, wm = pcall(function() return cam:call("get_WorldMatrix") end)
    if not ok or not wm then return nil end
    local pos = { x = wm[3].x, y = wm[3].y, z = wm[3].z }
    local right, up, fwd = axes_from_world_matrix(wm)
    if not right then return nil end
    local rot = nil
    pcall(function() rot = wm:to_quat() end)
    return pos, right, up, fwd, rot
end

--- HMD position with head-local axes (tracks pitch/roll/yaw with the headset).
local function get_hmd_pose_local()
    local pos, right, up, fwd = get_game_world_camera_pose()
    if not pos then return nil end
    return pos, right, up, fwd
end

local function refresh_holster_joint(tf, holster_state, joint_names)
    if not tf or not holster_state then return false end
    if holster_state.joint then
        local valid = false
        pcall(function() valid = holster_state.joint:get_Valid() end)
        if valid then return true end
        holster_state.joint = nil
    end
    local joint = find_player_joint(tf, joint_names)
    if joint then
        holster_state.joint = joint
        return true
    end
    return false
end

local function refresh_right_hand_joint(tf)
    if not tf then return false end
    if GRIP.right_joint then
        local valid = false
        pcall(function() valid = GRIP.right_joint:get_Valid() end)
        if valid then return true end
        GRIP.right_joint = nil
    end
    local joint = find_player_joint(tf, PLAYER_JOINT.right_wrist)
    if joint then
        GRIP.right_joint = joint
        return true
    end
    return false
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

local function resolve_holster_anchor(holster_state, joint_names)
    local tf = get_player_transform()
    if not tf then return nil end
    refresh_holster_joint(tf, holster_state, joint_names)
    if holster_state.joint then
        local origin = safe_call(holster_state.joint, "get_Position")
        if origin then
            return origin,
                safe_call(holster_state.joint, "get_AxisX"),
                safe_call(holster_state.joint, "get_AxisY"),
                safe_call(holster_state.joint, "get_AxisZ")
        end
    end
    local body_pos, right, up, fwd = get_body_pose_yaw()
    if body_pos then return body_pos, right, up, fwd end
    return nil
end

local function holster_capture_pose(slot)
    if slot == "special" then
        return get_hmd_pose_local()
    end
    local probe = { joint = nil }
    local joint_names = PLAYER_JOINT[slot]
    if joint_names then
        local origin, ax, ay, az = resolve_holster_anchor(probe, joint_names)
        if origin then return origin, ax, ay, az end
    end
    return get_body_pose_yaw()
end

local function zone_haptic_opts_for_slot(slot)
    local enabled = CFG.zone_haptic_enabled ~= false
    local continuous = false
    if slot == "hip" then
        enabled = enabled and CFG.hip_zone_haptic_enabled ~= false
        continuous = CFG.hip_zone_haptic_continuous == true
    elseif slot == "shoulder" then
        enabled = enabled and CFG.shoulder_zone_haptic_enabled ~= false
        continuous = CFG.shoulder_zone_haptic_continuous == true
    elseif slot == "chest" then
        enabled = enabled and CFG.chest_zone_haptic_enabled ~= false
        continuous = CFG.chest_zone_haptic_continuous == true
    elseif slot == "special" then
        enabled = enabled and CFG.special_zone_haptic_enabled ~= false
        continuous = CFG.special_zone_haptic_continuous == true
    end
    return enabled, continuous
end

local function maybe_zone_haptic(holster_state, joy, slot)
    if GRIP.suppress_haptics_for_aim then
        return
    end
    local zone_enabled, zone_continuous = zone_haptic_opts_for_slot(slot)
    if not zone_enabled or not holster_state.in_zone or not joy then
        if not holster_state.in_zone then
            holster_state.haptic_pending_frames = 0
            holster_state.zone_enter_pulse = false
        end
        return
    end
    if holster_state.zone_enter_pulse then
        holster_state.zone_enter_pulse = false
        holster_state.haptic_pending_frames = 0
        holster_haptic_pulse(joy, CFG.zone_haptic_duration, CFG.zone_haptic_frequency, CFG.zone_haptic_amplitude)
        return
    end
    if not zone_continuous then
        return
    end
    local interval = tonumber(CFG.zone_haptic_frames) or 3
    if interval < 1 then interval = 1 end
    holster_state.haptic_pending_frames = (holster_state.haptic_pending_frames or 0) + 1
    if holster_state.haptic_pending_frames >= interval then
        holster_state.haptic_pending_frames = 0
        holster_haptic_pulse(joy, CFG.zone_haptic_duration, CFG.zone_haptic_frequency, CFG.zone_haptic_amplitude)
    end
end

local function get_joint_world_pos(tf, joint_name)
    if not tf then return nil end
    local hj = safe_call(tf, "getJointByName", joint_name)
    if hj then
        return safe_call(hj, "get_Position")
    end
    return nil
end

local function get_right_hand_pos()
    local j = rawget(_G, "__vr_rh_joint_pos")
    if j and type(j.x) == "number" then return j end
    local w = rawget(_G, "__vr_rh_world")
    if w and type(w.x) == "number" then return w end
    return get_joint_world_pos(get_player_transform(), "r_arm_wrist")
end

local function get_left_hand_pos()
    local j = rawget(_G, "__vr_lh_joint_pos")
    if j and type(j.x) == "number" then return j end
    local w = rawget(_G, "__vr_lh_world")
    if w and type(w.x) == "number" then return w end
    return get_joint_world_pos(get_player_transform(), "l_arm_wrist")
end

--- Default is (0, 0.27, 0) -- straight up from the HMD, requiring a small
--- reach above the head (avoids overlapping the shoulder zone, which sits
--- just below/behind head height). off_x/off_z are deliberately kept at 0
--- rather than also offsetting sideways/forward: any offset gets rotated
--- by the HMD's right/up/fwd axes (holster_pos_with_offsets), and the
--- right/fwd axes were found to drift off the player's actual facing
--- during physical (room-scale) turning -- they track correctly during
--- in-game stick/snap turning, but lag or misalign on real body rotation.
--- The up axis doesn't have this problem (it stays pointing up regardless
--- of which way you're facing), so a vertical-only offset is safe.
local function resolve_special_offsets(P)
    if not P then return 0.0, 0.0, 0.0 end
    return P.special_off_x or 0.0, P.special_off_y or 0.0, P.special_off_z or 0.0
end

local function refresh_holster_zone(holster_state, cfg_enabled, joint_names,
    off_x, off_y, off_z, trigger_dist, release_dist, hand_pos, rj, zone_slot)
    if not cfg_enabled or not hand_pos then
        holster_state.in_zone = false
        return
    end
    local origin, ax, ay, az = resolve_holster_anchor(holster_state, joint_names)
    if not origin then
        holster_state.in_zone = false
        return
    end
    local right, up, fwd = ax, ay, az
    if not (ax and ay and az) then
        _, right, up, fwd = get_body_pose_yaw()
    end
    local holster_pos = holster_pos_with_offsets(origin, off_x, off_y, off_z, ax, ay, az, right, up, fwd)
    holster_state.last_pos = holster_pos
    local d = vec3_dist(hand_pos, holster_pos)
    holster_state.last_dist = d
    local was_in_zone = holster_state.in_zone == true
    if not holster_state.in_zone then
        if d <= trigger_dist then holster_state.in_zone = true end
    else
        if d > release_dist then holster_state.in_zone = false end
    end
    if holster_state.in_zone and not was_in_zone then
        holster_state.zone_enter_pulse = true
    end
    maybe_zone_haptic(holster_state, rj, zone_slot)
end

--- Same shape/behavior as refresh_holster_zone, but anchored on the HMD
--- (head position) instead of a skeletal joint -- there's no body joint
--- for "near your head", so this mirrors resolve_holster_anchor's math
--- against get_hmd_pose_local() directly. Used for the "special" (heavy
--- weapons) holster slot, drawn/stowed by reaching near the head with the
--- right hand, same as hip/shoulder/chest are reached with the right hand
--- relative to their own body joints.
local function refresh_special_zone(holster_state, cfg_enabled,
    off_x, off_y, off_z, trigger_dist, release_dist, hand_pos, rj)
    if not cfg_enabled or not hand_pos then
        holster_state.in_zone = false
        return
    end
    local hmd, right, up, fwd = get_hmd_pose_local()
    if not hmd then
        holster_state.in_zone = false
        return
    end
    local holster_pos = holster_pos_with_offsets(hmd, off_x, off_y, off_z, nil, nil, nil, right, up, fwd)
    holster_state.last_pos = holster_pos
    local d = vec3_dist(hand_pos, holster_pos)
    holster_state.last_dist = d
    local was_in_zone = holster_state.in_zone == true
    if not holster_state.in_zone then
        if d <= trigger_dist then holster_state.in_zone = true end
    else
        if d > release_dist then holster_state.in_zone = false end
    end
    if holster_state.in_zone and not was_in_zone then
        holster_state.zone_enter_pulse = true
    end
    maybe_zone_haptic(holster_state, rj, "special")
end

--- Pre-UpdateBehavior zone refresh (independent of right-grip hold silence in on_frame).
local function refresh_weapon_holster_zones_for_suppress()
    if not CFG.enabled or not CFG.suppress_shoot_ready_in_holster_zone then
        hip.in_zone = false
        shoulder.in_zone = false
        chest.in_zone = false
        special.in_zone = false
        return false
    end
    if is_menu_blocking() or block_weapon_inputs_active() then
        hip.in_zone = false
        shoulder.in_zone = false
        chest.in_zone = false
        special.in_zone = false
        return false
    end
    local cur_wep = get_current_weapon_id()
    if cur_wep and HOLSTER_DISABLED_WEAPONS[cur_wep] then
        hip.in_zone = false
        shoulder.in_zone = false
        chest.in_zone = false
        special.in_zone = false
        return false
    end

    local P = get_profile()
    local player_tf = get_player_transform()
    local hand_pos = nil
    if player_tf and refresh_right_hand_joint(player_tf) and GRIP.right_joint then
        hand_pos = safe_call(GRIP.right_joint, "get_Position")
    end
    if not hand_pos then
        hand_pos = get_right_hand_pos()
    end
    if not hand_pos then
        hip.in_zone = false
        shoulder.in_zone = false
        chest.in_zone = false
        special.in_zone = false
        return false
    end

    if cur_wep and is_longarm_category(cur_wep) then
        reconcile_holster_slot_cache(P, "pistol")
    elseif cur_wep and is_pistol_category(cur_wep) then
        reconcile_holster_slot_cache(P, "longarm")
    end

    local in_any = false

    if CFG.hip_pistol_enabled and (
        profile_has_stowed_pistol(P) or weapon_id_matches_holster_slot(cur_wep, "pistol")) then
        refresh_holster_zone(hip, true, PLAYER_JOINT.hip,
            P.hip_pistol_off_right, P.hip_pistol_off_up, P.hip_pistol_off_forward,
            P.hip_pistol_trigger_dist, P.hip_pistol_release_dist,
            hand_pos, nil, "hip")
        in_any = in_any or hip.in_zone
    else
        hip.in_zone = false
    end

    if CFG.shoulder_enabled and (
        profile_has_stowed_longarm(P) or weapon_id_matches_holster_slot(cur_wep, "longarm")) then
        refresh_holster_zone(shoulder, true, PLAYER_JOINT.shoulder,
            P.shoulder_off_x, P.shoulder_off_y, P.shoulder_off_z,
            P.shoulder_trigger_dist, P.shoulder_release_dist,
            hand_pos, nil, "shoulder")
        in_any = in_any or shoulder.in_zone
    else
        shoulder.in_zone = false
    end

    if CFG.chest_enabled and (
        profile_has_stowed_chest(P) or weapon_id_matches_holster_slot(cur_wep, "chest")) then
        refresh_holster_zone(chest, true, PLAYER_JOINT.chest,
            P.chest_off_x, P.chest_off_y, P.chest_off_z,
            P.chest_trigger_dist, P.chest_release_dist,
            hand_pos, nil, "chest")
        in_any = in_any or chest.in_zone
    else
        chest.in_zone = false
    end

    if CFG.special_enabled and (
        profile_has_stowed_special(P) or weapon_id_matches_holster_slot(cur_wep, "special")) then
        local off_x, off_y, off_z = resolve_special_offsets(P)
        refresh_special_zone(special, true, off_x, off_y, off_z,
            P.special_trigger_dist, P.special_release_dist,
            hand_pos, nil)
        in_any = in_any or special.in_zone
    else
        special.in_zone = false
    end

    return in_any
end

local function pick_closest_from_list(list)
    local best = nil
    for _, c in ipairs(list) do
        if not best or (c.state.last_dist or 999) < (best.state.last_dist or 999) then
            best = c
        end
    end
    return best
end

--- Prefer cross-holster draw (pistol out + shoulder grab) over stow at wrong zone (hip steals shoulder).
local function pick_closest_holster_zone(holster_zones, cur_wep)
    local active = {}
    for _, c in ipairs(holster_zones) do
        if c.state.in_zone and (c.can_stow or c.can_draw) then
            active[#active + 1] = c
        end
    end
    if #active == 0 then return nil end

    local cur_slot = holster_slot_for_weapon_id(cur_wep)
    if cur_slot then
        local cross_draw = {}
        for _, c in ipairs(active) do
            if c.can_draw and c.slot ~= cur_slot then
                cross_draw[#cross_draw + 1] = c
            end
        end
        if #cross_draw > 0 then
            local hip_draw = nil
            local other_draw = {}
            for _, c in ipairs(cross_draw) do
                if c.slot == "pistol" then hip_draw = c
                else other_draw[#other_draw + 1] = c end
            end
            if cur_slot == "longarm" and hip_draw then
                return hip_draw
            end
            if cur_slot == "pistol" and #other_draw > 0 then
                return pick_closest_from_list(other_draw)
            end
            return pick_closest_from_list(cross_draw)
        end

        local home_stow = {}
        for _, c in ipairs(active) do
            if c.can_stow and c.slot == cur_slot then
                home_stow[#home_stow + 1] = c
            end
        end
        if #home_stow > 0 then
            return pick_closest_from_list(home_stow)
        end
    end

    return pick_closest_from_list(active)
end

local CAP = { delay = 5.0, target = nil, deadline = 0, last_beep = -1 }
local MAG_CAL = { last_beep = -1 }

local function start_capture(target)
    CAP.target = target
    CAP.deadline = os.clock() + CAP.delay
    CAP.last_beep = -1
end

re.on_pre_application_entry("UpdateBehavior", function()
    if not CFG.enabled or not CFG.suppress_shoot_ready_in_holster_zone then
        clear_weapon_hold_suppress()
    else
        local holster_in_zone = refresh_weapon_holster_zones_for_suppress()
        sync_weapon_hold_suppress(holster_in_zone)
    end
    apply_holster_vr_input_suppress()
end)

re.on_frame(function()
    tick_shoot_ready_suppress()
    execute_pending_action()
    tick_shoot_ready_suppress()

    local P = get_profile()
    local rj_cap = get_right_joystick()

    if CAP.target then
        local now = os.clock()
        local remaining = CAP.deadline - now
        if remaining <= 0 then
            local cap_hand = get_right_hand_pos()
            local hmd_cap, right_cap, up_cap, fwd_cap = holster_capture_pose(CAP.target)
            if cap_hand and hmd_cap and right_cap and up_cap and fwd_cap then
                local off_x, off_y, off_z = decompose_hand_offset(
                    cap_hand, hmd_cap, right_cap, up_cap, fwd_cap)
                if CAP.target == "hip" then
                    P.hip_pistol_off_right = off_x
                    P.hip_pistol_off_up = off_y
                    P.hip_pistol_off_forward = off_z
                elseif CAP.target == "shoulder" then
                    P.shoulder_off_x = off_x
                    P.shoulder_off_y = off_y
                    P.shoulder_off_z = off_z
                elseif CAP.target == "chest" then
                    P.chest_off_x = off_x
                    P.chest_off_y = off_y
                    P.chest_off_z = off_z
                elseif CAP.target == "special" then
                    -- No minimum-offset rejection here (unlike the other
                    -- 3 slots' implicit "hand too close" concern doesn't
                    -- apply) -- a near-zero offset is the desired/default
                    -- case for this slot, not a bad calibration sample.
                    P.special_off_x = off_x
                    P.special_off_y = off_y
                    P.special_off_z = off_z
                end
                save_cfg()
                local joy_cap_done = rj_cap
                if joy_cap_done then haptic_pulse(joy_cap_done, 0.25, 250.0, 1.0) end
            end
            CAP.target = nil
            CAP.last_beep = -1
        else
            local int_s = math.ceil(remaining)
            if int_s ~= CAP.last_beep then
                CAP.last_beep = int_s
                if rj_cap then haptic_pulse(rj_cap, 0.06, 160.0, 0.6) end
            end
        end
    end

    do
        local get_rem = rawget(_G, "__vr_mag_holster_get_capture_remaining")
        if type(get_rem) == "function" then
            local rem = get_rem()
            if rem == nil then
                MAG_CAL.last_beep = -1
            elseif rem > 0 then
                local int_s = math.ceil(rem)
                if int_s ~= MAG_CAL.last_beep then
                    MAG_CAL.last_beep = int_s
                    local lj_mag = get_left_joystick()
                    if lj_mag then haptic_pulse(lj_mag, 0.06, 160.0, 0.6) end
                end
            end
            if rem ~= nil then
                local mag_tick = rawget(_G, "__vr_mag_holster_tick_calibrate")
                if type(mag_tick) == "function" then
                    mag_tick()
                end
            end
        end
    end

    if CFG.head_flashlight_enabled then
        -- Always track the physical trigger state/edge regardless of
        -- suppression, and only gate the ACTUAL toggle on it -- same
        -- reasoning as the old X-button version had: force-resetting the
        -- prev-state while suppressed would misread the tail end of a
        -- single held press as a fresh edge the instant suppression lifts.
        if not vr_flash.lt_action or vr_flash.lt_action == 0 then
            pcall(function() vr_flash.lt_action = vrmod:get_action_trigger() end)
        end
        local lj_lt = get_left_joystick()
        local lt_down = false
        if vr_flash.lt_action and lj_lt then
            local ok_lt, active = pcall(function()
                return vrmod:is_action_active(vr_flash.lt_action, lj_lt)
            end)
            lt_down = ok_lt and active == true
        end
        local lt_suppressed = is_left_grip_pressed() or is_right_grip_pressed()
            or block_weapon_inputs_active()

        if lt_down and not vr_flash.lt_prev and not lt_suppressed then
            flashlight_power = not flashlight_power
            apply_vr_head_flashlight_toggle()
        end
        vr_flash.lt_prev = lt_down

        maintain_vr_head_flashlight_state()
    end

    if not CFG.enabled then
        return
    end

    if is_menu_blocking() then
        silence_all_zones()
        return
    end

    track_weapon()
    suppress_holster_anims()

    if block_weapon_inputs_active() then
        silence_all_zones()
        return
    end

    local cur_wep_block = get_current_weapon_id()
    if cur_wep_block and HOLSTER_DISABLED_WEAPONS[cur_wep_block] then
        silence_all_zones()
        return
    end

    local player_tf = get_player_transform()
    local hand_pos = nil
    if player_tf and refresh_right_hand_joint(player_tf) and GRIP.right_joint then
        hand_pos = safe_call(GRIP.right_joint, "get_Position")
    end
    if not hand_pos then
        hand_pos = get_right_hand_pos()
    end
    if not hand_pos then
        silence_all_zones()
        return
    end

    local grip_now = is_right_grip_pressed()
    local rj = get_right_joystick()
    local grip_was_held = GRIP.aim_prev

    do
        GRIP.aim_prev = grip_now
        GRIP.suppress_haptics_for_aim = grip_now and grip_was_held
    end

    local cur_wep = get_current_weapon_id()
    local holster_zones = {}
    local had_holster_zone = hip.in_zone or shoulder.in_zone or chest.in_zone or special.in_zone

    if cur_wep and is_longarm_category(cur_wep) then
        reconcile_holster_slot_cache(P, "pistol")
    elseif cur_wep and is_pistol_category(cur_wep) then
        reconcile_holster_slot_cache(P, "longarm")
    end

    local hip_zone_active = profile_has_stowed_pistol(P)
        or weapon_id_matches_holster_slot(cur_wep, "pistol")
    if CFG.hip_pistol_enabled and hip_zone_active then
        refresh_holster_zone(hip, true, PLAYER_JOINT.hip,
            P.hip_pistol_off_right, P.hip_pistol_off_up, P.hip_pistol_off_forward,
            P.hip_pistol_trigger_dist, P.hip_pistol_release_dist,
            hand_pos, rj, "hip")
        holster_zones[#holster_zones + 1] = {
            slot = "pistol",
            state = hip,
            cooldown = P.hip_pistol_cooldown,
            can_stow = weapon_id_matches_holster_slot(cur_wep, "pistol"),
            can_draw = profile_has_stowed_pistol(P)
                and (not cur_wep or not weapon_id_matches_holster_slot(cur_wep, "pistol")),
        }
    else
        hip.in_zone = false
    end

    if CFG.shoulder_enabled and (profile_has_stowed_longarm(P) or weapon_id_matches_holster_slot(cur_wep, "longarm")) then
        refresh_holster_zone(shoulder, true, PLAYER_JOINT.shoulder,
            P.shoulder_off_x, P.shoulder_off_y, P.shoulder_off_z,
            P.shoulder_trigger_dist, P.shoulder_release_dist,
            hand_pos, rj, "shoulder")
        holster_zones[#holster_zones + 1] = {
            slot = "longarm",
            state = shoulder,
            cooldown = P.shoulder_cooldown,
            can_stow = weapon_id_matches_holster_slot(cur_wep, "longarm"),
            can_draw = profile_has_stowed_longarm(P)
                and (not cur_wep or not weapon_id_matches_holster_slot(cur_wep, "longarm")),
        }
    else
        shoulder.in_zone = false
    end

    if CFG.chest_enabled and (profile_has_stowed_chest(P) or weapon_id_matches_holster_slot(cur_wep, "chest")) then
        refresh_holster_zone(chest, true, PLAYER_JOINT.chest,
            P.chest_off_x, P.chest_off_y, P.chest_off_z,
            P.chest_trigger_dist, P.chest_release_dist,
            hand_pos, rj, "chest")
        holster_zones[#holster_zones + 1] = {
            slot = "chest",
            state = chest,
            cooldown = P.chest_cooldown,
            can_stow = weapon_id_matches_holster_slot(cur_wep, "chest"),
            can_draw = profile_has_stowed_chest(P)
                and (not cur_wep or not weapon_id_matches_holster_slot(cur_wep, "chest")),
        }
    else
        chest.in_zone = false
    end

    if CFG.special_enabled and (profile_has_stowed_special(P) or weapon_id_matches_holster_slot(cur_wep, "special")) then
        local off_x, off_y, off_z = resolve_special_offsets(P)
        refresh_special_zone(special, true, off_x, off_y, off_z,
            P.special_trigger_dist, P.special_release_dist,
            hand_pos, rj)
        holster_zones[#holster_zones + 1] = {
            slot = "special",
            state = special,
            cooldown = P.special_cooldown,
            can_stow = weapon_id_matches_holster_slot(cur_wep, "special"),
            can_draw = profile_has_stowed_special(P)
                and (not cur_wep or not weapon_id_matches_holster_slot(cur_wep, "special")),
        }
    else
        special.in_zone = false
    end

    local has_holster_zone = hip.in_zone or shoulder.in_zone or chest.in_zone or special.in_zone
    if has_holster_zone and not had_holster_zone then
        if grip_now and grip_was_held then
            GRIP.holster_prev = true
        else
            GRIP.holster_prev = false
        end
    end

    local closest = pick_closest_holster_zone(holster_zones, cur_wep)
    local grab_ready = closest and closest.state.in_zone and grip_now
    local grab_edge = grab_ready and not GRIP.holster_prev and not GRIP.suppress_haptics_for_aim
    GRIP.holster_prev = grip_now

    if closest and grab_edge and not manual_reload_blocks_holster() then
        local now = os.clock()
        if now - (closest.state.last_grab_t or -1) >= (closest.cooldown or 0.6) then
            closest.state.last_grab_t = now
            closest.state.trigger_count = (closest.state.trigger_count or 0) + 1
            if rj then
                holster_haptic_pulse(rj, CFG.grab_haptic_duration, CFG.grab_haptic_frequency, CFG.grab_haptic_amplitude)
            end
            if closest.can_draw and (not cur_wep or holster_slot_for_weapon_id(cur_wep) ~= closest.slot) then
                HOLSTER_ACTION.pending = { kind = "equip", slot = closest.slot }
            elseif closest.can_stow and weapon_id_matches_holster_slot(cur_wep, closest.slot) then
                HOLSTER_ACTION.pending = { kind = "unequip" }
            end
        end
    end

    local holster_in_zone = hip.in_zone or shoulder.in_zone or chest.in_zone or special.in_zone
    sync_weapon_hold_suppress(holster_in_zone)
    apply_holster_vr_input_suppress()
end)

local RELEASE_MARGIN = 0.10

local function apply_profile_trigger(P, trigger_k, release_k, val)
    P[trigger_k] = val
    P[release_k] = math.max(val + RELEASE_MARGIN, val * 1.25)
end

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

local function draw_holster_calibrate(cap_target, label)
    if CAP.target == cap_target then
        imgui.text(string.format(
            ">>> %s capture in %.1fs — hold controller still (haptic/s)",
            label, math.max(0, CAP.deadline - os.clock())))
        return
    end
    imgui.push_style_color(0, UI_BTN)
    if imgui.button(string.format("Calibrate %s (+5Sec)", label)) then
        start_capture(cap_target)
    end
    imgui.pop_style_color(1)
end

local function draw_holster_ui_block(id, label, enabled_key, cap_target, trigger_k, release_k, haptic_en_key, haptic_cont_key)
    local dirty = false
    local c, v = draw_feature_enable_toggle(CFG[enabled_key], "holster_" .. id, label)
    if c then CFG[enabled_key] = v; dirty = true end

    if not CFG[enabled_key] then
        return dirty
    end

    draw_holster_calibrate(cap_target, label)

    local P = get_profile()
    local tdc, tdv = imgui.slider_float(label .. " Trigger Distance (m)", P[trigger_k], 0.10, 0.60, "%.2f")
    if tdc then
        apply_profile_trigger(P, trigger_k, release_k, tdv)
        dirty = true
    end

    c, v = imgui.checkbox("##holster_" .. id .. "_rumble", CFG[haptic_en_key] ~= false)
    imgui.same_line()
    imgui.text_colored("Enable", UI_ACCENT)
    imgui.same_line()
    imgui.text(label .. " Zone Rumble")
    if c then CFG[haptic_en_key] = v; dirty = true end

    c, v = imgui.checkbox("##holster_" .. id .. "_rumble_cont", CFG[haptic_cont_key] == true)
    imgui.same_line()
    imgui.text("Continuous zone rumble (off = enter pulse only)")
    if c then CFG[haptic_cont_key] = v; dirty = true end

    return dirty
end

local function draw_mag_holster_calibrate()
    local mag_remaining = nil
    if _G.__vr_mag_holster_get_capture_remaining then
        mag_remaining = _G.__vr_mag_holster_get_capture_remaining()
    end
    if mag_remaining and mag_remaining > 0 then
        imgui.text(string.format(
            ">>> Ammo Holster capture in %.1fs — hold controller still (haptic/s)",
            mag_remaining))
        return
    end
    imgui.push_style_color(0, UI_BTN)
    if imgui.button("Calibrate Ammo Holster (+5Sec)") then
        MAG_CAL.last_beep = -1
        if _G.__vr_mag_holster_start_calibrate then
            _G.__vr_mag_holster_start_calibrate()
        end
    end
    imgui.pop_style_color(1)
end

local function draw_mag_holster_ui_block()
    local mag_dirty = false

    imgui.text_colored("Ammo Holster", UI_ACCENT)


    local get_mag_cfg = rawget(_G, "__vr_mag_holster_get_cfg")
    local set_mag_field = rawget(_G, "__vr_mag_holster_set_cfg_field")
    local save_mag_cfg = rawget(_G, "__vr_mag_holster_save_cfg")
    local mag_cfg = (type(get_mag_cfg) == "function") and get_mag_cfg() or nil
    if not mag_cfg or type(set_mag_field) ~= "function" then
        imgui.text_colored("Reload extension not loaded.", UI_MUTED)
        return false
    end

    draw_mag_holster_calibrate()

    local trigger = tonumber(mag_cfg.trigger_dist) or 0.25
    local tdc, tdv = imgui.slider_float("Ammo Holster Trigger Distance (m)", trigger, 0.10, 0.60, "%.2f")
    if tdc then
        set_mag_field("trigger_dist", tdv)
        set_mag_field("release_dist", math.max(tdv + RELEASE_MARGIN, tdv * 1.25))
        mag_dirty = true
    end

    if mag_dirty and type(save_mag_cfg) == "function" then
        save_mag_cfg()
    end
    return mag_dirty
end

local function draw_holster_ui()
    if not imgui then return end

    local dirty = false
    local c, v

    imgui.text_colored("Holsters:", UI_ACCENT)

    c, v = draw_feature_enable_toggle(CFG.enabled, "holster_master", "Holster")
    if c then CFG.enabled = v; dirty = true end

    local hi = tonumber(CFG.haptic_intensity) or 1.0
    local hic, hiv = imgui.slider_float("Holster Haptic Intensity", hi, 0.0, 1.0, "%.2f")
    if hic then CFG.haptic_intensity = hiv; dirty = true end

    if CFG.enabled then
        if draw_holster_ui_block(
            "hip", "Hip Holster", "hip_pistol_enabled", "hip",
            "hip_pistol_trigger_dist", "hip_pistol_release_dist",
            "hip_zone_haptic_enabled", "hip_zone_haptic_continuous") then
            dirty = true
        end
        if draw_holster_ui_block(
            "shoulder", "Shoulder Holster", "shoulder_enabled", "shoulder",
            "shoulder_trigger_dist", "shoulder_release_dist",
            "shoulder_zone_haptic_enabled", "shoulder_zone_haptic_continuous") then
            dirty = true
        end
        if draw_holster_ui_block(
            "chest", "Left Hip Holster", "chest_enabled", "chest",
            "chest_trigger_dist", "chest_release_dist",
            "chest_zone_haptic_enabled", "chest_zone_haptic_continuous") then
            dirty = true
        end
        if draw_holster_ui_block(
            "special", "Special Holster (head)", "special_enabled", "special",
            "special_trigger_dist", "special_release_dist",
            "special_zone_haptic_enabled", "special_zone_haptic_continuous") then
            dirty = true
        end

        -- Flashlight is left-trigger-toggled now, not zone-based -- just a
        -- plain enable switch, no calibration/distance/haptics needed.
        c, v = draw_feature_enable_toggle(CFG.head_flashlight_enabled, "head_flashlight", "Head Flashlight (LT toggle)")
        if c then CFG.head_flashlight_enabled = v; dirty = true end
    end

    draw_mag_holster_ui_block()

    if dirty then save_cfg() end

    imgui.separator()
    imgui.separator()
end

_G.__vr_ui_callbacks = _G.__vr_ui_callbacks or {}
table.insert(_G.__vr_ui_callbacks, { order = 30, fn = draw_holster_ui })

if not _G.__vr_ui_master_installed then
    _G.__vr_ui_master_installed = true
    re.on_draw_ui(function()
        if not _G.__vr_ui_callbacks then return end
        table.sort(_G.__vr_ui_callbacks, function(a, b)
            return (a.order or 0) < (b.order or 0)
        end)
        for _, cb in ipairs(_G.__vr_ui_callbacks) do
            if cb.fn then pcall(cb.fn) end
        end
    end)
end

re.on_script_reset(function()
    HOLSTER_ACTION.shoot_until = 0
    HOLSTER_ACTION.pending = nil
    GRIP.aim_prev = false
    GRIP.holster_prev = false
    GRIP.suppress_haptics_for_aim = false
    WP.id_by_enum = nil
    WP.enum_by_id = nil
    -- The head-flash reach zone (and its suppression of native left-support
    -- input) was dropped along with the reach-gesture toggle -- nothing in
    -- this file writes these two globals anymore, but a stale `true` left
    -- over from a script reload that happened mid-reach (before this
    -- change) would otherwise stick forever, since nothing would ever
    -- clear it again. re2_vr_haptics.lua/re2_vr_recoil.lua/
    -- re2_vr_ik_extention.lua/re2_vr_reload.lua all still read
    -- __vr_in_head_flashlight_zone as an OR-condition alongside
    -- __vr_in_holster_zone, so force both to a clean false here.
    rawset(_G, "__vr_in_head_flashlight_zone", false)
    rawset(_G, "__vr_block_left_support_in_head_flash_zone", false)
    rawset(_G, "__vr_is_menu_blocking", nil)
    rawset(_G, "__vr_is_cinematic_blocking", nil)
    rawset(_G, "__vr_block_shoot_ready", false)
    clear_weapon_hold_suppress()
    CAP.target = nil
    CAP.last_beep = -1
end)

log.info("[re2_vr_holster] Loaded — config: " .. CFG_PATH)

return {}
