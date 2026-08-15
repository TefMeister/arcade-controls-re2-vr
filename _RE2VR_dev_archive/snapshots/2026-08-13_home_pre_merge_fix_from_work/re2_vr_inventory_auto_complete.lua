-- REAL FEATURE (not a diagnostic) -- auto-completes the item-pickup screen
-- without requiring the player to navigate/confirm manually. Ships
-- DISABLED by default -- enable and verify live across several different
-- real pickups (ammo, herbs, key items, weapons) before trusting it.
--
-- Full chain, confirmed working live 2026-08-10 via manual step-by-step
-- testing in re2_vr_inventory_confirm_test.lua:
--   1. Inventory.getInitializeCursorPosition fires automatically the
--      instant the screen opens (native code, nothing we do) -- its return
--      value is the real target slot index. We just capture it.
--   2. SlotBehavior.exchangeGetItem(slotIndex) + SlotBehavior.setSlotItem(
--      slotIndex) -- grants the item into that slot. Calling these too
--      early (same frame as step 1) is a silent no-op; needs a short real
--      delay first for the screen's own per-frame update to settle.
--   3. DetailBehavior.close() -- first half of telling the screen the
--      interaction is done.
--   4. NewInventoryBehavior.close(), SlotBehavior.close(),
--      DetailBehavior.forceClose(), SlotBehavior.mainPanelStateFinished(),
--      NewInventoryBehavior.finish() -- the rest, mirroring the ~300ms gap
--      observed between step 3 and this step in real gameplay.
--
-- Skipping straight to step 2 without step 1's natural delay produced a
-- real but useless write (removeSlot fired, item never granted). Skipping
-- steps 3-4 after step 2 granted the item correctly but left the screen's
-- own cursor/selection state desynced -- a subsequent real click triggered
-- an unwanted "swap" prompt and misplaced the item. Both are why this is
-- timed, not instant, and why all three phases matter.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

local state = {
    enabled = false,
    hooked = false,
    phase = "idle",       -- idle -> waiting_step2 -> waiting_step3 -> done
    slot_index = nil,
    phase_started_at = nil,
    log_buffer = {},
    stats = { attempts = 0, granted = 0, closed = 0 },
    suppress_blur = false,
    original_blur = nil,
    force_new_item_look = false,
    hooked_open_rewrite = false,
}

-- Tunable delays (seconds), defaults chosen conservatively above what was
-- proven to work live -- lower them later once confidence is built across
-- many real pickups, not before.
local delay_before_grant = 0.5
local delay_before_detail_close = 0.3
local delay_before_finish_chain = 0.35

local MAX_LOG_LINES = 60

local function log_line(s)
    local full = "[inv_auto_complete] " .. s
    log.info(full)
    table.insert(state.log_buffer, 1, full)
    if #state.log_buffer > MAX_LOG_LINES then table.remove(state.log_buffer) end
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

local function try_call(obj, method_name, ...)
    if not obj then return false, "object unavailable" end
    local args = { ... }
    return pcall(function() return obj:call(method_name, table.unpack(args)) end)
end

local function safe_get_field(obj, name)
    if not obj then return nil end
    local ok, v = pcall(function() return obj:get_field(name) end)
    if ok then return v end
    return nil
end

local function safe_set_field(obj, name, value)
    if not obj then return end
    pcall(function() obj:set_field(name, value) end)
end

-- Experimental: NewInventoryBehavior drives its own dedicated camera/blur
-- for the zoomed "detail" examine shot (CameraFov=~75.7 normal vs
-- DetailCameraFov=60.0 zoomed, DetailBlurScale=20.0/DetailBlurMipLevel=3.0
-- -- real values captured earlier this session), separate from the normal
-- gameplay/VR camera. Suspected root cause of "background goes fully black
-- in VR, just blurry on flatscreen" -- this camera/blur system most likely
-- was never built with stereo VR rendering in mind. Rather than try to fix
-- VR rendering for it (a much bigger, riskier job), this suppresses the
-- blur and matches the detail FOV to the normal FOV so the transition into
-- that camera space is as close to a no-op as possible. Caches originals
-- and restores them once our sequence finishes, so manual inventory use
-- elsewhere isn't affected.
local function suppress_detail_blur()
    local behavior = get_sub_behaviors()
    if not behavior then return end

    state.original_blur = {
        scale = safe_get_field(behavior, "<DetailBlurScale>k__BackingField"),
        mip = safe_get_field(behavior, "<DetailBlurMipLevel>k__BackingField"),
        detail_fov = safe_get_field(behavior, "<DetailCameraFov>k__BackingField"),
    }
    local normal_fov = safe_get_field(behavior, "<CameraFov>k__BackingField")

    safe_set_field(behavior, "<DetailBlurScale>k__BackingField", 0.0)
    safe_set_field(behavior, "<DetailBlurMipLevel>k__BackingField", 0.0)
    if normal_fov then
        safe_set_field(behavior, "<DetailCameraFov>k__BackingField", normal_fov)
    end
    log_line(string.format("Suppressed detail blur/zoom (was scale=%s mip=%s detailFov=%s, normalFov=%s)",
        tostring(state.original_blur.scale), tostring(state.original_blur.mip),
        tostring(state.original_blur.detail_fov), tostring(normal_fov)))
end

local function restore_detail_blur()
    if not state.original_blur then return end
    local behavior = get_sub_behaviors()
    if behavior then
        safe_set_field(behavior, "<DetailBlurScale>k__BackingField", state.original_blur.scale)
        safe_set_field(behavior, "<DetailBlurMipLevel>k__BackingField", state.original_blur.mip)
        safe_set_field(behavior, "<DetailCameraFov>k__BackingField", state.original_blur.detail_fov)
        log_line("Restored original blur/zoom values")
    end
    state.original_blur = nil
end

local function do_grant_step()
    local behavior, slot_behavior = get_sub_behaviors()
    if not slot_behavior or state.slot_index == nil then
        log_line("grant step: SlotBehavior or slot_index unavailable, aborting this pickup")
        state.phase = "idle"
        restore_detail_blur()
        return
    end
    local ok1 = try_call(slot_behavior, "exchangeGetItem", state.slot_index)
    local ok2 = try_call(slot_behavior, "setSlotItem", state.slot_index)
    log_line(string.format("grant step: exchangeGetItem ok=%s setSlotItem ok=%s (slot=%s)",
        tostring(ok1), tostring(ok2), tostring(state.slot_index)))
    if ok1 and ok2 then state.stats.granted = state.stats.granted + 1 end
    state.phase = "waiting_step2"
    state.phase_started_at = os.clock()
end

local function do_detail_close_step()
    local _, _, detail_behavior = get_sub_behaviors()
    if not detail_behavior then
        log_line("detail close step: DetailBehavior unavailable, aborting close (item already granted)")
        state.phase = "idle"
        restore_detail_blur()
        return
    end
    local ok = try_call(detail_behavior, "close")
    log_line("detail close step: DetailBehavior.close ok=" .. tostring(ok))
    state.phase = "waiting_step3"
    state.phase_started_at = os.clock()
end

local function do_finish_chain_step()
    local behavior, slot_behavior, detail_behavior = get_sub_behaviors()
    if not behavior or not slot_behavior or not detail_behavior then
        log_line("finish chain: one of Behavior/SlotBehavior/DetailBehavior unavailable, aborting")
        state.phase = "idle"
        restore_detail_blur()
        return
    end
    local ok1 = try_call(behavior, "close")
    local ok2 = try_call(slot_behavior, "close")
    local ok3 = try_call(detail_behavior, "forceClose")
    local ok4 = try_call(slot_behavior, "mainPanelStateFinished")
    local ok5 = try_call(behavior, "finish")
    log_line(string.format("finish chain: close=%s close=%s forceClose=%s mainPanelStateFinished=%s finish=%s",
        tostring(ok1), tostring(ok2), tostring(ok3), tostring(ok4), tostring(ok5)))
    if ok1 and ok2 and ok3 and ok4 and ok5 then state.stats.closed = state.stats.closed + 1 end
    state.phase = "idle"
    state.slot_index = nil
    restore_detail_blur()
end

-- CONFIRMED WORKING live 2026-08-10 (re2_vr_inventory_new_item_test.lua):
-- NewInventoryDetailBehavior.open(StockItem, mode, SetItemSaveData) --
-- mode is passed IN as open()'s own argument (2=known item's normal grid
-- flow, 3=new-item card, the cleaner low-friction one), not decided
-- internally. Rewriting that argument in a PRE-hook before the original
-- runs forces every pickup down the "new item" path -- confirmed live, the
-- card actually shows up for known items now. This is a display/UI-flow
-- argument, not core inventory data -- does not affect whether the item is
-- actually granted (that's still exchangeGetItem/setSlotItem below).
local function install_open_mode_rewrite_hook()
    if state.hooked_open_rewrite then return end

    local detail_type = sdk.find_type_definition(NS("gui.NewInventoryDetailBehavior"))
    if not detail_type then return end
    local m = detail_type:get_method("open")
    if not m then
        log_line("could not find NewInventoryDetailBehavior.open")
        return
    end

    local ok_h = pcall(function()
        sdk.hook(m,
            function(args)
                if state.force_new_item_look then
                    pcall(function() args[4] = sdk.to_ptr(3) end)
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end)
    if ok_h then
        state.hooked_open_rewrite = true
        log_line("Hooked NewInventoryDetailBehavior.open for new-item-look rewrite")
    end
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
            if not state.enabled then return retval end
            if state.phase ~= "idle" then
                -- Already mid-sequence for a previous pickup -- don't stomp it.
                return retval
            end
            local ok_r, r = pcall(function() return sdk.to_int64(retval) end)
            if not ok_r or r == nil then return retval end

            state.slot_index = r
            state.stats.attempts = state.stats.attempts + 1
            state.phase = "waiting_step1"
            state.phase_started_at = os.clock()
            log_line("Pickup detected, slot=" .. tostring(r) .. " -- auto-sequence armed")
            if state.suppress_blur then
                pcall(suppress_detail_blur)
            end
            return retval
        end)

    state.hooked = true
    log_line("Hooked Inventory.getInitializeCursorPosition")
end

re.on_frame(function()
    if not state.hooked_open_rewrite then
        pcall(install_open_mode_rewrite_hook)
    end
    if not state.hooked then
        pcall(install_hook)
        return
    end
    if not state.enabled then return end
    if state.phase == "idle" then return end

    local elapsed = os.clock() - (state.phase_started_at or os.clock())
    if state.phase == "waiting_step1" and elapsed >= delay_before_grant then
        pcall(do_grant_step)
    elseif state.phase == "waiting_step2" and elapsed >= delay_before_detail_close then
        pcall(do_detail_close_step)
    elseif state.phase == "waiting_step3" and elapsed >= delay_before_finish_chain then
        pcall(do_finish_chain_step)
    end
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text_colored(
        "REAL FEATURE -- auto-completes pickup screen. Verify across several real pickups",
        0xFF88CCFF)
    imgui.text_colored(
        "(ammo, herbs, key items, weapons) before trusting this fully.",
        0xFF88CCFF)
    imgui.spacing()

    local changed, new_val = imgui.checkbox("Enable auto-complete pickup screen", state.enabled)
    if changed then
        state.enabled = new_val
        log_line("Enabled = " .. tostring(new_val))
    end

    local changed_b, new_val_b = imgui.checkbox(
        "EXPERIMENTAL: suppress detail blur/zoom (for VR black-screen / flatscreen blur)",
        state.suppress_blur)
    if changed_b then
        state.suppress_blur = new_val_b
        log_line("Suppress blur = " .. tostring(new_val_b))
    end

    local changed_n, new_val_n = imgui.checkbox(
        "Make every pickup show the clean 'new item' card instead of the grid (CONFIRMED working)",
        state.force_new_item_look)
    if changed_n then
        state.force_new_item_look = new_val_n
        log_line("Force new item look = " .. tostring(new_val_n))
    end

    imgui.spacing()
    imgui.text("Current phase: " .. state.phase)
    imgui.text(string.format("Stats: attempts=%d granted=%d closed=%d",
        state.stats.attempts, state.stats.granted, state.stats.closed))

    imgui.spacing()
    if imgui.tree_node("Timing (seconds) -- lower only after confidence is built") then
        local c1, v1 = imgui.slider_float("Delay before grant", delay_before_grant, 0.1, 1.5)
        if c1 then delay_before_grant = v1 end
        local c2, v2 = imgui.slider_float("Delay before DetailBehavior.close", delay_before_detail_close, 0.05, 1.0)
        if c2 then delay_before_detail_close = v2 end
        local c3, v3 = imgui.slider_float("Delay before finish chain", delay_before_finish_chain, 0.05, 1.0)
        if c3 then delay_before_finish_chain = v3 end
        imgui.tree_pop()
    end

    imgui.spacing()
    if imgui.button("Clear log") then state.log_buffer = {} end
    for _, line in ipairs(state.log_buffer) do
        imgui.text(line)
    end
end)

log.info("[re2_vr_inventory_auto_complete] Loaded")
