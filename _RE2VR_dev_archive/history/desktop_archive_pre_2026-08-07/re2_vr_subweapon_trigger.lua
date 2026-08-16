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
-- STATUS: fourth pass.
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
--              the initial press. If the game treats ForceEquipType as a
--              one-shot command it clears after reading, a single write
--              isn't enough to hold the transition through to completion.
--   Attempt 4 (this one): keep reasserting ForceEquipType every frame while
--              the trigger is held, instead of writing it once on the edge.
-- Watch the REFramework log for [re2_vr_subweapon_trigger] lines either way.

local vrc_manager = require("vr/VRControllerManager")
local re2 = require("utility/RE2")
local GameObject = require("utility/GameObject")

local NS = sdk.game_namespace

local state = {
    forcing = false, -- true while we are the one holding ForceEquipType overridden
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
        equipment:set_field("<ForceEquipType>k__BackingField", sub_type)
    end)
    if ok3 then
        state.forcing = true
    else
        log.warn("[re2_vr_subweapon_trigger] Forcing ForceEquipType failed: " .. tostring(err))
    end
end

local function stop_force(equipment)
    local ok, err = pcall(function()
        equipment:set_field("<ForceEquipType>k__BackingField", nil)
    end)
    if not ok then
        log.warn("[re2_vr_subweapon_trigger] Clearing ForceEquipType failed: " .. tostring(err))
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

    if want_sub then
        -- Reassert every frame. If ForceEquipType behaves like a one-shot
        -- command that the game clears after reading it, a single write on
        -- the initial press isn't enough to hold the equip through to
        -- completion -- so we just keep writing it while the trigger is held.
        start_force(equipment)
    elseif state.forcing then
        stop_force(equipment)
    end
end)

log.info("[re2_vr_subweapon_trigger] Loaded.")
