-- EXPERIMENTAL PROBE (2026-08-13): tests whether the native
-- SurvivorCondition.IsHold flag ("is aiming", read everywhere in this mod --
-- re2_vr_recoil.lua, re2_vr_ik_extention.lua, re2_vr_haptics.lua,
-- re2_smooth_movement.lua -- but never written anywhere) can be force-set
-- true while LG alone is held (RG not pressed), so the game's OWN existing
-- two-handed aim pose systems (re2_vr_ik_extention.lua etc.) produce the
-- weapon-held pose identically to genuine RG aiming, instead of
-- re2_vr_recoil.lua's hand-rolled real-grip position/rotation math (source
-- of every real-grip bug found this session -- see
-- re2_vr_real_weapon_grip_attempt memory).
--
-- Fully additive/isolated: does not touch any existing script. The
-- real-grip system in re2_vr_cosmetic_dock.lua/re2_vr_recoil.lua has been
-- temporarily disabled (enabled:false in its JSON) so it doesn't fight this
-- probe for control of the same pose during testing -- re-enable it there if
-- this probe doesn't pan out.
--
-- Does NOT attempt to suppress firing -- this first pass only tests whether
-- the pose itself can be forced at all. Test somewhere safe in case forcing
-- IsHold has an unexpected effect on weapon-fire readiness (untested,
-- unconfirmed either way).

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace
local vrc_manager = require("vr/VRControllerManager")

local survivor_condition_type = nil
local function get_survivor_condition(player)
    if not player then return nil end
    if not survivor_condition_type then
        survivor_condition_type = sdk.typeof(NS("survivor.SurvivorCondition"))
    end
    if not survivor_condition_type then return nil end
    local ok, cond = pcall(function()
        return player:call("getComponent(System.Type)", survivor_condition_type)
    end)
    return ok and cond or nil
end

local function get_is_hold(cond)
    if not cond then return false end
    local ok, v = pcall(function() return cond:call("get_IsHold") end)
    return ok and v == true
end

-- Same technique as re2_vr_cosmetic_dock.lua's is_left_grip_pressed/
-- is_right_grip_pressed, copied verbatim for consistency.
local function is_left_grip_pressed()
    if not vrmod then return false end
    if vrc_manager:has_controllers() then
        local lc = vrc_manager.controllers_list[1]
        if lc then
            return lc:is_action_active(vrc_manager.Actions.GRIP) == true
        end
    end
    local ok_lj, lj = pcall(function() return vrmod:get_left_joystick() end)
    if not ok_lj or not lj then return false end
    local ok_a, action = pcall(function() return vrmod:get_action_grip() end)
    if not ok_a or not action then return false end
    local ok_v, v = pcall(function() return vrmod:is_action_active(action, lj) end)
    return ok_v and v == true
end

local function is_right_grip_pressed()
    if not vrmod then return false end
    if vrc_manager:has_controllers() then
        local rc = vrc_manager.controllers_list[2]
        if rc then
            return rc:is_action_active(vrc_manager.Actions.GRIP) == true
        end
    end
    local ok_rj, rj = pcall(function() return vrmod:get_right_joystick() end)
    if not ok_rj or not rj then return false end
    local ok_a, action = pcall(function() return vrmod:get_action_grip() end)
    if not ok_a or not action then return false end
    local ok_v, v = pcall(function() return vrmod:is_action_active(action, rj) end)
    return ok_v and v == true
end

local function uptime_now()
    local ok, t = pcall(function() return via.Application:get_UpTimeSecond() end)
    return ok and t or os.clock()
end

local state = {
    prev_lg = false,
    last_log_time = 0,
}

re.on_frame(function()
    local player = re2.get_localplayer()
    local cond = get_survivor_condition(player)
    if not cond then return end

    local lg = is_left_grip_pressed()
    local rg = is_right_grip_pressed()

    if lg and not rg then
        -- Force every frame, not just once -- this codebase has already hit
        -- native per-frame flag recompute elsewhere (e.g.
        -- re2_vr_suppress_supporthold.lua's SUPPORT_HOLD flag), so a
        -- one-shot set on the rising edge would likely just get overwritten
        -- next frame if the same pattern applies here.
        local ok_set = pcall(function() cond:call("set_IsHold", true) end)
        local now_holding = get_is_hold(cond)
        local now = uptime_now()
        if now - state.last_log_time > 0.5 then
            state.last_log_time = now
            log.info(string.format(
                "[re2_vr_force_aim_grip_probe] LG-only held: set_IsHold call ok=%s -> IsHold reads back %s",
                tostring(ok_set), tostring(now_holding)))
        end
    end

    if lg and not state.prev_lg then
        log.info(string.format("[re2_vr_force_aim_grip_probe] LG pressed (RG=%s, IsHold=%s)",
            tostring(rg), tostring(get_is_hold(cond))))
    elseif not lg and state.prev_lg then
        log.info(string.format("[re2_vr_force_aim_grip_probe] LG released (IsHold=%s)",
            tostring(get_is_hold(cond))))
    end
    state.prev_lg = lg
end)

re.on_draw_ui(function()
    if imgui.tree_node("Force-Aim Grip Probe (experimental)") then
        local player = re2.get_localplayer()
        local cond = get_survivor_condition(player)
        imgui.text("LG: " .. tostring(is_left_grip_pressed()) .. "   RG: " .. tostring(is_right_grip_pressed()))
        imgui.text("IsHold (live): " .. tostring(get_is_hold(cond)))
        imgui.text_colored("Prefix to grep for: [re2_vr_force_aim_grip_probe]", 0.6, 0.9, 1.0, 1.0)
        imgui.tree_pop()
    end
end)

log.info("[re2_vr_force_aim_grip_probe] Loaded -- experimental, real-grip system should be disabled while testing this")
