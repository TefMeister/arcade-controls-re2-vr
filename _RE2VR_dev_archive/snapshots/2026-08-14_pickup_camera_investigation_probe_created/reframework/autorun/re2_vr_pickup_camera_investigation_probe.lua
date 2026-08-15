-- Diagnostic only (read-only, no writes) -- continuing the pickup black-
-- screen investigation (see re2_vr_pickup_reuse_itembox_camera_idea memory).
--
-- What's already confirmed dead: DetailBlurScale/DetailBlurMipLevel/
-- DetailCameraFov (numeric fields on NewInventoryBehavior) can be written
-- and read back correctly, but have ZERO visual effect on the VR black
-- screen -- same dead-end shape as re2_vr_inventory_bg_tint_status's
-- BgBlur/ColorScale findings from a week earlier. Both investigations only
-- ever probed a small, specific, already-guessed set of fields though --
-- neither ever did a full, unfiltered dump of everything these classes
-- actually expose. This probe does that: a broad keyword-filtered dump
-- (camera/view/capture/scene/render/target) across the full type hierarchy
-- of NewInventoryBehavior AND NewInventoryDetailBehavior, PLUS the same
-- for the already-known CapturePanel/BgPanel components (methods this
-- time, not just properties -- the earlier investigation only ever tried
-- writing properties on these, never looked at what methods they expose).
-- Goal: find the actual camera-switch/capture-trigger mechanism, since the
-- numeric knobs on the camera that's already active clearly aren't it.
--
-- Also logs firstpersonmod's plain Lua type -- already confirmed via
-- re2_vr_firstpersonmod_probe.lua's log output that it's a non-reflectable
-- Lua-side proxy (pairs() fails, "not a reflectable managed object"), so no
-- point re-trying that angle here.
--
-- Safe to delete/archive once findings are captured.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

local KEYWORDS = { "camera", "view", "capture", "scene", "render", "target", "detail" }

local function name_matches_keywords(name)
    local lower = name:lower()
    for _, kw in ipairs(KEYWORDS) do
        if lower:find(kw) then return true end
    end
    return false
end

local function safe_get_field_value(obj, fname, is_static, field)
    local ok, v
    if is_static then
        ok, v = pcall(function() return field:get_data(nil) end)
    else
        ok, v = pcall(function() return field:get_data(obj) end)
    end
    return ok and v or nil
end

local function dump_type_hierarchy(tag, obj)
    if not obj then
        log.info("[pickup_cam_probe] " .. tag .. ": object unavailable")
        return
    end
    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    if not ok_td or not td then
        log.info("[pickup_cam_probe] " .. tag .. ": no type definition")
        return
    end

    local depth = 0
    while td and depth < 8 do
        local ok_name, full_name = pcall(function() return td:get_full_name() end)
        log.info("[pickup_cam_probe] " .. tag .. " L" .. depth .. " type: " .. tostring(ok_name and full_name or "?"))

        local ok_f, fields = pcall(function() return td:get_fields() end)
        if ok_f and fields then
            for _, f in ipairs(fields) do
                local ok_n, fname = pcall(function() return f:get_name() end)
                if ok_n and fname and name_matches_keywords(fname) then
                    local ok_static, is_static = pcall(function() return f:is_static() end)
                    local value = safe_get_field_value(obj, fname, ok_static and is_static, f)
                    local ok_ftype, ftype = pcall(function()
                        local t = f:get_type()
                        return t and t:get_full_name() or "?"
                    end)
                    log.info(string.format("[pickup_cam_probe]   [L%d] field: %s (type=%s) = %s",
                        depth, fname, tostring(ok_ftype and ftype or "?"), tostring(value)))
                end
            end
        end

        local ok_m, methods = pcall(function() return td:get_methods() end)
        if ok_m and methods then
            for _, m in ipairs(methods) do
                local ok_n, mname = pcall(function() return m:get_name() end)
                if ok_n and mname and name_matches_keywords(mname) then
                    log.info(string.format("[pickup_cam_probe]   [L%d] method: %s", depth, mname))
                end
            end
        end

        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if not ok_p or not parent then break end
        td = parent
        depth = depth + 1
    end
end

-- Same CapturePanel/BgPanel objects re2_vr_inventory_bg_tint_status already
-- found -- reusing that investigation's own proven discovery method (GUI
-- element named "GuiBack" carries the NewInventoryBackBehavior component,
-- found via on_pre_gui_draw_element, not a guessed GameObject hierarchy
-- walk) rather than guessing where it lives. This time dumping METHODS too
-- (matching the same keyword list), which that investigation never tried
-- -- it only ever wrote properties like BlurScale/ColorScale.
local dumped_capture_panel = false
local function try_dump_capture_panel(go)
    if dumped_capture_panel then return end
    local ok_name, name = pcall(function() return go:call("get_Name") end)
    if not ok_name or name ~= "GuiBack" then return end
    dumped_capture_panel = true

    local ok_back, back_behavior = pcall(function()
        return go:call("getComponent(System.Type)", sdk.typeof(NS("gui.NewInventoryBackBehavior")))
    end)
    if not ok_back or not back_behavior then
        log.info("[pickup_cam_probe] NewInventoryBackBehavior: getComponent failed on GuiBack")
        return
    end
    dump_type_hierarchy("NewInventoryBackBehavior", back_behavior)

    for _, fname in ipairs({ "BgPanel", "CapturePanel", "MainPanel", "BgBlur" }) do
        local ok_f, sub = pcall(function() return back_behavior:get_field(fname) end)
        if ok_f and sub then
            dump_type_hierarchy(fname, sub)
        end
    end
end

re.on_pre_gui_draw_element(function(element, context)
    if dumped_capture_panel then return true end
    local ok_go, go = pcall(function() return element:call("get_GameObject") end)
    if ok_go and go then pcall(try_dump_capture_panel, go) end
    return true
end)

local dumped_once = false
local hooked_open = false
local function install_open_observer()
    if hooked_open then return end
    local detail_type = sdk.find_type_definition(NS("gui.NewInventoryDetailBehavior"))
    if not detail_type then return end
    local m = detail_type:get_method("open")
    if not m then return end
    local ok_h = pcall(function()
        sdk.hook(m,
            function(args)
                if not dumped_once then
                    dumped_once = true
                    log.info("[pickup_cam_probe] === NewInventoryDetailBehavior.open fired, dumping now ===")
                    local behavior = re2.get_inventory_gui_behavior()
                    dump_type_hierarchy("NewInventoryBehavior", behavior)
                    local ok_self, self_obj = pcall(function() return sdk.to_managed_object(args[2]) end)
                    if ok_self and self_obj then
                        dump_type_hierarchy("NewInventoryDetailBehavior(self)", self_obj)
                    end
                    log.info("[pickup_cam_probe] === dump complete (GuiBack/CapturePanel dump runs separately via on_pre_gui_draw_element) ===")
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end)
    if ok_h then
        hooked_open = true
        log.info("[pickup_cam_probe] Hooked NewInventoryDetailBehavior.open (observer only, one-shot dump)")
    end
end

re.on_frame(function()
    if not hooked_open then pcall(install_open_observer) end
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Pickup camera/capture investigation probe (read-only, one-shot dump)")
    imgui.text("Prefix to grep: [pickup_cam_probe]")
    imgui.text("Detail-behavior dump done: " .. tostring(dumped_once))
    imgui.text("GuiBack/CapturePanel dump done: " .. tostring(dumped_capture_panel))
    imgui.text_colored("Pick up a regular world item once to trigger the dump.", 0xFF88CCFF)
end)

log.info("[pickup_cam_probe] Loaded. Pick up a regular item once -- dumps NewInventoryBehavior/NewInventoryDetailBehavior/CapturePanel camera-related fields+methods on first open only.")
