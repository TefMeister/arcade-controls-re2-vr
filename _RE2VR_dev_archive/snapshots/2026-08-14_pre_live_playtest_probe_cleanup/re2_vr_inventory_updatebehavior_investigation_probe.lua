-- Diagnostic only (read-only, no writes) -- follow-up to
-- re2_vr_inventory_no_pause_idea: via.Application.GlobalSpeed CONFIRMED to
-- stay at 1.0 the whole time inventory is open (no global clock-scale
-- pause), yet the player confirmed directly ("they definitely stop moving,
-- I have played this a lot") that enemies genuinely freeze. So the pause is
-- real but NOT implemented via one central speed knob -- most likely each
-- AI/physics system individually checks something like GUIMaster.
-- get_IsOpenInventory() and skips its own per-frame update.
--
-- This probe answers ONE specific question first, before assuming which
-- category of problem this is: does the engine's own "UpdateBehavior" frame
-- pipeline stage (the same entry point re2_vr_recoil.lua/re2_vr_holster.lua
-- already hook elsewhere in this mod via re.on_pre_application_entry) still
-- fire at all while the inventory is open, or does the native engine skip
-- the whole stage?
--
-- If it KEEPS firing normally -> pause is per-object (each Behavior class
-- checking a flag itself), meaning there's no single lever -- would need to
-- find and patch each relevant system individually, likely impractical
-- (unknown how many systems, high risk of missing something like health
-- regen/timers/hazards).
-- If it STOPS/changes -> pause is a more centralized native-engine skip,
-- which is still likely unreachable from Lua (the C++ frame dispatcher
-- deciding not to invoke a stage at all isn't something a hook on that
-- stage's own entry point can force back on), but at least tells us which
-- kind of wall this is before spending more time on it.
--
-- Safe to delete/archive once findings are captured.

if reframework:get_game_name() ~= "re2" then
    return
end

local NS = sdk.game_namespace

local function is_inventory_open()
    local gm = sdk.get_managed_singleton(NS("gui.GUIMaster"))
    if not gm then return false end
    local ok, is_open = pcall(function() return gm:call("get_IsOpenInventory") end)
    return ok and is_open == true
end

local update_calls_total = 0
local update_calls_since_open = 0
local was_open = false
local last_log_time = 0

re.on_pre_application_entry("UpdateBehavior", function()
    update_calls_total = update_calls_total + 1
    if is_inventory_open() then
        update_calls_since_open = update_calls_since_open + 1
    end
end)

re.on_frame(function()
    local now = os.clock()
    local open_now = is_inventory_open()

    if open_now and not was_open then
        update_calls_since_open = 0
        log.info("[updatebehavior_probe] inventory OPENED -- starting to count UpdateBehavior calls")
    elseif not open_now and was_open then
        log.info(string.format(
            "[updatebehavior_probe] inventory CLOSED -- UpdateBehavior fired %d times while open",
            update_calls_since_open))
    end
    was_open = open_now

    -- Throttled heartbeat while open, so we can see the rate, not just a
    -- before/after total.
    if open_now and (now - last_log_time) >= 0.5 then
        last_log_time = now
        log.info(string.format(
            "[updatebehavior_probe] inventory open, UpdateBehavior calls so far this screen: %d (total ever: %d)",
            update_calls_since_open, update_calls_total))
    end
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Inventory UpdateBehavior pipeline investigation probe (read-only)")
    imgui.text("Prefix to grep: [updatebehavior_probe]")
    imgui.text("Inventory open now: " .. tostring(is_inventory_open()))
    imgui.text("UpdateBehavior calls total this session: " .. tostring(update_calls_total))
    imgui.text_colored("Open the inventory near an enemy (or just open it) to test.", 0xFF88CCFF)
end)

log.info("[updatebehavior_probe] Loaded. Open the inventory once (ideally near an enemy).")
