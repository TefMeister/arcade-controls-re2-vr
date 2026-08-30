-- Diagnostic only (read-only, no writes) -- round 3 of the pickup fade
-- investigation. Round 2 (re2_vr_pickup_fade_investigation_probe2.lua)
-- logged BlackFade/WhiteFade's Segment on EVERY change with no gating and
-- got pure noise: both objects were "first sighted" ~30ms after the probe
-- loaded (before any player action was possible) and Segment cycled through
-- a handful of values many times WITHIN single ~16ms frames. Conclusion:
-- BlackFade/WhiteFade are persistent GUI nodes reused for lots of unrelated
-- on-screen content every frame, not a pickup-exclusive fade animation --
-- round 2's raw Segment-change log can't tell pickup-relevant changes apart
-- from background redraw noise.
--
-- This probe borrows the proven context-gating technique from
-- re2_vr_pickup_bg_investigation_probe.lua (GUIMaster.isBusyItemBox /
-- getItemBoxEnable / get_IsOpenInventory, current_context()) plus a hook on
-- NewInventoryDetailBehavior.open (the exact native call that opens the
-- "Got [item]" detail card during regular pickup) to take Segment/PlaySpeed/
-- Enabled SNAPSHOTS only at real transition points, instead of continuous
-- unfiltered logging:
--   1. Context change (NONE <-> ITEM_BOX <-> PICKUP_OR_INVENTORY) -- one
--      snapshot at the moment of entry, one at the moment of exit.
--   2. NewInventoryDetailBehavior.open call -- one snapshot immediately
--      before the call, one immediately after it returns.
-- Test plan (mirrors pickup_bg_probe's own, for a clean control/test
-- contrast): open the item box once and close it (no black screen expected
-- -- control), THEN pick up a regular world item once (black screen
-- expected -- test). If Segment/PlaySpeed/Enabled snapshots differ
-- meaningfully between the two, that's real signal. If they look the same
-- either way, this BlackFade/WhiteFade lead is a dead end.
--
-- Safe to delete/archive once findings are captured.

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

-- Tracks the last-seen elements themselves (found via the same
-- on_pre_gui_draw_element name-match technique) so snapshots can be taken
-- on demand rather than only inside the draw callback.
local last_element = { BlackFade = nil, WhiteFade = nil }

re.on_pre_gui_draw_element(function(element, context)
    local ok_go, go = pcall(function() return element:call("get_GameObject") end)
    if not ok_go or not go then return true end
    local ok_n, name = pcall(function() return go:call("get_Name") end)
    if not ok_n or type(name) ~= "string" then return true end
    if last_element[name] ~= nil then
        last_element[name] = element
    elseif name == "BlackFade" or name == "WhiteFade" then
        last_element[name] = element
    end
    return true
end)

local function snapshot(tag)
    for _, name in ipairs({ "BlackFade", "WhiteFade" }) do
        local el = last_element[name]
        if not el then
            log.info(string.format("[pickup_fade_probe3] %s %s: no element captured yet", tag, name))
        else
            local ok_seg, seg = pcall(function() return el:call("get_Segment") end)
            local ok_speed, speed = pcall(function() return el:call("get_PlaySpeed") end)
            local ok_en, en = pcall(function() return el:call("get_Enabled") end)
            log.info(string.format(
                "[pickup_fade_probe3] %s %s: Segment=%s PlaySpeed=%s Enabled=%s",
                tag, name,
                tostring(ok_seg and seg or "?"),
                tostring(ok_speed and speed or "?"),
                tostring(ok_en and en or "?")))
        end
    end
end

local last_context = "NONE"
re.on_frame(function()
    local ctx = current_context()
    if ctx ~= last_context then
        log.info(string.format("[pickup_fade_probe3] === CONTEXT CHANGE: %s -> %s ===", last_context, ctx))
        snapshot(last_context .. "->" .. ctx)
        last_context = ctx
    end
end)

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
                log.info("[pickup_fade_probe3] NewInventoryDetailBehavior.open PRE-CALL, context=" .. current_context())
                snapshot("PRE-open-call")
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                log.info("[pickup_fade_probe3] NewInventoryDetailBehavior.open POST-CALL, context=" .. current_context())
                snapshot("POST-open-call")
                return retval
            end)
    end)
    if ok_h then
        hooked_open = true
        log.info("[pickup_fade_probe3] Hooked NewInventoryDetailBehavior.open (observer only)")
    end
end

re.on_frame(function()
    if not hooked_open then pcall(install_open_observer) end
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Pickup fade round 3: gated snapshots (read-only)")
    imgui.text("Prefix to grep: [pickup_fade_probe3]")
    imgui.text("Current context: " .. current_context())
    imgui.text_colored("Test plan: open the item box once, close it (control),", 0xFF88CCFF)
    imgui.text_colored("then pick up a regular world item once (test).", 0xFF88CCFF)
end)

log.info("[pickup_fade_probe3] Loaded. Open item box + close (control), then pick up a regular item (test).")
