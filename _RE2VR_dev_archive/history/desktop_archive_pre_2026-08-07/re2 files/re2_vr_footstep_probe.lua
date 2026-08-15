-- Diagnostic only: dumps the full method/field list of
-- app.ropeway.PlayerFootEffectController (seen on the player GameObject in
-- re2_vr_movespeed_probe.lua's component dump). Goal: find a method we can
-- call directly to trigger a footstep sound/effect, so re2_smooth_movement.lua
-- can play footsteps matching its own overridden movement speed while
-- aiming (currently no footstep sound plays there, since native logic
-- presumably suppresses it at the very slow aim-shuffle pace).
-- Safe to delete after checking the log.

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

local re2 = require("utility/RE2")

local NS = sdk.game_namespace

local function dump_type_level(tag, td, obj, depth)
    local ok_name, full_name = pcall(function() return td:get_full_name() end)
    log.info("[re2_vr_footstep_probe] " .. tag .. " L" .. depth .. " type: " .. tostring(ok_name and full_name or "?"))

    local ok_m, methods = pcall(function() return td:get_methods() end)
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            if ok_n and mname then
                log.info("[re2_vr_footstep_probe]   [L" .. depth .. "] method: " .. mname)
            end
        end
    end

    local ok_f, fields = pcall(function() return td:get_fields() end)
    if ok_f and fields then
        for _, f in ipairs(fields) do
            local ok_n, fname = pcall(function() return f:get_name() end)
            if ok_n and fname then
                local ok_static, is_static = pcall(function() return f:is_static() end)
                local ok_v, value
                if ok_static and is_static then
                    ok_v, value = pcall(function() return f:get_data(nil) end)
                else
                    ok_v, value = pcall(function() return f:get_data(obj) end)
                end
                log.info("[re2_vr_footstep_probe]   [L" .. depth .. "] field: " .. fname
                    .. " = " .. tostring(ok_v and value or "?(get_data failed)"))
            end
        end
    end
end

local function dump_object(tag, obj)
    if not obj then
        log.info("[re2_vr_footstep_probe] " .. tag .. ": nil")
        return
    end

    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    if not ok_td or not td then
        log.warn("[re2_vr_footstep_probe] " .. tag .. ": could not get type definition")
        return
    end

    local depth = 0
    while td and depth < 8 do
        dump_type_level(tag, td, obj, depth)
        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if not ok_p or not parent then break end
        td = parent
        depth = depth + 1
    end
end

local dumped = false

re.on_frame(function()
    if dumped then return end
    local player = re2.get_localplayer()
    if not player then return end

    local t = sdk.typeof(NS("PlayerFootEffectController"))
    if not t then
        dumped = true
        log.warn("[re2_vr_footstep_probe] Could not resolve PlayerFootEffectController type")
        return
    end

    local ok_c, comp = pcall(function() return player:call("getComponent(System.Type)", t) end)
    if not ok_c or not comp then return end

    dumped = true
    log.info("[re2_vr_footstep_probe] --- dumping PlayerFootEffectController ---")
    dump_object("PlayerFootEffectController", comp)
end)
