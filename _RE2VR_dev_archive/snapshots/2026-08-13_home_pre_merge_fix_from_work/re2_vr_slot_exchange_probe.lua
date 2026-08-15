-- Diagnostic (read-only observation -- hooks exchangeGetItem but never alters
-- args or skips the original call).
--
-- Round 2. Round 1 confirmed the completion chain (exchangeGetItem/setSlotItem/
-- DetailBehavior.close/finish chain) logs identically successful whether the
-- world object despawns correctly or not -- the divergence isn't visible in
-- call presence/success. User's own live testing narrowed it precisely:
-- picking up into an EMPTY inventory slot always works; picking up when it
-- needs to MERGE into an already-occupied slot (e.g. a 2nd ammo box while
-- already carrying that ammo type) is what breaks.
--
-- Round 1's one-time field dump of SlotBehavior found exactly the fields that
-- matter for this: CombinedSlotNo (Int32), GetItemSlotNo (Int32), and
-- PreCombineStock/GetItemStock (both StockItem references) -- these track
-- the "merge into existing stack" case specifically. Working theory: our
-- auto_complete script's exchangeGetItem/setSlotItem calls use whatever
-- Inventory.getInitializeCursorPosition returned as the target slot, but for
-- a MERGE, the real target might need to be CombinedSlotNo instead -- if
-- they differ, we could be granting into the wrong slot.
--
-- This logs CombinedSlotNo/GetItemSlotNo/stock addresses at every single
-- exchangeGetItem call (not just once), so a working (empty-slot) pickup and
-- a broken (merge) pickup can be compared directly, call for call.

if reframework:get_game_name() ~= "re2" then
    return
end

local NS = sdk.game_namespace

local state = {
    hooked = false,
}

local function log_line(s)
    log.info("[slot_exchange_probe] " .. s)
end

local function safe_field(obj, name)
    local ok, v = pcall(function() return obj:get_field(name) end)
    if ok then return v end
    return nil
end

local function describe_stock_ref(obj, field_name)
    local v = safe_field(obj, field_name)
    if v == nil then return "nil" end
    -- StockItem is a managed object reference -- log its address as an
    -- identity check (same address across two reads = same stock; nil/
    -- different address tells us something meaningfully changed).
    local ok_addr, addr = pcall(function() return v:get_address() end)
    if ok_addr and addr then return string.format("0x%X", addr) end
    return tostring(v)
end

local function log_slot_context(this_obj, when)
    local combined = safe_field(this_obj, "CombinedSlotNo")
    local getitem_slot = safe_field(this_obj, "GetItemSlotNo")
    local pre_combine = describe_stock_ref(this_obj, "PreCombineStock")
    local get_item_stock = describe_stock_ref(this_obj, "<GetItemStock>k__BackingField")
    log_line(string.format(
        "  [%s] CombinedSlotNo=%s  GetItemSlotNo=%s  PreCombineStock=%s  GetItemStock=%s",
        when, tostring(combined), tostring(getitem_slot), pre_combine, get_item_stock))
end

local function install()
    if state.hooked then return end

    local slot_type = sdk.find_type_definition(NS("gui.NewInventorySlotBehavior"))
    if not slot_type then
        log_line("could not find gui.NewInventorySlotBehavior type")
        return
    end

    local exchange_m = slot_type:get_method("exchangeGetItem")
    if not exchange_m then
        log_line("could not find SlotBehavior.exchangeGetItem method")
        return
    end

    local pending_this = nil

    sdk.hook(exchange_m,
        function(args)
            local ok_this, this_obj = pcall(function() return sdk.to_managed_object(args[2]) end)
            local ok_slot, slot_idx = pcall(function() return sdk.to_int64(args[3]) end)
            log_line("=== exchangeGetItem CALLED, requested slot=" .. tostring(ok_slot and slot_idx or "?") .. " ===")
            if ok_this and this_obj then
                pending_this = this_obj
                log_slot_context(this_obj, "PRE")
            else
                pending_this = nil
            end
            return sdk.PreHookResult.CALL_ORIGINAL
        end,
        function(retval)
            local ok_i, ival = pcall(function() return sdk.to_int64(retval) end)
            log_line("exchangeGetItem returned: " .. tostring(ok_i and ival or "?"))
            if pending_this then
                log_slot_context(pending_this, "POST")
            end
            pending_this = nil
            return retval
        end)

    log_line("Hooked SlotBehavior.exchangeGetItem (slot-context logging)")
    state.hooked = true
end

re.on_frame(function()
    if not state.hooked then
        pcall(install)
    end
end)

re.on_draw_ui(function()
    if not imgui then return end
    if not imgui.tree_node("Slot Exchange Probe (empty-slot vs merge divergence)") then return end
    imgui.text("Read-only. Hooked: " .. tostring(state.hooked))
    imgui.text("Prefix to grep: [slot_exchange_probe]")
    imgui.text_colored(
        "Pick up into an EMPTY slot, then pick up something that MERGES into an existing stack.",
        0xFF88CCFF)
    imgui.text_colored(
        "Compare CombinedSlotNo / GetItemSlotNo / stock addresses between the two.",
        0xFF88CCFF)
    imgui.tree_pop()
end)

log.info("[re2_vr_slot_exchange_probe] Loaded (round 2)")
