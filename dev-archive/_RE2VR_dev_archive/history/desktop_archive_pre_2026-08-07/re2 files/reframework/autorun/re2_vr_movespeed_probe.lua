-- Diagnostic only: dumps the full method/field list of
-- app.ropeway.survivor.SurvivorCondition (the same component this mod
-- already reads get_IsHold()/get_IsReload() off of, in re2_vr_recoil.lua/
-- re2_vr_haptics.lua/re2_vr_ik_extention.lua) walking up its parent chain,
-- looking for anything related to movement speed capping while aiming
-- (RG held). Flat-screen Leon slows down while aiming/holding the weapon
-- ready -- goal is to find whatever field/method drives that, so it can
-- be bypassed while RG is held.
-- Safe to delete after checking the log.

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

local re2 = require("utility/RE2")
local GameObject = require("utility/GameObject")

local NS = sdk.game_namespace

local keywords = { "speed", "move", "rate", "limit", "walk", "run" }

local function matches(name)
    local lower = name:lower()
    for _, kw in ipairs(keywords) do
        if lower:find(kw) then return true end
    end
    return false
end

local function dump_type_level(tag, td, obj, depth, unfiltered)
    local ok_name, full_name = pcall(function() return td:get_full_name() end)
    log.info("[re2_vr_movespeed_probe] " .. tag .. " L" .. depth .. " type: " .. tostring(ok_name and full_name or "?"))

    local ok_m, methods = pcall(function() return td:get_methods() end)
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            if ok_n and mname and (unfiltered or matches(mname)) then
                log.info("[re2_vr_movespeed_probe]   [L" .. depth .. "] method: " .. mname
                    .. (matches(mname) and "  <-- MATCH" or ""))
            end
        end
    end

    local ok_f, fields = pcall(function() return td:get_fields() end)
    if ok_f and fields then
        for _, f in ipairs(fields) do
            local ok_n, fname = pcall(function() return f:get_name() end)
            if ok_n and fname and (unfiltered or matches(fname)) then
                local ok_static, is_static = pcall(function() return f:is_static() end)
                local ok_v, value
                if ok_static and is_static then
                    ok_v, value = pcall(function() return f:get_data(nil) end)
                else
                    ok_v, value = pcall(function() return f:get_data(obj) end)
                end
                log.info("[re2_vr_movespeed_probe]   [L" .. depth .. "] field: " .. fname
                    .. " = " .. tostring(ok_v and value or "?(get_data failed)") .. (matches(fname) and "  <-- MATCH" or ""))
            end
        end
    end
end

local function dump_object(tag, obj, unfiltered)
    if not obj then
        log.info("[re2_vr_movespeed_probe] " .. tag .. ": nil")
        return
    end

    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    if not ok_td or not td then
        log.warn("[re2_vr_movespeed_probe] " .. tag .. ": could not get type definition")
        return
    end

    local depth = 0
    while td and depth < 8 do
        dump_type_level(tag, td, obj, depth, unfiltered)
        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if not ok_p or not parent then break end
        td = parent
        depth = depth + 1
    end
end

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

-- PlayerCondition (aliased "SurvivorCondition" by this mod's own code) only
-- had get_IsWalk/get_IsWalkEnd -- no speed-multiplier field. The actual cap
-- is more likely on a separate movement/locomotion component that CHECKS
-- PlayerCondition.IsHold to decide to slow down. List every component
-- attached to the player GameObject so we can pick out the real candidate
-- by name (anything with Move/Locomotion/Control/Speed in it) instead of
-- guessing further namespaces blind.
local function list_player_components(player)
    local ok_c, components = pcall(function() return GameObject.get_components(player) end)
    if not ok_c or not components then
        log.warn("[re2_vr_movespeed_probe] Could not list player components")
        return
    end

    log.info("[re2_vr_movespeed_probe] --- player GameObject components ---")
    for _, comp in ipairs(components) do
        local ok_td, td = pcall(function() return comp:get_type_definition() end)
        if ok_td and td then
            local ok_n, full_name = pcall(function() return td:get_full_name() end)
            log.info("[re2_vr_movespeed_probe] component: " .. tostring(ok_n and full_name or "?"))
        end
    end
end

local dumped = false

re.on_frame(function()
    if dumped then return end
    local player = re2.get_localplayer()
    if not player then return end
    local cond = get_survivor_condition(player)
    if not cond then return end

    dumped = true
    list_player_components(player)
    log.info("[re2_vr_movespeed_probe] --- dumping SurvivorCondition (keywords: "
        .. table.concat(keywords, ", ") .. ") ---")
    dump_object("SurvivorCondition", cond)

    -- SurvivorMotionSpeedController was a dead end (confirmed via live
    -- polling: MotionSpeed/PlaySpeed/TensionSpeed/DefaultSpeed all stayed
    -- 1.0 regardless of RG state or weapon-out, even though the player DID
    -- report a real slowdown with weapon-out + RG held). Try the actual
    -- movement/character-control components instead, keyword-filtered.
    local function dump_component_by_type(tag, type_name)
        local t = sdk.typeof(NS(type_name))
        local ok_c, comp = pcall(function()
            return t and player:call("getComponent(System.Type)", t)
        end)
        log.info("[re2_vr_movespeed_probe] --- dumping " .. tag .. " (keywords: "
            .. table.concat(keywords, ", ") .. ") ---")
        dump_object(tag, ok_c and comp or nil)
    end

    dump_component_by_type("PlayerController", "survivor.player.PlayerController")
    dump_component_by_type("SurvivorCharacterController", "survivor.SurvivorCharacterController")

    -- via.physics.CharacterController is a via-namespace (engine base) type,
    -- not app.ropeway -- needs the raw type name, not NS().
    local ok_cc, cc = pcall(function()
        local t = sdk.typeof("via.physics.CharacterController")
        return t and player:call("getComponent(System.Type)", t)
    end)
    log.info("[re2_vr_movespeed_probe] --- dumping via.physics.CharacterController (keywords: "
        .. table.concat(keywords, ", ") .. ") ---")
    dump_object("CharacterController", ok_cc and cc or nil)
end)
