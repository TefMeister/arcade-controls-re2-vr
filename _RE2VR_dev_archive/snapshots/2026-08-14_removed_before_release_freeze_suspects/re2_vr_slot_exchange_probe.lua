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

local MAX_LOG_LINES = 3000

local state = {
    hooked = false,
    log_buffer = {},
}

local function log_line(s)
    local full = "[slot_exchange_probe] " .. s
    log.info(full)
    table.insert(state.log_buffer, 1, full)
    if #state.log_buffer > MAX_LOG_LINES then table.remove(state.log_buffer) end
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

-- Generic multi-arg describer (args[1]=context, args[2]=this, args[3..] =
-- real params) -- same pattern already proven in re2_vr_worlditem_probe.lua.
local function describe_args_generic(args, max_slots)
    local parts = {}
    for i = 3, (max_slots or 8) do
        local ok_obj, obj = pcall(function() return sdk.to_managed_object(args[i]) end)
        if ok_obj and obj ~= nil then
            local ok_tn, tname = pcall(function() return obj:get_type_definition():get_full_name() end)
            table.insert(parts, string.format("arg%d=<obj:%s>", i - 2, tostring(ok_tn and tname or "?")))
        else
            local ok_i, ival = pcall(function() return sdk.to_int64(args[i]) end)
            table.insert(parts, string.format("arg%d=%s", i - 2, tostring(ok_i and ival or "?")))
        end
    end
    return table.concat(parts, ", ")
end

-- Round 5: combinationItemGetItemMode() alone caused real data loss (both the
-- original stack AND the new pickup vanished from inventory) -- the real
-- trace showed precombinationItemSub(StockItem, 6) firing BEFORE it, almost
-- certainly establishing "how much to add" as internal state that
-- combinationItemGetItemMode() then reads. Need the real quantity field name
-- on StockItem itself (not guessed) before wiring precombinationItemSub in --
-- one-time read-only dump, no calls, no writes.
-- Round 8 (2026-08-12): schema is fully known now (Count/ItemId/BulletId/
-- WeaponParts/WeaponId directly on StockItem) -- the full hierarchy dump was
-- only ever needed to FIND that schema, and re-deriving which dump belonged
-- to which field by position/ordering in the log has repeatedly caused
-- mismatched conclusions (both mine and in re-telling test results). Replaced
-- with a single self-labeled line per object -- the label is IN the log line
-- itself, no positional inference needed ever again.
local function log_stock_count(label, stock_obj)
    if not stock_obj then
        log_line(string.format("  [%s] StockItem is nil", label))
        return
    end
    local ok_addr, addr = pcall(function() return stock_obj:get_address() end)
    log_line(string.format("  [%s] address=%s", label,
        tostring(ok_addr and string.format("0x%X", addr) or "?")))

    -- SOLVED (2026-08-12): re-reading the very first successful full dump
    -- carefully, "field: Count ... value: 6" was never a direct field of
    -- StockItem -- it was logged inside the NESTED "-- nested AdditionalItem
    -- (PrimitiveItem) fields --" block (same "field: X type: Y value: Z"
    -- format as the top-level walk, easy to misattribute). StockItem itself
    -- only directly declares ExData/AdditionalItem/DefaultItem/IsWeaponEquip
    -- /Index -- Count/ItemId/BulletId/WeaponParts/WeaponId all live on the
    -- nested PrimitiveItem structs. AdditionalItem.Count is the real,
    -- varying quantity; DefaultItem.Count is a constant 1 (a template),
    -- which is why it looked unchanging across every test.
    for _, nested_name in ipairs({ "AdditionalItem", "DefaultItem" }) do
        local ok_n, nested = pcall(function() return stock_obj:get_field(nested_name) end)
        if ok_n and nested then
            local ok_c, count = pcall(function() return nested:get_field("Count") end)
            local ok_i, item_id = pcall(function() return nested:get_field("ItemId") end)
            log_line(string.format("      [%s].%s Count=%s ItemId=%s",
                label, nested_name,
                tostring(ok_c and count or "?"),
                tostring(ok_i and item_id or "?")))
        else
            log_line(string.format("      [%s].%s could not be read (ok=%s)", label, nested_name, tostring(ok_n)))
        end
    end
end

local function log_slot_context(this_obj, when)
    local combined = safe_field(this_obj, "CombinedSlotNo")
    local getitem_slot = safe_field(this_obj, "GetItemSlotNo")
    local pre_combine = describe_stock_ref(this_obj, "PreCombineStock")
    local get_item_stock = describe_stock_ref(this_obj, "<GetItemStock>k__BackingField")
    log_line(string.format(
        "  [%s] CombinedSlotNo=%s  GetItemSlotNo=%s  PreCombineStock=%s  GetItemStock=%s",
        when, tostring(combined), tostring(getitem_slot), pre_combine, get_item_stock))

    local raw_stock = safe_field(this_obj, "<GetItemStock>k__BackingField")
    log_stock_count("GetItemStock", raw_stock)

    local raw_pre_combine = safe_field(this_obj, "PreCombineStock")
    log_stock_count("PreCombineStock", raw_pre_combine)
end

-- Round 3: manual merge pickup (no auto-complete) works fine, only the
-- AUTOMATED merge fails -- meaning real manual merging must call something
-- our automation's exchangeGetItem+setSlotItem pair doesn't replicate.
-- Dump SlotBehavior's COMPLETE method list (never done before, only ever
-- looked at those two specific methods) and wide-net hook anything that
-- looks combine/merge/stack-shaped, so we can compare what fires during a
-- REAL manual merge vs our automated one.
local MERGE_KEYWORDS = { "combine", "merge", "stack", "add" }

local function looks_merge_related(mname)
    local lower = mname:lower()
    for _, kw in ipairs(MERGE_KEYWORDS) do
        if lower:find(kw, 1, true) then return true end
    end
    return false
end

local function dump_and_hook_merge_candidates(slot_type)
    log_line("========================================")
    log_line("NewInventorySlotBehavior: full method list")
    local ok_m, methods = pcall(function() return slot_type:get_methods() end)
    local candidates = {}
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            if ok_n and mname then
                local ok_p, nparams = pcall(function() return m:get_num_params() end)
                log_line(string.format("  method: %s (params: %s)", mname, tostring(ok_p and nparams or "?")))
                if looks_merge_related(mname) then
                    table.insert(candidates, m)
                end
            end
        end
    end
    log_line("========================================")

    -- dispAddInfoIcon fires many times per frame during any UI update --
    -- pure noise that was flooding the 400-line buffer out of existence
    -- before the one-time StockItem dump could even be seen (2026-08-12).
    -- Silence it specifically; still calls original, just doesn't log.
    local NOISY_NAMES = { dispAddInfoIcon = true }

    local hooked = 0
    for _, m in ipairs(candidates) do
        local ok_n, mname = pcall(function() return m:get_name() end)
        if ok_n and mname then
            local ok_h = pcall(function()
                sdk.hook(m,
                    function(args)
                        if not NOISY_NAMES[mname] then
                            local ok_slot, slot_idx = pcall(function() return sdk.to_int64(args[3]) end)
                            log_line(string.format("*** SlotBehavior.%s CALLED, arg3=%s (os.clock=%.3f)",
                                mname, tostring(ok_slot and slot_idx or "?"), os.clock()))
                        end
                        return sdk.PreHookResult.CALL_ORIGINAL
                    end,
                    function(retval) return retval end)
            end)
            if ok_h then hooked = hooked + 1 end
        end
    end
    log_line(string.format("Wide-net hooked %d combine/merge/stack-shaped method(s) on SlotBehavior.", hooked))
end

-- Round 4: fast manual merging (mashing confirm) STILL disappeared correctly
-- -- and, tellingly, that manual merge fired NO exchangeGetItem call at all
-- (confirmed via this exact log). Real manual merges apparently don't
-- necessarily go through exchangeGetItem/setSlotItem -- there must be a
-- dedicated combine method. Round 3's keyword filter ("combine") missed
-- these by one letter (combinAtion doesn't contain combinE as a substring)
-- -- hook them explicitly by exact name instead of guessing at keywords.
local EXACT_METHODS_TO_HOOK = {
    "combinationItem",
    "combinationItemGetItemMode",
    "precombinationItem",
    "precombinationItemSub",
    "executeCommandExchangeCombinationMode",
    "isAbleToCombineSlotAndBox",
    "isFirstCustomCombination",
    "exchangeItem", -- distinct from exchangeGetItem -- 2 params, never checked
    "exchangeItemSlotAndBox",
    -- Round 6 (2026-08-12): auto_complete's fix attempt called
    -- getSlotItemCount(CombinedSlotNo) and got -1 back -- CombinedSlotNo is
    -- evidently not the right index for this method. Hook it (and its
    -- neighbor isSlotItemCountMax) to see what a REAL manual merge actually
    -- passes in and gets back.
    "getSlotItemCount",
    "isSlotItemCountMax",
}

local function hook_exact_methods(slot_type)
    local hooked = 0
    for _, mname in ipairs(EXACT_METHODS_TO_HOOK) do
        local m = slot_type:get_method(mname)
        if m then
            local ok_h = pcall(function()
                sdk.hook(m,
                    function(args)
                        log_line(string.format("+++ SlotBehavior.%s CALLED %s (os.clock=%.3f)",
                            mname, describe_args_generic(args), os.clock()))
                        if mname == "precombinationItemSub" then
                            -- args[1]=context, args[2]=this, args[3]=the real
                            -- StockItem param -- dump it directly here since
                            -- manual merges never call exchangeGetItem (the
                            -- other trigger point for this dump).
                            local ok_this, this_obj = pcall(function() return sdk.to_managed_object(args[2]) end)
                            if ok_this and this_obj then
                                log_slot_context(this_obj, "MERGE-precombine")
                            end

                            local ok_obj, stock_obj = pcall(function() return sdk.to_managed_object(args[3]) end)
                            if ok_obj and stock_obj then
                                log_stock_count("precombinationItemSub_arg1", stock_obj)
                            else
                                log_line("  precombinationItemSub arg1: could not resolve to managed object")
                            end
                        end

                        if mname == "isSlotItemCountMax" then
                            -- Round 7 found this dumps the EXISTING occupant's
                            -- save record (used for the "already at max"
                            -- check), not the incoming box -- confirmed by
                            -- matching its Count against the existing stack.
                            -- Keep only a one-line self-labeled Count check
                            -- now, same pattern as log_stock_count.
                            local ok_sd, save_data = pcall(function() return sdk.to_managed_object(args[5]) end)
                            if ok_sd and save_data then
                                local ok_c, count = pcall(function() return save_data:get_field("Count") end)
                                log_line(string.format("  [isSlotItemCountMax_arg3_SetItemSaveData] Count=%s",
                                    tostring(ok_c and count or "?")))
                            end
                        end
                        return sdk.PreHookResult.CALL_ORIGINAL
                    end,
                    function(retval)
                        local ok_i, ival = pcall(function() return sdk.to_int64(retval) end)
                        log_line(string.format("+++ SlotBehavior.%s returned %s", mname,
                            tostring(ok_i and ival or "(non-int or void)")))
                        return retval
                    end)
            end)
            if ok_h then
                hooked = hooked + 1
            else
                log_line("  failed to hook " .. mname)
            end
        else
            log_line("  method not found: " .. mname)
        end
    end
    log_line(string.format("Exact-name hooked %d/%d combine-related method(s) on SlotBehavior.",
        hooked, #EXACT_METHODS_TO_HOOK))
end

-- Round 9 (2026-08-13): two new asks -- (1) a full-inventory pickup swaps
-- the upper-left slot's item into the world instead of blocking the pickup
-- (vanilla RE2 normally gates a slot-occupied-by-a-DIFFERENT-item swap
-- behind a player confirmation prompt -- our script forcing exchangeGetItem
-- unconditionally skips that prompt). Need to find a reliable "would this
-- be a swap, not an empty-slot grant" signal before fixing live. (2) user
-- wants auto-complete restricted to a specific allowlist of consumable item
-- names -- rather than live-testing each one's numeric ItemId individually,
-- dump the real Item.ID enum directly (name->value, no guessing) plus
-- Inventory/NewInventoryBehavior's method lists for anything full/empty/
-- space-shaped that could answer (1) too.
local function dump_item_id_enum()
    local enum_type = sdk.find_type_definition(NS("gamemastering.Item.ID"))
    if not enum_type then
        log_line("Item.ID enum: type not found")
        return
    end
    log_line("======================================== ")
    log_line("app.ropeway.gamemastering.Item.ID enum dump (name = value):")
    local ok_f, fields = pcall(function() return enum_type:get_fields() end)
    if not ok_f or not fields then
        log_line("  get_fields failed")
        return
    end
    for _, f in ipairs(fields) do
        local ok_static, is_static = pcall(function() return f:is_static() end)
        if ok_static and is_static then
            local ok_n, fname = pcall(function() return f:get_name() end)
            local ok_v, fval = pcall(function() return f:get_data(nil) end)
            if ok_n and fname and fname ~= "value__" then
                log_line(string.format("  %s = %s", fname, tostring(ok_v and fval or "?")))
            end
        end
    end
    log_line("======================================== ")
end

local function dump_fullness_related_methods()
    for _, type_name in ipairs({ "survivor.Inventory", "gui.NewInventoryBehavior" }) do
        local td = sdk.find_type_definition(NS(type_name))
        if td then
            log_line("======================================== ")
            log_line(type_name .. ": methods matching full/empty/space/remain (case-insensitive)")
            local ok_m, methods = pcall(function() return td:get_methods() end)
            if ok_m and methods then
                for _, m in ipairs(methods) do
                    local ok_n, mname = pcall(function() return m:get_name() end)
                    if ok_n and mname then
                        local lower = mname:lower()
                        if lower:find("full") or lower:find("empty") or lower:find("space") or lower:find("remain") then
                            local ok_p, nparams = pcall(function() return m:get_num_params() end)
                            log_line(string.format("  method: %s (params: %s)", mname, tostring(ok_p and nparams or "?")))
                        end
                    end
                end
            end
            log_line("======================================== ")
        else
            log_line(type_name .. ": type not found")
        end
    end
end

-- Inventory.getSlotEmpty (0 params) found via the fullness-method search --
-- hook it read-only to see what "this" is and what it returns, since a
-- 0-param signature is surprising for "is slot N empty" (may be called per-
-- slot-object rather than taking an index, or may check a cursor/selected
-- slot implicitly).
local function hook_get_slot_empty()
    local inv_type = sdk.find_type_definition(NS("survivor.Inventory"))
    if not inv_type then return end
    local m = inv_type:get_method("getSlotEmpty")
    if not m then
        log_line("getSlotEmpty: method not found on survivor.Inventory")
        return
    end
    local ok_h = pcall(function()
        sdk.hook(m,
            function(args)
                log_line(string.format("+++ Inventory.getSlotEmpty CALLED %s (os.clock=%.3f)",
                    describe_args_generic(args, 6), os.clock()))
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                local ok_i, ival = pcall(function() return sdk.to_int64(retval) end)
                log_line(string.format("+++ Inventory.getSlotEmpty returned %s",
                    tostring(ok_i and ival or "(non-int or void)")))
                return retval
            end)
    end)
    if ok_h then
        log_line("Hooked Inventory.getSlotEmpty")
    else
        log_line("failed to hook Inventory.getSlotEmpty")
    end
end

local function install()
    if state.hooked then return end

    dump_item_id_enum()
    dump_fullness_related_methods()
    hook_get_slot_empty()

    local slot_type = sdk.find_type_definition(NS("gui.NewInventorySlotBehavior"))
    if not slot_type then
        log_line("could not find gui.NewInventorySlotBehavior type")
        return
    end

    dump_and_hook_merge_candidates(slot_type)
    hook_exact_methods(slot_type)

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
    imgui.spacing()
    if imgui.button("Clear on-screen log") then
        state.log_buffer = {}
    end
    for _, line in ipairs(state.log_buffer) do
        imgui.text(line)
    end
    imgui.tree_pop()
end)

log.info("[re2_vr_slot_exchange_probe] Loaded (round 2)")
