-- Diagnostic only (read-only, no writes) -- investigating the player's own
-- idea (see re2_vr_pickup_reuse_itembox_camera_idea memory): item-box
-- withdrawal never shows the disruptive black-screen/blur that regular
-- world-item pickup does -- background stays visible, player isn't
-- rendered, no jarring zoom camera. Goal: find out WHAT is actually
-- different between the two screens so regular pickup could potentially be
-- routed through (or made to imitate) whatever item box already does,
-- rather than trying to fix pickup's own blur/zoom camera directly (already
-- a confirmed dead end via reflection, see re2_vr_inventory_bg_tint_status
-- memory -- BgBlur/BgPanel/ColorScale don't do anything reachable).
--
-- Known lead going in: utility/RE2.lua's RE2.get_inventory_gui_gameobject()
-- reads GUIMaster.RefInventoryUI (used for BOTH regular pickup and the
-- manual inventory menu, per re2_vr_inventory_auto_complete.lua's existing
-- code). re2_vr_holster.lua's own BLOCKING_GUI_NAMES list separately
-- references "RefItemBoxUI" as a distinct GUI element name -- so item box
-- likely has its own top-level GameObject entirely, not routed through
-- RefInventoryUI/NewInventoryBehavior at all. This probe confirms that (or
-- disproves it) with real data instead of assuming.
--
-- Technique reused verbatim from two old probes found in the dev archive
-- (re2_vr_itembox_probe.lua, re2_vr_itemexamine_probe.lua,
-- 2026-08-07-era investigation): on_pre_gui_draw_element to log every named
-- GUI element's active/inactive transitions, tagged here by which context
-- (ITEM_BOX vs PICKUP_OR_INVENTORY vs NONE) was live at that moment, so the
-- two screens' actual element sets can be diffed directly from the log.
--
-- Safe to delete/archive once the findings from a real test are captured.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

local function safe_call(obj, method, ...)
    if not obj then return nil end
    local args = { ... }
    local ok, v = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return v end
    return nil
end

local function safe_get_field(obj, name)
    if not obj then return nil end
    local ok, v = pcall(function() return obj:get_field(name) end)
    if ok then return v end
    return nil
end

-- One-time: dump every GUIMaster field whose name suggests it's a GUI root
-- GameObject reference ("Ref...UI" pattern, matches RefInventoryUI/
-- RefItemBoxUI already known from other files in this mod) -- confirms the
-- exact field name/casing live rather than assuming, and surfaces any OTHER
-- Ref*UI fields neither existing script currently knows about.
local dumped_gm_fields = false
local function dump_gm_ref_fields()
    if dumped_gm_fields then return end
    dumped_gm_fields = true
    local gm = sdk.get_managed_singleton(NS("gui.GUIMaster"))
    if not gm then return end
    local ok_td, td = pcall(function() return gm:get_type_definition() end)
    if not ok_td or not td then return end
    log.info("[pickup_bg_probe] --- GUIMaster fields matching 'Ref' or 'UI' ---")
    local depth = 0
    while td and depth < 6 do
        local ok_f, fields = pcall(function() return td:get_fields() end)
        if ok_f and fields then
            for _, f in ipairs(fields) do
                local ok_n, fname = pcall(function() return f:get_name() end)
                if ok_n and fname and (fname:find("Ref") or fname:find("UI")) then
                    local ok_static, is_static = pcall(function() return f:is_static() end)
                    local ok_v, value
                    if ok_static and is_static then
                        ok_v, value = pcall(function() return f:get_data(nil) end)
                    else
                        ok_v, value = pcall(function() return f:get_data(gm) end)
                    end
                    log.info("[pickup_bg_probe]   [L" .. depth .. "] field: " .. fname
                        .. " = " .. tostring(ok_v and value or "?(get_data failed)"))
                end
            end
        end
        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if not ok_p or not parent then break end
        td = parent
        depth = depth + 1
    end
end

local function is_item_box_open()
    local gm = sdk.get_managed_singleton(NS("gui.GUIMaster"))
    if not gm then return false end
    if safe_call(gm, "isBusyItemBox") == true then return true end
    if safe_call(gm, "getItemBoxEnable") == true then return true end
    return false
end

local function is_inventory_open()
    local gm = sdk.get_managed_singleton(NS("gui.GUIMaster"))
    if not gm then return false end
    return safe_call(gm, "get_IsOpenInventory") == true
end

local function current_context()
    if is_item_box_open() then return "ITEM_BOX" end
    if is_inventory_open() then return "PICKUP_OR_INVENTORY" end
    return "NONE"
end

-- Snapshot of the same camera/blur fields re2_vr_inventory_auto_complete.lua
-- already reads/writes for its (unproven, now-parked) suppress_blur
-- experiment -- logged here read-only, tagged by context, to see whether
-- item box even has these fields populated the same way (same behavior
-- object at all?) or whether NewInventoryBehavior isn't involved for item
-- box in the first place.
local function log_camera_snapshot(tag)
    local behavior = re2.get_inventory_gui_behavior()
    if not behavior then
        log.info("[pickup_bg_probe] " .. tag .. ": NewInventoryBehavior unavailable")
        return
    end
    log.info(string.format(
        "[pickup_bg_probe] %s: CameraFov=%s DetailCameraFov=%s DetailBlurScale=%s DetailBlurMipLevel=%s",
        tag,
        tostring(safe_get_field(behavior, "<CameraFov>k__BackingField")),
        tostring(safe_get_field(behavior, "<DetailCameraFov>k__BackingField")),
        tostring(safe_get_field(behavior, "<DetailBlurScale>k__BackingField")),
        tostring(safe_get_field(behavior, "<DetailBlurMipLevel>k__BackingField"))))
end

-- Context transition logging + one camera snapshot at the moment each
-- context is entered (not every frame -- avoids log spam, one clean
-- before/after per screen open is enough to compare).
local last_context = "NONE"
re.on_frame(function()
    dump_gm_ref_fields()
    local ctx = current_context()
    if ctx ~= last_context then
        log.info(string.format("[pickup_bg_probe] === CONTEXT CHANGE: %s -> %s ===", last_context, ctx))
        if ctx ~= "NONE" then
            log_camera_snapshot(ctx .. " (on entry)")
        end
        last_context = ctx
    end
end)

-- Passive observer on the same native call re2_vr_inventory_auto_complete.lua
-- already hooks for its NIC feature -- separate hook instance, read-only,
-- does not touch args. Confirms (or disproves) whether item box ever calls
-- this at all.
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
                log.info("[pickup_bg_probe] NewInventoryDetailBehavior.open called, context=" .. current_context())
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end)
    if ok_h then
        hooked_open = true
        log.info("[pickup_bg_probe] Hooked NewInventoryDetailBehavior.open (observer only)")
    end
end

re.on_frame(function()
    if not hooked_open then pcall(install_open_observer) end
end)

-- Proven technique (verbatim pattern from the 2026-08-07 item-box/examine
-- probes in the dev archive): log every named GUI element's active/inactive
-- transition, tagged with whatever context was live at that moment.
local last_active_by_name = {}
re.on_pre_gui_draw_element(function(element, context)
    local ok_go, go = pcall(function() return element:call("get_GameObject") end)
    if not ok_go or not go then return true end
    local ok_n, name = pcall(function() return go:call("get_Name") end)
    if not ok_n or type(name) ~= "string" or name == "" then return true end

    local active = false
    pcall(function() active = go:read_byte(0x10) == 1 end)

    if last_active_by_name[name] ~= active then
        last_active_by_name[name] = active
        log.info(string.format("[pickup_bg_probe] GUI element '%s' active=%s  (ctx=%s)",
            name, tostring(active), current_context()))
    end
    return true
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Pickup/item-box background investigation probe (read-only)")
    imgui.text("Prefix to grep: [pickup_bg_probe]")
    imgui.text("Current context: " .. current_context())
    imgui.text_colored(
        "Test plan: open the item box once, close it, then pick up a regular",
        0xFF88CCFF)
    imgui.text_colored(
        "world item once. Then check re2_framework_log.txt for both traces.",
        0xFF88CCFF)
end)

log.info("[pickup_bg_probe] Loaded. Open the item box, then pick up a regular item, then check the log.")
