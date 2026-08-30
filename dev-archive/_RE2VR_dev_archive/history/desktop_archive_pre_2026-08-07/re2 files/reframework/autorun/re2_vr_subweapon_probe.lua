-- Diagnostic only: watches which VR button (grip vs trigger, left vs right)
-- is actually driving the game's "sub weapon ready" input.
-- Safe to delete after checking the log.

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

if not vrmod then
    log.warn("[re2_vr_subweapon_probe] vrmod not available, aborting")
    return
end

local vrc_manager = require("vr/VRControllerManager")
local statics = require("utility/Statics")

local NS = sdk.game_namespace
local KIND = statics.generate(NS("InputDefine.Kind"))

local SUPPORT_HOLD = KIND.SUPPORT_HOLD or 128
local HOLD = KIND.HOLD or 64

local BUTTON_OFF = { Down = 0x10, On = 0x18, Up = 0x20 }

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

local function read_button_bits()
    local input_system = sdk.get_managed_singleton(NS("InputSystem"))
    if not input_system then return nil end

    local ok, bb = pcall(function() return input_system:call("get_ButtonBits") end)
    if not ok or not bb then return nil end

    return {
        Down = read_u64_field(bb, "Down"),
        On = read_u64_field(bb, "On"),
        Up = read_u64_field(bb, "Up"),
    }
end

local function bit_set(value, mask)
    if type(value) ~= "number" or not mask then return false end
    return (value & mask) ~= 0
end

local last = {
    left_grip = false,
    right_grip = false,
    left_trigger = false,
    right_trigger = false,
    support_hold_on = false,
    hold_on = false,
}

log.info("[re2_vr_subweapon_probe] Started. Press grip/trigger on each controller in-game and watch the log for SUPPORT_HOLD/HOLD edges.")

local function input_snapshot()
    return "L_grip=" .. tostring(last.left_grip)
        .. " R_grip=" .. tostring(last.right_grip)
        .. " L_trig=" .. tostring(last.left_trigger)
        .. " R_trig=" .. tostring(last.right_trigger)
end

re.on_frame(function()
    if not vrc_manager:has_controllers() then return end

    local lc = vrc_manager.controllers_list[1]
    local rc = vrc_manager.controllers_list[2]

    local left_grip = (lc and lc:is_action_active(vrc_manager.Actions.GRIP)) == true
    local right_grip = (rc and rc:is_action_active(vrc_manager.Actions.GRIP)) == true
    local left_trigger = (lc and lc:is_action_active(vrc_manager.Actions.TRIGGER)) == true
    local right_trigger = (rc and rc:is_action_active(vrc_manager.Actions.TRIGGER)) == true

    if left_grip ~= last.left_grip then
        log.info("[re2_vr_subweapon_probe] left_grip: " .. tostring(last.left_grip) .. " -> " .. tostring(left_grip))
        last.left_grip = left_grip
    end
    if right_grip ~= last.right_grip then
        log.info("[re2_vr_subweapon_probe] right_grip: " .. tostring(last.right_grip) .. " -> " .. tostring(right_grip))
        last.right_grip = right_grip
    end
    if left_trigger ~= last.left_trigger then
        log.info("[re2_vr_subweapon_probe] left_trigger: " .. tostring(last.left_trigger) .. " -> " .. tostring(left_trigger))
        last.left_trigger = left_trigger
    end
    if right_trigger ~= last.right_trigger then
        log.info("[re2_vr_subweapon_probe] right_trigger: " .. tostring(last.right_trigger) .. " -> " .. tostring(right_trigger))
        last.right_trigger = right_trigger
    end

    local bits = read_button_bits()
    if bits then
        local support_hold_on = bit_set(bits.On, SUPPORT_HOLD)
        local hold_on = bit_set(bits.On, HOLD)

        if support_hold_on ~= last.support_hold_on then
            log.info("[re2_vr_subweapon_probe] SUPPORT_HOLD (sub weapon ready): "
                .. tostring(last.support_hold_on) .. " -> " .. tostring(support_hold_on)
                .. "  [" .. input_snapshot() .. "]")
            last.support_hold_on = support_hold_on
        end

        if hold_on ~= last.hold_on then
            log.info("[re2_vr_subweapon_probe] HOLD (main weapon ready): "
                .. tostring(last.hold_on) .. " -> " .. tostring(hold_on)
                .. "  [" .. input_snapshot() .. "]")
            last.hold_on = hold_on
        end
    end
end)
