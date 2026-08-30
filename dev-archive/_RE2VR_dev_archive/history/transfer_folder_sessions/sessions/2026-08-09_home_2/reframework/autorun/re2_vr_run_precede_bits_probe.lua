-- One-shot, read-only diagnostic for the run-toggle fix's real blocker.
--
-- Confirmed live (2026-08-09): re2_vr_run_toggle_fix.lua's approach --
-- un-inhibiting the native JOG petient order via
-- PlayerActionOrderer:setInhibitPetient(false, JOG) -- does NOT make the
-- character actually start jogging. Root cause: "inhibit" only BLOCKS or
-- PERMITS an order that something else has to independently REQUEST first.
-- Nothing in the VR control path currently requests a JOG order (there's no
-- native keyboard/gamepad "hold to run" input being fed in VR), so
-- un-inhibiting an order nobody's asking for does nothing.
--
-- Real lead: re2_vr_holster.lua's flashlight-toggle feature already found a
-- genuine way to simulate a native input request through this same
-- ActionOrderer -- its <PrecedeBits>k__BackingField field exposes a
-- set_Accept(64) method that simulates the manual flashlight-switch button
-- press (see vr_flash_pulse_toggle in that file). That strongly suggests
-- PrecedeBits has other named "set_X" bit-setters for other actions,
-- possibly including jog/run. This probe dumps the full reflected method
-- list for both the ActionOrderer itself (in case there's a more direct
-- "request this order" method beyond setInhibitPetient) and PrecedeBits, so
-- the right one can be identified before guessing at a raw bit value --
-- same "observe first" pattern used successfully elsewhere in this project.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

local survivor_condition_type = sdk.typeof(NS("survivor.SurvivorCondition"))
local dumped = false

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

-- (2026-08-10) Extended: hunting for where the native "Run Type"
-- (Toggle/Hold/Always) OPTIONS MENU setting is stored, so it can potentially
-- be force-set on load and skip a manual settings-menu step for players.
-- Not found anywhere on SurvivorCondition/PlayerController/PlayerActionOrderer
-- via their get_/is_-style methods (already fully dumped by
-- re2_vr_run_state_probe.lua) -- dumping raw FIELDS here instead, in case
-- it's a plain field with no get_/set_ accessor pair, same technique
-- re2_vr_holster.lua's build_weapon_type_maps() already uses successfully.
local function dump_fields(tag, obj)
    if not obj then return end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then return end
    local fields = safe(function() return td:get_fields() end)
    if not fields then return end
    for _, f in ipairs(fields) do
        local ok_static, is_static = pcall(function() return f:is_static() end)
        if ok_static and not is_static then
            local fname = safe(function() return f:get_name() end)
            if fname then
                local ok_v, v = pcall(function() return f:get_data(obj) end)
                log.info(string.format("[run_precede_probe]   %s field: %s = %s",
                    tag, fname, ok_v and tostring(v) or "?"))
            end
        end
    end
end

local function dump_methods(tag, obj)
    if not obj then
        log.info("[run_precede_probe] " .. tag .. ": nil")
        return
    end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then
        log.info("[run_precede_probe] " .. tag .. ": not a reflectable managed object")
        return
    end
    local name = safe(function() return td:get_full_name() end)
    log.info("[run_precede_probe] " .. tag .. " type: " .. tostring(name))
    local methods = safe(function() return td:get_methods() end)
    if not methods then return end
    for _, m in ipairs(methods) do
        local mname = safe(function() return m:get_name() end)
        if mname then
            log.info("[run_precede_probe]   " .. tag .. " method: " .. mname)
        end
    end
end

-- (2026-08-10) ActionOrderer has no RunType/RunKind field of its own --
-- just Hold-mode timer objects (HoldJogDeferTimer/HoldJogExtendTimer/
-- ForbidHoldDeferTimer) it uses internally once it already knows the mode.
-- The actual Options -> Controls -> Run Type preference must live
-- elsewhere. Checking GUIMaster next -- already a known-accessible
-- singleton in this mod (re2_vr_holster.lua reads its RefInventoryUI
-- field), so a real lead worth checking before guessing at brand new
-- singleton type names.
local gm_dumped = false
local function dump_guimaster_fields()
    if gm_dumped then return end
    local gm = safe(function() return sdk.get_managed_singleton(sdk.game_namespace("gui.GUIMaster")) end)
    if not gm then
        log.info("[run_precede_probe] GUIMaster: singleton not found")
        return
    end
    gm_dumped = true
    log.info("[run_precede_probe] --- GUIMaster fields (filtering for Option/Config/Setting/Run) ---")
    local td = safe(function() return gm:get_type_definition() end)
    if not td then return end
    local fields = safe(function() return td:get_fields() end)
    if not fields then return end
    for _, f in ipairs(fields) do
        local ok_static, is_static = pcall(function() return f:is_static() end)
        if ok_static and not is_static then
            local fname = safe(function() return f:get_name() end)
            if fname and fname:lower():find("option") or (fname and fname:lower():find("config"))
                or (fname and fname:lower():find("setting")) or (fname and fname:lower():find("run")) then
                local ok_v, v = pcall(function() return f:get_data(gm) end)
                log.info(string.format("[run_precede_probe]   GUIMaster field: %s = %s", fname, ok_v and tostring(v) or "?"))
            end
        end
    end
    log.info("[run_precede_probe] --- end GUIMaster field scan ---")

    -- (2026-08-10) RefOptionUI/RefOptionResult turned out to be plain
    -- via.GameObject containers -- generic create/destroy/getComponent
    -- plumbing, nothing options-specific on the GameObject itself. The real
    -- data must live on a COMPONENT attached to them. Using this project's
    -- existing GameObject.get_components() helper (same one
    -- re2_vr_posture_twist_probe.lua used successfully for exactly this
    -- kind of "what's actually attached here" question) to list what's
    -- attached before drilling into any one of them.
    local GameObject = require("utility/GameObject")
    local function dump_components(tag, go)
        if not go then return end
        local ok, components = pcall(function() return GameObject.get_components(go) end)
        if not ok or not components then
            log.info("[run_precede_probe] " .. tag .. ": get_components failed")
            return
        end
        for _, comp in ipairs(components) do
            local td = safe(function() return comp:get_type_definition() end)
            local name = td and safe(function() return td:get_full_name() end) or nil
            log.info("[run_precede_probe]   " .. tag .. " component: " .. tostring(name))
        end
    end

    local ref_option_ui = safe(function() return gm:get_field("RefOptionUI") end)
    local ref_option_result = safe(function() return gm:get_field("RefOptionResult") end)
    log.info("[run_precede_probe] --- RefOptionUI components ---")
    dump_components("RefOptionUI", ref_option_ui)
    log.info("[run_precede_probe] --- RefOptionResult components ---")
    dump_components("RefOptionResult", ref_option_result)

    -- (2026-08-10) Found the real candidates: app.ropeway.gui.OptionBehavior
    -- (on RefOptionUI) and app.ropeway.gui.OptionResultBehavior (on
    -- RefOptionResult) -- dump both fully now.
    local option_behavior_type = sdk.typeof(NS("gui.OptionBehavior"))
    local option_result_type = sdk.typeof(NS("gui.OptionResultBehavior"))
    local ob = ref_option_ui and option_behavior_type and safe(function()
        return ref_option_ui:call("getComponent(System.Type)", option_behavior_type)
    end) or nil
    local orb = ref_option_result and option_result_type and safe(function()
        return ref_option_result:call("getComponent(System.Type)", option_result_type)
    end) or nil
    dump_methods("OptionBehavior", ob)
    dump_fields("OptionBehavior", ob)
    dump_methods("OptionResultBehavior", orb)
    dump_fields("OptionResultBehavior", orb)

    -- (2026-08-10) OptionResultBehavior is graphics/memory display, a dead
    -- end. OptionBehavior.ControlsCommandList is the real lead -- almost
    -- certainly the live list of entries in the Controls options tab,
    -- Run Type among them. Try the same :get_elements() collection pattern
    -- utility/GameObject.lua already uses successfully for get_Components();
    -- if that doesn't resolve, fall back to dumping the collection object's
    -- own methods so the right accessor can be found next.
    local controls_list = ob and safe(function() return ob:get_field("ControlsCommandList") end) or nil
    if controls_list then
        -- Standard System.Collections.Generic.List<T> -- 0-indexed
        -- get_Count/get_Item, not the get_elements() convenience wrapper
        -- (that's specific to via.gui component collections, confirmed not
        -- available here).
        local count = safe(function() return controls_list:call("get_Count") end)
        log.info("[run_precede_probe] --- ControlsCommandList: " .. tostring(count) .. " nodes ---")
        if type(count) == "number" then
            for i = 0, count - 1 do
                local node = safe(function() return controls_list:call("get_Item", i) end)
                if node then
                    local td = safe(function() return node:get_type_definition() end)
                    local tname = td and safe(function() return td:get_full_name() end) or "?"
                    log.info(string.format("[run_precede_probe]   [%d] type=%s", i, tostring(tname)))
                    dump_fields("ControlsCommandList[" .. i .. "]", node)
                end
            end
        end
        log.info("[run_precede_probe] --- end ControlsCommandList ---")
    end
end

re.on_frame(function()
    if dumped then return end
    dump_guimaster_fields()
    local player = re2.get_localplayer()
    if not player then return end
    local cond = safe(function() return player:call("getComponent(System.Type)", survivor_condition_type) end)
    if not cond then return end
    local ao = safe(function() return cond:call("get_ActionOrderer") end)
    if not ao then return end

    dumped = true
    log.info("[run_precede_probe] --- dump start ---")
    dump_methods("ActionOrderer", ao)
    dump_fields("ActionOrderer", ao)
    local bits = safe(function() return ao:get_field("<PrecedeBits>k__BackingField") end)
    dump_methods("PrecedeBits", bits)
    dump_fields("PrecedeBits", bits)
    log.info("[run_precede_probe] --- dump end ---")
end)

log.info("[re2_vr_run_precede_bits_probe] Loaded -- dumps automatically once a player is found")
