-- Diagnostic only: verifies whether the player's
-- app.ropeway.survivor.SurvivorMotionSpeedController is what reduces
-- movement speed while aiming/holding the weapon ready (RG held).
--
-- The previous version of this script hooked applyTensionSpeed() directly
-- and crashed the game on loading into an actual level (main menu was
-- fine). Most likely cause: that component almost certainly exists on
-- every character in the scene (not just the player), so the hook was
-- firing at high frequency for NPCs too, doing several extra native calls
-- plus VR-controller-state reads per invocation -- a plausible crash/
-- thread-safety combination. This version avoids hooking entirely: it just
-- polls the PLAYER's own component once per frame (the same safe,
-- established re.on_frame pattern used throughout this mod) and logs only
-- when the values actually change, alongside the cached RG state.
-- Safe to delete after checking the log.

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

if not vrmod then
    log.warn("[re2_vr_tensionspeed_probe] vrmod not available, aborting")
    return
end

local re2 = require("utility/RE2")
local vrc_manager = require("vr/VRControllerManager")

local NS = sdk.game_namespace

local function get_player_msc()
    local player = re2.get_localplayer()
    if not player then return nil end
    local t = sdk.typeof(NS("survivor.SurvivorMotionSpeedController"))
    if not t then return nil end
    local ok, msc = pcall(function() return player:call("getComponent(System.Type)", t) end)
    return ok and msc or nil
end

local function safe_call(obj, method)
    local ok, v = pcall(function() return obj:call(method) end)
    if ok then return v end
    return nil
end

local last_motion_speed = nil
local last_right_grip = nil

log.info("[re2_vr_tensionspeed_probe] Started. Walk around, hold RG, release RG, and check the log for speed changes.")

re.on_frame(function()
    if not vrc_manager:has_controllers() then return end

    local rc = vrc_manager.controllers_list[2]
    local right_grip = (rc and rc:is_action_active(vrc_manager.Actions.GRIP)) == true

    local msc = get_player_msc()
    if not msc then return end

    local motion_speed = safe_call(msc, "get_MotionSpeed")

    if motion_speed ~= last_motion_speed or right_grip ~= last_right_grip then
        local play_speed = safe_call(msc, "get_PlaySpeed")
        local tension_speed = safe_call(msc, "get_TensionSpeed")
        local default_speed = safe_call(msc, "getDefaultSpeed")
        log.info(string.format(
            "[re2_vr_tensionspeed_probe] RG=%s MotionSpeed=%s PlaySpeed=%s TensionSpeed=%s DefaultSpeed=%s",
            tostring(right_grip), tostring(motion_speed), tostring(play_speed),
            tostring(tension_speed), tostring(default_speed)))
        last_motion_speed = motion_speed
        last_right_grip = right_grip
    end
end)
