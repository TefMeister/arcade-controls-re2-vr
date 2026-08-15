-- Diagnostic only (read-only, no writes) -- round 4 of the pickup black-
-- screen investigation. Four dead ends confirmed so far, each with real
-- verified evidence, not guesses: BgBlur/ColorScale numeric properties
-- (re2_vr_inventory_bg_tint_status), DetailBlurScale/DetailCameraFov
-- (suppress_blur [BG]), the MainCamera object itself (probe3 -- sits right
-- at the player's own position, nothing degenerate), and now
-- activatePostEffectCapture's trigger call (skip_post_effect_capture [BG2]
-- -- SKIPPED confirmed live via log, black screen unchanged, but the item
-- model itself still rendered fine).
--
-- That last result narrows things usefully: since the item model renders
-- correctly, the item's own camera/render path is fine in VR. It's
-- specifically the BACKGROUND (the captured/blurred snapshot of the game
-- world behind the item) that's black -- pointing at the via.gui.Capture
-- mechanism itself (BgPanel/CapturePanel/MainPanel, found in round 1's
-- dump, exposing getCaptureAction/setCaptureAction/get_CaptureEnable/
-- get_CaptureTexture/get_RenderTargetResource/get_CaptureSize/
-- get_CaptureStartPosition -- never actually READ before, only enumerated
-- by name).
--
-- This probe reads (not writes) those Capture properties live during a
-- pickup, on BgPanel (used by the grid/back view -- also active during the
-- detail view per round 1's dump) and CapturePanel. Goal: is capture even
-- enabled? Does it have a valid render target/size, or is something
-- visibly empty/zeroed? Real data before deciding whether a
-- set_CaptureEnable(false) experiment (or similar) is worth trying.
--
-- Safe to delete/archive once findings are captured.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
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
        log.info("[pickup_capture_probe4] " .. tag .. ": unavailable")
        return
    end
    log.info(string.format(
        "[pickup_capture_probe4] %s: CaptureEnable=%s CaptureTextureId=%s RenderTargetFormat=%s CaptureAllFrame=%s CaptureAction=%s CaptureRequest=%s",
        tag,
        tostring(safe_call(capture_obj, "get_CaptureEnable")),
        tostring(safe_call(capture_obj, "get_CaptureTextureId")),
        tostring(safe_call(capture_obj, "getRenderTargetFormat")),
        tostring(safe_call(capture_obj, "get_CaptureAllFrame")),
        tostring(safe_call(capture_obj, "getCaptureAction")),
        tostring(safe_call(capture_obj, "getCaptureRequest"))))
    log.info(string.format(
        "[pickup_capture_probe4] %s: CaptureStartPosition=%s CaptureSize=%s",
        tag,
        fmt_vec2(safe_call(capture_obj, "get_CaptureStartPosition")),
        fmt_vec2(safe_call(capture_obj, "get_CaptureSize"))))
    local ok_rt, render_target = pcall(function() return capture_obj:call("get_RenderTargetResource") end)
    log.info(string.format("[pickup_capture_probe4] %s: RenderTargetResource=%s", tag, tostring(ok_rt and render_target or "?")))
    local ok_ct, capture_tex = pcall(function() return capture_obj:call("getCaptureTexture") end)
    log.info(string.format("[pickup_capture_probe4] %s: CaptureTexture(via method)=%s", tag, tostring(ok_ct and capture_tex or "?")))
end

local dumped_capture = false
local function try_dump_on_guiback(go)
    if dumped_capture then return end
    local ok_name, name = pcall(function() return go:call("get_Name") end)
    if not ok_name or name ~= "GuiBack" then return end
    dumped_capture = true

    local ok_back, back_behavior = pcall(function()
        return go:call("getComponent(System.Type)", sdk.typeof(NS("gui.NewInventoryBackBehavior")))
    end)
    if not ok_back or not back_behavior then
        log.info("[pickup_capture_probe4] NewInventoryBackBehavior: getComponent failed on GuiBack")
        return
    end

    for _, fname in ipairs({ "BgPanel", "CapturePanel", "MainPanel" }) do
        local ok_f, panel = pcall(function() return back_behavior:get_field(fname) end)
        if ok_f and panel then
            dump_capture_state(fname, panel)
        else
            log.info("[pickup_capture_probe4] " .. fname .. ": field unavailable")
        end
    end
end

re.on_pre_gui_draw_element(function(element, context)
    if dumped_capture then return true end
    local ok_go, go = pcall(function() return element:call("get_GameObject") end)
    if ok_go and go then pcall(try_dump_on_guiback, go) end
    return true
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Pickup capture-state investigation probe 4 (read-only)")
    imgui.text("Prefix to grep: [pickup_capture_probe4]")
    imgui.text("Dumped: " .. tostring(dumped_capture))
    imgui.text_colored("Pick up a regular world item once (or open the manual inventory) to trigger the readout.", 0xFF88CCFF)
end)

log.info("[pickup_capture_probe4] Loaded. Pick up a regular item once.")
