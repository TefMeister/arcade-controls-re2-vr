-- Diagnostic only (read-only, no writes) -- new investigation, player's idea
-- 2026-08-14: rather than fix the pickup/inventory screen's black VR
-- background (see re2_vr_pickup_reuse_itembox_camera_idea memory, PARKED
-- after six rounds of real elimination -- likely shader/native-level, out
-- of Lua's reach), what if the game simply didn't pause gameplay time while
-- the inventory/pickup screen is open at all? Different angle entirely: not
-- fixing the render, changing whether time freezes for it.
--
-- Genuinely fresh territory -- nothing in this mod has investigated pause/
-- time-scale behavior before. First guess was via.SceneManager -- CONFIRMED
-- WRONG live (zero methods/fields matched time/scale/pause/speed at all,
-- not just unconfirmed). Widened to also check via.Application, the more
-- standard RE Engine global time/speed control class used across many
-- REFramework mods for exactly this purpose. Proven singleton-fetch pattern
-- already used in this exact mod (re2_vr_melee.lua's
-- `sdk.get_native_singleton("via.SceneManager")` / `sdk.call_native_func`),
-- applied to both classes now, not guessed blind.
--
-- Safe to delete/archive once findings are captured.

if reframework:get_game_name() ~= "re2" then
    return
end

local NS = sdk.game_namespace

local scene_manager = sdk.get_native_singleton("via.SceneManager")
local scene_manager_typedef = sdk.find_type_definition("via.SceneManager")
local application = sdk.get_native_singleton("via.Application")
local application_typedef = sdk.find_type_definition("via.Application")

local function is_inventory_open()
    local gm = sdk.get_managed_singleton(NS("gui.GUIMaster"))
    if not gm then return false end
    local ok, is_open = pcall(function() return gm:call("get_IsOpenInventory") end)
    return ok and is_open == true
end

local dumped_methods = false
local KEYWORDS = { "time", "scale", "pause", "speed", "clock" }
local function name_matches(name)
    local lower = name:lower()
    for _, kw in ipairs(KEYWORDS) do
        if lower:find(kw) then return true end
    end
    return false
end

local function dump_type_api(tag, typedef)
    if not typedef then
        log.info("[pause_probe] " .. tag .. ": type definition unavailable")
        return
    end
    log.info("[pause_probe] --- " .. tag .. " methods matching time/scale/pause/speed/clock ---")
    local ok_m, methods = pcall(function() return typedef:get_methods() end)
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            if ok_n and mname and name_matches(mname) then
                log.info("[pause_probe]   method: " .. mname)
            end
        end
    end
    log.info("[pause_probe] --- " .. tag .. " fields matching time/scale/pause/speed/clock ---")
    local ok_f, fields = pcall(function() return typedef:get_fields() end)
    if ok_f and fields then
        for _, f in ipairs(fields) do
            local ok_n, fname = pcall(function() return f:get_name() end)
            if ok_n and fname and name_matches(fname) then
                log.info("[pause_probe]   field: " .. fname)
            end
        end
    end
end

local function dump_all_apis()
    if dumped_methods then return end
    dumped_methods = true
    dump_type_api("via.SceneManager", scene_manager_typedef)
    dump_type_api("via.Application", application_typedef)
end

-- Best-effort read attempts for the most likely candidate names -- tried
-- via pcall so a wrong guess just logs "unavailable" rather than erroring,
-- but the real dumps above are what actually drive which of these to trust.
-- via.SceneManager already CONFIRMED to have none of these (round 1) --
-- kept in the candidate list anyway in case the real dump surfaces a
-- differently-named match worth trying by hand later, but via.Application
-- is now the primary suspect.
local CANDIDATE_GETTERS = { "get_TimeScale", "get_CurrentTimeScale", "get_Speed", "get_SpeedRate" }

local function try_read_from(obj, typedef)
    for _, getter in ipairs(CANDIDATE_GETTERS) do
        local ok, v = pcall(function() return sdk.call_native_func(obj, typedef, getter) end)
        if ok and v ~= nil then
            return getter, v
        end
    end
    return nil, nil
end

local function try_read_timescale()
    local g1, v1 = try_read_from(application, application_typedef)
    if g1 then return "Application." .. g1, v1 end
    local g2, v2 = try_read_from(scene_manager, scene_manager_typedef)
    if g2 then return "SceneManager." .. g2, v2 end
    return nil, nil
end

local last_inv_open = false
local last_logged_value = nil
re.on_frame(function()
    pcall(dump_all_apis)

    local inv_open = is_inventory_open()
    if inv_open ~= last_inv_open then
        local getter, v = try_read_timescale()
        log.info(string.format("[pause_probe] inventory open changed: %s -> %s | %s=%s",
            tostring(last_inv_open), tostring(inv_open), tostring(getter), tostring(v)))
        last_inv_open = inv_open
        last_logged_value = v
    elseif inv_open then
        -- While open, log again only if the read value actually changes,
        -- to catch a delayed/animated transition rather than an instant one.
        local getter, v = try_read_timescale()
        if v ~= nil and v ~= last_logged_value then
            log.info(string.format("[pause_probe] value changed while inventory open: %s=%s (was %s)",
                tostring(getter), tostring(v), tostring(last_logged_value)))
            last_logged_value = v
        end
    end
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Inventory pause/time-scale investigation probe (read-only)")
    imgui.text("Prefix to grep: [pause_probe]")
    imgui.text("Inventory open now: " .. tostring(is_inventory_open()))
    local getter, v = try_read_timescale()
    imgui.text(string.format("Current read: %s = %s", tostring(getter), tostring(v)))
    imgui.text_colored("Open the inventory / pick up an item to see what changes.", 0xFF88CCFF)
end)

log.info("[pause_probe] Loaded. Open the inventory or pick up an item once.")
