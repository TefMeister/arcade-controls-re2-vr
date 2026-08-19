-- re2_vr_menu_hide_player.lua
--
-- Goal: inventory/map screens currently jump to a 3rd-person view of the player.
-- Until the camera itself can be kept first-person (separate investigation, see
-- re2_vr_inventory_camera_probe.lua), make those screens behave like the item box:
-- the player (and held weapon) simply isn't there to look at.
--
-- Technique: same per-pass draw flags as re2_vr_head_shadow.lua (proven working
-- 2026-08-19) -- set_DrawDefault(false) + set_DrawShadowCast(false) on every
-- via.render.Mesh under the player while GUIMaster reports the inventory, map or
-- pause menu open (get_IsOpenInventory / get_IsOpenMap / get_IsOpenPause /
-- get_IsOpenPauseForEvent -- all proven detectors from
-- re2_vr_holster.lua's is_menu_blocking()). Originals are captured at menu-open
-- and restored at menu-close, so this composes cleanly with the head-shadow
-- script's own flag management (which pauses itself via the
-- __vr_menu_player_hidden global while this is active).
--
-- Enable checkbox OFF by default (project convention). No config persistence yet.

local RE2 = require("utility/RE2")
local GameObject = require("utility/GameObject")

local log_prefix = "[menu_hide]"

local function logmsg(msg)
    log.info(log_prefix .. " " .. msg)
end

--------------------------------------------------------------------------------
-- via.render.Mesh API check (same requirements as re2_vr_head_shadow.lua)
--------------------------------------------------------------------------------
local api = nil

local function check_mesh_api()
    if api ~= nil then return api end
    api = { ok = false, has_raytracing = false, reason = "" }

    local ok_td, td = pcall(function() return sdk.find_type_definition("via.render.Mesh") end)
    if not ok_td or td == nil then
        api.reason = "via.render.Mesh type definition not found"
        logmsg(api.reason)
        return api
    end

    local function has_method(name)
        local ok, m = pcall(function() return td:get_method(name) end)
        return ok and m ~= nil
    end

    if not (has_method("set_DrawDefault") and has_method("get_DrawDefault")
            and has_method("set_DrawShadowCast") and has_method("get_DrawShadowCast")) then
        api.reason = "DrawDefault/DrawShadowCast not available on via.render.Mesh"
        logmsg(api.reason)
        return api
    end

    api.ok = true
    api.has_raytracing = has_method("set_DrawRaytracing") and has_method("get_DrawRaytracing")
    return api
end

--------------------------------------------------------------------------------
-- Mesh collection (player hierarchy + equipped weapon hierarchy, deduped)
--------------------------------------------------------------------------------
local function component_type_name(comp)
    local ok, td = pcall(function() return comp:get_type_definition() end)
    if not ok or td == nil then return "?" end
    local ok2, name = pcall(function() return td:get_full_name() end)
    return (ok2 and name) or "?"
end

local function get_children(transform)
    local children = {}
    if transform == nil then return children end
    local ok, first = pcall(function() return transform:call("get_Child") end)
    if not ok or first == nil then return children end
    local cur = first
    local guard = 0
    while cur ~= nil and guard < 500 do
        table.insert(children, cur)
        local ok2, nxt = pcall(function() return cur:call("get_Next") end)
        if not ok2 then break end
        cur = nxt
        guard = guard + 1
    end
    return children
end

local function walk_for_meshes(transform, depth, results, seen)
    if transform == nil or depth > 12 then return end

    local ok_go, go = pcall(function() return transform:call("get_GameObject") end)
    if ok_go and go ~= nil then
        local ok_name, name = pcall(function() return go:call("get_Name") end)
        name = (ok_name and name) or "?"

        local ok_c, comps = pcall(function() return GameObject.get_components(go) end)
        if ok_c and comps then
            for _, comp in ipairs(comps) do
                if component_type_name(comp) == "via.render.Mesh" then
                    local ok_addr, addr = pcall(function() return comp:get_address() end)
                    local key = ok_addr and addr or tostring(comp)
                    if not seen[key] then
                        seen[key] = true
                        table.insert(results, { name = tostring(name), comp = comp })
                    end
                end
            end
        end
    end

    for _, child in ipairs(get_children(transform)) do
        walk_for_meshes(child, depth + 1, results, seen)
    end
end

local function collect_player_meshes()
    local results, seen = {}, {}

    local player = RE2.get_localplayer()
    if player == nil then return results end

    local ok_tf, root_tf = pcall(function() return player:call("get_Transform") end)
    if ok_tf and root_tf ~= nil then
        walk_for_meshes(root_tf, 0, results, seen)
    end

    -- Equipped weapon may or may not be parented under the player transform --
    -- walk it explicitly too (deduped by component address if it already was).
    local ok_w, weapon_go = pcall(function() return RE2.get_weapon_object(player) end)
    if ok_w and weapon_go ~= nil then
        local ok_wtf, wtf = pcall(function() return weapon_go:call("get_Transform") end)
        if ok_wtf and wtf ~= nil then
            walk_for_meshes(wtf, 0, results, seen)
        end
    end

    return results
end

--------------------------------------------------------------------------------
-- State machine: hide on menu open, restore on close
--------------------------------------------------------------------------------
local state = {
    enabled = false,
    hide_on_inventory = true,
    hide_on_map = true,
    hide_on_pause = true,
    entries = {},     -- { name, comp, orig = {draw_default, draw_shadow, draw_rt} }
    hidden = false,
    status = "idle",
}

local function gui_bool(gm, getter)
    local ok, v = pcall(function() return gm:call(getter) end)
    return ok and v == true
end

local function menu_wants_hide()
    local gm = sdk.get_managed_singleton(sdk.game_namespace("gui.GUIMaster"))
    if not gm then return false end
    if state.hide_on_inventory and gui_bool(gm, "get_IsOpenInventory") then return true end
    if state.hide_on_map and gui_bool(gm, "get_IsOpenMap") then return true end
    -- Pause menu (load game / options / exit to title). Both getters come from
    -- re2_vr_holster.lua's is_menu_blocking(), where they are already proven.
    if state.hide_on_pause and (gui_bool(gm, "get_IsOpenPause")
        or gui_bool(gm, "get_IsOpenPauseForEvent")) then return true end
    return false
end

local function hide_all()
    state.entries = collect_player_meshes()

    local count = 0
    for _, e in ipairs(state.entries) do
        local ok_d, d = pcall(function() return e.comp:call("get_DrawDefault") end)
        local ok_s, s = pcall(function() return e.comp:call("get_DrawShadowCast") end)
        local rt = nil
        if api.has_raytracing then
            local ok_rt, v = pcall(function() return e.comp:call("get_DrawRaytracing") end)
            if ok_rt then rt = v end
        end
        if ok_d and ok_s then
            e.orig = { draw_default = d, draw_shadow = s, draw_rt = rt }
            pcall(function() e.comp:call("set_DrawDefault", false) end)
            pcall(function() e.comp:call("set_DrawShadowCast", false) end)
            if rt ~= nil then
                pcall(function() e.comp:call("set_DrawRaytracing", false) end)
            end
            count = count + 1
        end
    end

    state.hidden = true
    rawset(_G, "__vr_menu_player_hidden", true)
    state.status = "hidden (" .. count .. " meshes)"
    logmsg("menu opened -- hid " .. count .. " mesh components")
end

local function reapply_all()
    -- Cheap per-frame reassertion while the menu stays open, in case the game
    -- rewrites flags mid-menu (lesson from ForceEquipType: one-shot writes can
    -- lose races against native per-frame recomputation).
    for _, e in ipairs(state.entries) do
        if e.orig ~= nil then
            pcall(function() e.comp:call("set_DrawDefault", false) end)
            pcall(function() e.comp:call("set_DrawShadowCast", false) end)
            if e.orig.draw_rt ~= nil then
                pcall(function() e.comp:call("set_DrawRaytracing", false) end)
            end
        end
    end
end

local function restore_all()
    local count = 0
    for _, e in ipairs(state.entries) do
        if e.orig ~= nil then
            pcall(function() e.comp:call("set_DrawDefault", e.orig.draw_default) end)
            pcall(function() e.comp:call("set_DrawShadowCast", e.orig.draw_shadow) end)
            if e.orig.draw_rt ~= nil then
                pcall(function() e.comp:call("set_DrawRaytracing", e.orig.draw_rt) end)
            end
            count = count + 1
        end
    end
    state.entries = {}
    if state.hidden then
        logmsg("menu closed -- restored " .. count .. " mesh components")
    end
    state.hidden = false
    rawset(_G, "__vr_menu_player_hidden", false)
    state.status = "visible"
end

re.on_frame(function()
    local a = check_mesh_api()
    if not a.ok then return end

    if not state.enabled then
        if state.hidden then restore_all() end
        return
    end

    local want = menu_wants_hide()
    if want and not state.hidden then
        hide_all()
    elseif want and state.hidden then
        reapply_all()
    elseif not want and state.hidden then
        restore_all()
    end
end)

re.on_script_reset(function()
    restore_all()
end)

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.tree_node("Menu: hide player (item-box style)") then return end

    local a = check_mesh_api()
    if not a.ok then
        imgui.text("NOT AVAILABLE: " .. tostring(a.reason))
        imgui.tree_pop()
        return
    end

    imgui.text("While the inventory/map/pause menu is open, player + weapon are fully")
    imgui.text("hidden -- the 3rd-person menu camera shows only the scene,")
    imgui.text("like the item box screen. Everything restores on close.")

    local changed
    changed, state.enabled = imgui.checkbox("Enable", state.enabled)
    changed, state.hide_on_inventory = imgui.checkbox("Hide during inventory", state.hide_on_inventory)
    changed, state.hide_on_map = imgui.checkbox("Hide during map", state.hide_on_map)
    changed, state.hide_on_pause = imgui.checkbox("Hide during pause menu", state.hide_on_pause)

    imgui.text("Status: " .. tostring(state.status))

    if state.hidden and imgui.tree_node("Currently hidden meshes") then
        for _, e in ipairs(state.entries) do
            imgui.text("  " .. e.name)
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

logmsg("loaded")
