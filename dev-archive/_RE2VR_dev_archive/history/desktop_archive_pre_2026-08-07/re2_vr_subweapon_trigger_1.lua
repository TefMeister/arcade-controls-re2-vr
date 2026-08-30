-- re2_vr_subweapon_trigger.lua
--
-- Holding RIGHT TRIGGER alone forces the player's current sub-weapon
-- (knife/grenade, whatever is currently assigned) into the right hand,
-- instantly, without needing the native left-grip + weapondial combo.
--
-- Suppressed (does nothing) whenever right grip or left grip is held, so it
-- never interferes with:
--   - normal firing (right grip + right trigger)
--   - two-handing a long gun (left grip + right grip)
--
-- Built on the same instance-lookup pattern already used in
-- re2_vr_grenade.lua / re2_vr_melee.lua (re2.get_localplayer() ->
-- GameObject.get_component(..., "survivor.Equipment")).
--
-- STATUS: sixth pass.
--   Attempt 1: called set_ForceEquipType(sub_type) via method call -> threw
--              an exception every frame (likely Nullable<T> marshaling).
--   Attempt 2: wrote EquipType directly (field, then real setter) -> ran
--              clean, no errors, but had no visible effect -- almost
--              certainly because EquipType is recomputed every frame by the
--              game's own updateEquip() and our write gets stomped before
--              it's ever rendered.
--   Attempt 3: back to ForceEquipType via raw field write -> ran clean, and
--              this time there was a real reaction: a brief equip sound
--              played on trigger-press, but it reverted instantly with no
--              visual change. That sound is a genuine side effect, so this
--              is the right hook -- but we were only writing it once, on
--              the initial press.
--   Attempt 4: kept reasserting ForceEquipType every frame instead -> the
--              sound went away completely, which suggests the game reacts
--              to a CHANGE in the field (nil -> value), not to it merely
--              being present, so writing the same value every frame reads
--              as "no change" and does nothing.
--   Attempt 5: found changeWeapon(EquipCategory, WeaponType, WeaponParts),
--              whose signature matches the onChangeWeapon event exactly, so
--              it looked like the real "commit" method -> ran clean, but
--              this time there was NOT EVEN THE SOUND from attempt 3. Total
--              silence. changeWeapon may be more of an inventory-slot
--              assignment function than a "put this in hand right now"
--              trigger.
--   Attempt 6 (this one): a fuller method dump turned up a THIRD distinct
--              thing named setForceEquipType(Nullable<WeaponType>,
--              Nullable<WeaponParts>, bool) -- a real method, not the same
--              as the set_ForceEquipType property (attempt 1, threw) or the
--              raw field write (attempts 3/4). The extra bool param may be
--              an explicit "apply now" flag that the raw field write was
--              missing. Called once on press/release (not every frame),
--              same lesson as attempt 4.
-- Watch the REFramework log for [re2_vr_subweapon_trigger] lines either way.

local vrc_manager = require("vr/VRControllerManager")
local re2 = require("utility/RE2")
local GameObject = require("utility/GameObject")

local NS = sdk.game_namespace

-- From app.ropeway.EquipmentDefine.WeaponParts, confirmed via
-- re2_enum_probe.lua's log output.
local WEAPON_PARTS_NONE = 0

local state = {
    forcing = false, -- true while we are the one holding sub-weapon forced
}

local function get_equipment()
    local ok, player = pcall(function() return re2.get_localplayer() end)
    if not ok or not player then return nil end

    local ok2, equipment = pcall(function()
        return GameObject.get_component(player, NS("survivor.Equipment"))
    end)
    if not ok2 or not equipment then return nil end

    return equipment
end

local function read_right_trigger()
    local right = vrc_manager.controllers_list[2]
    if not right then return false end
    local ok, active = pcall(function()
        return right:is_action_active(vrc_manager.Actions.TRIGGER)
    end)
    return ok and active == true
end

local function read_grip(index)
    local controller = vrc_manager.controllers_list[index]
    if not controller then return false end
    local ok, active = pcall(function()
        return controller:is_action_active(vrc_manager.Actions.GRIP)
    end)
    return ok and active == true
end

local function start_force(equipment)
    local ok1, sub_type = pcall(function() return equipment:get_field("_SubType") end)
    if not ok1 or sub_type == nil then
        log.warn("[re2_vr_subweapon_trigger] Could not read _SubType")
        return
    end

    local ok3, err = pcall(function()
        equipment:call("setForceEquipType", sub_type, WEAPON_PARTS_NONE, true)
    end)
    if ok3 then
        state.forcing = true
    else
        log.warn("[re2_vr_subweapon_trigger] setForceEquipType(sub) failed: " .. tostring(err))
    end
end

local function stop_force(equipment)
    local ok, err = pcall(function()
        equipment:call("setForceEquipType", nil, nil, true)
    end)
    if not ok then
        log.warn("[re2_vr_subweapon_trigger] setForceEquipType(clear) failed: " .. tostring(err))
    end
    state.forcing = false
end

re.on_frame(function()
    local equipment = get_equipment()
    if not equipment then
        state.forcing = false
        return
    end

    local right_trigger = read_right_trigger()
    local right_grip = read_grip(2)
    local left_grip = read_grip(1)

    local want_sub = right_trigger and not right_grip and not left_grip

    if want_sub and not state.forcing then
        start_force(equipment)
    elseif (not want_sub) and state.forcing then
        stop_force(equipment)
    end
end)

log.info("[re2_vr_subweapon_trigger] Loaded.")
