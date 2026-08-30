-- Diagnostic (passive only -- no writes, no calls, no input simulation).
--
-- New bug: after auto-complete grants an item, the world pickup object
-- (e.g. an ammo box) stays in the world instead of being removed/disabled
-- like a normal pickup. Re-interacting with it re-triggers our sequence
-- against a slot that already holds that item, which appears to make
-- exchangeGetItem behave like a toggle (alternating add/remove) instead of
-- a clean grant.
--
-- Root theory: auto-complete only ever drives the UI/inventory-data chain
-- (SlotBehavior/DetailBehavior/NewInventoryBehavior/Inventory) -- it never
-- touches whatever WORLD-side component is responsible for destroying/
-- deactivating the pickup object after a real completion. Every pickup
-- hook all day has carried a SetItemSaveData argument
-- (app.ropeway.gimmick.action.SetItem.SetItemSaveData) -- SetItem is
-- almost certainly the actual world-object gimmick component (the thing
-- attached to the ammo box), and SetItemSaveData a nested type of it.
--
-- This dumps SetItem's full method list (static reflection, looking for
-- destroy/remove/collect/finish/complete-shaped names) and wide-net hooks
-- every non-getter method on it, so we can compare what fires during a
-- REAL manual pickup (auto-complete OFF) vs. an auto-complete-driven one
-- and find the exact missing call.

if reframework:get_game_name() ~= "re2" then
    return
end

local NS = sdk.game_namespace

local state = {
    dumped = false,
    hooked = false,
    call_counts = {},
    log_buffer = {},
}

local MAX_LOG_LINES = 400
local MAX_LOGGED_PER_METHOD = 15

local function log_line(s)
    local full = "[worlditem_probe] " .. s
    log.info(full)
    table.insert(state.log_buffer, 1, full)
    if #state.log_buffer > MAX_LOG_LINES then table.remove(state.log_buffer) end
end

local function describe_args(args, max_slots)
    local parts = {}
    for i = 2, (max_slots or 6) do
        local ok_obj, obj = pcall(function() return sdk.to_managed_object(args[i]) end)
        if ok_obj and obj ~= nil then
            local ok_tn, tname = pcall(function() return obj:get_type_definition():get_full_name() end)
            table.insert(parts, string.format("arg%d=<obj:%s>", i - 1, tostring(ok_tn and tname or "?")))
        else
            local ok_i, ival = pcall(function() return sdk.to_int64(args[i]) end)
            table.insert(parts, string.format("arg%d=%s", i - 1, tostring(ok_i and ival or "?")))
        end
    end
    return table.concat(parts, ", ")
end

local function dump_and_hook_setitem()
    if state.dumped then return end

    local set_item_type = sdk.find_type_definition(NS("gimmick.action.SetItem"))
    if not set_item_type then
        log_line("could not find gimmick.action.SetItem type -- trying alternate namespace guesses")
        return
    end
    state.dumped = true

    log_line("========================================")
    log_line("SetItem: full method list")
    local ok_m, methods = pcall(function() return set_item_type:get_methods() end)
    local hookable = {}
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            if ok_n and mname then
                log_line("  method: " .. mname)
                local lower = mname:lower()
                if not lower:match("^get_") and not lower:match("^set_")
                    and mname ~= ".ctor" and mname ~= ".cctor"
                    and not lower:find("update") then
                    table.insert(hookable, m)
                end
            end
        end
    end
    log_line("========================================")

    local hooked = 0
    for _, m in ipairs(hookable) do
        local ok_n, mname = pcall(function() return m:get_name() end)
        if ok_n and mname then
            local ok_h = pcall(function()
                sdk.hook(m,
                    function(args)
                        local key = "SetItem." .. mname
                        local count = (state.call_counts[key] or 0) + 1
                        state.call_counts[key] = count
                        if count <= MAX_LOGGED_PER_METHOD then
                            log_line(string.format("### SetItem.%s CALLED (#%d) %s (os.clock=%.3f)",
                                mname, count, describe_args(args), os.clock()))
                        end
                        return sdk.PreHookResult.CALL_ORIGINAL
                    end,
                    function(retval) return retval end)
            end)
            if ok_h then hooked = hooked + 1 end
        end
    end
    log_line(string.format("Wide-net hooked %d non-getter/setter method(s) on SetItem.", hooked))

    state.hooked = true
end

re.on_frame(function()
    if not state.dumped then
        pcall(dump_and_hook_setitem)
    end
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text_colored(
        "Passive only -- no writes, no calls, no input simulation.",
        0xFF88CCFF)
    imgui.text("Test 1: disable auto-complete, pick up an item MANUALLY (real navigation),")
    imgui.text("confirm the box disappears normally. Check log for what fired -- this is the reference.")
    imgui.text("Test 2: enable auto-complete, pick up a DIFFERENT item, see what's missing vs test 1.")
    imgui.spacing()
    imgui.text("Dumped: " .. tostring(state.dumped))
    imgui.text("Hooked: " .. tostring(state.hooked))
    imgui.spacing()
    if imgui.button("Clear on-screen log") then
        state.log_buffer = {}
    end
    for _, line in ipairs(state.log_buffer) do
        imgui.text(line)
    end
end)

log.info("[re2_vr_worlditem_probe] Loaded")
