-- Inventory/pickup background un-hide for VR (2026-08-19).
--
-- ROOT CAUSE of the "black void" inventory/pickup background in VR, found
-- by reading REFramework's own source (src/mods/VR.cpp, on_pre_gui_draw_element):
--
--     // the weird buggy overlay in the inventory
--     case "GuiBack"_fnv:
--         if (gi.is_re2() || gi.is_re3()) {
--             return false;      // <- element draw is CANCELLED entirely
--         }
--
-- REFramework's VR mod deliberately suppresses the whole "GuiBack"
-- GameObject (the element holding NewInventoryBackBehavior: BgPanel /
-- CapturePanel / BgBlur -- the inventory & pickup backdrop) by NAME HASH,
-- every frame, whenever the VR runtime is active. That is why every prior
-- Lua-side lever (BlurScale, ColorScale, CaptureEnable,
-- activatePostEffectCapture, DetailBlurScale...) wrote real values with
-- zero visual effect: the element was never drawn in the first place.
--
-- Bypass: the C++ check re-reads the GameObject's name fresh on every draw
-- call, so renaming the GameObject makes the hash check miss, and the
-- element goes through REFramework's GENERIC screen->worldspace GUI path
-- (ViewType World + Overlay + Detonemap) like every other inventory
-- element, i.e. it gets drawn on the VR UI plane.
--
-- Mod callback order is fixed (Mods.cpp): VR runs BEFORE ScriptRunner, and
-- if ANY mod returns false the draw is skipped -- so a Lua pre-hook cannot
-- out-vote the suppression for the same call, and a per-draw rename
-- sandwich cannot work either. Instead: rename persistently while the
-- screen is up (first sighting in our own pre-gui-draw hook -- which fires
-- even for suppressed elements), restore automatically once the element
-- stops being sighted for RESTORE_AFTER_S (screen closed), on toggle-off,
-- and on script reset.
--
-- Expected first-test outcome is praydog's "weird buggy overlay", NOT
-- necessarily a clean backdrop -- but anything visible beats the void, and
-- once the element actually draws, the previously-"inert" blur/tint fields
-- (all confirmed to write correctly) become live tuning levers.

if reframework:get_game_name() ~= "re2" then
    return
end

local ORIGINAL_NAME = "GuiBack"
local BYPASS_NAME = "GuiBackU" -- any name whose fnv hash differs works

-- How long after the last sighting (screen closed, element no longer being
-- dispatched) before the original name is written back.
local RESTORE_AFTER_S = 1.0

local state = {
    enabled = true,
    set_name_ok = nil, -- nil = not yet checked, then true/false
    renamed = {}, -- go -> true, objects currently carrying BYPASS_NAME
    renamed_count = 0,
    rename_events = 0,
    restore_events = 0,
    last_seen_t = 0.0,
    draw_sightings = 0, -- sightings of the RENAMED element (VR no longer culling by name)
}

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

local function hmd_active()
    if not vrmod or type(vrmod.is_hmd_active) ~= "function" then return false end
    local ok, active = pcall(vrmod.is_hmd_active, vrmod)
    return ok and active or false
end

-- One-time check that via.GameObject actually exposes set_Name in this
-- build's TDB (REFramework's own get_name() prefers the reflected get_Name,
-- so the property family should exist -- but verify before use).
local function check_set_name(go)
    if state.set_name_ok ~= nil then return state.set_name_ok end
    local m = safe(function()
        return go:get_type_definition():get_method("set_Name")
    end)
    state.set_name_ok = (m ~= nil)
    if not state.set_name_ok then
        log.info("[bg_unhide] via.GameObject.set_Name NOT in TDB -- feature disabled, needs the raw-field fallback instead")
    end
    return state.set_name_ok
end

local function set_go_name(go, name)
    return pcall(function() go:call("set_Name", name) end)
end

local function restore_all(reason)
    for go, _ in pairs(state.renamed) do
        local ok = set_go_name(go, ORIGINAL_NAME)
        if ok then
            state.restore_events = state.restore_events + 1
        end
    end
    if state.renamed_count > 0 then
        log.info("[bg_unhide] restored " .. tostring(state.renamed_count) .. " GuiBack name(s) (" .. reason .. ")")
    end
    state.renamed = {}
    state.renamed_count = 0
end

re.on_pre_gui_draw_element(function(element, context)
    if not state.enabled then return true end

    -- pcall-hardened like re2_vr_crosshair.lua: during UI teardown
    -- get_GameObject on a dying element throws.
    local ok_go, go = pcall(function() return element:call("get_GameObject") end)
    if not ok_go or go == nil then return true end

    local ok_n, name = pcall(function() return go:call("get_Name") end)
    if not ok_n or name == nil then return true end

    if name == ORIGINAL_NAME then
        if not hmd_active() then return true end
        if not check_set_name(go) then return true end

        if set_go_name(go, BYPASS_NAME) then
            state.renamed[go] = true
            state.renamed_count = state.renamed_count + 1
            state.rename_events = state.rename_events + 1
            state.last_seen_t = os.clock()
            log.info("[bg_unhide] GuiBack sighted + renamed to " .. BYPASS_NAME .. " (VR suppression bypassed from next frame)")
        else
            log.info("[bg_unhide] set_Name call FAILED on GuiBack")
        end
    elseif name == BYPASS_NAME then
        -- Renamed element being dispatched; VR's name filter is missing it.
        state.last_seen_t = os.clock()
        state.draw_sightings = state.draw_sightings + 1
    end

    return true
end)

re.on_frame(function()
    if state.renamed_count == 0 then return end

    local stale = (os.clock() - state.last_seen_t) > RESTORE_AFTER_S
    if stale or not state.enabled or not hmd_active() then
        restore_all(stale and "screen closed" or "disabled/HMD off")
    end
end)

re.on_script_reset(function()
    restore_all("script reset")
end)

re.on_draw_ui(function()
    if imgui.tree_node("Inventory BG Unhide (VR)") then
        local changed
        changed, state.enabled = imgui.checkbox("Enable (un-hide GuiBack backdrop in VR)", state.enabled)

        if state.set_name_ok == false then
            imgui.text_colored("via.GameObject.set_Name missing from TDB -- feature inert", 0xFF4040FF)
        end

        imgui.text("Currently renamed: " .. tostring(state.renamed_count))
        imgui.text("Rename events: " .. tostring(state.rename_events) .. "  Restore events: " .. tostring(state.restore_events))
        imgui.text("Renamed-element draw sightings: " .. tostring(state.draw_sightings))
        if state.last_seen_t > 0 then
            imgui.text(string.format("Last sighting: %.1fs ago", os.clock() - state.last_seen_t))
        end
        imgui.tree_pop()
    end
end)

log.info("[bg_unhide] loaded (enabled=" .. tostring(state.enabled) .. ")")
