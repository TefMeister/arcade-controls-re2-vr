-- Diagnostic only (read-only, no writes) -- round 2 of the pickup black-
-- screen investigation, following up on real leads found in round 1's dump
-- (re2_vr_pickup_camera_investigation_probe.lua), which surfaced things
-- neither prior investigation (blur/FOV fields, BgPanel/CapturePanel
-- properties -- both CONFIRMED dead ends) ever looked at:
--
--   1. NewInventoryDetailBehavior has a MainCamera field (via.GameObject) --
--      a REAL camera object reference, not just a FOV number. Never
--      inspected before. If this is the wrong camera (not VR-aware, or a
--      degenerate/zeroed transform), that would explain a black VR-only
--      background directly.
--   2. NewInventoryBehavior has real trigger methods:
--      activatePostEffectCapture / changePostEffectDetail /
--      deactivatePostEffectDetail / openDetailDisp / closeDetailDisp /
--      setItemCamera -- these are plausibly what actually turns the
--      capture/blur effect on, as opposed to the blur/FOV fields (which are
--      just parameters OF the effect, confirmed to do nothing on their own).
--   3. NewInventoryBehavior.CaptureTexture (via.render.
--      RenderTargetTextureResourceHolder) -- a literal render target object,
--      never inspected. If it's never actually populated in VR, that's a
--      direct smoking gun.
--
-- This probe: (a) hooks the trigger methods above as pure observers (log
-- call order/timing, no writes) during a real pickup, (b) dumps MainCamera's
-- identity/transform once and compares against the real HMD position
-- (vrmod:get_position(0), same technique re2_vr_ik_extention.lua/
-- re2_vr_haptics.lua/re8_vr.lua already use) to see if it's positioned
-- sanely, (c) dumps CaptureTexture's own type hierarchy unfiltered (it's a
-- small, specific object, unlike the earlier broad keyword-filtered dumps).
--
-- Safe to delete/archive once findings are captured.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

local function fmt_vec(v)
    if not v then return "nil" end
    local ok, s = pcall(function() return string.format("(%.3f, %.3f, %.3f)", v.x, v.y, v.z) end)
    return ok and s or "invalid"
end

local function dump_full_type_hierarchy(tag, obj)
    if not obj then
        log.info("[pickup_cam_probe2] " .. tag .. ": object unavailable")
        return
    end
    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    if not ok_td or not td then
        log.info("[pickup_cam_probe2] " .. tag .. ": no type definition")
        return
    end
    local depth = 0
    while td and depth < 6 do
        local ok_name, full_name = pcall(function() return td:get_full_name() end)
        log.info("[pickup_cam_probe2] " .. tag .. " L" .. depth .. " type: " .. tostring(ok_name and full_name or "?"))
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
                    log.info(string.format("[pickup_cam_probe2]   [L%d] field: %s = %s", depth, fname, tostring(ok_v and v or "?")))
                end
            end
        end
        local ok_m, methods = pcall(function() return td:get_methods() end)
        if ok_m and methods then
            for _, m in ipairs(methods) do
                local ok_n, mname = pcall(function() return m:get_name() end)
                if ok_n and mname then
                    log.info(string.format("[pickup_cam_probe2]   [L%d] method: %s", depth, mname))
                end
            end
        end
        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if not ok_p or not parent then break end
        td = parent
        depth = depth + 1
    end
end

local function dump_main_camera(detail_behavior)
    local ok_mc, main_camera = pcall(function() return detail_behavior:get_field("MainCamera") end)
    if not ok_mc or not main_camera then
        log.info("[pickup_cam_probe2] MainCamera: unavailable")
        return
    end
    local ok_name, name = pcall(function() return main_camera:call("get_Name") end)
    log.info("[pickup_cam_probe2] MainCamera GameObject name: " .. tostring(ok_name and name or "?"))

    local ok_transform, transform = pcall(function() return main_camera:call("get_Transform") end)
    if ok_transform and transform then
        local ok_pos, pos = pcall(function() return transform:call("get_Position") end)
        log.info("[pickup_cam_probe2] MainCamera Transform position: " .. fmt_vec(ok_pos and pos or nil))
    end

    local ok_hmd, hmd_pos = pcall(function() return vrmod and vrmod:get_position(0) end)
    log.info("[pickup_cam_probe2] Real HMD position (vrmod:get_position(0)): " .. fmt_vec(ok_hmd and hmd_pos or nil))

    -- Also check for an actual via.Camera component on this GameObject --
    -- the GameObject itself might just be a rig/holder, the real camera
    -- data (FOV, near/far, render target) lives on the via.Camera component.
    local ok_cam_comp, cam_comp = pcall(function()
        return main_camera:call("getComponent(System.Type)", sdk.typeof("via.Camera"))
    end)
    if ok_cam_comp and cam_comp then
        dump_full_type_hierarchy("MainCamera's via.Camera component", cam_comp)
    else
        log.info("[pickup_cam_probe2] MainCamera: no via.Camera component found")
    end
end

local hooked_methods = false
local function install_method_observers()
    if hooked_methods then return end

    local inv_type = sdk.find_type_definition(NS("gui.NewInventoryBehavior"))
    local detail_type = sdk.find_type_definition(NS("gui.NewInventoryDetailBehavior"))
    if not inv_type or not detail_type then return end

    local function hook_observer(type_def, method_name)
        local m = type_def:get_method(method_name)
        if not m then
            log.info("[pickup_cam_probe2] method not found: " .. method_name)
            return
        end
        pcall(function()
            sdk.hook(m,
                function(args)
                    log.info(string.format("[pickup_cam_probe2] CALLED: %s (frame=%d)", method_name, re.get_frame_count()))
                    return sdk.PreHookResult.CALL_ORIGINAL
                end,
                function(retval)
                    log.info("[pickup_cam_probe2] RETURNED: " .. method_name)
                    return retval
                end)
        end)
    end

    for _, name in ipairs({ "openDetailDisp", "closeDetailDisp", "closeDetailOnly",
        "activatePostEffectCapture", "changePostEffectDetail", "deactivatePostEffectDetail",
        "setItemCamera" }) do
        hook_observer(inv_type, name)
    end
    hook_observer(detail_type, "searchMainCamera")

    hooked_methods = true
    log.info("[pickup_cam_probe2] Installed method-call observers")
end

local dumped_camera = false
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
                if not dumped_camera then
                    dumped_camera = true
                    local ok_self, self_obj = pcall(function() return sdk.to_managed_object(args[2]) end)
                    if ok_self and self_obj then
                        log.info("[pickup_cam_probe2] === open() fired, dumping MainCamera ===")
                        dump_main_camera(self_obj)
                    end
                    local behavior = re2.get_inventory_gui_behavior()
                    if behavior then
                        local ok_ct, capture_tex = pcall(function() return behavior:get_field("CaptureTexture") end)
                        if ok_ct and capture_tex then
                            dump_full_type_hierarchy("CaptureTexture", capture_tex)
                        end
                    end
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end)
    hooked_open = true
end

re.on_frame(function()
    if not hooked_methods then pcall(install_method_observers) end
    if not hooked_open then pcall(install_open_observer) end
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Pickup camera investigation probe 2 (read-only)")
    imgui.text("Prefix to grep: [pickup_cam_probe2]")
    imgui.text("MainCamera dumped: " .. tostring(dumped_camera))
    imgui.text_colored("Pick up a regular world item once to trigger everything.", 0xFF88CCFF)
end)

log.info("[pickup_cam_probe2] Loaded. Pick up a regular item once.")
