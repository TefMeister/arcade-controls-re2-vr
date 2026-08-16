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
-- Uses the real set_EquipType()/get_EquipType() methods (not a raw backing
-- field write) so that whatever side effects the game normally runs on
-- equip change (animation, OnChangeWeapon event, etc.) still fire.
--
-- STATUS: second pass. First attempt (writing the EquipType backing field
-- directly) ran with no errors but had no visible in-game effect, likely
-- because it skipped those side effects. Watch the REFramework log for
-- [re2_vr_subweapon_trigger] lines if this pass still doesn't work.

local vrc_manager = require("vr/VRControllerManager")
local re2 = require("utility/RE2")
local GameObject = require("utility/GameObject")

local NS = sdk.game_namespace

local state = {
    forcing = false,      -- true while we are the one holding EquipType overridden
    previous_value = nil, -- the EquipType we saw right before forcing, to restore exactly
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

    local ok2, current = pcall(function() return equipment:call("get_EquipType") end)
    if not ok2 or current == nil then
        log.warn("[re2_vr_subweapon_trigger] Could not read current EquipType")
        return
    end

    local ok3, err = pcall(function()
        equipment:call("set_EquipType", sub_type)
    end)
    if ok3 then
        state.forcing = true
        state.previous_value = current
    else
        log.warn("[re2_vr_subweapon_trigger] Forcing EquipType failed: " .. tostring(err))
    end
end

local function stop_force(equipment)
    if state.previous_value ~= nil then
        local ok, err = pcall(function()
            equipment:call("set_EquipType", state.previous_value)
        end)
        if not ok then
            log.warn("[re2_vr_subweapon_trigger] Restoring EquipType failed: " .. tostring(err))
        end
    end
    state.forcing = false
    state.previous_value = nil
end

re.on_frame(function()
    local equipment = get_equipment()
    if not equipment then
        if state.forcing then
            -- Lost our reference while still forcing; nothing we can safely
            -- clear it on, just drop our own bookkeeping.
            state.forcing = false
            state.previous_value = nil
        end
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
