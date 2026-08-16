-- VR-friendly run toggle. Press LThumb (left joystick click) once to arm
-- running, and it auto-disarms the instant the stick returns to neutral OR
-- LThumb is pressed again -- exactly the behavior originally asked for.
--
-- History: an earlier version of this script tried
-- PlayerActionOrderer:setInhibitPetient(bool, JOG) -- confirmed live
-- (2026-08-09) this does NOT work. Inhibiting only blocks/permits the JOG
-- order; it can't request one, and nothing in the VR control path ever
-- requests one on its own, so un-inhibiting an order nobody's asking for
-- does nothing.
--
-- What actually works: PlayerActionOrderer.get_JogMode/set_JogMode is a
-- real per-frame request flag, confirmed via a read-only observation probe
-- (re2_vr_run_state_probe.lua) -- native code calls set_JogMode(true) every
-- frame while actually jogging and set_JogMode(false) every frame while
-- not, driven by whatever real input triggers running. Deliberately did
-- NOT write to this blind -- a direct write to a *different* FSM flag
-- (IsJog) elsewhere in this investigation froze movement outright, so this
-- was confirmed safe to treat as a real request API (a proper get_/set_
-- pair, not a raw animation-state bool) before ever calling it ourselves.
--
-- First attempt (2026-08-09, superseded): hooked doSurvivorActionOrdererUpdate
-- (the outer update method) and forced JogMode in its POST hook, assuming
-- that was the one and only place set_JogMode gets called per frame.
-- CONFIRMED WRONG live: running still didn't start under Hold, and under
-- Toggle, running would resume if the stick was re-pressed quickly even
-- after our disarm -- both point to set_JogMode being called from more
-- than one place (or at a point our hook didn't actually precede), so
-- "write after this one specific update method" wasn't reliably last.
--
-- Current approach: hook set_JogMode itself, directly, with a PRE hook that
-- overwrites the incoming argument before the native setter ever runs.
-- This intercepts every call to it regardless of how many times or from
-- where it's invoked per frame -- no ordering assumptions needed, unlike
-- the update-method approach above.
--
-- Should work under any native Run Type setting now (Toggle/Hold/Always)
-- since we're forcing the final per-frame value directly rather than
-- depending on native Toggle/Hold semantics -- but Hold is still the
-- recommended setting to avoid native Toggle's own separate stuck-latch
-- behavior fighting this from a different angle.
--
-- Ships ENABLED by default (2026-08-09 onward) -- confirmed working live
-- with the set_JogMode pre-hook override, unlike the earlier
-- setInhibitPetient approach which never worked and stayed disabled.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

local state = {
    enabled = true, -- confirmed working live 2026-08-09, on by default
    run_armed = false,
    joystick_click_action = nil,
    was_click_down = false,
    last_stick_mag = 0.0,
    status = "idle",
    hook_installed = false,
}

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
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

local function install_jog_mode_hook()
    if state.hook_installed then return end
    local ao_type = sdk.find_type_definition(NS("survivor.player.PlayerActionOrderer"))
    if not ao_type then return end
    local m = ao_type:get_method("set_JogMode")
    if not m then return end
    state.hook_installed = true
    sdk.hook(m,
        function(args)
            -- args[2] = this (ActionOrderer instance), args[3] = the bool
            -- native code wants to set. Overwrite it with our own armed
            -- state before the original setter runs, so every call this
            -- frame -- no matter how many or from where -- lands on our
            -- value instead of native's.
            if state.enabled then
                args[3] = sdk.to_ptr(state.run_armed and 1 or 0)
            end
            return sdk.PreHookResult.CALL_ORIGINAL
        end,
        function(retval) return retval end)
    log.info("[re2_vr_run_toggle_fix] Installed set_JogMode override hook")
end

re.on_application_entry("UpdateBehavior", function()
    install_jog_mode_hook()

    if not state.enabled then
        state.run_armed = false
        state.status = "disabled"
        return
    end

    local player = re2.get_localplayer()
    if not player then
        state.status = "no local player"
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

    state.status = string.format("armed=%s stick_mag=%.2f", tostring(state.run_armed), mag)
end)

re.on_script_reset(function()
    state.run_armed = false
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("VR run toggle fix (overrides every set_JogMode call via a pre-hook)")
    imgui.text_colored(
        "Recommended: RE2's native Options -> Controls -> Run Type set to HOLD (not required anymore, but avoids native Toggle's own stuck-latch behavior).",
        0xFF88CCFF)

    local c, v = imgui.checkbox("Enable VR-friendly run toggle", state.enabled)
    if c then state.enabled = v end

    imgui.text("Status: " .. tostring(state.status))
    imgui.text("Left stick magnitude: " .. string.format("%.3f", state.last_stick_mag))
end)

log.info("[re2_vr_run_toggle_fix] Loaded")
