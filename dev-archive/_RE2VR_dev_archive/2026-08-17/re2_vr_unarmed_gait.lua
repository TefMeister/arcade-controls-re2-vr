-- Unarmed gait with weapons equipped (2026-08-17, player feature request:
-- "have [foot animations] where no weapon is equipped all the time").
--
-- Mechanism, fully decoded via re2_vr_gait_probe.lua (3 capture passes,
-- 2026-08-16/17):
--   * Locomotion always plays motion id 160/190/192 from bank id 1000 --
--     what changes with weapon state is WHICH motlist bank id 1000 resolves
--     to. All candidates coexist in the Motion component's active bank list
--     (e.g. HDG_MOVE_cnFINE_stNORMAL_01 vs CMN_MOVE, both BankID=1000).
--   * Selection rule (read off the live BankType/BankTypeMaskBit values):
--     a bank is eligible when (Motion.TargetBankType & BankTypeMaskBit) ==
--     BankType. TargetBankType measured: 287 (0x11F) with handgun drawn, 0
--     unarmed. Low byte = weapon category (HDG move = 31), high bits =
--     condition/state (stWATER=0x100000, stLIGHT=0x200000, stCOMBAT=
--     0x300000, cnCAUTION=0x1000000, cnDANGER=0x2000000).
--   * The weapon-grip pose lives in separate HOLD (2000) and FINGER (10000)
--     banks selected by the same rule -- which is why forcing
--     TargetBankType=0 is the WRONG fix: it would also revert the hand grip
--     to bare-hand CMN_FINGER. Not used here.
--
-- Fix used instead: poison ONLY the weapon-specific *_MOVE banks (BankID
-- 1000, name like HDG_MOVE_*/STG_MOVE_*/MAG_MOVE_*, never CMN_MOVE*) by
-- writing BankType=255, BankTypeMaskBit=255 -- a combination no real
-- TargetBankType satisfies (low byte is a small weapon-category id). Bank
-- 1000 resolution then falls through to the CMN_MOVE* family, which keeps
-- its own condition-bit matching, so caution/danger/wet gait variants keep
-- working -- just the relaxed, no-weapon versions of them. HOLD/FINGER
-- banks untouched: the weapon stays properly gripped.
--
-- The active bank list is REBUILT when the equipped weapon changes (probe
-- pass 3 showed MAG_* entries appear/disappear with the equip), so the
-- poison is re-applied on a short polling interval rather than once.
-- Originals are remembered per bank Name and restored on disable/reset.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")

local motion_type = sdk.typeof("via.motion.Motion")

local POISON_TYPE = 255
local POISON_MASK = 255
local SCAN_INTERVAL_S = 0.25

local state = {
    enabled = true,
    status = "idle",
    last_scan_t = 0.0,
    poisoned_count = 0,
    originals = {}, -- [bank Name] = { bank_type = n, mask = n }
    setter_ok = nil, -- nil = unknown, true/false once first write attempted
}

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

local function get_player_motion()
    local player = re2.get_localplayer()
    if not player or not motion_type then return nil end
    return safe(function()
        return player:call("getComponent(System.Type)", motion_type)
    end)
end

local function is_weapon_move_bank(name)
    if type(name) ~= "string" then return false end
    if name:sub(1, 3) == "CMN" then return false end
    return name:find("_MOVE", 1, true) ~= nil
end

local function write_bank(bank, bank_type, mask)
    local ok1 = pcall(function() bank:call("set_BankType", bank_type) end)
    local ok2 = pcall(function() bank:call("set_BankTypeMaskBit", mask) end)
    return ok1 and ok2
end

local function for_each_active_bank(fn)
    local mc = get_player_motion()
    if not mc then return false end
    local count = safe(function() return mc:call("getActiveMotionBankCount") end)
    for i = 0, (tonumber(count) or 0) - 1 do
        local bank = safe(function() return mc:call("getActiveMotionBank", i) end)
        if bank then fn(bank) end
    end
    return true
end

local function apply_poison()
    local touched = 0
    local ok = for_each_active_bank(function(bank)
        local bid = safe(function() return bank:call("get_BankID") end)
        if bid ~= 1000 then return end
        local name = tostring(safe(function() return bank:call("get_Name") end) or "")
        if not is_weapon_move_bank(name) then return end
        local bt = safe(function() return bank:call("get_BankType") end)
        if bt == POISON_TYPE then return end -- already poisoned (this rebuild)
        if not state.originals[name] then
            state.originals[name] = {
                bank_type = bt,
                mask = safe(function() return bank:call("get_BankTypeMaskBit") end),
            }
        end
        local wrote = write_bank(bank, POISON_TYPE, POISON_MASK)
        if state.setter_ok == nil then state.setter_ok = wrote end
        if wrote then touched = touched + 1 end
    end)
    if not ok then
        state.status = "no player/motion component"
        return
    end
    if state.setter_ok == false then
        state.status = "set_BankType/set_BankTypeMaskBit NOT writable -- approach dead, tell Claude"
        return
    end
    if touched > 0 then
        state.poisoned_count = state.poisoned_count + touched
        state.status = string.format("active (%d bank(s) redirected total)", state.poisoned_count)
    elseif state.status == "idle" then
        state.status = "active (nothing to redirect yet)"
    end
end

local function restore_originals()
    for_each_active_bank(function(bank)
        local bid = safe(function() return bank:call("get_BankID") end)
        if bid ~= 1000 then return end
        local name = tostring(safe(function() return bank:call("get_Name") end) or "")
        local orig = state.originals[name]
        local bt = safe(function() return bank:call("get_BankType") end)
        if orig and bt == POISON_TYPE then
            write_bank(bank, orig.bank_type, orig.mask)
        end
    end)
    state.status = "restored/disabled"
    state.poisoned_count = 0
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    if not state.enabled then return end
    local now = os.clock()
    if now - state.last_scan_t < SCAN_INTERVAL_S then return end
    state.last_scan_t = now
    apply_poison()
end)

re.on_draw_ui(function()
    if not imgui then return end
    if not imgui.tree_node("Unarmed Gait (relaxed walk while armed)") then return end

    local c, v = imgui.checkbox("Use unarmed walk/idle animations while a weapon is equipped", state.enabled)
    if c then
        state.enabled = v
        if not v then restore_originals() end
    end
    imgui.text("Status: " .. tostring(state.status))
    imgui.text_colored(
        "Weapon grip/fingers unaffected (separate HOLD/FINGER banks). Caution/danger/wet",
        0xFF88CCFF)
    imgui.text_colored(
        "gait variants still work -- just their relaxed, no-weapon versions.",
        0xFF88CCFF)

    imgui.tree_pop()
end)

re.on_script_reset(function()
    restore_originals()
end)

log.info("[re2_vr_unarmed_gait] Loaded")
