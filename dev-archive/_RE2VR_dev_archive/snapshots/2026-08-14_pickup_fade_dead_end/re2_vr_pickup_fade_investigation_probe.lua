-- Diagnostic only (read-only, no writes) -- new angle on the pickup
-- black-screen disruption, raised by the player right after both the
-- render-fix investigation (PARKED, see re2_vr_pickup_reuse_itembox_camera_idea)
-- and the no-pause investigation (PARKED, see re2_vr_inventory_no_pause_idea)
-- were closed out: instead of fixing what's black, or removing the pause,
-- what about fading smoothly in/out of it instead of an instant cut?
--
-- Real lead already sitting in this session's own data: BOTH
-- re2_vr_pickup_bg_investigation_probe.lua (round 1) and
-- re2_vr_pickup_capture_investigation_probe6.lua (round 6) independently
-- logged "BlackFade" and "WhiteFade" as real active GUI elements during the
-- exact pickup sequence being investigated -- never followed up on since
-- those probes were chasing the render/capture mechanism, not a fade
-- overlay. These are very likely native fade-transition objects the game
-- already uses elsewhere (loading screens, scene transitions), which would
-- make this a much more Lua-reachable lever than the shader/render-level
-- wall the black-screen investigation hit -- opacity/color control on a GUI
-- panel is a completely standard operation, unlike the native camera/
-- capture internals that dead-ended.
--
-- This probe: finds BlackFade/WhiteFade (same proven on_pre_gui_draw_element
-- name-match technique used throughout this session), dumps their FULL type
-- hierarchy (fields+methods, unfiltered by keyword this time since we don't
-- know what terms this specific class uses -- could be Alpha/Opacity/
-- ColorScale/FadeRate/etc.), and tracks any alpha-like field's value across
-- a real pickup open/close cycle to see whether the game ALREADY animates
-- it (in which case extending/slowing that existing animation might be
-- easier than building a new one from scratch).
--
-- Safe to delete/archive once findings are captured.

if reframework:get_game_name() ~= "re2" then
    return
end

local NS = sdk.game_namespace

local function dump_full_type_hierarchy(tag, obj)
    if not obj then
        log.info("[pickup_fade_probe] " .. tag .. ": object unavailable")
        return
    end
    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    if not ok_td or not td then
        log.info("[pickup_fade_probe] " .. tag .. ": no type definition")
        return
    end
    local depth = 0
    while td and depth < 6 do
        local ok_name, full_name = pcall(function() return td:get_full_name() end)
        log.info("[pickup_fade_probe] " .. tag .. " L" .. depth .. " type: " .. tostring(ok_name and full_name or "?"))
        local ok_f, fields = pcall(function() return td:get_fields() end)
        if ok_f and fields then
            for _, f in ipairs(fields) do
                local ok_n, fname = pcall(function() return f:get_name() end)
                if ok_n and fname then
                    local ok_static, is_static = pcall(function() return f:is_static() end)
                    local ok_v, v
                    if ok_static and is_static then
                        ok_v, v = pcall(function() return f:get_data(nil) end)
                    else
                        ok_v, v = pcall(function() return f:get_data(obj) end)
                    end
                    log.info(string.format("[pickup_fade_probe]   [L%d] field: %s = %s", depth, fname, tostring(ok_v and v or "?")))
                end
            end
        end
        local ok_m, methods = pcall(function() return td:get_methods() end)
        if ok_m and methods then
            for _, m in ipairs(methods) do
                local ok_n, mname = pcall(function() return m:get_name() end)
                if ok_n and mname then
                    log.info(string.format("[pickup_fade_probe]   [L%d] method: %s", depth, mname))
                end
            end
        end
        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if not ok_p or not parent then break end
        td = parent
        depth = depth + 1
    end
end

local dumped = { BlackFade = false, WhiteFade = false }
re.on_pre_gui_draw_element(function(element, context)
    local ok_go, go = pcall(function() return element:call("get_GameObject") end)
    if not ok_go or not go then return true end
    local ok_n, name = pcall(function() return go:call("get_Name") end)
    if not ok_n or type(name) ~= "string" then return true end
    if (name == "BlackFade" or name == "WhiteFade") and not dumped[name] then
        dumped[name] = true
        log.info("[pickup_fade_probe] === " .. name .. " found -- dumping full type hierarchy ===")
        dump_full_type_hierarchy(name .. "_GameObject", go)
        -- Also try the element itself (the via.gui.Element/Panel/Control
        -- object passed into this callback, not just the GameObject) --
        -- the actual alpha/color control is more likely to live here.
        dump_full_type_hierarchy(name .. "_Element", element)
    end
    return true
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Pickup fade-overlay investigation probe (read-only)")
    imgui.text("Prefix to grep: [pickup_fade_probe]")
    imgui.text("BlackFade dumped: " .. tostring(dumped.BlackFade))
    imgui.text("WhiteFade dumped: " .. tostring(dumped.WhiteFade))
    imgui.text_colored("Pick up a regular world item once to trigger the dump.", 0xFF88CCFF)
end)

log.info("[pickup_fade_probe] Loaded. Pick up a regular item once.")
