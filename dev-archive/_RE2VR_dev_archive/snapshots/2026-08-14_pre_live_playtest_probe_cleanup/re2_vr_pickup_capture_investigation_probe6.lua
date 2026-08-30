-- Diagnostic only (read-only, no writes) -- round 6. Round 5 assumed the
-- "GuiBack" GUI element name (confirmed present in round 1's dump, from an
-- earlier/different test) would reliably appear during a pickup, and cached
-- panel references off it -- but on this specific test, BOTH scheduled
-- dumps (at open() and ~30 frames later) came back "unavailable", meaning
-- GuiBack was never actually observed via on_pre_gui_draw_element at all
-- during this whole session up to that point. Rather than guess why
-- (timing? different element name for this pickup context? draw order?),
-- this round drops the assumption entirely and just logs EVERY uniquely-
-- named active GUI element seen during a real pickup, unfiltered -- same
-- "observe everything, don't assume" technique the original BgPanel/
-- CapturePanel discovery (re2_vr_inventory_bg_tint_status) and the
-- 2026-08-07 itembox/examine probes both used successfully.
--
-- Logging window: armed the instant NewInventoryDetailBehavior.open() fires,
-- runs for 120 frames (~1.3-2s depending on frame rate) so it comfortably
-- covers the screen actually becoming visible, then stops on its own so it
-- doesn't spam indefinitely.
--
-- 2026-08-14 update: once live-tested, "GuiBack" WAS observed reliably
-- (~1 frame after open()) -- round 5's earlier "unavailable" result was
-- apparently just bad luck on that one test, not a real problem with the
-- technique. Added back round 5's capture-state dump (BgPanel/CapturePanel/
-- MainPanel), triggered off this proven sighting instead of asking for a
-- separate 7th probe file.
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
        log.info("[pickup_capture_probe6] " .. tag .. ": unavailable")
        return
    end
    log.info(string.format(
        "[pickup_capture_probe6] %s: CaptureEnable=%s CaptureTextureId=%s CaptureAllFrame=%s CaptureAction=%s CaptureRequest=%s CaptureSize=%s",
        tag,
        tostring(safe_call(capture_obj, "get_CaptureEnable")),
        tostring(safe_call(capture_obj, "get_CaptureTextureId")),
        tostring(safe_call(capture_obj, "get_CaptureAllFrame")),
        tostring(safe_call(capture_obj, "getCaptureAction")),
        tostring(safe_call(capture_obj, "getCaptureRequest")),
        fmt_vec2(safe_call(capture_obj, "get_CaptureSize"))))
end

-- 2026-08-14 addition: now that this exact hook has empirically confirmed
-- "GuiBack" reliably becomes active ~1 frame after open() fires, reuse that
-- sighting to also cache + dump the via.gui.Capture state on BgPanel/
-- CapturePanel/MainPanel -- combining round 5's dump logic (which was
-- correct, just got unlucky on its one prior test) with round 6's proven
-- sighting timing, instead of asking for a 7th separate test.
local panel_dump_frame = nil
local function try_cache_and_dump_panels(go)
    local ok_back, back_behavior = pcall(function()
        return go:call("getComponent(System.Type)", sdk.typeof(NS("gui.NewInventoryBackBehavior")))
    end)
    if not ok_back or not back_behavior then
        log.info("[pickup_capture_probe6] NewInventoryBackBehavior: getComponent failed on GuiBack")
        return
    end
    log.info("[pickup_capture_probe6] === GuiBack found -- immediate capture-state dump ===")
    for _, fname in ipairs({ "BgPanel", "CapturePanel", "MainPanel" }) do
        local ok_f, panel = pcall(function() return back_behavior:get_field(fname) end)
        dump_capture_state("IMMEDIATE/" .. fname, ok_f and panel or nil)
    end
    panel_dump_frame = { go = go, wait = 30 }
end

local logging_frames_left = 0
local seen_names = {}
local dumped_panels_once = false

re.on_pre_gui_draw_element(function(element, context)
    if logging_frames_left <= 0 then return true end
    local ok_go, go = pcall(function() return element:call("get_GameObject") end)
    if not ok_go or not go then return true end
    local ok_n, name = pcall(function() return go:call("get_Name") end)
    if not ok_n or type(name) ~= "string" or name == "" then return true end
    if not seen_names[name] then
        seen_names[name] = true
        log.info("[pickup_capture_probe6] active GUI element seen: '" .. name .. "'")
        if name == "GuiBack" and not dumped_panels_once then
            dumped_panels_once = true
            pcall(try_cache_and_dump_panels, go)
        end
    end
    return true
end)

local armed = false
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
                if not armed then
                    armed = true
                    logging_frames_left = 120
                    log.info("[pickup_capture_probe6] === open() fired -- logging active GUI elements for 120 frames ===")
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end)
    hooked_open = true
end

re.on_frame(function()
    if not hooked_open then pcall(install_open_observer) end
    if logging_frames_left > 0 then
        logging_frames_left = logging_frames_left - 1
        if logging_frames_left == 0 then
            log.info("[pickup_capture_probe6] === logging window ended ===")
        end
    end
    if panel_dump_frame then
        panel_dump_frame.wait = panel_dump_frame.wait - 1
        if panel_dump_frame.wait <= 0 then
            local go = panel_dump_frame.go
            panel_dump_frame = nil
            log.info("[pickup_capture_probe6] === ~30 frames after GuiBack -- delayed capture-state dump ===")
            local ok_back, back_behavior = pcall(function()
                return go:call("getComponent(System.Type)", sdk.typeof(NS("gui.NewInventoryBackBehavior")))
            end)
            if ok_back and back_behavior then
                for _, fname in ipairs({ "BgPanel", "CapturePanel", "MainPanel" }) do
                    local ok_f, panel = pcall(function() return back_behavior:get_field(fname) end)
                    dump_capture_state("DELAYED/" .. fname, ok_f and panel or nil)
                end
            end
        end
    end
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Pickup GUI-element sweep probe 6 (read-only)")
    imgui.text("Prefix to grep: [pickup_capture_probe6]")
    imgui.text("Armed: " .. tostring(armed))
    imgui.text("Frames left in window: " .. tostring(logging_frames_left))
    imgui.text_colored("Pick up a regular world item once to trigger the sweep.", 0xFF88CCFF)
end)

log.info("[pickup_capture_probe6] Loaded. Pick up a regular item once.")
