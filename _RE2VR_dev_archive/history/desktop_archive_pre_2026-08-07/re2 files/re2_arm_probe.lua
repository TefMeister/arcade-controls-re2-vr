-- Diagnostic only: on a single right-trigger tap, reads the live Arm objects
-- returned by Equipment:get_MainWeapon()/get_SubWeapon() and dumps their
-- runtime type name plus any method/field whose name contains
-- "type"/"kind"/"id"/"weapon". Goal: find the correct way to read the
-- *actual* currently-equipped sub-weapon (Equipment._SubType was proven
-- unreliable -- it reads Invalid even with a knife equipped).
-- Safe to delete after checking the log.

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

if not vrmod then
    log.warn("[re2_arm_probe] vrmod not available, aborting")
    return
end

local vrc_manager = require("vr/VRControllerManager")
local re2 = require("utility/RE2")
local GameObject = require("utility/GameObject")

local NS = sdk.game_namespace

local keywords = { "type", "kind", "id", "weapon" }

local function matches(name)
    local lower = name:lower()
    for _, kw in ipairs(keywords) do
        if lower:find(kw) then return true end
    end
    return false
end

local function dump_type_level(tag, td, obj, depth)
    local ok_name, full_name = pcall(function() return td:get_full_name() end)
    log.info("[re2_arm_probe] " .. tag .. " L" .. depth .. " type: " .. tostring(ok_name and full_name or "?"))

    local ok_m, methods = pcall(function() return td:get_methods() end)
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            if ok_n and mname and matches(mname) then
                log.info("[re2_arm_probe]   [L" .. depth .. "] method: " .. mname)
            end
        end
    end

    local ok_f, fields = pcall(function() return td:get_fields() end)
    if ok_f and fields then
        for _, f in ipairs(fields) do
            local ok_n, fname = pcall(function() return f:get_name() end)
            if ok_n and fname and matches(fname) then
                local ok_static, is_static = pcall(function() return f:is_static() end)
                local ok_v, value
                if ok_static and is_static then
                    ok_v, value = pcall(function() return f:get_data(nil) end)
                else
                    ok_v, value = pcall(function() return f:get_data(obj) end)
                end
                log.info("[re2_arm_probe]   [L" .. depth .. "] field: " .. fname .. " = " .. tostring(ok_v and value or "?"))
            end
        end
    end
end

local function dump_object(tag, obj)
    if not obj then
        log.info("[re2_arm_probe] " .. tag .. ": nil")
        return
    end

    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    if not ok_td or not td then
        log.warn("[re2_arm_probe] " .. tag .. ": could not get type definition")
        return
    end

    -- Walk up the class's family tree (this type, then its parent, then
    -- its parent's parent...) since a shared identity field/method may live
    -- on a common ancestor rather than on Gun/Melee specifically.
    local depth = 0
    while td and depth < 10 do
        dump_type_level(tag, td, obj, depth)
        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if not ok_p or not parent then break end
        td = parent
        depth = depth + 1
    end
end

local last_right_trigger = false

log.info("[re2_arm_probe] Started. Single-tap the RIGHT trigger (don't hold) with a knife equipped to dump MainWeapon/SubWeapon Arm info.")

re.on_frame(function()
    if not vrc_manager:has_controllers() then return end

    local rc = vrc_manager.controllers_list[2]
    local right_trigger = (rc and rc:is_action_active(vrc_manager.Actions.TRIGGER)) == true

    if right_trigger and not last_right_trigger then
        log.info("[re2_arm_probe] --- right trigger tapped, probing Equipment ---")

        local ok_p, player = pcall(function() return re2.get_localplayer() end)
        if not ok_p or not player then
            log.warn("[re2_arm_probe] Could not get local player")
        else
            local ok_e, equipment = pcall(function()
                return GameObject.get_component(player, NS("survivor.Equipment"))
            end)
            if not ok_e or not equipment then
                log.warn("[re2_arm_probe] Could not get Equipment component")
            else
                local ok_main, main_arm = pcall(function() return equipment:call("get_MainWeapon") end)
                dump_object("MainWeapon", ok_main and main_arm or nil)

                local ok_sub, sub_arm = pcall(function() return equipment:call("get_SubWeapon") end)
                dump_object("SubWeapon", ok_sub and sub_arm or nil)
            end
        end
    end
    last_right_trigger = right_trigger
end)
