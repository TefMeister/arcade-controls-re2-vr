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
-- Safe to delete/archive once findings are captured.

if reframework:get_game_name() ~= "re2" then
    return
end

local NS = sdk.game_namespace

local logging_frames_left = 0
local seen_names = {}

re.on_pre_gui_draw_element(function(element, context)
    if logging_frames_left <= 0 then return true end
    local ok_go, go = pcall(function() return element:call("get_GameObject") end)
    if not ok_go or not go then return true end
    local ok_n, name = pcall(function() return go:call("get_Name") end)
    if not ok_n or type(name) ~= "string" or name == "" then return true end
    if not seen_names[name] then
        seen_names[name] = true
        log.info("[pickup_capture_probe6] active GUI element seen: '" .. name .. "'")
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
