-- Diagnostic only (read-only, no writes) -- round 2 of the pickup fade
-- investigation. Round 1 (re2_vr_pickup_fade_investigation_probe.lua)
-- confirmed BlackFade/WhiteFade are via.gui.GUI components with ZERO raw
-- fields exposed -- no plain Alpha/Opacity field exists on either the
-- GameObject or Element chain. Instead both expose a native timeline-style
-- API: get_Asset/set_Asset, get_Segment/set_Segment, get_PlaySpeed/
-- set_PlaySpeed, plus a named-parameter system (findParameterVariable,
-- getParameterListCount). This strongly suggests the fade is a pre-built
-- .gui timeline animation, not a raw value we write directly.
--
-- This probe:
-- 1) On first sighting of each element, logs getParameterListCount() and
--    probes findParameterVariable() with a list of plausible names (Alpha,
--    Opacity, Color, ColorScale, Fade, FadeAlpha, Value, In, Out) -- for any
--    that resolve non-nil, dumps that returned object's own type hierarchy
--    too, since the real alpha control likely lives ON the parameter
--    variable object, not on the GUI component itself.
-- 2) Every frame, tracks get_Segment()/get_PlaySpeed()/get_Enabled() for
--    both elements and logs ONLY on change (not throttled-spam) -- this
--    will show directly whether the game already animates Segment or
--    PlaySpeed across a real pickup open/close cycle, which is the
--    "does a native animation already exist to extend/slow" question round
--    1 set out to answer but couldn't due to the missing field.
--
-- Safe to delete/archive once findings are captured.

if reframework:get_game_name() ~= "re2" then
    return
end

local CANDIDATE_PARAM_NAMES = {
    "Alpha", "alpha", "Opacity", "opacity", "Color", "ColorScale",
    "Fade", "FadeAlpha", "Value", "value", "In", "Out", "Rate", "FadeRate",
}

local function dump_full_type_hierarchy(tag, obj, max_depth)
    if not obj then
        log.info("[pickup_fade_probe2] " .. tag .. ": object unavailable")
        return
    end
    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    if not ok_td or not td then
        log.info("[pickup_fade_probe2] " .. tag .. ": no type definition")
        return
    end
    local depth = 0
    while td and depth < (max_depth or 4) do
        local ok_name, full_name = pcall(function() return td:get_full_name() end)
        log.info("[pickup_fade_probe2] " .. tag .. " L" .. depth .. " type: " .. tostring(ok_name and full_name or "?"))
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
                    log.info(string.format("[pickup_fade_probe2]   [L%d] field: %s = %s", depth, fname, tostring(ok_v and v or "?")))
                end
            end
        end
        local ok_m, methods = pcall(function() return td:get_methods() end)
        if ok_m and methods then
            for _, m in ipairs(methods) do
                local ok_n, mname = pcall(function() return m:get_name() end)
                if ok_n and mname then
                    log.info(string.format("[pickup_fade_probe2]   [L%d] method: %s", depth, mname))
                end
            end
        end
        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if not ok_p or not parent then break end
        td = parent
        depth = depth + 1
    end
end

local state = {
    BlackFade = { probed = false, last_segment = nil, last_playspeed = nil, last_enabled = nil },
    WhiteFade = { probed = false, last_segment = nil, last_playspeed = nil, last_enabled = nil },
}

local function probe_parameters(tag, element)
    local ok_count, count = pcall(function() return element:call("getParameterListCount") end)
    log.info(string.format("[pickup_fade_probe2] %s getParameterListCount = %s (ok=%s)", tag, tostring(count), tostring(ok_count)))

    for _, name in ipairs(CANDIDATE_PARAM_NAMES) do
        local ok_pv, pv = pcall(function() return element:call("findParameterVariable", name) end)
        if ok_pv and pv then
            log.info(string.format("[pickup_fade_probe2] %s findParameterVariable(%q) -> FOUND, dumping", tag, name))
            dump_full_type_hierarchy(tag .. "_param_" .. name, pv, 4)
        end
    end

    local ok_path, path = pcall(function() return element:call("get_AssetPath") end)
    log.info(string.format("[pickup_fade_probe2] %s AssetPath = %s (ok=%s)", tag, tostring(path), tostring(ok_path)))
end

re.on_pre_gui_draw_element(function(element, context)
    local ok_go, go = pcall(function() return element:call("get_GameObject") end)
    if not ok_go or not go then return true end
    local ok_n, name = pcall(function() return go:call("get_Name") end)
    if not ok_n or type(name) ~= "string" then return true end

    local s = state[name]
    if not s then return true end

    if not s.probed then
        s.probed = true
        log.info("[pickup_fade_probe2] === " .. name .. " first sighting -- probing parameters ===")
        probe_parameters(name, element)
    end

    local ok_seg, seg = pcall(function() return element:call("get_Segment") end)
    local ok_speed, speed = pcall(function() return element:call("get_PlaySpeed") end)
    local ok_en, en = pcall(function() return element:call("get_Enabled") end)

    if ok_seg and seg ~= s.last_segment then
        log.info(string.format("[pickup_fade_probe2] %s Segment changed: %s -> %s", name, tostring(s.last_segment), tostring(seg)))
        s.last_segment = seg
    end
    if ok_speed and speed ~= s.last_playspeed then
        log.info(string.format("[pickup_fade_probe2] %s PlaySpeed changed: %s -> %s", name, tostring(s.last_playspeed), tostring(speed)))
        s.last_playspeed = speed
    end
    if ok_en and en ~= s.last_enabled then
        log.info(string.format("[pickup_fade_probe2] %s Enabled changed: %s -> %s", name, tostring(s.last_enabled), tostring(en)))
        s.last_enabled = en
    end

    return true
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Pickup fade round 2: Segment/PlaySpeed/Parameters (read-only)")
    imgui.text("Prefix to grep: [pickup_fade_probe2]")
    imgui.text("BlackFade probed: " .. tostring(state.BlackFade.probed))
    imgui.text("WhiteFade probed: " .. tostring(state.WhiteFade.probed))
    imgui.text_colored("Pick up a regular world item a couple times (open+close a few times ideally).", 0xFF88CCFF)
end)

log.info("[pickup_fade_probe2] Loaded. Pick up a regular item a couple times.")
