-- Diagnostic only: hooks candidate native methods related to firing and
-- cartridge/shell creation on Gun/Equipment, purely to log call order and
-- timing (frame numbers) relative to when a shotgun fires. Goal: find out
-- which native call actually spawns the visible ejected shell casing, so a
-- later script can gate/delay it until the manual pump-action completes
-- (see "Sub-weapon must not appear while RG is held" section and the new
-- shell-eject request in re2_vr_mod_project_status.md).
--
-- Pure observer -- nothing here blocks or modifies any native call.
-- Safe to delete after checking the log.

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

local NS = sdk.game_namespace

local function get_frame_id()
    local ok, id = pcall(function() return sdk.get_current_frame_count() end)
    if ok and id then return id end
    return os.clock()
end

local function hook_method(type_name, method_name, tag)
    local td = sdk.find_type_definition(type_name)
    if not td then
        log.warn("[re2_vr_shell_eject_probe] Could not find type " .. type_name)
        return false
    end

    local method = td:get_method(method_name)
    if not method then
        log.warn("[re2_vr_shell_eject_probe] " .. type_name .. " has no method " .. method_name)
        return false
    end

    sdk.hook(method,
        function(args)
            log.info("[re2_vr_shell_eject_probe] PRE  " .. tag .. " frame=" .. tostring(get_frame_id()))
        end,
        function(retval)
            log.info("[re2_vr_shell_eject_probe] POST " .. tag .. " frame=" .. tostring(get_frame_id()))
            return retval
        end)

    log.info("[re2_vr_shell_eject_probe] Hooked " .. tag)
    return true
end

-- weapon.generator.ShotgunShellGenerator / BulletShellGenerator do not
-- exist under this namespace -- dead end, likely copied from a different
-- RE-engine game's template code. More promising real lead from the
-- earlier Gun reflection dump: get_ShellCartridgeController /
-- set_ShellCartridgeController -- a dedicated controller OBJECT, which is
-- a much more specific name than the generic get/set noise around it.
-- Read it directly off the currently-equipped weapon's Arm object (single
-- right-trigger tap, mirroring re2_arm_probe.lua's pattern) and dump ITS
-- own methods -- the real eject/spawn call is more likely to live there
-- than directly on Gun.
local vrc_manager = require("vr/VRControllerManager")
local re2 = require("utility/RE2")
local GameObject = require("utility/GameObject")

local function dump_object_methods(tag, obj)
    if not obj then
        log.info("[re2_vr_shell_eject_probe] " .. tag .. ": nil")
        return
    end

    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    if not ok_td or not td then
        log.warn("[re2_vr_shell_eject_probe] " .. tag .. ": could not get type definition")
        return
    end

    local depth = 0
    while td and depth < 6 do
        local ok_name, full_name = pcall(function() return td:get_full_name() end)
        log.info("[re2_vr_shell_eject_probe] " .. tag .. " L" .. depth .. " type: " .. tostring(ok_name and full_name or "?"))

        local ok_m, methods = pcall(function() return td:get_methods() end)
        if ok_m and methods then
            for _, m in ipairs(methods) do
                local ok_n, mname = pcall(function() return m:get_name() end)
                if ok_n and mname then
                    log.info("[re2_vr_shell_eject_probe]   [L" .. depth .. "] method: " .. mname)
                end
            end
        end

        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if not ok_p or not parent then break end
        td = parent
        depth = depth + 1
    end
end

local last_right_trigger_probe = false

re.on_frame(function()
    if not vrc_manager:has_controllers() then return end

    local rc = vrc_manager.controllers_list[2]
    local right_trigger = (rc and rc:is_action_active(vrc_manager.Actions.TRIGGER)) == true

    if right_trigger and not last_right_trigger_probe then
        log.info("[re2_vr_shell_eject_probe] --- right trigger tapped, probing ShellCartridgeController ---")

        local ok_p, player = pcall(function() return re2.get_localplayer() end)
        if ok_p and player then
            local ok_e, equipment = pcall(function()
                return GameObject.get_component(player, NS("survivor.Equipment"))
            end)
            if ok_e and equipment then
                local ok_arm, arm = pcall(function() return equipment:call("get_MainWeapon") end)
                if ok_arm and arm then
                    local ok_scc, scc = pcall(function() return arm:call("get_ShellCartridgeController") end)
                    dump_object_methods("ShellCartridgeController", ok_scc and scc or nil)
                else
                    log.warn("[re2_vr_shell_eject_probe] get_MainWeapon() returned nil")
                end
            end
        end
    end
    last_right_trigger_probe = right_trigger
end)

local gun_type = NS("implement.Gun")
local eq_type = NS("survivor.Equipment")

-- Candidate methods, in rough order of suspicion based on earlier
-- reflection dumps of app.ropeway.implement.Gun (see re2_arm_probe.lua
-- history): createCartridge is already hooked elsewhere in this mod for
-- an unrelated purpose (bullet-type-change gating) -- this adds our own
-- independently-tagged hook on top so we can see its timing without
-- touching that existing behavior.
hook_method(gun_type, "createCartridge", "Gun.createCartridge")
hook_method(gun_type, "requestFire", "Gun.requestFire")
hook_method(eq_type, "requestFire", "Equipment.requestFire")

-- These looked like property accessors on Gun in earlier probing
-- (get_/set_RequestCreateCartridge, get_/set_EjectCartridgeTrackHandle,
-- get_/set_CartridgeTrackHandle). Hooking the setters specifically tells
-- us WHEN native code assigns a new cartridge/track object, which is a
-- strong signal for "a shell was just spawned."
hook_method(gun_type, "set_RequestCreateCartridge", "Gun.set_RequestCreateCartridge")
hook_method(gun_type, "set_EjectCartridgeTrackHandle", "Gun.set_EjectCartridgeTrackHandle")
hook_method(gun_type, "set_CartridgeTrackHandle", "Gun.set_CartridgeTrackHandle")

-- Found via live dump: ShellCartridgeController's own methods are
-- doStart/doOnDestroy/lateUpdate/request/generate/.ctor. "request" and
-- "generate" are the standout candidates -- naming strongly suggests
-- request() is the entry point (called from fire) and generate() is the
-- actual spawn, possibly on a delay/coroutine.
local scc_type = NS("weapon.shell.ShellCartridgeController")
hook_method(scc_type, "request", "ShellCartridgeController.request")

-- EXPERIMENT: block generate() entirely and see (a) whether the shell
-- casing actually stops appearing on fire, and (b) whether firing/sound/
-- ammo consumption still work normally otherwise. If both hold, generate()
-- is purely the cosmetic spawn and safe to gate/delay for real.
-- Experiment confirmed generate() is purely cosmetic (ammo/sound/recoil
-- all unaffected when blocked). Turned off now that
-- re2_vr_delayed_shell_eject.lua does the real, weapon-gated version of
-- this -- leaving it true here would double-block generate() for every
-- weapon, not just manual-pump shotguns.
local EXPERIMENT_BLOCK_GENERATE = false

do
    local td = sdk.find_type_definition(scc_type)
    local method = td and td:get_method("generate")
    if method then
        sdk.hook(method,
            function(args)
                log.info("[re2_vr_shell_eject_probe] PRE  ShellCartridgeController.generate frame="
                    .. tostring(get_frame_id()) .. " BLOCKING=" .. tostring(EXPERIMENT_BLOCK_GENERATE))
                if EXPERIMENT_BLOCK_GENERATE then
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end,
            function(retval)
                log.info("[re2_vr_shell_eject_probe] POST ShellCartridgeController.generate frame=" .. tostring(get_frame_id()))
                return retval
            end)
        log.info("[re2_vr_shell_eject_probe] Hooked ShellCartridgeController.generate (experiment active="
            .. tostring(EXPERIMENT_BLOCK_GENERATE) .. ")")
    else
        log.warn("[re2_vr_shell_eject_probe] ShellCartridgeController has no method generate")
    end
end

log.info("[re2_vr_shell_eject_probe] Started. Fire the shotgun once and check the log for PRE/POST order and frame numbers.")
