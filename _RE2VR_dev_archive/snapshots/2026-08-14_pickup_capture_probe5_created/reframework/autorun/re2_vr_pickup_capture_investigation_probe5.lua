-- Diagnostic only (read-only, no writes) -- round 5, fixing a timing flaw in
-- round 4's probe. Round 4 dumped BgPanel/CapturePanel/MainPanel's
-- via.gui.Capture state on the FIRST sighting of the "GuiBack" GUI element
-- ever -- which fired far too early (likely at scene load, long before any
-- actual pickup), showing CaptureEnable=false / CaptureTextureId=0 across
-- all three panels. That's plausibly just idle/baseline state, not the real
-- state while the black background is actually visible -- not trustworthy
-- evidence either way until re-read at the right moment.
--
-- This round: caches the back_behavior/panel references the first time
-- GuiBack is seen (same proven discovery method, no guessing), but does NOT
-- dump immediately. Instead dumps their live Capture state (a) the instant
-- NewInventoryDetailBehavior.open() fires (the actual black-screen trigger
-- point, same timing round 2/3 already used), and (b) again ~30 frames
-- later (roughly half a second), to see whether CaptureEnable/
-- CaptureTextureId actually change once the screen is genuinely open and
-- visible, rather than trusting a single too-early snapshot.
--
-- Safe to delete/archive once findings are captured.

if reframework:get_game_name() ~= "re2" then
    return
end

local NS = sdk.game_namespace

local function safe_call(obj, method)
    if not obj then return nil end
    local ok, v = pcall(function() return obj:call(method) end)
    if ok then return v end
    return nil
end

local function fmt_vec2(v)
    if not v then return "nil" end
    local ok, s = pcall(function() return string.format("(%.1f, %.1f)", v.x, v.y) end)
    return ok and s or tostring(v)
end

local function dump_capture_state(tag, capture_obj)
    if not capture_obj then
        log.info("[pickup_capture_probe5] " .. tag .. ": unavailable")
        return
    end
    log.info(string.format(
        "[pickup_capture_probe5] %s: CaptureEnable=%s CaptureTextureId=%s CaptureAllFrame=%s CaptureAction=%s CaptureRequest=%s CaptureSize=%s",
        tag,
        tostring(safe_call(capture_obj, "get_CaptureEnable")),
        tostring(safe_call(capture_obj, "get_CaptureTextureId")),
        tostring(safe_call(capture_obj, "get_CaptureAllFrame")),
        tostring(safe_call(capture_obj, "getCaptureAction")),
        tostring(safe_call(capture_obj, "getCaptureRequest")),
        fmt_vec2(safe_call(capture_obj, "get_CaptureSize"))))
end

-- Cached panel references, found once via the proven "GuiBack" discovery
-- method, then reused for repeated reads at the right moments (unlike
-- round 4, which only ever read them once, immediately, too early).
local panels = { BgPanel = nil, CapturePanel = nil, MainPanel = nil }
local panels_found = false

local function try_cache_panels(go)
    if panels_found then return end
    local ok_name, name = pcall(function() return go:call("get_Name") end)
    if not ok_name or name ~= "GuiBack" then return end

    local ok_back, back_behavior = pcall(function()
        return go:call("getComponent(System.Type)", sdk.typeof(NS("gui.NewInventoryBackBehavior")))
    end)
    if not ok_back or not back_behavior then return end

    for fname, _ in pairs(panels) do
        local ok_f, panel = pcall(function() return back_behavior:get_field(fname) end)
        if ok_f and panel then
            panels[fname] = panel
        end
    end
    panels_found = (panels.BgPanel ~= nil) or (panels.CapturePanel ~= nil) or (panels.MainPanel ~= nil)
    if panels_found then
        log.info("[pickup_capture_probe5] Panel references cached from GuiBack")
    end
end

re.on_pre_gui_draw_element(function(element, context)
    if panels_found then return true end
    local ok_go, go = pcall(function() return element:call("get_GameObject") end)
    if ok_go and go then pcall(try_cache_panels, go) end
    return true
end)

local function dump_all_panels(tag)
    for _, fname in ipairs({ "BgPanel", "CapturePanel", "MainPanel" }) do
        dump_capture_state(tag .. "/" .. fname, panels[fname])
    end
end

local dumped_at_open = false
local delayed_dump_frame = nil
local hooked_open = false
local function install_open_observer()
    if hooked_open then return end
    local detail_type = sdk.find_type_definition(NS("gui.NewInventoryDetailBehavior"))
    if not detail_type then return end
    local m = detail_type:get_method("open")
    if not m then return end
    pcall(function()
        sdk.hook(m,
            function(args)
                if not dumped_at_open then
                    dumped_at_open = true
                    log.info("[pickup_capture_probe5] === open() fired -- immediate capture-state dump ===")
                    dump_all_panels("AT_OPEN")
                    delayed_dump_frame = 30
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end)
    hooked_open = true
end

re.on_frame(function()
    if not hooked_open then pcall(install_open_observer) end
    if delayed_dump_frame then
        delayed_dump_frame = delayed_dump_frame - 1
        if delayed_dump_frame <= 0 then
            delayed_dump_frame = nil
            log.info("[pickup_capture_probe5] === ~30 frames after open() -- second capture-state dump ===")
            pcall(dump_all_panels, "DELAYED")
        end
    end
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Pickup capture-state investigation probe 5 (read-only, fixed timing)")
    imgui.text("Prefix to grep: [pickup_capture_probe5]")
    imgui.text("Panels cached: " .. tostring(panels_found))
    imgui.text("Dumped at open: " .. tostring(dumped_at_open))
    imgui.text_colored("Pick up a regular world item once to trigger both dumps.", 0xFF88CCFF)
end)

log.info("[pickup_capture_probe5] Loaded. Pick up a regular item once.")
