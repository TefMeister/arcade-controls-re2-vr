-- EXPERIMENTAL, manual single-press test only -- real commit attempt,
-- same risk class as prior live failures on this exact feature (item loss,
-- hang). Test on a save you don't mind risking.
--
-- Round 4. Prior round called exchangeGetItem(slotIndex) alone -- correct
-- signature (confirmed via reflection), reached real native code (no
-- REFramework arg-count warning), but the item never landed in inventory.
-- re2_vr_inventory_decide_probe.lua then passively observed a REAL confirm
-- press (Space key) during a real pickup and caught the actual sequence:
--   exchangeGetItem(1)             -- single int, the slot index
--   setDuplicateItemCursor(1,0,0)  -- looks cosmetic (cursor icon), skipped here
--   setSlotItem(1)                 -- SAME slot index, called immediately after
--
-- Hypothesis: exchangeGetItem clears/prepares the slot, setSlotItem is the
-- actual commit -- calling only the first half (what round 3 did) would
-- explain exactly what was observed: a slot cleared via removeSlot, with
-- nothing written back in, i.e. the item vanishing.
--
-- This test calls BOTH in the same order and slot index the real game used,
-- via a single manual button -- not automatic, not same-frame-armed (an
-- earlier same-frame attempt had zero effect at all, only the ~1s-delayed
-- manual attempt reached real logic, so this only offers the delayed path).
--
-- Round 5 (after round 4's live test): exchangeGetItem+setSlotItem DID
-- grant the item this time -- first real success in the whole investigation
-- -- but left the screen's own cursor/selection state stuck mid-decision.
-- A subsequent real mouse click on an empty slot triggered an unexpected
-- "swap" prompt and the item ended up in a slot the player never chose.
-- Root cause: we skipped the rest of the original 2026-08-05 completion
-- chain (DetailBehavior.close -> ~300ms gap -> NewInventoryBehavior.close
-- -> SlotBehavior.close -> DetailBehavior.forceClose ->
-- SlotBehavior.mainPanelStateFinished -> NewInventoryBehavior.finish) --
-- those signal "this interaction is done," which we never told the screen.
-- Added reflection-verified signatures for all of them (never checked
-- before -- that chain was only ever mapped by name, not by real arg
-- count, back in the original investigation) plus two more manual buttons
-- to close things out properly, split into two steps to mirror the real
-- ~300ms gap observed between DetailBehavior.close and the rest.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

local state = {
    hooked = false,
    captured_slot_index = nil,
    log_buffer = {},
    last_attempt_result = "(not tried yet)",
}

local MAX_LOG_LINES = 100

local function log_line(s)
    local full = "[inv_confirm_test] " .. s
    log.info(full)
    table.insert(state.log_buffer, 1, full)
    if #state.log_buffer > MAX_LOG_LINES then table.remove(state.log_buffer) end
end

local function log_signature(type_def, method_name, label)
    if not type_def then
        log_line(label .. ": type not found")
        return
    end
    local m = type_def:get_method(method_name)
    if not m then
        log_line(label .. ": method not found")
        return
    end
    local ok_np, num_params = pcall(function() return m:get_num_params() end)
    local ok_rt, rt = pcall(function() return m:get_return_type():get_full_name() end)
    log_line(string.format("%s: (%s param(s)) -> %s",
        label, tostring(ok_np and num_params or "?"), tostring(ok_rt and rt or "?")))
end

local function install_hook()
    if state.hooked then return end

    local inv_type = sdk.find_type_definition(NS("survivor.Inventory"))
    if not inv_type then return end
    local method = inv_type:get_method("getInitializeCursorPosition")
    if not method then
        log_line("could not find Inventory.getInitializeCursorPosition")
        return
    end

    sdk.hook(method,
        function(args) return sdk.PreHookResult.CALL_ORIGINAL end,
        function(retval)
            local ok_r, r = pcall(function() return sdk.to_int64(retval) end)
            state.captured_slot_index = ok_r and r or nil
            log_line("getInitializeCursorPosition POST retval (slot index) = " ..
                tostring(state.captured_slot_index))
            return retval
        end)

    -- Reflection-verify the rest of the original 2026-08-05 completion
    -- chain's real signatures before ever calling any of them.
    local detail_type = sdk.find_type_definition(NS("gui.NewInventoryDetailBehavior"))
    local slot_type = sdk.find_type_definition(NS("gui.NewInventorySlotBehavior"))
    local behavior_type = sdk.find_type_definition(NS("gui.NewInventoryBehavior"))
    log_signature(detail_type, "close", "DetailBehavior.close")
    log_signature(detail_type, "forceClose", "DetailBehavior.forceClose")
    log_signature(slot_type, "close", "SlotBehavior.close")
    log_signature(slot_type, "mainPanelStateFinished", "SlotBehavior.mainPanelStateFinished")
    log_signature(behavior_type, "close", "NewInventoryBehavior.close")
    log_signature(behavior_type, "finish", "NewInventoryBehavior.finish")

    state.hooked = true
    log_line("Hooked Inventory.getInitializeCursorPosition")
end

local function get_sub_behaviors()
    local ok_beh, behavior = pcall(function() return re2.get_inventory_gui_behavior() end)
    if not ok_beh or not behavior then return nil end
    local ok_slot, slot_behavior = pcall(function()
        return behavior:get_field("<SlotBehavior>k__BackingField")
    end)
    local ok_detail, detail_behavior = pcall(function()
        return behavior:get_field("<DetailBehavior>k__BackingField")
    end)
    return behavior, (ok_slot and slot_behavior or nil), (ok_detail and detail_behavior or nil)
end

local function try_call(obj, method_name, label)
    if not obj then
        log_line(label .. ": object unavailable")
        return
    end
    local ok, err = pcall(function() return obj:call(method_name) end)
    log_line(string.format("%s() ok=%s err=%s", label, tostring(ok), tostring(err)))
end

local function try_close_step_a()
    local behavior, slot_behavior, detail_behavior = get_sub_behaviors()
    if not detail_behavior then
        state.last_attempt_result = "could not get DetailBehavior right now"
        log_line(state.last_attempt_result)
        return
    end
    try_call(detail_behavior, "close", "DetailBehavior.close")
    state.last_attempt_result = "Step A done (DetailBehavior.close) -- wait a beat, then try Step B"
end

local function try_close_step_b()
    local behavior, slot_behavior, detail_behavior = get_sub_behaviors()
    if not behavior or not slot_behavior or not detail_behavior then
        state.last_attempt_result = "could not get one of Behavior/SlotBehavior/DetailBehavior right now"
        log_line(state.last_attempt_result)
        return
    end
    try_call(behavior, "close", "NewInventoryBehavior.close")
    try_call(slot_behavior, "close", "SlotBehavior.close")
    try_call(detail_behavior, "forceClose", "DetailBehavior.forceClose")
    try_call(slot_behavior, "mainPanelStateFinished", "SlotBehavior.mainPanelStateFinished")
    try_call(behavior, "finish", "NewInventoryBehavior.finish")
    state.last_attempt_result = "Step B done -- check whether the screen actually closed cleanly"
end

local function try_confirm()
    if state.captured_slot_index == nil then
        state.last_attempt_result = "no captured slot index yet -- let a pickup screen open first"
        log_line(state.last_attempt_result)
        return
    end

    local ok_beh, behavior = pcall(function() return re2.get_inventory_gui_behavior() end)
    if not ok_beh or not behavior then
        state.last_attempt_result = "could not get NewInventoryBehavior right now"
        log_line(state.last_attempt_result)
        return
    end
    local ok_slot, slot_behavior = pcall(function()
        return behavior:get_field("<SlotBehavior>k__BackingField")
    end)
    if not ok_slot or not slot_behavior then
        state.last_attempt_result = "could not get SlotBehavior right now"
        log_line(state.last_attempt_result)
        return
    end

    local slot = state.captured_slot_index

    local ok1, err1 = pcall(function() return slot_behavior:call("exchangeGetItem", slot) end)
    log_line(string.format("exchangeGetItem(%s) ok=%s err=%s", tostring(slot), tostring(ok1), tostring(err1)))

    local ok2, err2 = pcall(function() return slot_behavior:call("setSlotItem", slot) end)
    log_line(string.format("setSlotItem(%s) ok=%s err=%s", tostring(slot), tostring(ok2), tostring(err2)))

    state.last_attempt_result = string.format("exchangeGetItem ok=%s, setSlotItem ok=%s -- CHECK INVENTORY NOW",
        tostring(ok1), tostring(ok2))
    log_line(state.last_attempt_result)
end

re.on_frame(function()
    if not state.hooked then
        pcall(install_hook)
    end
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text_colored(
        "EXPERIMENTAL -- real commit attempt, single manual press only. May lose the item or desync",
        0xFF6688FF)
    imgui.text_colored(
        "state. Test on a save you don't mind risking. CHECK INVENTORY COUNT after pressing.",
        0xFF6688FF)
    imgui.spacing()
    imgui.text("Hooked: " .. tostring(state.hooked))
    imgui.text("Captured slot index: " .. tostring(state.captured_slot_index))
    imgui.spacing()
    imgui.text("Last attempt result: " .. state.last_attempt_result)
    imgui.spacing()
    imgui.text("Pick up an item, wait a moment for the screen to fully open, THEN press:")
    if imgui.button("1) Try exchangeGetItem(slot) + setSlotItem(slot)") then
        try_confirm()
    end
    imgui.spacing()
    imgui.text_colored(
        "Only proceed to 2/3 if the item actually landed but the screen looks stuck/desynced.",
        0xFFAAAAAA)
    if imgui.button("2) Close step A: DetailBehavior.close()") then
        try_close_step_a()
    end
    if imgui.button("3) Close step B: NewInventoryBehavior/SlotBehavior/DetailBehavior finish chain") then
        try_close_step_b()
    end
    imgui.spacing()
    for _, line in ipairs(state.log_buffer) do
        imgui.text(line)
    end
end)

log.info("[re2_vr_inventory_confirm_test] Loaded")
