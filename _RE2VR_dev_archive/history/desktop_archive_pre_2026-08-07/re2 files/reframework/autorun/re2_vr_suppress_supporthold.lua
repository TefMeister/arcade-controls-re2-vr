-- Prevents the sub-weapon from ever appearing while RG (right grip) is
-- held, regardless of what LG is doing.
--
-- Background: the native "SUPPORT_HOLD" input flag (InputSystem's
-- ButtonBits) triggers off LG's press and persists/re-asserts the
-- sub-weapon in hand for as long as LG stays held. An earlier version of
-- this script tried to clear that raw input bit directly every frame, but
-- that turned out to be a losing race against native per-frame
-- recomputation (confirmed live: our clear landed, but the native
-- ready-state still flipped true moments later on the very same
-- interaction).
--
-- This version corrects the RESULT instead of trying to preempt the input:
-- for as long as RG is held, it re-asserts the main weapon into
-- Equipment.ForceEquipType every single frame using the same struct-field
-- mutation technique proven reliable in re2_vr_subweapon_force.lua,
-- overriding whatever the native support-hold logic just tried to do. Once
-- RG is released, it stops forcing and clears the override a few frames
-- later (same pulse-then-clear pattern as that script, to avoid leaving a
-- stale override that could strip attachments later).
--
-- LG+RG is ambiguous on its own -- it's both "add support grip to my main
-- weapon" AND the native grenade-throw gesture (arm/throw whatever's
-- already readied in the off-hand via LG). The two are told apart by
-- ENGAGEMENT ORDER: RG-first-then-LG-joins means two-handing the main
-- weapon (suppress SW); LG-already-held-when-RG-engages means the player
-- deliberately readied a throwable and is now interacting with it (must
-- NOT be interrupted). This is decided once, at the moment RG's rising
-- edge occurs, and stays fixed for that whole RG hold regardless of what
-- LG does afterward.

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

if not vrmod then
    log.warn("[re2_vr_suppress_supporthold] vrmod not available, aborting")
    return
end

local vrc_manager = require("vr/VRControllerManager")
local re2 = require("utility/RE2")
local GameObject = require("utility/GameObject")

local NS = sdk.game_namespace

local FORCE_EQUIP_FIELD = "<ForceEquipType>k__BackingField"
local WEAPON_TYPE_FIELD = "_WeaponType"

-- Found via dump_equipment_parts_fields: Equipment has a paired
-- <ForceEquipParts>k__BackingField alongside ForceEquipType (matches
-- setForceEquipType's real signature taking both a WeaponType and a
-- WeaponParts). Forcing WeaponType alone was what stripped attachments;
-- forcing both together should preserve them.
local FORCE_EQUIP_PARTS_FIELD = "<ForceEquipParts>k__BackingField"
local WEAPON_PARTS_FIELD = "_WeaponParts"

local CLEAR_DELAY_FRAMES = 3
local pending_clear_equipment = nil
local pending_clear_countdown = 0

local last_right_grip = false
local suppress_this_rg_hold = false

log.info("[re2_vr_suppress_supporthold] Started. Forcing main weapon into hand every frame while RG is held.")

local function get_equipment()
    local ok_p, player = pcall(function() return re2.get_localplayer() end)
    if not ok_p or not player then return nil end

    local ok_e, equipment = pcall(function()
        return GameObject.get_component(player, NS("survivor.Equipment"))
    end)
    if not ok_e or not equipment then return nil end

    return equipment
end

-- One-time diagnostic: forcing ForceEquipType alone strips attachments,
-- since WeaponType only identifies the base weapon, not its parts (the
-- muzzle-stripping bug from before -- tolerable there since it was a brief
-- pulse, not tolerable here since we hold it for the whole RG-held
-- duration). setForceEquipType's real signature is
-- (Nullable<WeaponType>, Nullable<WeaponParts>, bool), which strongly
-- implies Equipment has a paired parts-override field alongside
-- ForceEquipType. Dump Equipment's own fields/methods (not the Arm's) for
-- anything containing "part" to find it.
local dumped_equipment_parts = false
local function dump_equipment_parts_fields(equipment)
    if dumped_equipment_parts then return end
    dumped_equipment_parts = true

    local ok_td, td = pcall(function() return equipment:get_type_definition() end)
    if not ok_td or not td then
        log.warn("[re2_vr_suppress_supporthold] could not get Equipment type definition")
        return
    end

    local depth = 0
    while td and depth < 10 do
        local ok_name, full_name = pcall(function() return td:get_full_name() end)
        log.info("[re2_vr_suppress_supporthold] Equipment L" .. depth .. " type: " .. tostring(ok_name and full_name or "?"))

        local ok_m, methods = pcall(function() return td:get_methods() end)
        if ok_m and methods then
            for _, m in ipairs(methods) do
                local ok_n, mname = pcall(function() return m:get_name() end)
                if ok_n and mname and mname:lower():find("part") then
                    log.info("[re2_vr_suppress_supporthold]   [L" .. depth .. "] method: " .. mname)
                end
            end
        end

        local ok_f, fields = pcall(function() return td:get_fields() end)
        if ok_f and fields then
            for _, f in ipairs(fields) do
                local ok_n, fname = pcall(function() return f:get_name() end)
                if ok_n and fname and fname:lower():find("part") then
                    local ok_static, is_static = pcall(function() return f:is_static() end)
                    local ok_v, value
                    if ok_static and is_static then
                        ok_v, value = pcall(function() return f:get_data(nil) end)
                    else
                        ok_v, value = pcall(function() return f:get_data(equipment) end)
                    end
                    log.info("[re2_vr_suppress_supporthold]   [L" .. depth .. "] field: " .. fname
                        .. " = " .. tostring(ok_v and value or "?(get_data failed)"))
                end
            end
        end

        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if not ok_p or not parent then break end
        td = parent
        depth = depth + 1
    end
end

local logged_parts_write = false

local function force_main_weapon(equipment)
    dump_equipment_parts_fields(equipment)

    local ok_arm, arm = pcall(function() return equipment:call("get_MainWeapon") end)
    if not ok_arm or not arm then return end

    local ok_wt, weapon_type = pcall(function() return arm:get_field(WEAPON_TYPE_FIELD) end)
    if not ok_wt or weapon_type == nil then return end

    local ok_wp, weapon_parts = pcall(function() return arm:get_field(WEAPON_PARTS_FIELD) end)

    local ok_before, before = pcall(function() return equipment:get_field(FORCE_EQUIP_FIELD) end)
    if not ok_before or not before then return end

    pcall(function() before:set_field("_HasValue", true) end)
    pcall(function() before:set_field("_Value", weapon_type) end)
    pcall(function() equipment:set_field(FORCE_EQUIP_FIELD, before) end)

    if ok_wp and weapon_parts ~= nil then
        local ok_parts_before, parts_before = pcall(function() return equipment:get_field(FORCE_EQUIP_PARTS_FIELD) end)
        if ok_parts_before and parts_before then
            local ok_ph = pcall(function() parts_before:set_field("_HasValue", true) end)
            local ok_pv = pcall(function() parts_before:set_field("_Value", weapon_parts) end)
            local ok_pset = pcall(function() equipment:set_field(FORCE_EQUIP_PARTS_FIELD, parts_before) end)

            if not logged_parts_write then
                logged_parts_write = true
                log.info("[re2_vr_suppress_supporthold] ForceEquipParts write: weapon_parts="
                    .. tostring(weapon_parts) .. " ok_ph=" .. tostring(ok_ph)
                    .. " ok_pv=" .. tostring(ok_pv) .. " ok_pset=" .. tostring(ok_pset))
            end
        end
    end
end

local function clear_force_equip(equipment)
    local ok_cur, cur = pcall(function() return equipment:get_field(FORCE_EQUIP_FIELD) end)
    if ok_cur and cur then
        pcall(function() cur:set_field("_HasValue", false) end)
        pcall(function() cur:set_field("_Value", 0) end)
        pcall(function() equipment:set_field(FORCE_EQUIP_FIELD, cur) end)
    end

    local ok_parts_cur, parts_cur = pcall(function() return equipment:get_field(FORCE_EQUIP_PARTS_FIELD) end)
    if ok_parts_cur and parts_cur then
        pcall(function() parts_cur:set_field("_HasValue", false) end)
        pcall(function() parts_cur:set_field("_Value", 0) end)
        pcall(function() equipment:set_field(FORCE_EQUIP_PARTS_FIELD, parts_cur) end)
    end

    log.info("[re2_vr_suppress_supporthold] ForceEquipType/ForceEquipParts cleared")
end

re.on_frame(function()
    if not vrc_manager:has_controllers() then return end

    local lc = vrc_manager.controllers_list[1]
    local rc = vrc_manager.controllers_list[2]
    local left_grip = (lc and lc:is_action_active(vrc_manager.Actions.GRIP)) == true
    local right_grip = (rc and rc:is_action_active(vrc_manager.Actions.GRIP)) == true

    if right_grip and not last_right_grip then
        -- RG's rising edge: decide now, once, whether this hold should
        -- suppress SW. LG already held here means the player is mid
        -- grenade-throw (or similar) -- leave it alone.
        suppress_this_rg_hold = not left_grip
        log.info("[re2_vr_suppress_supporthold] RG pressed, LG already held=" .. tostring(left_grip)
            .. " -> suppress_this_hold=" .. tostring(suppress_this_rg_hold))
    end

    if right_grip then
        if suppress_this_rg_hold then
            local equipment = get_equipment()
            if equipment then
                force_main_weapon(equipment)
                pending_clear_equipment = nil
                pending_clear_countdown = 0
            end
        end
    elseif last_right_grip then
        if suppress_this_rg_hold then
            log.info("[re2_vr_suppress_supporthold] RG released, scheduling clear")
            local equipment = get_equipment()
            if equipment then
                pending_clear_equipment = equipment
                pending_clear_countdown = CLEAR_DELAY_FRAMES
            end
        end
        suppress_this_rg_hold = false
    end

    last_right_grip = right_grip

    if pending_clear_countdown > 0 and pending_clear_equipment then
        pending_clear_countdown = pending_clear_countdown - 1
        if pending_clear_countdown == 0 then
            clear_force_equip(pending_clear_equipment)
            pending_clear_equipment = nil
        end
    end
end)
