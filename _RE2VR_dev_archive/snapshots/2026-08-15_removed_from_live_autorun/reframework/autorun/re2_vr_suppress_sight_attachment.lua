-- Suppresses a weapon-attachment PART (default: bit 2, "the sight" on the
-- one weapon this was ever confirmed against, wp3000 Lightning Hawk) by
-- continuously re-forcing Equipment.ForceEquipType/ForceEquipParts with
-- that bit masked out of the real, live WeaponParts value -- same Nullable
-- struct-field-write technique already proven safe under continuous
-- per-frame forcing in re2_vr_suppress_supporthold.lua (zero flicker there
-- for the whole RG-held duration).
--
-- Why (2026-08-15): [[re2_vr_laser_sight_drift_status]] closed a
-- 17-mechanism dead-end investigation into the Red Dot Sight attachment's
-- rendered dot drifting off actual aim in VR -- confirmed correlated with
-- torso correction being active, never traced to a fixable native cause.
-- Player confirmed the sight IS equipped and the drift is now worse (moves
-- with head pitch too, not just body). Rather than keep chasing the native
-- render bug, player wants to just remove the broken sight and rely on this
-- mod's own always-accurate crosshair instead (re2_vr_crosshair.lua,
-- GUI_Reticle repositioned via raycast every frame -- already default-on).
-- Bonus hypothesis, untested: RE2 may suppress the normal reticle in favor
-- of the optic's own aim visualization while a sight is equipped, in which
-- case removing the sight should also just let the existing crosshair
-- script start showing again on its own -- no separate "enable crosshair on
-- RG" code should be needed.
--
-- KNOWN TRADEOFF (from the original investigation, mechanism 11): this
-- also strips the sight's native "fast lock-in" reticle gameplay behavior
-- -- a real gameplay effect, not just cosmetic. That's WHY this was never
-- shipped back then. Player has explicitly decided that tradeoff is worth
-- it this time in exchange for a correct sight picture -- OFF by default
-- here regardless, opt in via the checkbox.
--
-- KNOWN CAVEAT (from the original investigation): forcing WeaponParts only
-- visibly took effect after a STATE TRANSITION (RG release), not instantly
-- mid-aim, when only forced for the RG-held duration. This version
-- sidesteps that by forcing CONTINUOUSLY and UNCONDITIONALLY (not gated to
-- RG-hold at all, every frame regardless of aim state) -- the override
-- should already be active before any equip/draw/holster transition
-- happens, so there shouldn't be a window where the sight is still
-- visually present. If it still only refreshes after a re-draw/holster
-- cycle, that's the same native limitation as before, not a bug in this
-- script.
--
-- Which bit is "the sight" is WEAPON-SPECIFIC and was only ever confirmed
-- for wp3000 -- exposed here as individual bit checkboxes (not hardcoded
-- and silently trusted) with a live raw-parts readout, so it's safe to
-- verify/adjust for whatever weapon is actually being tested.

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

local re2 = require("utility/RE2")
local GameObject = require("utility/GameObject")

local NS = sdk.game_namespace

local FORCE_EQUIP_FIELD = "<ForceEquipType>k__BackingField"
local FORCE_EQUIP_PARTS_FIELD = "<ForceEquipParts>k__BackingField"
local WEAPON_TYPE_FIELD = "_WeaponType"
local WEAPON_PARTS_FIELD = "_WeaponParts"

-- Widened 2026-08-15 from 8 -- JMB Hp3 (wp0200) showed no correlation on
-- any of bits 0-7 during testing, so the real bit (if _WeaponParts is even
-- the right field for this weapon at all -- unconfirmed, may be baked into
-- the base weapon instead of a togglable part) could be higher.
local NUM_BITS = 16

local state = {
    enabled = false,
    -- Bit 2 pre-checked per the original investigation's confirmed sight
    -- bit on wp3000. Verify against the live readout below before trusting
    -- it for a different weapon -- don't just assume it's right.
    mask_bits = { false, false, true, false, false, false, false, false,
                  false, false, false, false, false, false, false, false },
    last_raw_parts = nil,
    last_masked_parts = nil,
    status = "idle",
}

local function get_equipment()
    local ok_p, player = pcall(function() return re2.get_localplayer() end)
    if not ok_p or not player then return nil end
    local ok_e, equipment = pcall(function()
        return GameObject.get_component(player, NS("survivor.Equipment"))
    end)
    return ok_e and equipment or nil
end

local function compute_mask()
    local mask = 0
    for i = 1, NUM_BITS do
        if state.mask_bits[i] then
            mask = mask | (1 << (i - 1))
        end
    end
    return mask
end

local function force_masked_parts(equipment)
    local ok_arm, arm = pcall(function() return equipment:call("get_MainWeapon") end)
    if not ok_arm or not arm then
        state.status = "no MainWeapon"
        return
    end

    local ok_wt, weapon_type = pcall(function() return arm:get_field(WEAPON_TYPE_FIELD) end)
    local ok_wp, weapon_parts = pcall(function() return arm:get_field(WEAPON_PARTS_FIELD) end)
    if not ok_wt or weapon_type == nil or not ok_wp or weapon_parts == nil then
        state.status = "could not read weapon type/parts"
        return
    end

    state.last_raw_parts = weapon_parts
    local masked_parts = weapon_parts & ~compute_mask()
    state.last_masked_parts = masked_parts

    local ok_before, before = pcall(function() return equipment:get_field(FORCE_EQUIP_FIELD) end)
    if ok_before and before then
        pcall(function() before:set_field("_HasValue", true) end)
        pcall(function() before:set_field("_Value", weapon_type) end)
        pcall(function() equipment:set_field(FORCE_EQUIP_FIELD, before) end)
    end

    local ok_parts_before, parts_before = pcall(function() return equipment:get_field(FORCE_EQUIP_PARTS_FIELD) end)
    if ok_parts_before and parts_before then
        pcall(function() parts_before:set_field("_HasValue", true) end)
        pcall(function() parts_before:set_field("_Value", masked_parts) end)
        pcall(function() equipment:set_field(FORCE_EQUIP_PARTS_FIELD, parts_before) end)
    end

    state.status = string.format("forcing parts %d -> %d (mask 0x%02X)", weapon_parts, masked_parts, compute_mask())
end

local function clear_force(equipment)
    local ok_cur, cur = pcall(function() return equipment:get_field(FORCE_EQUIP_FIELD) end)
    if ok_cur and cur then
        pcall(function() cur:set_field("_HasValue", false) end)
        pcall(function() cur:set_field("_Value", 0) end)
        pcall(function() equipment:set_field(FORCE_EQUIP_FIELD, cur) end)
    end
    local ok_parts_cur, parts_cur = pcall(function() return equipment:get_field(FORCE_EQUIP_PARTS_FIELD) end)
    if ok_parts_cur and parts_cur then
        pcall(function() parts_cur:set_field("_HasValue", false) end)
        pcall(function() parts_cur:set_field("_Value", 0) end)
        pcall(function() equipment:set_field(FORCE_EQUIP_PARTS_FIELD, parts_cur) end)
    end
    state.status = "cleared"
end

local was_enabled = false

re.on_frame(function()
    local equipment = get_equipment()
    if not equipment then return end

    if state.enabled then
        force_masked_parts(equipment)
        was_enabled = true
    elseif was_enabled then
        clear_force(equipment)
        was_enabled = false
    end
end)

re.on_draw_ui(function()
    if not imgui then return end
    if not imgui.tree_node("Sight Attachment Suppression (experimental)") then return end

    imgui.text_colored(
        "Trades away the sight's native \"fast lock-in\" aim-assist -- a real gameplay effect, not just cosmetic.",
        0xFF88CCFF)
    imgui.text_colored(
        "May need a weapon re-draw/holster cycle to visually refresh after toggling.",
        0xFF88CCFF)

    local c, v = imgui.checkbox("Enable", state.enabled)
    if c then state.enabled = v end

    imgui.text("Mask bits (checked = forced OFF). Bit 2 = sight, confirmed on wp3000 only -- verify for other weapons via the readout below.")
    for i = 1, NUM_BITS do
        local bc, bv = imgui.checkbox("Bit " .. (i - 1), state.mask_bits[i])
        if bc then state.mask_bits[i] = bv end
        if i % 4 ~= 0 then imgui.same_line() end
    end

    if state.last_raw_parts then
        imgui.text(string.format("Live WeaponParts: raw=%d (0x%X)  masked=%d (0x%X)",
            state.last_raw_parts, state.last_raw_parts, state.last_masked_parts or 0, state.last_masked_parts or 0))
    end
    imgui.text("Status: " .. tostring(state.status))

    imgui.tree_pop()
end)

re.on_script_reset(function()
    state.enabled = false
    local equipment = get_equipment()
    if equipment then clear_force(equipment) end
end)

log.info("[re2_vr_suppress_sight_attachment] Loaded")
