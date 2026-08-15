-- Forces the currently-equipped sub-weapon (knife, grenade, flashbang,
-- whatever) into the player's hand while RT is held alone (no grips), and
-- forces the main weapon back on release.
-- want_sub = RT held AND NOT RG held AND NOT LG held.
--
-- DISABLED (2026-07-31, player request): RT-brings-out-sub-weapon is no
-- longer needed now that re2_vr_suppress_supporthold.lua handles the actual
-- problem (SW must never show while RG is held). Left in place rather than
-- deleted since the ForceEquipType struct-mutation technique here is
-- reusable reference. Remove this early return to re-enable.
if true then
    return
end

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

if not vrmod then
    log.warn("[re2_vr_subweapon_force] vrmod not available, aborting")
    return
end

local vrc_manager = require("vr/VRControllerManager")
local re2 = require("utility/RE2")
local GameObject = require("utility/GameObject")

local NS = sdk.game_namespace

local FORCE_EQUIP_FIELD = "<ForceEquipType>k__BackingField"
local WEAPON_TYPE_FIELD = "_WeaponType"

local last_want_sub = false

log.info("[re2_vr_subweapon_force] Started. Hold RT alone (no grips) to force-equip the sub-weapon.")

-- ForceEquipType is a Nullable<WeaponType> struct with real fields
-- _HasValue/_Value (no setter methods -- must mutate the struct's own
-- fields via reflection). It does not self-clear once raw-written, so every
-- write is treated as a one-shot pulse: set true, then explicitly clear a
-- few frames later. Leaving it permanently set to a bare WeaponType (no
-- WeaponParts info) causes unrelated engine logic that later re-reads it
-- (e.g. the native left-grip support-hold pose) to redraw the weapon from
-- that stale override, stripping attachments (confirmed bug: holding LG
-- removed the Matilda's muzzle until release).
--
-- Only the "back to main weapon" transition auto-clears. The sub-weapon
-- override must stay set for as long as RT is held -- nothing else keeps
-- "sub-weapon" as the real equip state, so clearing it while RT is still
-- down just snaps back to main immediately (confirmed bug: sub-weapon
-- reverted in under a second). Main weapon, by contrast, is already the
-- true underlying equip state, so pulsing it and clearing afterward is safe
-- and prevents the override from lingering.
local CLEAR_DELAY_FRAMES = 3
local pending_clear_equipment = nil
local pending_clear_countdown = 0

local function get_equipment()
    local ok_p, player = pcall(function() return re2.get_localplayer() end)
    if not ok_p or not player then
        log.warn("[re2_vr_subweapon_force] Could not get local player")
        return nil
    end

    local ok_e, equipment = pcall(function()
        return GameObject.get_component(player, NS("survivor.Equipment"))
    end)
    if not ok_e or not equipment then
        log.warn("[re2_vr_subweapon_force] Could not get Equipment component")
        return nil
    end

    return equipment
end

-- Reads the live WeaponType off whichever Arm the given Equipment getter
-- ("get_MainWeapon" or "get_SubWeapon") returns, then force-equips it by
-- mutating the ForceEquipType struct's own _HasValue/_Value fields and
-- writing the whole struct back (a bare int write into the parent field
-- does not set _HasValue).
local function force_equip_from(equipment, arm_getter_name, label, schedule_clear)
    local ok_arm, arm = pcall(function() return equipment:call(arm_getter_name) end)
    if not ok_arm or not arm then
        log.warn("[re2_vr_subweapon_force] " .. arm_getter_name .. "() returned nil, nothing to equip")
        return
    end

    local ok_wt, weapon_type = pcall(function() return arm:get_field(WEAPON_TYPE_FIELD) end)
    if not ok_wt or weapon_type == nil then
        log.warn("[re2_vr_subweapon_force] Could not read live WeaponType from " .. arm_getter_name)
        return
    end

    local ok_before, before = pcall(function() return equipment:get_field(FORCE_EQUIP_FIELD) end)
    if not ok_before or not before then
        log.warn("[re2_vr_subweapon_force] Could not read ForceEquipType struct")
        return
    end

    log.info("[re2_vr_subweapon_force] Forcing " .. label .. " (WeaponType=" .. tostring(weapon_type) .. ") into hand")

    local ok_sh = pcall(function() before:set_field("_HasValue", true) end)
    local ok_sv = pcall(function() before:set_field("_Value", weapon_type) end)
    if not ok_sh or not ok_sv then
        log.warn("[re2_vr_subweapon_force] Failed to set _HasValue/_Value on struct (ok_sh="
            .. tostring(ok_sh) .. ", ok_sv=" .. tostring(ok_sv) .. ")")
        return
    end

    local ok_set = pcall(function() equipment:set_field(FORCE_EQUIP_FIELD, before) end)
    if not ok_set then
        log.warn("[re2_vr_subweapon_force] Failed to write ForceEquipType")
        return
    end

    if schedule_clear then
        pending_clear_equipment = equipment
        pending_clear_countdown = CLEAR_DELAY_FRAMES
    else
        pending_clear_equipment = nil
        pending_clear_countdown = 0
    end
end

local function clear_force_equip(equipment)
    local ok_cur, cur = pcall(function() return equipment:get_field(FORCE_EQUIP_FIELD) end)
    if not ok_cur or not cur then
        log.warn("[re2_vr_subweapon_force] Could not read ForceEquipType to clear it")
        return
    end

    local ok_ch = pcall(function() cur:set_field("_HasValue", false) end)
    local ok_cv = pcall(function() cur:set_field("_Value", 0) end)
    if not ok_ch or not ok_cv then
        log.warn("[re2_vr_subweapon_force] Failed to clear _HasValue/_Value on struct")
        return
    end

    local ok_set = pcall(function() equipment:set_field(FORCE_EQUIP_FIELD, cur) end)
    if not ok_set then
        log.warn("[re2_vr_subweapon_force] Failed to write cleared ForceEquipType")
    end
end

re.on_frame(function()
    if not vrc_manager:has_controllers() then return end

    local lc = vrc_manager.controllers_list[1]
    local rc = vrc_manager.controllers_list[2]

    local lg = (lc and lc:is_action_active(vrc_manager.Actions.GRIP)) == true
    local rg = (rc and rc:is_action_active(vrc_manager.Actions.GRIP)) == true
    local rt = (rc and rc:is_action_active(vrc_manager.Actions.TRIGGER)) == true

    local want_sub = rt and not rg and not lg

    if want_sub and not last_want_sub then
        log.info("[re2_vr_subweapon_force] want_sub turned ON")
        local equipment = get_equipment()
        if equipment then
            force_equip_from(equipment, "get_SubWeapon", "sub-weapon", false)
        end
    elseif not want_sub and last_want_sub then
        log.info("[re2_vr_subweapon_force] want_sub turned OFF")
        local equipment = get_equipment()
        if equipment then
            force_equip_from(equipment, "get_MainWeapon", "main weapon", true)
        end
    end

    last_want_sub = want_sub

    if pending_clear_countdown > 0 and pending_clear_equipment then
        pending_clear_countdown = pending_clear_countdown - 1
        if pending_clear_countdown == 0 then
            clear_force_equip(pending_clear_equipment)
            pending_clear_equipment = nil
        end
    end
end)
