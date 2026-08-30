-- Diagnostic only: dumps the parameter signatures of callSE/callFootEffect/
-- checkEmitEffect on via.motion.script.FootEffectController (the parent
-- class PlayerFootEffectController extends), so we know exactly what to
-- pass when calling them manually to trigger a footstep sound/effect at
-- the right pace while aiming (see re2_vr_footstep_probe.lua's dump for
-- context: WalkSoundType=1, JogSoundType=2 constants live on the child
-- class, PlayerFootEffectController).
-- Safe to delete after checking the log.

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

local function dump_method_signature(td, method_name)
    local ok_m, method = pcall(function() return td:get_method(method_name) end)
    if not ok_m or not method then
        log.warn("[re2_vr_footstep_signature_probe] Could not find method " .. method_name)
        return
    end

    local ok_n, num_params = pcall(function() return method:get_num_params() end)
    log.info("[re2_vr_footstep_signature_probe] " .. method_name .. " num_params="
        .. tostring(ok_n and num_params or "?"))

    if ok_n and num_params then
        for i = 0, num_params - 1 do
            local ok_p, param_type_name = pcall(function()
                local pt = method:get_param_type(i)
                return pt and pt:get_full_name()
            end)
            log.info("[re2_vr_footstep_signature_probe]   param[" .. i .. "] = "
                .. tostring(ok_p and param_type_name or "?(lookup failed)"))
        end
    end

    local ok_r, ret_type = pcall(function()
        local rt = method:get_return_type()
        return rt and rt:get_full_name()
    end)
    log.info("[re2_vr_footstep_signature_probe]   return = " .. tostring(ok_r and ret_type or "?"))
end

local td = sdk.find_type_definition("via.motion.script.FootEffectController")
if not td then
    log.warn("[re2_vr_footstep_signature_probe] Could not find via.motion.script.FootEffectController")
    return
end

log.info("[re2_vr_footstep_signature_probe] --- FootEffectController method signatures ---")
dump_method_signature(td, "callSE")
dump_method_signature(td, "callFootEffect")
dump_method_signature(td, "checkEmitEffect")
dump_method_signature(td, "getSETriggerHash")

local player_td = sdk.find_type_definition(sdk.game_namespace("PlayerFootEffectController"))
if player_td then
    log.info("[re2_vr_footstep_signature_probe] --- PlayerFootEffectController method signatures ---")
    dump_method_signature(player_td, "callSE")
    dump_method_signature(player_td, "castRay")
end
