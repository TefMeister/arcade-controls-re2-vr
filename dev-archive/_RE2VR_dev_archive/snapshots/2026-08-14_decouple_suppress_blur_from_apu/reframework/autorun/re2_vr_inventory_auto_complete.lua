-- REAL FEATURE (not a diagnostic) -- auto-completes the item-pickup screen
-- without requiring the player to navigate/confirm manually. Defaults to
-- DISABLED as of 2026-08-14 -- reverted from the brief enabled-by-default
-- period (2026-08-13) after a hard game freeze during herb-combining with
-- this feature active. Known/suspected game-breaking; kept in the mod as an
-- opt-in checkbox for anyone who wants to help test it, not as a trusted
-- default. The merge bug (world pickup object not despawning after
-- auto-completing a merge) IS fixed: correct is_merge detection via
-- PreCombineStock.DefaultItem.ItemId, a freshly-built StockItem snapshot
-- passed to precombinationItemSub (never a live reference -- that subtracts
-- from whatever it's given), and an item-box safety gate so box withdrawals
-- stay fully manual. Confirmed live across merges, empty-slot weapon
-- pickups, and item-box withdrawals -- but the freeze means it is NOT yet
-- trusted as safe-by-default.
--
-- 2026-08-14, second update: the herb-combine freeze recurred with THIS
-- master toggle (APU) off, narrowing the search to `force_new_item_look`
-- (NIC) below -- the one piece of this file that ran completely
-- unconditionally regardless of this `enabled` flag.
--
-- 2026-08-14, third update: CONFIRMED via isolated live testing. With APU
-- fully off and ONLY NIC on, combining two herbs still froze the game. This
-- rules APU's own grant/close/finish chain out entirely as the cause (that
-- code never runs while APU is off) and confirms NIC's unconditional
-- NewInventoryDetailBehavior.open rewrite as the actual culprit. See
-- `force_new_item_look` below -- do not re-enable it for normal play.
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

-- Auto-pickup allowlist (2026-08-13, user's explicit request): only these
-- item types should ever be auto-completed -- everything else (weapons,
-- key items, documents, etc.) must stay fully manual. IDs are StockItem.
-- DefaultItem.ItemId values (confirmed live throughout this whole
-- investigation, e.g. Handgun Ammo=15 seen over and over in merge testing),
-- sourced from a community RE2 item-ID table and cross-checked against that
-- live-confirmed value before trusting the rest of the table. Combat
-- Knife/Hand Grenade/Flash Grenade are classified as "weapon" IDs
-- internally (not in the same ID table as consumables) despite being
-- consumable-ish in practice -- included per the user's explicit list.
local AUTO_PICKUP_ALLOWLIST = {
    [1] = "First Aid Spray",
    [2] = "Green Herb",
    [3] = "Red Herb",
    [4] = "Blue Herb",
    [5] = "Mixed Herb (G+G)",
    [6] = "Mixed Herb (G+R)",
    [7] = "Mixed Herb (G+B)",
    [8] = "Mixed Herb (G+G+B)",
    [9] = "Mixed Herb (G+G+G)",
    [10] = "Mixed Herb (G+R+B)",
    [11] = "Mixed Herb (R+B)",
    [15] = "Handgun Ammo",
    [16] = "Shotgun Shells",
    [17] = "Submachine Gun Ammo",
    [18] = "MAG Ammo",
    [22] = "Acid Rounds",
    [23] = "Flame Rounds",
    [24] = "Needle Cartridges",
    [25] = "Fuel",
    [26] = "Large-caliber Handgun Ammo",
    [27] = "High-Powered Rounds",
    [32] = "Ink Ribbon",
    [33] = "Wooden Board",
    [36] = "Gunpowder",
    [37] = "Gunpowder (Large)",
    [38] = "High-Grade Gunpowder (Yellow)",
    [39] = "High-Grade Gunpowder (White)",
    [46] = "Combat Knife",
    [65] = "Hand Grenade",
    [66] = "Flash Grenade",
}

local state = {
    -- Defaults to DISABLED (2026-08-14) -- flipped back off after a hard
    -- game freeze during herb-combining while this was enabled (root cause
    -- unconfirmed). The merge fix (fresh StockItem snapshot + corrected
    -- PreCombineStock.DefaultItem.ItemId merge detection + item-box safety
    -- gate) is confirmed working live across merges, empty-slot weapon
    -- pickups, and item-box withdrawals, but that freeze means this is
    -- opt-in/experimental until it's proven non-janky, not a safe default.
    enabled = false,
    hooked = false,
    phase = "idle",       -- idle -> waiting_step2 -> waiting_step3 -> done
    slot_index = nil,
    phase_started_at = nil,
    log_buffer = {},
    stats = { attempts = 0, granted = 0, closed = 0 },
    -- Concurrency guard (2026-08-13): a Portable Safe key item vanished with
    -- zero log trace after rapidly picking it up right after a merge --
    -- theory is our OWN delayed detail-close/finish-chain steps (still
    -- pending from the merge, ~0.3-0.35s out) fired AFTER the player had
    -- already opened the safe's screen, and since get_sub_behaviors() always
    -- fetches the CURRENT live singleton UI objects (not a snapshot from
    -- arm-time), those calls could have closed the safe's screen instead of
    -- the merge's. raw_detect_count increments on EVERY
    -- getInitializeCursorPosition firing, even ones we ignore (phase ~=
    -- idle) -- if it changed since we armed, something else has opened in
    -- the meantime and it's not safe to fire our queued close/finish calls.
    raw_detect_count = 0,
    armed_detect_count = nil,
    -- 2026-08-14: DECOUPLED from APU -- now triggers/restores off its own
    -- independent NewInventoryDetailBehavior.open hook + GUIMaster.
    -- get_IsOpenInventory() close-detection (see install_open_mode_rewrite_hook
    -- and the on_frame loop below), not APU's arm/close/finish sequence.
    -- Genuinely independent of both APU and NIC now -- this is the primary
    -- candidate for the item-pickup black-screen investigation (see
    -- re2_vr_pickup_reuse_itembox_camera_idea memory): item box was confirmed
    -- live to NEVER call NewInventoryDetailBehavior.open at all, staying on
    -- the normal grid/slot view instead of switching to this dedicated
    -- zoom/blur "detail" camera -- exactly the fields this toggle zeroes.
    -- Still unconfirmed whether zeroing them actually fixes the VR black
    -- screen (untested since the day it was written) -- that's the open
    -- question this toggle now exists to answer, in isolation.
    suppress_blur = false,
    original_blur = nil,
    -- Isolation toggle (2026-08-12): exchangeGetItem/setSlotItem followed by
    -- combinationItemGetItemMode() still overwrote the count down to just
    -- the new box's amount (5, not 6+5=11) -- same symptom as passing
    -- PreCombineStock into precombinationItemSub. Unclear whether
    -- combinationItemGetItemMode() itself is destructive regardless of
    -- prior state, or whether exchangeGetItem/setSlotItem never actually
    -- added on a merge slot in the first place. Toggle to test
    -- exchangeGetItem/setSlotItem completely alone.
    -- 2026-08-14: defaulted OFF along with every other checkbox in this file
    -- (player's explicit request) -- only meaningful while APU is also on,
    -- which itself defaults off, so this was inert either way, but kept
    -- consistent with "everything off by default" for v1.3.1.
    merge_call_combination_mode = false,
    -- 2026-08-14: CONFIRMED game-breaking, via isolated live testing -- DO
    -- NOT re-enable by default. With APU (state.enabled) fully OFF and ONLY
    -- this checkbox on, combining two herbs still froze the game (heart-
    -- monitor HUD animating, all buttons unresponsive). This isolates the
    -- cause conclusively: it is NOT APU's grant/close/finish chain (that
    -- code path never runs when APU is off) -- it is specifically forcing
    -- NewInventoryDetailBehavior.open's mode argument to 3 ("new item card")
    -- for a MERGE result. Matches the precedent in
    -- re2_vr_run_state_probe.lua's header: forcing a different field
    -- (IsFinish) on this same NewInventoryDetailBehavior class caused a
    -- confirmed full game hang earlier in this project. This hook installs
    -- and applies completely unconditionally (install_open_mode_rewrite_hook
    -- runs every frame regardless of `enabled`, see the on_frame loop
    -- below), which is exactly why leaving it on "just for testing APU" was
    -- never actually a clean isolation -- it has to be off for any other
    -- inventory testing to mean anything. Confirmed working (visually) since
    -- 2026-08-10 for genuinely NEW items, but that never covered merges,
    -- which is exactly the case that hangs.
    force_new_item_look = false,
    hooked_open_rewrite = false,
    -- Real fix attempt (2026-08-12): live testing found the one confirmed
    -- real difference between a working manual merge and a stuck automated
    -- one -- SlotBehavior.GetItemSlotNo sat at its unresolved default (-1)
    -- for the working manual merge, but had already resolved to a concrete
    -- slot number for the stuck automated one. Theory: the game's own
    -- per-frame cursor-position logic needs multiple real frames to settle
    -- this field naturally during manual play; our fixed 0.5s timer may
    -- call exchangeGetItem before that settling has actually happened,
    -- catching a stale/premature read. Wait for GetItemSlotNo/CombinedSlotNo
    -- to stop changing frame-to-frame (not just wait longer blindly, which
    -- was already tried and didn't help) before firing the grant step.
    stability = {
        last_get_item_slot = nil,
        last_combined_slot = nil,
        stable_frames = 0,
    },
}

-- Tunable delays (seconds), defaults chosen conservatively above what was
-- proven to work live -- lower them later once confidence is built across
-- many real pickups, not before.
local delay_before_grant = 0.5
local delay_before_detail_close = 0.3
local delay_before_finish_chain = 0.35

-- How many consecutive frames GetItemSlotNo/CombinedSlotNo must be
-- unchanged before we trust the state has actually settled.
local STABLE_FRAMES_REQUIRED = 3
-- Hard ceiling so this can never hang forever if stability genuinely never
-- happens for some item type -- falls back to firing anyway past this point.
local MAX_STABILITY_WAIT_S = 2.0

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

-- Reads the two fields whose live values told working (manual merge) and
-- stuck (automated merge) cases apart during investigation. Returns
-- ok, get_item_slot, combined_slot.
local function read_stability_fields()
    local _, slot_behavior = get_sub_behaviors()
    if not slot_behavior then return false, nil, nil end
    local ok1, get_item_slot = pcall(function() return slot_behavior:get_field("GetItemSlotNo") end)
    local ok2, combined_slot = pcall(function() return slot_behavior:get_field("CombinedSlotNo") end)
    if not ok1 or not ok2 then return false, nil, nil end
    return true, get_item_slot, combined_slot
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

-- 2026-08-14: moved above do_grant_step (was previously only defined/used by
-- do_detail_close_step/do_finish_chain_step below) so do_grant_step can use
-- it too -- see the new guard at the top of do_grant_step for why.
local function context_still_ours()
    if state.armed_detect_count == nil then return true end
    if state.raw_detect_count ~= state.armed_detect_count then
        log_line(string.format(
            "concurrency guard: another pickup screen opened since we armed (armed=%s now=%s) -- skipping close/finish to avoid touching the wrong screen",
            tostring(state.armed_detect_count), tostring(state.raw_detect_count)))
        return false
    end
    return true
end

-- 2026-08-14: found via live reproduction (player reported the automation
-- desyncing across a rapid sequence of pickups, then a hard freeze on a
-- herb-combine screen right after) -- this function was the ONE step in the
-- whole grant/close/finish chain that never checked context_still_ours(),
-- even though it's the step that actually calls exchangeGetItem/
-- precombinationItemSub. get_sub_behaviors() always fetches the CURRENT live
-- singleton UI objects, not a snapshot from when this was armed -- if the
-- player moves fast enough that a DIFFERENT screen (the next pickup, or a
-- merge confirmation) is open by the time this fires (0.5s+ after arming,
-- see delay_before_grant/STABLE_FRAMES_REQUIRED above), this would blindly
-- act on that new screen using state.slot_index captured for the OLD item --
-- a real mismatch, not just a theoretical one, and a strong candidate for
-- the reported herb-combine freeze. Same guard do_detail_close_step/
-- do_finish_chain_step already use.
local function do_grant_step()
    if not context_still_ours() then
        log_line("grant step: another pickup screen opened since arming -- aborting to stay manual, not touching the new screen")
        state.phase = "idle"
        state.slot_index = nil
        state.armed_detect_count = nil
        restore_detail_blur()
        return
    end
    local behavior, slot_behavior = get_sub_behaviors()
    if not slot_behavior or state.slot_index == nil then
        log_line("grant step: SlotBehavior or slot_index unavailable, aborting this pickup")
        state.phase = "idle"
        state.armed_detect_count = nil
        restore_detail_blur()
        return
    end

    -- Allowlist gate (2026-08-13, user's explicit request): only auto-
    -- complete a specific set of consumable item types -- everything else
    -- must stay fully manual. GetItemStock.DefaultItem.ItemId reliably
    -- reflects the incoming item by this point (confirmed throughout this
    -- whole investigation -- it's populated before precombinationItemSub/
    -- exchangeGetItem ever fire). If the item isn't on the list, or the ID
    -- can't be read, abort without touching anything -- native manual flow
    -- takes over exactly as if auto-complete were off for this one pickup.
    local ok_gis, get_item_stock = pcall(function() return slot_behavior:get_field("<GetItemStock>k__BackingField") end)
    local ok_gis_default, gis_default_item = false, nil
    if ok_gis and get_item_stock then
        ok_gis_default, gis_default_item = pcall(function() return get_item_stock:get_field("DefaultItem") end)
    end
    local ok_gis_id, gis_item_id = false, nil
    if ok_gis_default and gis_default_item then
        ok_gis_id, gis_item_id = pcall(function() return gis_default_item:get_field("ItemId") end)
    end
    local allowed_name = ok_gis_id and gis_item_id ~= nil and AUTO_PICKUP_ALLOWLIST[gis_item_id] or nil
    if not allowed_name then
        log_line(string.format(
            "grant step: ItemId=%s not on auto-pickup allowlist -- staying manual for this item",
            tostring(ok_gis_id and gis_item_id or "?")))
        state.phase = "idle"
        state.slot_index = nil
        state.armed_detect_count = nil
        restore_detail_blur()
        return
    end
    log_line(string.format("grant step: ItemId=%s (%s) is on allowlist -- proceeding", tostring(gis_item_id), allowed_name))

    -- Merge detection FIXED (2026-08-13): CombinedSlotNo ~= -1 was
    -- unreliable -- confirmed live to hold 0, -1, AND 12 across different
    -- EMPTY-SLOT pickups (not merges at all), which is exactly what caused
    -- Attempt 6's fresh-object-creation code to misfire on ordinary weapon
    -- pickups (Matilda/SLS60 corruption, 2026-08-12/13). Clean probe
    -- captures found a semantically real signal instead: PreCombineStock.
    -- DefaultItem is a genuinely UNUSED placeholder (Count=1, ItemId=0) for
    -- empty-slot grants, and only gets populated with the real item's data
    -- (real ItemId, matching GetItemStock) when the game itself detects a
    -- merge. Check ItemId ~= 0 there instead -- confirmed reliable across
    -- both a real merge test and a real empty-slot test.
    local ok_pcs, pre_combine_stock = pcall(function() return slot_behavior:get_field("PreCombineStock") end)
    local ok_pcs_default, pcs_default_item = false, nil
    if ok_pcs and pre_combine_stock then
        ok_pcs_default, pcs_default_item = pcall(function() return pre_combine_stock:get_field("DefaultItem") end)
    end
    local ok_pcs_id, pcs_item_id = false, nil
    if ok_pcs_default and pcs_default_item then
        ok_pcs_id, pcs_item_id = pcall(function() return pcs_default_item:get_field("ItemId") end)
    end
    local is_merge = ok_pcs_id and pcs_item_id ~= nil and pcs_item_id ~= 0
    log_line(string.format("grant step: merge-detect PreCombineStock.DefaultItem.ItemId=%s -> is_merge=%s",
        tostring(ok_pcs_id and pcs_item_id or "?"), tostring(is_merge)))

    if is_merge then
        -- Attempt 6 (2026-08-12): Attempt 5 passed the slot's REAL, LIVE
        -- GetItemStock reference as arg1 -- live testing showed
        -- precombinationItemSub(liveStock, itsOwnCount) SUBTRACTS from
        -- whatever it's given, so handing it a live reference to the actual
        -- slot data zeroed the slot out directly (both stacks vanished).
        -- The real game's arg1 must be a separate, freshly-built snapshot,
        -- not a live reference -- build one for real via sdk.create_instance
        -- (already proven safe/working elsewhere in this codebase for
        -- via.physics.CastRayQuery/Result), copying Count/ItemId out of the
        -- real GetItemStock.DefaultItem so the snapshot matches, then hand
        -- that disposable copy to precombinationItemSub instead.
        local PRIMITIVE_ITEM_TYPE = NS("gamemastering.InventoryManager.PrimitiveItem")
        local STOCK_ITEM_TYPE = NS("gamemastering.InventoryManager.StockItem")

        local function clone_primitive(source)
            if not source then return nil end
            local ok_new, fresh = pcall(function() return sdk.create_instance(PRIMITIVE_ITEM_TYPE) end)
            if not ok_new or not fresh then return nil end
            for _, fname in ipairs({ "Count", "ItemId", "BulletId", "WeaponParts", "WeaponId" }) do
                local ok_v, v = pcall(function() return source:get_field(fname) end)
                if ok_v then pcall(function() fresh:set_field(fname, v) end) end
            end
            return fresh
        end

        local ok_stock, get_item_stock = pcall(function() return slot_behavior:get_field("<GetItemStock>k__BackingField") end)
        local ok_default, default_item = false, nil
        local ok_additional, additional_item = false, nil
        if ok_stock and get_item_stock then
            ok_default, default_item = pcall(function() return get_item_stock:get_field("DefaultItem") end)
            ok_additional, additional_item = pcall(function() return get_item_stock:get_field("AdditionalItem") end)
        end
        local ok_count, existing_count = false, nil
        if ok_default and default_item then
            ok_count, existing_count = pcall(function() return default_item:get_field("Count") end)
        end

        local trust = ok_stock and get_item_stock and ok_count and existing_count ~= nil and existing_count >= 0
        local fresh_stock = nil

        if trust then
            local fresh_default = clone_primitive(default_item)
            local fresh_additional = ok_additional and clone_primitive(additional_item) or nil
            local ok_new_stock
            ok_new_stock, fresh_stock = pcall(function() return sdk.create_instance(STOCK_ITEM_TYPE) end)
            if ok_new_stock and fresh_stock and fresh_default then
                pcall(function() fresh_stock:set_field("DefaultItem", fresh_default) end)
                if fresh_additional then pcall(function() fresh_stock:set_field("AdditionalItem", fresh_additional) end) end
            else
                trust = false
                log_line(string.format(
                    "grant step (MERGE path): failed to build fresh StockItem snapshot (new_stock ok=%s default ok=%s)",
                    tostring(ok_new_stock), tostring(fresh_default ~= nil)))
            end
        end

        if trust and fresh_stock then
            local ok_sub = try_call(slot_behavior, "precombinationItemSub", fresh_stock, existing_count)
            log_line(string.format(
                "grant step (MERGE path): precombinationItemSub(freshStockSnapshot, %s) ok=%s",
                tostring(existing_count), tostring(ok_sub)))
            trust = ok_sub
        elseif ok_stock then
            log_line(string.format(
                "grant step (MERGE path): could not resolve GetItemStock.DefaultItem.Count (stock ok=%s default ok=%s count ok=%s val=%s)",
                tostring(ok_stock), tostring(ok_default), tostring(ok_count), tostring(existing_count)))
        end

        local ok1, ok2
        if trust and state.merge_call_combination_mode then
            local ok3 = try_call(slot_behavior, "combinationItemGetItemMode")
            log_line(string.format(
                "grant step (MERGE path): combinationItemGetItemMode ok=%s (PreCombineStock.ItemId=%s)",
                tostring(ok3), tostring(pcs_item_id)))
            ok1, ok2 = ok3, ok3
        else
            -- Known-safe fallback: adds correctly, doesn't despawn.
            ok1 = try_call(slot_behavior, "exchangeGetItem", state.slot_index)
            ok2 = try_call(slot_behavior, "setSlotItem", state.slot_index)
            log_line(string.format(
                "grant step (MERGE path, FALLBACK): exchangeGetItem ok=%s setSlotItem ok=%s (slot=%s)",
                tostring(ok1), tostring(ok2), tostring(state.slot_index)))
        end

        if ok1 and ok2 then state.stats.granted = state.stats.granted + 1 end
    else
        -- Full-inventory swap gate (2026-08-13): confirmed live via
        -- diagnostic logging -- when the inventory is full and
        -- getInitializeCursorPosition hands back an OCCUPIED slot (e.g. 0,
        -- the top-left/Matilda slot), isBlankSlot(slot) correctly reports
        -- false right at the moment the swap would happen (real log:
        -- "isBlankSlot(0) ok=true -> false" at the exact frame a Matilda-for-
        -- Blue-Herb swap occurred). Gate on it: abort to native/manual flow
        -- exactly like the allowlist/item-box gates above, rather than
        -- silently evicting whatever's already in that slot.
        local ok_blank, is_blank = pcall(function() return slot_behavior:call("isBlankSlot", state.slot_index) end)
        if ok_blank and is_blank == false then
            log_line(string.format(
                "grant step: target slot=%s is NOT blank (isBlankSlot=false) -- likely a full-inventory swap, aborting to stay manual",
                tostring(state.slot_index)))
            state.phase = "idle"
            state.slot_index = nil
            state.armed_detect_count = nil
            restore_detail_blur()
            return
        end

        local ok1 = try_call(slot_behavior, "exchangeGetItem", state.slot_index)
        local ok2 = try_call(slot_behavior, "setSlotItem", state.slot_index)
        log_line(string.format("grant step (EMPTY-SLOT path): exchangeGetItem ok=%s setSlotItem ok=%s (slot=%s)",
            tostring(ok1), tostring(ok2), tostring(state.slot_index)))
        if ok1 and ok2 then state.stats.granted = state.stats.granted + 1 end
    end

    state.phase = "waiting_step2"
    state.phase_started_at = os.clock()
end

local function do_detail_close_step()
    if not context_still_ours() then
        state.phase = "idle"
        state.slot_index = nil
        state.armed_detect_count = nil
        restore_detail_blur()
        return
    end
    local _, _, detail_behavior = get_sub_behaviors()
    if not detail_behavior then
        log_line("detail close step: DetailBehavior unavailable, aborting close (item already granted)")
        state.phase = "idle"
        state.armed_detect_count = nil
        restore_detail_blur()
        return
    end
    local ok = try_call(detail_behavior, "close")
    log_line("detail close step: DetailBehavior.close ok=" .. tostring(ok))
    state.phase = "waiting_step3"
    state.phase_started_at = os.clock()
end

local function do_finish_chain_step()
    if not context_still_ours() then
        state.phase = "idle"
        state.slot_index = nil
        state.armed_detect_count = nil
        restore_detail_blur()
        return
    end
    local behavior, slot_behavior, detail_behavior = get_sub_behaviors()
    if not behavior or not slot_behavior or not detail_behavior then
        log_line("finish chain: one of Behavior/SlotBehavior/DetailBehavior unavailable, aborting")
        state.phase = "idle"
        state.armed_detect_count = nil
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
    state.armed_detect_count = nil
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
                -- 2026-08-14: decoupled from APU -- this hook already fires
                -- unconditionally on every open() call regardless of APU/NIC
                -- (see the on_frame loop below, which installs it every
                -- frame with no gate), so it's the right place to trigger
                -- suppress_blur too, independent of whether APU's own
                -- automation is armed. Previously this only fired as a side
                -- effect deep inside APU's arm sequence, meaning it was
                -- impossible to test in isolation -- exactly the wrong
                -- coupling for something meant to be a pure background/
                -- presentation experiment. See is_inventory_open_now's
                -- close-side restore below for the other half of this.
                if state.suppress_blur then
                    pcall(suppress_detail_blur)
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

-- 2026-08-14: independent close-side restore for suppress_blur, now that its
-- trigger (above) no longer depends on APU's own arm/close/finish sequence
-- ever running. Reuses the exact same GUIMaster.get_IsOpenInventory() signal
-- re2_vr_pickup_bg_investigation_probe.lua already confirmed live (context
-- transition PICKUP_OR_INVENTORY -> NONE) rather than inventing a new
-- detection method. Tracked independently of state.phase so this works
-- whether or not APU is enabled.
local last_inventory_open = false
local function is_inventory_open_now()
    local gm = sdk.get_managed_singleton(NS("gui.GUIMaster"))
    if not gm then return false end
    local ok, is_open = pcall(function() return gm:call("get_IsOpenInventory") end)
    return ok and is_open == true
end

-- Item box safety gate (2026-08-13): Inventory.getInitializeCursorPosition
-- ALSO fires during item-box storage withdrawals, not just world pickups --
-- confirmed live when auto-complete auto-closed a manual item-box takeout of
-- the Matilda and the weapon was deleted entirely. Item-box interactions
-- must stay fully manual. re2_vr_holster.lua already solved detecting this
-- context (for a different reason -- avoiding the X-button/flashlight
-- conflict) via GUIMaster.isBusyItemBox()/getItemBoxEnable() -- reuse the
-- same proven getters here instead of re-deriving detection from scratch.
local function is_item_box_open()
    local gm = sdk.get_managed_singleton(NS("gui.GUIMaster"))
    if not gm then return false end
    local ok1, busy = pcall(function() return gm:call("isBusyItemBox") end)
    if ok1 and busy == true then return true end
    local ok2, enabled = pcall(function() return gm:call("getItemBoxEnable") end)
    if ok2 and enabled == true then return true end
    return false
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
            -- Counts EVERY firing, even ones we ignore below -- this is the
            -- concurrency guard's signal that a new pickup screen has opened,
            -- used by do_detail_close_step/do_finish_chain_step to detect
            -- "the player has already moved on, don't touch this screen."
            state.raw_detect_count = state.raw_detect_count + 1

            if not state.enabled then return retval end
            if state.phase ~= "idle" then
                -- Already mid-sequence for a previous pickup -- don't stomp it.
                -- 2026-08-14: was silent before -- logged now so a fast
                -- back-to-back pickup sequence (this screen staying fully
                -- manual because the previous one's automation hadn't
                -- finished yet) is visible in the log instead of looking
                -- like unexplained inconsistent behavior.
                log_line(string.format(
                    "Pickup screen opened but phase=%s (not idle) -- staying manual for this one, not stomping the in-progress sequence",
                    state.phase))
                return retval
            end
            if is_item_box_open() then
                log_line("Pickup detected but item box is open -- skipping, stays manual")
                return retval
            end
            local ok_r, r = pcall(function() return sdk.to_int64(retval) end)
            if not ok_r or r == nil then return retval end

            state.slot_index = r
            state.armed_detect_count = state.raw_detect_count
            state.stats.attempts = state.stats.attempts + 1
            state.phase = "waiting_step1"
            state.phase_started_at = os.clock()
            state.stability.last_get_item_slot = nil
            state.stability.last_combined_slot = nil
            state.stability.stable_frames = 0
            log_line("Pickup detected, slot=" .. tostring(r) .. " -- auto-sequence armed")
            return retval
        end)

    state.hooked = true
    log_line("Hooked Inventory.getInitializeCursorPosition")
end

re.on_frame(function()
    if not state.hooked_open_rewrite then
        pcall(install_open_mode_rewrite_hook)
    end

    -- Independent of APU (state.enabled) on purpose -- see the comment on
    -- suppress_blur's trigger point above. Runs every frame regardless of
    -- hook-install status so the restore fires even if suppress_blur was
    -- toggled on mid-screen.
    if state.suppress_blur then
        local is_open_now = is_inventory_open_now()
        if last_inventory_open and not is_open_now then
            pcall(restore_detail_blur)
        end
        last_inventory_open = is_open_now
    end

    if not state.hooked then
        pcall(install_hook)
        return
    end
    if not state.enabled then return end
    if state.phase == "idle" then return end

    local elapsed = os.clock() - (state.phase_started_at or os.clock())
    if state.phase == "waiting_step1" and elapsed >= delay_before_grant then
        local ok, get_item_slot, combined_slot = read_stability_fields()
        local ready = false
        if ok then
            if get_item_slot == state.stability.last_get_item_slot
                and combined_slot == state.stability.last_combined_slot then
                state.stability.stable_frames = state.stability.stable_frames + 1
            else
                state.stability.stable_frames = 0
                state.stability.last_get_item_slot = get_item_slot
                state.stability.last_combined_slot = combined_slot
            end
            if state.stability.stable_frames >= STABLE_FRAMES_REQUIRED then
                ready = true
            end
        end
        if elapsed >= (delay_before_grant + MAX_STABILITY_WAIT_S) then
            -- Never seen stable, or read_stability_fields kept failing --
            -- don't hang forever, fire anyway and note it in the log.
            if not ready then
                log_line(string.format(
                    "grant step: stability wait hit hard ceiling (%.1fs) without settling -- firing anyway",
                    MAX_STABILITY_WAIT_S))
            end
            ready = true
        end
        if ready then
            log_line(string.format(
                "grant step: state settled after %.2fs (GetItemSlotNo=%s CombinedSlotNo=%s)",
                elapsed, tostring(get_item_slot), tostring(combined_slot)))
            pcall(do_grant_step)
        end
    elseif state.phase == "waiting_step2" and elapsed >= delay_before_detail_close then
        pcall(do_detail_close_step)
    elseif state.phase == "waiting_step3" and elapsed >= delay_before_finish_chain then
        pcall(do_finish_chain_step)
    end
end)

re.on_draw_ui(function()
    if not imgui then return end

    imgui.text_colored("Background/presentation only -- independent of APU and NIC below:", 0xFF88CCFF)
    imgui.text_colored(
        "Item box was confirmed (2026-08-14) to never open the zoom/blur 'detail'",
        0xFF88CCFF)
    imgui.text_colored(
        "screen at all -- this zeroes the same camera/blur fields on regular",
        0xFF88CCFF)
    imgui.text_colored(
        "pickup's detail screen instead. Untested whether it actually fixes the",
        0xFF88CCFF)
    imgui.text_colored(
        "VR black screen -- try this first, doesn't touch pickup mechanics at all.",
        0xFF88CCFF)
    local changed_b, new_val_b = imgui.checkbox(
        "Suppress detail blur/zoom [BG] (for VR black-screen / flatscreen blur)",
        state.suppress_blur)
    if changed_b then
        state.suppress_blur = new_val_b
        log_line("Suppress blur [BG] = " .. tostring(new_val_b))
    end

    imgui.spacing()
    imgui.separator()
    imgui.spacing()

    imgui.text_colored(
        "KNOWN BUGGY / POTENTIALLY GAME-BREAKING -- suspected cause of a hard game",
        0xFF5050FF)
    imgui.text_colored(
        "freeze during herb-combining. OFF by default. Opt-in for testing only,",
        0xFF5050FF)
    imgui.text_colored(
        "not recommended for normal play until confirmed safe.",
        0xFF5050FF)
    imgui.spacing()

    local changed, new_val = imgui.checkbox("Enable auto-complete pickup screen [APU] (EXPERIMENTAL, may freeze the game)", state.enabled)
    if changed then
        state.enabled = new_val
        log_line("Enabled = " .. tostring(new_val))
    end

    imgui.text_colored(
        "CONFIRMED cause of the herb-combine freeze (isolated live 2026-08-14:",
        0xFF5050FF)
    imgui.text_colored(
        "froze with [APU] fully OFF and ONLY this checkbox on). DO NOT ENABLE",
        0xFF5050FF)
    imgui.text_colored(
        "for normal play. Unconditionally rewrites NewInventoryDetailBehavior.open",
        0xFF5050FF)
    imgui.text_colored(
        "every time, regardless of [APU]'s state.",
        0xFF5050FF)
    local changed_n, new_val_n = imgui.checkbox(
        "Make every pickup show the clean 'new item' card instead of the grid [NIC] (CONFIRMED freezes on merges)",
        state.force_new_item_look)
    if changed_n then
        state.force_new_item_look = new_val_n
        log_line("Force new item look [NIC] = " .. tostring(new_val_n))
    end

    local changed_m, new_val_m = imgui.checkbox(
        "ISOLATION TEST: also call combinationItemGetItemMode on merges (uncheck to test exchangeGetItem alone)",
        state.merge_call_combination_mode)
    if changed_m then
        state.merge_call_combination_mode = new_val_m
        log_line("Merge calls combinationItemGetItemMode = " .. tostring(new_val_m))
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
