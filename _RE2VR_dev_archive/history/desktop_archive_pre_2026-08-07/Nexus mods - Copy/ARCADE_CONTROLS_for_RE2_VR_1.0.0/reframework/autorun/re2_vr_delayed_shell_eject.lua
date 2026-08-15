-- Delays the spent shotgun shell casing's visual eject from "on fire" to
-- "when the pump handle is pulled all the way down" (RG-ready, LG-grip the
-- pump handle, LT pulls it back -- see re2_vr_reload_ext_4.lua's Pump
-- module), for the manual-pump shotguns only. All other weapons are left
-- completely untouched.
--
-- Root cause found via re2_vr_shell_eject_probe.lua (live hook tracing):
-- firing calls Equipment.requestFire -> shortly after,
-- ShellCartridgeController.request() -> generate(). generate() is the
-- actual casing spawn -- confirmed by blocking it entirely: ammo still
-- decremented, sound/recoil still played normally, only the casing prop
-- stopped appearing. So generate() is purely cosmetic and safe to gate.
--
-- Approach: pre-hook generate(), and for manual-pump shotguns only, return
-- SKIP_ORIGINAL and just remember that a shell is owed for this weapon (NOT
-- the ShellCartridgeController instance itself -- holding a reference
-- across the delay until the pump-pull risks it going stale). A small
-- addition in re2_vr_reload_ext_4.lua sets __vr_pump_pulled_down_wp at the
-- exact moment the pull-down motion completes (gesture.pull_done becomes
-- true -- distinct from complete_pump_cycle(), which only fires later,
-- after release and the return stroke; the eject should happen on the
-- pull, not the return). This script watches that flag and, at that
-- moment, freshly re-fetches the current ShellCartridgeController off the
-- weapon and calls ONLY request() on it again (see REPLAY_GUARD_FRAMES
-- comment below for why not generate() too).

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

local re2 = require("utility/RE2")
local GameObject = require("utility/GameObject")

local NS = sdk.game_namespace

-- Same manual-pump shotgun list as re2_vr_reload.lua's weapon table
-- (wp1000/wp1100/wp1200/wp1500 all have needs_manual_pump = true there).
local MANUAL_PUMP_SHOTGUNS = {
    wp1000 = true,
    wp1100 = true,
    wp1200 = true,
    wp1500 = true,
}

local function get_current_wp_name()
    local go = re2.weapon_gameobject
    if not go then return nil end
    local ok, name = pcall(function() return go:call("get_Name") end)
    if ok and type(name) == "string" then return name end
    return nil
end

local function is_manual_pump_shotgun(wp_name)
    return wp_name ~= nil and MANUAL_PUMP_SHOTGUNS[wp_name] == true
end

local function get_current_shell_cartridge_controller()
    local ok_p, player = pcall(function() return re2.get_localplayer() end)
    if not ok_p or not player then return nil end

    local ok_e, equipment = pcall(function()
        return GameObject.get_component(player, NS("survivor.Equipment"))
    end)
    if not ok_e or not equipment then return nil end

    local ok_arm, arm = pcall(function() return equipment:call("get_MainWeapon") end)
    if not ok_arm or not arm then return nil end

    local ok_scc, scc = pcall(function() return arm:call("get_ShellCartridgeController") end)
    if not ok_scc or not scc then return nil end

    return scc
end

-- Pending: a shell is owed for this weapon once the pump completes.
local pending_wp = nil

-- ShellCartridgeController extends via.Behavior (has startCoroutine/
-- registerCoroutine). request()+generate() are ~13ms (about 1 frame)
-- apart in the natural fire sequence, which matches request() kicking off
-- a coroutine that calls generate() on a LATER frame rather than doing so
-- synchronously. First attempt (calling generate() alone) produced no
-- visible casing; second attempt (calling request() then immediately also
-- calling generate() ourselves, resetting the guard right after) produced
-- a second "Delaying shell eject" log ~25ms later -- almost certainly
-- request()'s own coroutine calling generate() on a subsequent frame,
-- after our guard had already reset, so our hook caught it again as if it
-- were a new fire event. Fix: call ONLY request() (let its own coroutine
-- drive generate() naturally, exactly like the real fire sequence), and
-- hold the guard open for several frames instead of resetting it
-- synchronously, so that later, coroutine-driven generate() call is let
-- through instead of re-deferred.
local REPLAY_GUARD_FRAMES = 10
local replaying_countdown = 0

local scc_type = NS("weapon.shell.ShellCartridgeController")
local td = sdk.find_type_definition(scc_type)
local generate_method = td and td:get_method("generate")

if not generate_method then
    log.warn("[re2_vr_delayed_shell_eject] Could not find ShellCartridgeController.generate, aborting")
    return
end

sdk.hook(generate_method,
    function(args)
        if replaying_countdown > 0 then return end

        local wp_name = get_current_wp_name()
        if not is_manual_pump_shotgun(wp_name) then
            return
        end

        if pending_wp ~= nil then
            log.warn("[re2_vr_delayed_shell_eject] Overwriting a still-pending shell eject (never got pumped) for wp="
                .. tostring(pending_wp))
        end

        pending_wp = wp_name
        log.info("[re2_vr_delayed_shell_eject] Delaying shell eject for wp=" .. tostring(wp_name) .. " until pump completes")

        return sdk.PreHookResult.SKIP_ORIGINAL
    end,
    function(retval)
        return retval
    end)

log.info("[re2_vr_delayed_shell_eject] Started. Manual-pump shotgun shells will eject on pump completion instead of on fire.")

re.on_frame(function()
    -- If the player swapped weapons before pumping, drop the stale pending
    -- eject rather than firing it later in the wrong context.
    if pending_wp ~= nil then
        local wp_name = get_current_wp_name()
        if wp_name ~= pending_wp then
            log.info("[re2_vr_delayed_shell_eject] Weapon changed before pump completed (was "
                .. tostring(pending_wp) .. ", now " .. tostring(wp_name) .. "), dropping pending shell eject")
            pending_wp = nil
        end
    end

    -- Bug fixed here: this used to be gated behind an early `return` when
    -- pulled_down_wp was nil (i.e. almost every frame), so the countdown
    -- below never actually decremented past its first tick -- it got stuck
    -- permanently above zero, which permanently disabled the generate()
    -- hook's suppression after the very first pump cycle (every later shot
    -- ejected immediately again). The countdown must run unconditionally,
    -- every frame, regardless of whether a pump-pull happened this frame.
    local pulled_down_wp = rawget(_G, "__vr_pump_pulled_down_wp")
    if pulled_down_wp ~= nil then
        rawset(_G, "__vr_pump_pulled_down_wp", nil)

        if pending_wp ~= nil and pending_wp == pulled_down_wp then
            log.info("[re2_vr_delayed_shell_eject] Pump pulled down for wp=" .. tostring(pulled_down_wp) .. ", releasing delayed shell eject")

            local scc = get_current_shell_cartridge_controller()
            if not scc then
                log.warn("[re2_vr_delayed_shell_eject] Could not fetch fresh ShellCartridgeController, shell eject lost")
            else
                replaying_countdown = REPLAY_GUARD_FRAMES
                local ok_req = pcall(function() scc:call("request") end)
                log.info("[re2_vr_delayed_shell_eject] Replayed request() on fresh instance: ok_req=" .. tostring(ok_req))
            end

            pending_wp = nil
        end
    end

    if replaying_countdown > 0 then
        replaying_countdown = replaying_countdown - 1
    end
end)
