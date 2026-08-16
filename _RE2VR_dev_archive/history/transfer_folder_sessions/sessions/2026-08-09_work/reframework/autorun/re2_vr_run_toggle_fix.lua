-- VR-friendly run toggle. Native RE2 has a "Run Type" control option
-- (Toggle/Hold/Always) -- confirmed live (2026-08-09) that "Toggle" mode is
-- actually a one-way latch (pressing the toggle key again mid-movement does
-- nothing; running only clears on a full stop) while "Hold" mode correctly
-- ties running to real-time input (stops the instant the key is released).
-- Holding a button continuously is awkward in VR though, so this script
-- keeps the native option on Hold and does the toggle UX itself: press
-- LThumb (left joystick click) once to arm running, and it auto-disarms
-- the instant the stick returns to neutral OR LThumb is pressed again --
-- exactly the behavior originally asked for.
--
-- Deliberately does NOT touch IsJog/IsWalk/IsIdle or any FSM-owned flag
-- directly -- two direct-write attempts on FSM state elsewhere in this
-- project caused real breakage (a full game hang on NewInventoryDetailBehavior.
-- IsFinish, and a suspected-but-unconfirmed movement freeze on IsJog here).
-- Instead this uses SurvivorDefine.ActionOrder.Petient's JOG order via
-- PlayerActionOrderer:setInhibitPetient(bool, order) -- a real, intended
-- game API already used safely elsewhere in this exact mod
-- (re2_vr_reload.lua inhibits/clears PATIENT_ORDER_JOG and
-- PATIENT_ORDER_HOLD_WALK around manual reload sequences). Inhibiting an
-- action order blocks the game's own logic from ever entering that state,
-- rather than fighting/forcing the state directly.
--
-- IMPORTANT: still needs the native "Run Type" option set to Hold in
-- RE2's own Options -> Controls menu for this to make sense -- if it's
-- left on native Toggle, this script's own toggle and the native one will
-- fight each other.
--
-- Ships DISABLED by default -- same "ship disabled, verify live" pattern
-- used for the RE3 torso-twist port, which worked cleanly first try.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace
local statics = require("utility/Statics")

local PetientOrderEnum = statics.generate(NS("SurvivorDefine.ActionOrder.Petient"))
local PATIENT_ORDER_JOG = PetientOrderEnum.JOG or 256

local state = {
    enabled = false, -- off by default -- verify live before trusting
    run_armed = false,
    survivor_condition_type = nil,
    joystick_click_action = nil,
    was_click_down = false,
    last_stick_mag = 0.0,
    status = "idle",
    inhibit_applied = nil, -- last value actually sent, to avoid redundant calls/logs
}

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

local function get_survivor_condition(player)
    if not player then return nil end
    if not state.survivor_condition_type then
        state.survivor_condition_type = sdk.typeof(NS("survivor.SurvivorCondition"))
    end
    if not state.survivor_condition_type then return nil end
    return safe(function()
        return player:call("getComponent(System.Type)", state.survivor_condition_type)
    end)
end

local function get_action_orderer(cond)
    if not cond then return nil end
    return safe(function() return cond:call("get_ActionOrderer") end)
end

local function get_left_stick_axis()
    if vrmod and vrmod.is_using_controllers and vrmod:is_using_controllers() then
        local ok, axis = pcall(function() return vrmod:get_left_stick_axis() end)
        if ok and axis then return axis end
    end
    return nil
end

local function poll_joystick_click_edge()
    if not vrmod then return false end
    if not state.joystick_click_action then
        pcall(function() state.joystick_click_action = vrmod:get_action_joystick_click() end)
    end
    if not state.joystick_click_action then return false end
    local lj = safe(function() return vrmod:get_left_joystick() end)
    if not lj then return false end
    local down = safe(function() return vrmod:is_action_active(state.joystick_click_action, lj) end) == true
    local pressed_edge = down and not state.was_click_down
    state.was_click_down = down
    return pressed_edge
end

-- Applies the inhibit only when the target value actually changes -- avoids
-- calling into native code every single frame for no reason.
local function apply_jog_inhibit(action_orderer, want_inhibited)
    if state.inhibit_applied == want_inhibited then return end
    local ok = pcall(function() action_orderer:call("setInhibitPetient", want_inhibited, PATIENT_ORDER_JOG) end)
    if ok then
        state.inhibit_applied = want_inhibited
    end
end

local function clear_inhibit_if_applied(action_orderer)
    if state.inhibit_applied == nil or state.inhibit_applied == false then return end
    if action_orderer then
        pcall(function() action_orderer:call("setInhibitPetient", false, PATIENT_ORDER_JOG) end)
    end
    state.inhibit_applied = nil
end

re.on_application_entry("UpdateBehavior", function()
    local player = re2.get_localplayer()
    if not player then return end
    local cond = get_survivor_condition(player)
    if not cond then return end
    local ao = get_action_orderer(cond)

    if not state.enabled then
        -- Disabled: make sure we're not leaving the player stuck with jog
        -- blocked from a previous session/toggle.
        clear_inhibit_if_applied(ao)
        state.run_armed = false
        state.status = "disabled"
        return
    end

    if not ao then
        state.status = "no ActionOrderer available"
        return
    end

    local axis = get_left_stick_axis()
    local mag = axis and axis:length() or 0.0
    state.last_stick_mag = mag

    local pressed = poll_joystick_click_edge()
    if pressed then
        state.run_armed = not state.run_armed
    end

    -- Auto-disarm the instant the stick returns to neutral -- this is the
    -- actual behavior originally asked for (running shouldn't survive a
    -- full stop and silently resume on the next movement).
    if mag <= 0.05 and state.run_armed then
        state.run_armed = false
    end

    apply_jog_inhibit(ao, state.run_armed ~= true)
    state.status = string.format("armed=%s stick_mag=%.2f jog_inhibited=%s",
        tostring(state.run_armed), mag, tostring(state.inhibit_applied))
end)

re.on_script_reset(function()
    -- Best-effort: can't reach the ActionOrderer from here (no player
    -- context guaranteed at reset time), but clear our own state so a
    -- fresh load starts clean. The UpdateBehavior handler above will also
    -- clear the native inhibit on its next tick if state.enabled is false.
    state.run_armed = false
    state.inhibit_applied = nil
    state.enabled = false
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("VR run toggle fix (uses PlayerActionOrderer.setInhibitPetient, not raw FSM writes)")
    imgui.text_colored(
        "Requires RE2's native Options -> Controls -> Run Type set to HOLD, not Toggle.",
        0xFF88CCFF)

    local c, v = imgui.checkbox("Enable VR-friendly run toggle", state.enabled)
    if c then state.enabled = v end

    imgui.text("Status: " .. tostring(state.status))
    imgui.text("Left stick magnitude: " .. string.format("%.3f", state.last_stick_mag))
end)

log.info("[re2_vr_run_toggle_fix] Loaded")
