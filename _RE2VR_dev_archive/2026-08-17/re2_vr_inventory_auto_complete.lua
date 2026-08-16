-- REAL FEATURE (not a diagnostic) -- auto-completes the item-pickup screen
-- without requiring the player to navigate/confirm manually. Defaults to
-- ENABLED as of 2026-08-14/15 -- the herb-combine freeze that previously
-- kept this off by default was root-caused to `force_new_item_look` (NIC),
-- a separate, unrelated toggle that unconditionally rewrote
-- NewInventoryDetailBehavior.open's mode argument -- CONFIRMED via isolated
-- live testing (froze with APU off / NIC alone on, did NOT freeze with APU
-- on / NIC off). NIC itself has since been REMOVED ENTIRELY (2026-08-15,
-- no longer needed now that merge detection/execution both work correctly
-- without it) -- still recoverable from git history/dev archive if ever
-- needed again, but not worth carrying as dead code in the live mod. The
-- merge bug (world pickup object not despawning after auto-completing a
-- merge) IS fixed: correct is_merge detection via
-- PreCombineStock.DefaultItem.ItemId, a freshly-built StockItem snapshot
-- passed to precombinationItemSub (never a live reference -- that subtracts
-- from whatever it's given), and an item-box safety gate so box withdrawals
-- stay fully manual. Confirmed live across merges, empty-slot weapon
-- pickups, item-box withdrawals, and sub-weapons (Combat Knife/Hand
-- Grenade/Flash Grenade, whose identity lives in WeaponId not ItemId --
-- see SUBWEAPON_BY_WEAPON_ID below).
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

-- Auto-pickup allowlist (2026-08-13, originally a small hand-picked
-- consumables list; REBUILT 2026-08-14 into a near-complete transcription
-- of the player's own authoritative RE2R "ALL ITEMS IDS" reference
-- screenshots, item by item, at the player's explicit request after the
-- bypass-all-items stress-test toggle proved unsafe for firearms -- an
-- exhaustive INCLUDE list is safer than a "grant everything except what we
-- remember to exclude" toggle). IDs are StockItem.DefaultItem.ItemId
-- values (confirmed live throughout this whole investigation, e.g. Handgun
-- Ammo=15 seen over and over in merge testing). Combat Knife/Hand
-- Grenade/Flash Grenade are classified as "weapon" IDs internally (matches
-- the SEPARATE "ALL WEAPON IDS" table, not this item table) despite being
-- consumable-ish in practice -- kept as-is, already confirmed working live.
--
-- Deliberately EXCLUDED: every weapon-attachment/part entry from the
-- screenshots (High-Capacity Mag/Muzzle Brake/Gun Stock/Speed Loader/Laser
-- Sight/Reinforced Frame/Shotgun Stock/Long Barrel/Suppressor/Red Dot
-- Sight/Shoulder Stock/Regulator/High Voltage Condenser, ids 48-66 other
-- than the two grenades) -- these ids fall in or near the firearm
-- WeaponId range and would be unreachable behind FORCE_MANUAL_WEAPON_IDS
-- below anyway (checked first), so including them would be dead weight.
--
-- Known ID-NAMESPACE COLLISIONS with FORCE_MANUAL_WEAPON_IDS below (kept
-- in this list for a complete transcription, but since the firearm gate is
-- checked FIRST and unconditionally, a pickup that happens to report one
-- of these ids will ALWAYS be forced manual even when it's genuinely the
-- listed item here, not the colliding firearm -- a deliberate, accepted
-- over-exclusion trade-off, safety over convenience): [82] Spade Key
-- collides with Samurai Edge (Infinite); [83] Parking Garage Key Card
-- collides with Samurai Edge (Chris Model); [84] Weapons Locker Key Card
-- collides with Samurai Edge (Jill Model).
--
-- [291] Portable Safe: this exact key item is why the concurrency guard
-- (context_still_ours(), see do_grant_step/do_detail_close_step) exists at
-- all -- it vanished with zero log trace once, early in this investigation,
-- before that guard was added. Included now that the guard is in place and
-- has been live-confirmed working since, but worth remembering if anything
-- Portable-Safe-shaped goes wrong again.
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
    [12] = "Green Herb",
    [13] = "Red Herb",
    [14] = "Blue Herb",
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
    [31] = "Detonator",
    [32] = "Ink Ribbon",
    [33] = "Wooden Board",
    [34] = "Electronic Gadget",
    [35] = "Battery (9-volt)",
    [36] = "Gunpowder",
    [37] = "Gunpowder (Large)",
    [38] = "High-Grade Gunpowder (Yellow)",
    [39] = "High-Grade Gunpowder (White)",
    [46] = "Combat Knife",
    [65] = "Hand Grenade",
    [66] = "Flash Grenade",
    [72] = "Film \"Hiding Place\"",
    [73] = "Film \"Rising Rookie\"",
    [74] = "Film \"Commemorative\"",
    [75] = "Film \"3F Locker\"",
    [76] = "Film \"Lion Statue\"",
    [77] = "Storage Room Key",
    [79] = "Mechanic Jack Handle",
    [80] = "Square Crank",
    [81] = "Unicorn Medallion",
    [82] = "Spade Key",
    [83] = "Parking Garage Key Card",
    [84] = "Weapons Locker Key Card",
    [86] = "Valve Handle",
    [87] = "S.T.A.R.S. Badge",
    [88] = "Scepter",
    [90] = "Red Jewel",
    [91] = "Bejeweled Box",
    [93] = "Bishop Plug",
    [94] = "Rook Plug",
    [95] = "King Plug",
    [98] = "Picture Block",
    [102] = "USB Dongle Key",
    [112] = "Spare Key (key pad)",
    [114] = "Red Book (Art Object)",
    [115] = "Statue's Left Arm",
    [116] = "Left Arm with Book",
    [118] = "Lion Medallion",
    [119] = "Diamond Key",
    [120] = "Car Key",
    [124] = "Maiden Medallion",
    [126] = "Power Panel Part",
    [127] = "Power Panel Part",
    [128] = "Lovers Relief",
    [129] = "Small Gear",
    [130] = "Large Gear",
    [131] = "Courtyard Key",
    [132] = "Knight Plug",
    [133] = "Pawn Plug",
    [134] = "Queen Plug",
    [135] = "Boxed Electronic Part",
    [136] = "Boxed Electronic Part",
    [159] = "Orphanage Key",
    [160] = "Club Key",
    [169] = "Heart Key",
    [170] = "U.S.S. Digital Video Cassette",
    [176] = "T-Bar Valve Handle",
    [179] = "Dispersal Cartridge (Empty)",
    [180] = "Dispersal Cartridge (Solution)",
    [181] = "Dispersal Cartridge (Herbicide)",
    [183] = "Joint Plug",
    [186] = "Upgrade Chip (Admin)",
    [187] = "ID Wristband (Admin)",
    [188] = "Electronic Chip",
    [189] = "Signal Modulator",
    [190] = "Trophy",
    [191] = "Trophy",
    [194] = "Sewers Key",
    [195] = "ID Wristband (Visitor)",
    [196] = "ID Wristband (General Staff)",
    [197] = "ID Wristband (Senior Staff)",
    [198] = "Upgrade Chip (General Staff)",
    [199] = "Upgrade Chip (Senior Staff)",
    [200] = "ID Wristband (Visitor)",
    [201] = "ID Wristband (General Staff)",
    [202] = "ID Wristband (Senior Staff)",
    [203] = "Lab Digital Video Cassette",
    [230] = "Briefcase",
    [240] = "Fuse (Main Hall)",
    [241] = "Fuse (Break Room Hallway)",
    [243] = "Scissors",
    [244] = "Bolt Cutter",
    [245] = "Stuffed Doll",
    [262] = "Hip Pouch",
    [291] = "Portable Safe",
    [293] = "Tin Storage Box",
    [294] = "Wooden Box",
    [295] = "Wooden Box",
    [296] = "Tin Storage Box",
}

-- 2026-08-14: found live via item_id_probe diagnostic -- Combat Knife/Hand
-- Grenade/Flash Grenade do NOT carry their identity in
-- GetItemStock.DefaultItem.ItemId when picked up fresh from the world (it
-- reads 0, the same "unused placeholder" value ordinary items show before
-- being populated) -- their real identity is in DefaultItem.WeaponId
-- instead, a completely different field. Confirmed live: a Flash Grenade
-- pickup logged "ItemId=0 DefaultItem(... WeaponId=66 ...)" -- 66 is
-- exactly Flash Grenade's id in the separate weapon-id table. This is WHY
-- the [46]/[65]/[66] entries in AUTO_PICKUP_ALLOWLIST above were never
-- actually matching for a real pickup (they check ItemId, which is always
-- 0 for these) -- left in place anyway as a harmless fallback in case some
-- OTHER pickup path (e.g. a merge) ever does populate ItemId directly for
-- them, unconfirmed either way. This table is the real, live-confirmed
-- fix -- checked against WeaponId, not ItemId, in do_grant_step below.
local SUBWEAPON_BY_WEAPON_ID = {
    [46] = "Combat Knife",
    [65] = "Hand Grenade",
    [66] = "Flash Grenade",
}

-- 2026-08-14: firearms FORCED to stay manual, checked unconditionally --
-- even overrides the "bypass allowlist, auto-pickup ALL items" stress-test
-- toggle. Player live-tested: guns auto-granted via the bypass toggle equip
-- fine (visually held) but can't aim/fire; the same guns picked up manually
-- fire correctly. Root cause not fully confirmed, but a real, dangerous
-- candidate is an ID-NAMESPACE COLLISION: per the player's authoritative
-- RE2R "ALL WEAPON IDS" reference (distinct from "ALL ITEMS IDS" above),
-- Matilda=1, JMB Hp3=3, SLS 60=9 -- the SAME numeric values our
-- AUTO_PICKUP_ALLOWLIST already maps to First Aid Spray(1)/Red Herb(3)/
-- Mixed Herb G+G+G(9). This is the same "weapon-classified ID" mechanism
-- already established and CONFIRMED correct for Combat Knife(46)/Hand
-- Grenade(65)/Flash Grenade(66) above (those match the WEAPON table, not
-- the item table) -- so it's entirely plausible a gun's GetItemStock.
-- DefaultItem.ItemId read here returns its WEAPON id, indistinguishable by
-- number alone from an unrelated consumable. Rather than rely on ID value
-- disambiguation (fundamentally ambiguous for colliding values), force
-- every known firearm WeaponId to stay manual outright -- sub-weapons
-- (Combat Knife/Hand Grenade/Flash Grenade) are NOT included here since
-- they're already confirmed working fine through the curated allowlist
-- above and aren't "aim to shoot" firearms in the same sense.
local FORCE_MANUAL_WEAPON_IDS = {
    [1] = "Matilda",
    [2] = "M19",
    [3] = "JMB Hp3",
    [4] = "Quickdraw Army Revolver",
    [7] = "MUP",
    [8] = "Broom Hc",
    [9] = "SLS 60",
    [11] = "W-870",
    [21] = "MQ 11",
    [23] = "LE 5 (Infinite)",
    [31] = "Lightning Hawk",
    [41] = "EMF Visualizer",
    [42] = "Grenade Launcher - GM 79",
    [43] = "Chemical Flamethrower",
    [44] = "Stun Gun - Spark Shot",
    [45] = "ATM-4",
    [49] = "Anti-tank Rocket",
    [50] = "Minigun",
    [82] = "Samurai Edge (Infinite)",
    [83] = "Samurai Edge (Chris Model)",
    [84] = "Samurai Edge (Jill Model)",
    [85] = "Samurai Edge (Albert Model)",
    [222] = "ATM-4 (Infinite)",
    [242] = "Anti-tank Rocket (Infinite)",
    [252] = "Minigun (Infinite)",
}

local state = {
    -- Defaulted back to ENABLED (2026-08-14, player's explicit request:
    -- "have APU on from now on"). The Green Herb regression that caused the
    -- previous disable turned out to be the M19/WeaponId-2 collision bug
    -- (already fixed, see re2_vr_apu_green_herb_followup memory) -- Green
    -- Herb confirmed clean in dedicated tests since. Sub-weapons (Combat
    -- Knife/Hand Grenade/Flash Grenade) also fixed this same session, see
    -- re2_vr_apu_subweapon_weaponid_fix memory -- first-pickup case
    -- confirmed working live; the merge-with-an-existing-one case just got
    -- a getStock()-based fix that hasn't been re-tested live yet.
    enabled = true,
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
    -- 2026-08-15: the whole VR-black-background investigation on this
    -- screen (suppress_blur/[BG], skip_post_effect_capture/[BG2],
    -- skip_detail_open_for_pickup/[BG3], and the hooks/UI that went with
    -- them) has been REMOVED ENTIRELY -- CLOSED, confirmed not this mod's
    -- bug at all: manually examining an owned item's description (a
    -- completely native interaction, zero mod code involved) shows the
    -- identical black background. This is a genuine VR-rendering limitation
    -- in this native UI screen, not something reachable or fixable through
    -- REFramework's Lua reflection/hooking layer -- see
    -- re2_vr_pickup_reuse_itembox_camera_idea memory for the full
    -- investigation and closing summary. Recoverable from git history/dev
    -- archive if ever revisited with a fundamentally different tool
    -- (shader debugging, native plugin work).
    -- Isolation toggle (2026-08-12): exchangeGetItem/setSlotItem followed by
    -- combinationItemGetItemMode() still overwrote the count down to just
    -- the new box's amount (5, not 6+5=11) -- same symptom as passing
    -- PreCombineStock into precombinationItemSub. That test called BOTH in
    -- sequence, unlike the current mutually-exclusive if/else below.
    -- 2026-08-14: defaulted OFF along with every other checkbox in this file
    -- (player's explicit request) for v1.3.1, then RE-TESTED in isolation
    -- (both branches genuinely alone, one at a time, via this checkbox) --
    -- exchangeGetItem/setSlotItem ALONE (checkbox off) on a real merge
    -- displaced the pre-existing stack out to the game world instead of
    -- adding to it ("swap" symptom, live-confirmed from the log: took the
    -- MERGE-path FALLBACK, "adds correctly, doesn't despawn" was WRONG).
    -- combinationItemGetItemMode() ALONE (checkbox on) merged correctly the
    -- same session. Flipped default to true: exchangeGetItem/setSlotItem is
    -- confirmed unsafe for merges, keep it for the EMPTY-SLOT path only
    -- (untouched, different code path below, not implicated by this test).
    merge_call_combination_mode = true,
    -- 2026-08-17: bypass_allowlist_all_items REMOVED (was a superseded
    -- stress-test flag; the curated allowlist is near-complete and firearms
    -- were confirmed to break under bypass).
    -- 2026-08-15: `force_new_item_look` (NIC) REMOVED ENTIRELY -- confirmed
    -- game-breaking (froze on merges, isolated via live testing with APU
    -- off/NIC alone on) and no longer needed now that merge detection and
    -- execution both work correctly on their own. Recoverable from git
    -- history/dev archive if ever needed again. The hook it used to share
    -- with the background-investigation toggles (install_open_mode_rewrite_
    -- hook) is gone too now, see the black-background-investigation removal
    -- note above -- `hooked_open_rewrite` no longer has anything left to
    -- guard, removed with it.
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

-- 2026-08-14: pure OBSERVER hooks (never alter args/return, always
-- CALL_ORIGINAL) on SlotBehavior's own combine-related methods, to watch
-- what the NATIVE game itself does during a 100% manual sub-weapon merge
-- (APU off). Two field-based hypotheses (getStock(slotIndex), GetItemStock.
-- AdditionalItem.WeaponId) both confirmed dead -- this observes real native
-- calls directly instead of guessing a third field to read.
local combine_observer_hooked = false
local function install_combine_observer_hooks()
    if combine_observer_hooked then return end
    local _, slot_behavior = get_sub_behaviors()
    if not slot_behavior then return end
    local ok_td, td = pcall(function() return slot_behavior:get_type_definition() end)
    if not ok_td or not td then return end

    local function dump_arg(tag, idx, raw)
        local ok_obj, obj = pcall(function() return sdk.to_managed_object(raw) end)
        if ok_obj and obj then
            local function f(name)
                local ok, v = pcall(function() return obj:get_field(name) end)
                return ok and tostring(v) or nil
            end
            local item_id, weapon_id, count = f("ItemId"), f("WeaponId"), f("Count")
            if item_id or weapon_id or count then
                log.info(string.format("[subweapon_merge_probe] %s arg%d: object ItemId=%s WeaponId=%s Count=%s",
                    tag, idx, tostring(item_id), tostring(weapon_id), tostring(count)))
                return
            end
            -- Object but not a PrimitiveItem-shaped one -- try DefaultItem nesting too.
            local ok_def, def = pcall(function() return obj:get_field("DefaultItem") end)
            if ok_def and def then
                local ok_did, did = pcall(function() return def:get_field("ItemId") end)
                local ok_dwid, dwid = pcall(function() return def:get_field("WeaponId") end)
                log.info(string.format("[subweapon_merge_probe] %s arg%d: object.DefaultItem ItemId=%s WeaponId=%s",
                    tag, idx, tostring(ok_did and did), tostring(ok_dwid and dwid)))
                return
            end
            local ok_type, tname = pcall(function() return obj:get_type_definition():get_full_name() end)
            log.info(string.format("[subweapon_merge_probe] %s arg%d: object type=%s (no recognized fields)",
                tag, idx, tostring(ok_type and tname or "?")))
            return
        end
        local ok_int, ival = pcall(function() return sdk.to_int64(raw) end)
        if ok_int then
            log.info(string.format("[subweapon_merge_probe] %s arg%d: int64=%s", tag, idx, tostring(ival)))
        else
            log.info(string.format("[subweapon_merge_probe] %s arg%d: unrecognized", tag, idx))
        end
    end

    local method_names = { "precombinationItem", "combinationItem", "precombinationItemSub", "combinationItemGetItemMode" }
    local hooked = 0
    for _, name in ipairs(method_names) do
        local m = td:get_method(name)
        if m then
            local this_name = name
            local ok_h = pcall(function()
                sdk.hook(m,
                    function(args)
                        log.info("[subweapon_merge_probe] === NATIVE CALL " .. this_name .. " ===")
                        for i = 3, 8 do
                            if args[i] == nil then break end
                            pcall(dump_arg, this_name, i - 2, args[i])
                        end
                        return sdk.PreHookResult.CALL_ORIGINAL
                    end,
                    function(retval)
                        log.info("[subweapon_merge_probe] " .. this_name .. " returned")
                        return retval
                    end)
            end)
            if ok_h then hooked = hooked + 1 end
        end
    end
    combine_observer_hooked = true
    log_line(string.format("[subweapon_merge_probe] Installed %d/%d combine-method observer hooks", hooked, #method_names))
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
        return
    end
    local behavior, slot_behavior = get_sub_behaviors()
    if not slot_behavior or state.slot_index == nil then
        log_line("grant step: SlotBehavior or slot_index unavailable, aborting this pickup")
        state.phase = "idle"
        state.armed_detect_count = nil
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
    -- 2026-08-14: found live -- Combat Knife/Hand Grenade/Flash Grenade
    -- carry their identity in WeaponId, not ItemId (which reads 0 for
    -- them). See SUBWEAPON_BY_WEAPON_ID above for the full story. Read
    -- WeaponId here too so the allowlist check below can fall back to it.
    local ok_gis_wid, gis_weapon_id = false, nil
    if ok_gis_default and gis_default_item then
        ok_gis_wid, gis_weapon_id = pcall(function() return gis_default_item:get_field("WeaponId") end)
    end
    local subweapon_name = ok_gis_wid and gis_weapon_id ~= nil and gis_weapon_id ~= -1
        and SUBWEAPON_BY_WEAPON_ID[gis_weapon_id] or nil
    -- 2026-08-14: firearm force-manual gate REMOVED (was active for a short
    -- window this same session). Live evidence flipped the whole premise:
    -- a "M19 is a firearm -- forced manual" log line turned out to be a
    -- misidentified GREEN HERB (ItemId 2 collides with M19's WeaponId 2 in
    -- FORCE_MANUAL_WEAPON_IDS below) -- and across the ENTIRE session, not
    -- one single grant-step log line was ever conclusively a real firearm;
    -- every case traced back to a misidentified consumable or key item (the
    -- "241 is a firearm" case earlier was actually a Fuse). That means this
    -- gate had no confirmed evidence it ever protected a real firearm
    -- pickup, while it DID have confirmed evidence of blocking ordinary,
    -- extremely common items (every basic herb/ammo whose id collides with
    -- an early WeaponId). Real firearms may simply never reach this hook at
    -- all (see re2_vr_weapon_aim_probe.lua, archived, for that unresolved
    -- question) -- if the original "guns equip but can't aim" symptom needs
    -- revisiting, it needs a live-confirmed root cause first, not another ID
    -- collision guess. FORCE_MANUAL_WEAPON_IDS table itself left in place
    -- below for reference/history, just no longer consulted here.

    local allowed_name = (ok_gis_id and gis_item_id ~= nil and AUTO_PICKUP_ALLOWLIST[gis_item_id]) or subweapon_name or nil
    if not allowed_name then
        log_line(string.format(
            "grant step: ItemId=%s WeaponId=%s not on auto-pickup allowlist -- staying manual for this item",
            tostring(ok_gis_id and gis_item_id or "?"), tostring(ok_gis_wid and gis_weapon_id or "?")))
        state.phase = "idle"
        state.slot_index = nil
        state.armed_detect_count = nil
        return
    end
    if subweapon_name and allowed_name == subweapon_name then
        log_line(string.format("grant step: WeaponId=%s (%s) is on allowlist -- proceeding", tostring(gis_weapon_id), allowed_name))
    else
        log_line(string.format("grant step: ItemId=%s (%s) is on allowlist -- proceeding", tostring(gis_item_id), allowed_name))
    end

    -- Merge detection FIXED (2026-08-13): CombinedSlotNo ~= -1 was
    -- unreliable -- confirmed live to hold 0, -1, AND 12 across different
    -- EMPTY-SLOT pickups (not merges at all), which is exactly what caused
    -- Attempt 6's fresh-object-creation code to misfire on ordinary weapon
    -- pickups (Matilda/SLS60 corruption, 2026-08-12/13). Clean probe
    -- captures found a semantically real signal instead: PreCombineStock.
    -- DefaultItem is a genuinely UNUSED placeholder (Count=1, ItemId=0) for
    -- empty-slot grants, and only gets populated with the real item's data
    -- (real ItemId, matching GetItemStock) when the game itself detects a
    -- merge. Originally checked ItemId ~= 0 alone -- confirmed reliable in
    -- that day's single-pickup tests, but NOT tested across a longer
    -- sequence.
    --
    -- BUG FOUND 2026-08-14 (live, extended multi-pickup testing): PreCombineStock
    -- is STALE, not reset -- it holds whatever ItemId the LAST genuine native
    -- merge populated it with, and never gets cleared for an ordinary
    -- empty-slot grant (our automation grants directly, bypassing whatever
    -- native step would otherwise reset it). Confirmed from the log: after a
    -- real Wooden Board merge (PreCombineStock.ItemId=33), the NEXT THREE
    -- unrelated pickups (Shotgun Shells ItemId=16, Gunpowder ItemId=38, Red
    -- Herb ItemId=3) all still read PreCombineStock.ItemId=33 and were
    -- WRONGLY routed down the MERGE path using that stale, unrelated item's
    -- data -- this is what corrupted the Wooden Board grant and left Red
    -- Herb needing manual placement ("many bugs AFTER some ammo or anything
    -- stackable has been merged"). Every GENUINE merge in the log has
    -- PreCombineStock.DefaultItem.ItemId == the CURRENT incoming item's own
    -- ItemId (gis_item_id, read above) -- a real merge can only ever be
    -- between two stacks of the SAME item type, so the native game always
    -- writes the matching id when it's real. Stale leftovers from a
    -- DIFFERENT prior item type won't match. Require that match instead of
    -- just nonzero.
    local ok_pcs, pre_combine_stock = pcall(function() return slot_behavior:get_field("PreCombineStock") end)
    local ok_pcs_default, pcs_default_item = false, nil
    if ok_pcs and pre_combine_stock then
        ok_pcs_default, pcs_default_item = pcall(function() return pre_combine_stock:get_field("DefaultItem") end)
    end
    local ok_pcs_id, pcs_item_id = false, nil
    if ok_pcs_default and pcs_default_item then
        ok_pcs_id, pcs_item_id = pcall(function() return pcs_default_item:get_field("ItemId") end)
    end
    local is_merge = ok_pcs_id and pcs_item_id ~= nil and pcs_item_id ~= 0 and pcs_item_id == gis_item_id
    -- 2026-08-14: sub-weapon (Combat Knife/Hand Grenade/Flash Grenade)
    -- merge check -- UNCONFIRMED, added defensively. These carry their
    -- identity in WeaponId, not ItemId (see SUBWEAPON_BY_WEAPON_ID/
    -- subweapon_name above) -- if PreCombineStock uses the same WeaponId-
    -- not-ItemId convention for them (not yet live-confirmed either way),
    -- the ItemId-only check above would never detect a genuine sub-weapon
    -- merge (both sides would show ItemId=0, and 0 ~= 0 is filtered out by
    -- the pcs_item_id ~= 0 guard), silently falling through to the EMPTY-
    -- SLOT path and overwriting an existing stack -- the exact bug class
    -- fixed for ordinary items above. Checking WeaponId in parallel so a
    -- genuine sub-weapon merge is caught even if ItemId stays 0 on both
    -- sides. Log line reports both so the next live sub-weapon merge test
    -- confirms whether this path is actually reachable.
    local ok_pcs_wid, pcs_weapon_id = false, nil
    if ok_pcs_default and pcs_default_item then
        ok_pcs_wid, pcs_weapon_id = pcall(function() return pcs_default_item:get_field("WeaponId") end)
    end
    if not is_merge and subweapon_name and ok_pcs_wid and pcs_weapon_id ~= nil
        and pcs_weapon_id ~= -1 and pcs_weapon_id == gis_weapon_id then
        is_merge = true
    end
    -- 2026-08-14: CONFIRMED live -- the check above never fires.
    -- PreCombineStock.DefaultItem.WeaponId stays -1 even during a genuine
    -- sub-weapon merge (player merged two Flash Grenades; PreCombineStock
    -- never signaled it). PreCombineStock apparently just doesn't reflect
    -- sub-weapon merges at all -- a different mechanism than ordinary
    -- stackables. Found via a one-time SlotBehavior method dump
    -- ([subweapon_merge_probe] in the log): getStock(slotIndex) exists and
    -- looks like a direct "what's currently in this slot" accessor,
    -- independent of PreCombineStock entirely. Using it here as the real
    -- fix for sub-weapons: read whatever's already sitting in the target
    -- slot directly, and if its WeaponId matches the incoming item's, this
    -- is unambiguously a real merge regardless of what PreCombineStock
    -- says.
    local existing_weapon_id = nil
    if not is_merge and subweapon_name then
        -- 2026-08-14: getStock(slotIndex) attempt (previous version of this
        -- block) confirmed DEAD -- the call succeeds (no error) but returns
        -- nil outright, meaning either the wrong argument type/count or
        -- it's not meant to be called this way at all. Not pursuing that
        -- API further. New hypothesis instead: GetItemStock (the INCOMING
        -- item's own stock, already read above as get_item_stock/
        -- gis_default_item) has a sibling AdditionalItem field --
        -- item_id_probe has been dumping its ItemId/Count this whole
        -- session (always ItemId=0/Count=1 for grenades so far) but never
        -- its WeaponId. Checking that here as the real candidate for "is
        -- this incoming pickup itself already aware it's stacking onto an
        -- existing sub-weapon".
        local ok_add, additional_item = pcall(function() return get_item_stock:get_field("AdditionalItem") end)
        local ok_add_wid, add_wid = false, nil
        if ok_add and additional_item then
            ok_add_wid, add_wid = pcall(function() return additional_item:get_field("WeaponId") end)
        end
        log_line(string.format(
            "[subweapon_merge_probe] GetItemStock.AdditionalItem(ok=%s).WeaponId(ok=%s)=%s",
            tostring(ok_add), tostring(ok_add_wid), tostring(add_wid)))
        if ok_add_wid and add_wid ~= nil and add_wid ~= -1 then
            existing_weapon_id = add_wid
        end
        if existing_weapon_id ~= nil and existing_weapon_id == gis_weapon_id then
            is_merge = true
        end
    end
    -- 2026-08-14: CONFIRMED live via a pure-observer native-method hook
    -- (player did a 100% manual merge with APU off) -- a sub-weapon merge
    -- calls ONLY combinationItemGetItemMode, never precombinationItem/
    -- precombinationItemSub at all. That explains why every PreCombineStock/
    -- GetItemStock field check above came back empty -- the native flow
    -- simply never populates the data those checks were looking for,
    -- because it doesn't need to feed a precombination-subtract step for
    -- sub-weapons in the first place. Since the native flow doesn't appear
    -- to need any item-identity cross-check of its own here either, the
    -- working theory is it trusts the target slot: getInitializeCursorPosition
    -- already chose state.slot_index as the target for THIS specific pickup,
    -- so if that slot isn't blank, the game deliberately routed this pickup
    -- at an existing compatible stack. For sub-weapons specifically (where
    -- none of the other signals work), treat "occupied slot" itself as the
    -- merge signal.
    if not is_merge and subweapon_name then
        local ok_blank_sw, is_blank_sw = pcall(function() return slot_behavior:call("isBlankSlot", state.slot_index) end)
        if ok_blank_sw and is_blank_sw == false then
            is_merge = true
        end
    end
    log_line(string.format(
        "grant step: merge-detect PreCombineStock.DefaultItem.ItemId=%s WeaponId=%s (incoming ItemId=%s WeaponId=%s) AdditionalItem.WeaponId=%s -> is_merge=%s",
        tostring(ok_pcs_id and pcs_item_id or "?"), tostring(ok_pcs_wid and pcs_weapon_id or "?"),
        tostring(gis_item_id), tostring(ok_gis_wid and gis_weapon_id or "?"),
        tostring(existing_weapon_id), tostring(is_merge)))

    if is_merge and subweapon_name then
        -- 2026-08-14: sub-weapon merge, confirmed via native observer hook
        -- to call ONLY combinationItemGetItemMode -- no precombinationItemSub
        -- at all, unlike ordinary items below. Matching that exactly rather
        -- than reusing the ordinary-item merge path (which would call
        -- precombinationItemSub unnecessarily -- untested/wrong for this
        -- item class, and precombinationItemSub is a subtraction-based call
        -- that's caused real corruption before when given data it wasn't
        -- designed for, see Attempt 6 history below).
        local ok_sw = try_call(slot_behavior, "combinationItemGetItemMode")
        log_line(string.format(
            "grant step (SUB-WEAPON MERGE path): combinationItemGetItemMode ok=%s (WeaponId=%s)",
            tostring(ok_sw), tostring(gis_weapon_id)))
        if ok_sw then state.stats.granted = state.stats.granted + 1 end
    elseif is_merge then
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
            -- CONFIRMED UNSAFE for merges (2026-08-14, live test): displaces
            -- the pre-existing stack out to the game world instead of
            -- adding to it, rather than the "adds correctly, doesn't
            -- despawn" this comment used to claim. Only reachable now if
            -- the player explicitly unchecks the ISOLATION TEST box.
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
            -- 2026-08-14: one-time diagnostic -- player found a real
            -- sub-weapon (grenade) merge case: already had a Flash Grenade,
            -- picked up a second, PreCombineStock never signaled a merge
            -- (WeaponId stayed -1 there even though the incoming item's own
            -- WeaponId=66 was read correctly) -- so this landed here,
            -- correctly refusing to blindly overwrite the occupied slot,
            -- but SHOULD have merged instead. Dumping SlotBehavior's own
            -- methods (filtered to item/slot/stock-sounding names) once, to
            -- find a direct "what's already in this slot" accessor we could
            -- use instead of relying on PreCombineStock for sub-weapons.
            if not state.dumped_slot_behavior_methods then
                state.dumped_slot_behavior_methods = true
                local ok_td, td = pcall(function() return slot_behavior:get_type_definition() end)
                if ok_td and td then
                    log.info("[subweapon_merge_probe] --- SlotBehavior methods (filtered) ---")
                    local depth = 0
                    while td and depth < 4 do
                        local ok_m, methods = pcall(function() return td:get_methods() end)
                        if ok_m and methods then
                            for _, m in ipairs(methods) do
                                local ok_n, mname = pcall(function() return m:get_name() end)
                                if ok_n and mname then
                                    local lower = mname:lower()
                                    if lower:find("item") or lower:find("slot") or lower:find("stock") then
                                        log.info("[subweapon_merge_probe]   [L" .. depth .. "] " .. mname)
                                    end
                                end
                            end
                        end
                        local ok_p, parent = pcall(function() return td:get_parent_type() end)
                        if not ok_p or not parent then break end
                        td = parent
                        depth = depth + 1
                    end
                end
            end
            state.phase = "idle"
            state.slot_index = nil
            state.armed_detect_count = nil
            return
        end

        -- 2026-08-14: weapon-field diagnostic (player's explicit request,
        -- stress-test bypass toggle) -- weapons equip fine after auto-grant
        -- but can't aim/fire. clone_primitive (MERGE path, above) already
        -- treats WeaponId/BulletId/WeaponParts as the fields that matter for
        -- a weapon-shaped PrimitiveItem; this EMPTY-SLOT path never rebuilds
        -- a snapshot (grants gis_default_item -- the live GetItemStock.
        -- DefaultItem -- as-is via exchangeGetItem/setSlotItem), so if one
        -- of those reads 0/nil here, the native pickup screen itself never
        -- populated it, which would point at something the manual/native
        -- confirm flow does that our direct grant skips.
        if gis_default_item then
            local function rf(fname)
                local ok, v = pcall(function() return gis_default_item:get_field(fname) end)
                return ok and v or "?"
            end
            log_line(string.format(
                "grant step (EMPTY-SLOT path): pre-grant fields WeaponId=%s BulletId=%s WeaponParts=%s Count=%s",
                tostring(rf("WeaponId")), tostring(rf("BulletId")), tostring(rf("WeaponParts")), tostring(rf("Count"))))
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
        return
    end
    local _, _, detail_behavior = get_sub_behaviors()
    if not detail_behavior then
        log_line("detail close step: DetailBehavior unavailable, aborting close (item already granted)")
        state.phase = "idle"
        state.armed_detect_count = nil
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
        return
    end
    local behavior, slot_behavior, detail_behavior = get_sub_behaviors()
    if not behavior or not slot_behavior or not detail_behavior then
        log_line("finish chain: one of Behavior/SlotBehavior/DetailBehavior unavailable, aborting")
        state.phase = "idle"
        state.armed_detect_count = nil
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
            -- 2026-08-14: diagnostic -- player found a Flash Grenade pickup
            -- read ItemId=0 (the documented "unused placeholder" value) at
            -- our normal 0.51s settle point, staying manual even though
            -- Flash Grenade IS on the allowlist. Theory: the settle-wait
            -- above only tracks GetItemSlotNo/CombinedSlotNo stability, not
            -- ItemId itself -- for weapon-classified sub-items (grenades/
            -- knife, which read their WeaponId through this same field, see
            -- AUTO_PICKUP_ALLOWLIST's own comment), ItemId may simply
            -- populate on a different timing than slot numbers do. This
            -- independent poller samples ItemId every frame for a few
            -- seconds after every pickup (not just grenades) and logs every
            -- change with elapsed time, so we can see directly whether/when
            -- it actually becomes correct, without changing any real
            -- behavior.
            state.item_id_probe = { active = true, started_at = os.clock(), last_id = "?" }
            log_line("Pickup detected, slot=" .. tostring(r) .. " -- auto-sequence armed")
            return retval
        end)

    state.hooked = true
    log_line("Hooked Inventory.getInitializeCursorPosition")
end

re.on_frame(function()
    -- 2026-08-14: item_id_probe diagnostic (see its start point above) --
    -- runs unconditionally, independent of state.enabled/phase, so it keeps
    -- sampling even after our own grant step has already read/aborted on a
    -- stale ItemId=0. Stops itself after ~2s.
    if state.item_id_probe and state.item_id_probe.active then
        local elapsed = os.clock() - state.item_id_probe.started_at
        if elapsed > 2.0 then
            state.item_id_probe.active = false
        else
            local _, sb = get_sub_behaviors()
            local id_str = "?"
            local extra = ""
            if sb then
                local ok_gis, get_item_stock = pcall(function() return sb:get_field("<GetItemStock>k__BackingField") end)
                if ok_gis and get_item_stock then
                    local ok_def, default_item = pcall(function() return get_item_stock:get_field("DefaultItem") end)
                    if ok_def and default_item then
                        local ok_id, item_id = pcall(function() return default_item:get_field("ItemId") end)
                        if ok_id then id_str = tostring(item_id) end
                        -- 2026-08-14: extended after finding Flash Grenade's
                        -- DefaultItem.ItemId reads 0 from the very first
                        -- sample, never anything else (unlike every working
                        -- item, which reads correctly at t=0 then resets to
                        -- 0 only AFTER our own grant completes). Dumping
                        -- DefaultItem's other fields plus AdditionalItem
                        -- entirely, to find out whether a grenade's real
                        -- identity lives somewhere other than
                        -- DefaultItem.ItemId.
                        local function f(obj, name)
                            if not obj then return "?" end
                            local ok, v = pcall(function() return obj:get_field(name) end)
                            return ok and tostring(v) or "?"
                        end
                        local ok_add, additional_item = pcall(function() return get_item_stock:get_field("AdditionalItem") end)
                        extra = string.format(
                            " DefaultItem(Count=%s WeaponId=%s BulletId=%s) AdditionalItem(ItemId=%s Count=%s)",
                            f(default_item, "Count"), f(default_item, "WeaponId"), f(default_item, "BulletId"),
                            f(ok_add and additional_item or nil, "ItemId"), f(ok_add and additional_item or nil, "Count"))
                    end
                end
            end
            if id_str ~= state.item_id_probe.last_id then
                log_line(string.format("[item_id_probe] t=%.2fs ItemId=%s%s", elapsed, id_str, extra))
                state.item_id_probe.last_id = id_str
            end
        end
    end

    if not combine_observer_hooked then
        pcall(install_combine_observer_hooks)
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
    if not imgui.tree_node("Inventory Auto-Complete (APU)") then return end

    if imgui.tree_node("Auto-pickup settings") then
        imgui.text_colored(
            "The freeze this used to cause during herb-combining was isolated to the",
            0xFFAAAAAA)
        imgui.text_colored(
            "[NIC] checkbox below, not this one -- confirmed via isolated live testing.",
            0xFFAAAAAA)
        imgui.text_colored(
            "On by default now. Turn it off if you'd rather confirm pickups manually.",
            0xFFAAAAAA)
        imgui.spacing()

        local changed, new_val = imgui.checkbox("Enable auto-complete pickup screen [APU]", state.enabled)
        if changed then
            state.enabled = new_val
            log_line("Enabled = " .. tostring(new_val))
        end

        local changed_m, new_val_m = imgui.checkbox(
            "Use combinationItemGetItemMode for merges (CONFIRMED correct 2026-08-14; uncheck only to debug, exchangeGetItem-alone displaces the existing stack)",
            state.merge_call_combination_mode)
        if changed_m then
            state.merge_call_combination_mode = new_val_m
            log_line("Merge calls combinationItemGetItemMode = " .. tostring(new_val_m))
        end

        imgui.spacing()
        imgui.text("Current phase: " .. state.phase)
        imgui.text(string.format("Stats: attempts=%d granted=%d closed=%d",
            state.stats.attempts, state.stats.granted, state.stats.closed))
        imgui.tree_pop()
    end

    if imgui.tree_node("Timing (seconds) -- lower only after confidence is built") then
        local c1, v1 = imgui.slider_float("Delay before grant", delay_before_grant, 0.1, 1.5)
        if c1 then delay_before_grant = v1 end
        local c2, v2 = imgui.slider_float("Delay before DetailBehavior.close", delay_before_detail_close, 0.05, 1.0)
        if c2 then delay_before_detail_close = v2 end
        local c3, v3 = imgui.slider_float("Delay before finish chain", delay_before_finish_chain, 0.05, 1.0)
        if c3 then delay_before_finish_chain = v3 end
        imgui.tree_pop()
    end

    if imgui.tree_node("Log") then
        if imgui.button("Clear log") then state.log_buffer = {} end
        for _, line in ipairs(state.log_buffer) do
            imgui.text(line)
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

log.info("[re2_vr_inventory_auto_complete] Loaded")
