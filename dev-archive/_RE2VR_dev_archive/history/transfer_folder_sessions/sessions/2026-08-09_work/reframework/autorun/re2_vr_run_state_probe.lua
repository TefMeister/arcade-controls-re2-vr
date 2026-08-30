-- Diagnostic (read-only, no writes) for the run/sprint toggle request:
-- user wants running to stop when the left stick returns to neutral, or
-- when LThumb (left joystick click) is pressed again -- currently, letting
-- go of the stick and moving it again resumes running automatically, which
-- means some native flag is "sticky" across stick release.
--
-- No existing script in this mod touches running/sprint state at all (only
-- re2_smooth_movement.lua exists for locomotion, and it just redirects
-- position, it doesn't know about a run/walk mode). So this is genuinely
-- unexplored territory -- this probe finds the real native field and
-- correlates it against stick magnitude and LThumb presses before any write
-- is attempted, same "observe first" approach used successfully elsewhere
-- in this project (e.g. the item-pickup investigation, after three failed
-- blind-write attempts on that system).

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

local state = {
    survivor_condition_type = nil,
    dumped = false,
    last_values = {},
    last_stick_mag_bucket = nil, -- "zero" or "nonzero", logged only on change
    joystick_click_action = nil,
    was_click_down = false,
    last_cond = nil,
}

-- CONFIRMED via the full parent-walking dump (2026-08-09): the real
-- locomotion gait state machine is IsIdle/IsWalk/IsWalkEnd/IsJogStart/
-- IsJog/IsJogEnd/IsTurn/IsWheel/IsStep -- "Jog" is RE2's internal name for
-- what the mod's controls call "running". None of the earlier guesses
-- (IsRun/IsDash/IsSprint) exist on this type at all. BUT: confirmed IsJog
-- is just the moment-to-moment gait ANIMATION state (re-triggers itself
-- 234ms after stopping and resuming movement, with no button press in
-- between) -- there must be a separate persistent preference driving that,
-- not yet found on SurvivorCondition or PlayerCondition.Controller
-- (SurvivorController) directly. Added two more real (not guessed) names
-- spotted in the earlier full dump but never polled yet -- PlOperationType/
-- PlStateType sound like they could be a mode ENUM (walk/run/aim/etc.)
-- rather than a boolean, which would explain why no boolean toggle panned
-- out in two rounds of searching.
local CANDIDATE_GETTERS = {
    "get_IsIdle", "get_IsWalk", "get_IsWalkEnd",
    "get_IsJogStart", "get_IsJog", "get_IsJogEnd",
    "get_IsTurn", "get_IsWheel", "get_IsStep",
    "get_PlOperationType", "get_PlStateType",
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

local function dump_object_methods(obj, label)
    if not obj then
        log.warn("[run_state_probe] " .. label .. " is nil, cannot dump")
        return
    end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then
        log.warn("[run_state_probe] could not get type definition for " .. label)
        return
    end
    log.info("[run_state_probe] --- " .. label .. " + parent types, all get_/is-style methods ---")
    local seen = {}
    local count = 0
    local level = 0
    while td and level < 5 do
        local ok_name, type_name = pcall(function() return td:get_full_name() end)
        log.info(string.format("[run_state_probe] -- level %d: %s --", level, ok_name and type_name or "?"))
        local methods = safe(function() return td:get_methods() end)
        if methods then
            for _, m in ipairs(methods) do
                local ok, name = pcall(function() return m:get_name() end)
                if ok and type(name) == "string" and not seen[name] then
                    -- get_/is-prefixed no-arg-style getters only -- skip
                    -- update/on*/set*/generic verbs to keep this readable.
                    if (name:sub(1, 4) == "get_" or name:sub(1, 3) == "Is_" or name:find("^Is[A-Z]") or name:find("^is[A-Z]"))
                        and name:sub(1, 4) ~= "set_" then
                        seen[name] = true
                        log.info("[run_state_probe]   " .. name)
                        count = count + 1
                    end
                end
            end
        end
        td = safe(function() return td:get_parent_type() end)
        level = level + 1
    end
    log.info(string.format("[run_state_probe] --- end dump of %s (%d getter-style methods across %d levels) ---", label, count, level))
end

local function dump_survivor_condition_methods(cond)
    if state.dumped or not cond then return end
    state.dumped = true
    dump_object_methods(cond, "SurvivorCondition")
    -- PlayerCondition.get_Controller -- not yet inspected. IsJog/IsWalk are
    -- just the moment-to-moment gait animation state (confirmed: IsJog
    -- re-triggers on its own after stopping and moving again, with no
    -- Shift press in between) -- there must be a separate persistent "run
    -- desired" preference driving that re-escalation, and the Controller
    -- object is the most likely place to hold player input preferences
    -- rather than animation state.
    local controller = safe(function() return cond:call("get_Controller") end)
    dump_object_methods(controller, "PlayerCondition.Controller")
end

local function poll_candidates(cond)
    if not cond then return end
    for _, getter in ipairs(CANDIDATE_GETTERS) do
        local ok, v = pcall(function() return cond:call(getter) end)
        if ok and v ~= nil then
            local key = getter
            local prev = state.last_values[key]
            if prev == nil then
                log.info(string.format("[run_state_probe] %s EXISTS, initial value = %s", getter, tostring(v)))
                state.last_values[key] = v
            elseif prev ~= v then
                log.info(string.format("[run_state_probe] %s changed: %s -> %s", getter, tostring(prev), tostring(v)))
                state.last_values[key] = v
            end
        end
    end
end

local function get_left_stick_axis()
    if vrmod and vrmod.is_using_controllers and vrmod:is_using_controllers() then
        local ok, axis = pcall(function() return vrmod:get_left_stick_axis() end)
        if ok and axis then return axis end
    end
    return nil
end

local function poll_stick_magnitude(axis)
    if not axis then return end
    local mag = axis:length()
    local bucket = (mag > 0.05) and "nonzero" or "zero"
    if bucket ~= state.last_stick_mag_bucket then
        log.info(string.format("[run_state_probe] left stick -> %s (mag=%.3f)", bucket, mag))
        state.last_stick_mag_bucket = bucket
    end
end

local function poll_joystick_click()
    if not vrmod then return end
    if not state.joystick_click_action then
        pcall(function() state.joystick_click_action = vrmod:get_action_joystick_click() end)
    end
    if not state.joystick_click_action then return end
    local lj = safe(function() return vrmod:get_left_joystick() end)
    if not lj then return end
    local down = safe(function() return vrmod:is_action_active(state.joystick_click_action, lj) end) == true
    if down and not state.was_click_down then
        log.info("[run_state_probe] LThumb (left joystick click) PRESSED")
    end
    state.was_click_down = down
end

-- CONFIRMED UNSAFE (2026-08-09): a manual test of cond:call("set_IsJog",
-- false) while actively jogging did NOT error and did NOT even change the
-- readback value (still read true immediately after) -- but visibly froze
-- the character to a full stop despite held forward input. This is an FSM-
-- owned flag with real side effects, not a safe request-flag to force
-- directly (same category as NewInventoryDetailBehavior.IsFinish elsewhere
-- in this project, which caused a full game hang when forced). DO NOT
-- attempt direct set_IsJog/set_IsWalk/set_IsIdle writes again -- that test
-- button has been removed. Pivoted to pure observation instead: hook the
-- setters (pre-only, never skip/alter the call) to see what native code
-- actually calls them and when, during completely normal play.

local function find_method_up_hierarchy(td, name)
    local level = 0
    while td and level < 6 do
        local m = safe(function() return td:get_method(name) end)
        if m then return m end
        td = safe(function() return td:get_parent_type() end)
        level = level + 1
    end
    return nil
end

local setter_hooks_installed = false
local function install_setter_hooks(cond)
    if setter_hooks_installed or not cond then return end
    local td = safe(function() return cond:get_type_definition() end)
    if not td then return end

    local SETTERS_TO_WATCH = {
        "set_IsIdle", "set_IsWalk", "set_IsWalkEnd",
        "set_IsJogStart", "set_IsJog", "set_IsJogEnd", "set_IsTurn",
    }
    local hooked = 0
    for _, name in ipairs(SETTERS_TO_WATCH) do
        local m = find_method_up_hierarchy(td, name)
        if m then
            local this_name = name
            sdk.hook(m,
                function(args)
                    -- args[2] = this (SurvivorCondition instance), args[3] = the bool being set.
                    local val = "?"
                    local ok, v = pcall(function() return sdk.to_int64(args[3]) end)
                    if ok then val = tostring(v ~= 0) end
                    log.info(string.format("[run_state_probe] NATIVE CALL %s(%s)", this_name, val))
                    return sdk.PreHookResult.CALL_ORIGINAL
                end,
                function(retval) return retval end -- observe only, never alter the return value
            )
            hooked = hooked + 1
        else
            log.warn("[run_state_probe] could not find method to hook: " .. name)
        end
    end
    setter_hooks_installed = true
    log.info(string.format("[run_state_probe] Installed %d/%d setter observation hooks", hooked, #SETTERS_TO_WATCH))
end

re.on_application_entry("UpdateBehavior", function()
    local player = re2.get_localplayer()
    if not player then return end
    local cond = get_survivor_condition(player)
    if not cond then return end

    state.last_cond = cond

    dump_survivor_condition_methods(cond)
    install_setter_hooks(cond)
    poll_candidates(cond)
    poll_stick_magnitude(get_left_stick_axis())
    poll_joystick_click()
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Run-state probe (read-only polling + setter-call observation)")
    imgui.text("Prefix to grep for: [run_state_probe]")
    imgui.text_colored(
        "Just play normally: move to start running, stop, move again, and press LThumb -- all logged automatically.",
        0xFF88CCFF)
    imgui.text_colored(
        "No write-test button anymore -- set_IsJog(false) was confirmed to freeze movement, not fix it.",
        0xFFFF8888)
end)

log.info("[re2_vr_run_state_probe] Loaded")
