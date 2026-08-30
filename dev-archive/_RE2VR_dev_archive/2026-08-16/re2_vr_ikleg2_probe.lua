-- Diagnostic for the residual footstep-synced sway banked in
-- re2_vr_torso_twist_status.md / re2_vr_laser_sight_drift_status.md
-- (2026-08-16): every joint from root down through spine_2, plus legs, was
-- rotation-freeze-tested and ruled out -- the sway is NOT any joint's
-- rotation. Leading theory: a POSITIONAL adjustment, in sync with footsteps.
--
-- New lead (2026-08-16, found via Ghidrust static analysis of re2.exe, not
-- guesswork): the engine ships a native `via.motion.IkLeg2` component whose
-- own registered controls include CenterAdjust, CenterStabilizing, Lean,
-- CenterDistance, FootLock -- i.e. a leg-IK solver that SHIFTS THE
-- CHARACTER'S CENTER based on foot placement every frame. A center shift is
-- a position change, not a joint rotation, so the entire joint-freeze
-- elimination pass would have been blind to it by construction -- exactly the
-- profile of the unexplained residual sway. (`via.motion.IkSpine` /
-- `IkSpineConformGround` with COG_MANAGE_TYPE also exist in the binary --
-- the scan below finds whichever of these the player actually carries
-- instead of assuming.)
--
-- What this probe does:
--   1. "Scan player for Ik components" -- enumerates the player GameObject's
--      real component list and shows every component whose type name
--      contains "Ik"/"IK". No assumptions about which IK classes this game
--      actually put on the survivor.
--   2. Per found component: an Enabled checkbox (live set_Enabled A/B --
--      the ONE write this probe can do, opt-in, per component, reversible)
--      and a "Dump" button (full unfiltered field+method dump with live
--      values, same discipline as re2_vr_laser_dot_probe.lua's
--      LaserSightController dump -- read what's really there, don't guess
--      member names from the binary strings).
--
-- A/B method, same as every confirmed test this session: walk in place with
-- spine correction ON, watch the sway, toggle a component off, watch again.
-- If disabling IkLeg2 (or whichever center-managing component turns up)
-- kills the sway, that's the source -- then the REAL fix is the narrow knob
-- (center-adjust off) rather than the whole component, via whatever
-- fields/methods the dump reveals. Pairs with re2_vr_camera_position_probe's
-- read-only capture for quantified confirmation.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")

local state = {
    comps = {},              -- { {comp, tname, enabled_ui} }
    last_scan_msg = "not scanned yet",
    last_dump_msg = "",
}

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

local function scan_ik_components()
    state.comps = {}
    local player = re2.get_localplayer()
    if not player then
        state.last_scan_msg = "no player (load into gameplay first)"
        return
    end
    -- get_Components via direct-call + get_elements() -- the exact pattern
    -- proven in re2_vr_laser_dot_probe.lua's hierarchy dump (and the exact
    -- :call("get_elements") mistake documented there, not repeated here).
    local components = safe(function()
        local list = player:call("get_Components")
        return list and list:get_elements()
    end)
    if not components then
        state.last_scan_msg = "get_Components returned nothing"
        return
    end
    local total = 0
    for _, comp in ipairs(components) do
        total = total + 1
        local tdef = safe(function() return comp:get_type_definition() end)
        local tname = tdef and safe(function() return tdef:get_full_name() end)
        if tname and (tname:find("Ik") or tname:find("IK")) then
            local enabled = safe(function() return comp:call("get_Enabled") end)
            table.insert(state.comps, {
                comp = comp,
                tname = tname,
                enabled_ui = enabled ~= false, -- nil (no get_Enabled) shows as on
            })
            log.info(string.format("[ikleg2_probe] found IK component: %s (Enabled=%s)",
                tname, tostring(enabled)))
        end
    end
    state.last_scan_msg = string.format("%d components on player, %d IK-named (see log)",
        total, #state.comps)
    log.info("[ikleg2_probe] " .. state.last_scan_msg)
end

local function dump_component(entry)
    local lines = {}
    table.insert(lines, "=== DUMP: " .. entry.tname .. " ===")
    local tdef = safe(function() return entry.comp:get_type_definition() end)
    local depth = 0
    while tdef and depth < 6 do
        local tname = safe(function() return tdef:get_full_name() end) or "?"
        table.insert(lines, string.format("== L%d: %s ==", depth, tname))

        local fields = safe(function() return tdef:get_fields() end) or {}
        for _, f in ipairs(fields) do
            local fname = safe(function() return f:get_name() end)
            local is_static = safe(function() return f:is_static() end)
            local ok_v, value
            if is_static then
                ok_v, value = pcall(function() return f:get_data(nil) end)
            else
                ok_v, value = pcall(function() return f:get_data(entry.comp) end)
            end
            table.insert(lines, string.format("  [field] %s = %s", fname or "?",
                ok_v and tostring(value) or "(unreadable)"))
        end

        local methods = safe(function() return tdef:get_methods() end) or {}
        for _, m in ipairs(methods) do
            local mname = safe(function() return m:get_name() end)
            if mname then table.insert(lines, "  [method] " .. mname) end
        end

        tdef = safe(function() return tdef:get_parent_type() end)
        depth = depth + 1
    end
    for _, l in ipairs(lines) do
        log.info("[ikleg2_probe] " .. l)
    end
    state.last_dump_msg = string.format("dumped %s (%d lines, grep [ikleg2_probe])",
        entry.tname, #lines)
end

re.on_draw_ui(function()
    if not imgui then return end
    if not imgui.tree_node("IkLeg2 / IK Component Probe (diagnostic)") then return end

    imgui.text("Residual-sway lead: via.motion.IkLeg2 CenterAdjust/Lean (found via")
    imgui.text("static analysis of re2.exe) shifts the body CENTER per footstep --")
    imgui.text("a position change no joint-rotation freeze could ever catch.")
    imgui.text_colored(
        "A/B: walk in place w/ spine correction ON, toggle a component off, compare sway.",
        0xFF88CCFF)

    imgui.spacing()
    if imgui.button("Scan player for Ik components") then
        scan_ik_components()
    end
    imgui.text(state.last_scan_msg)

    imgui.spacing()
    imgui.separator()
    for i, entry in ipairs(state.comps) do
        local changed, val = imgui.checkbox(
            string.format("Enabled##ik%d", i), entry.enabled_ui)
        if changed then
            local ok = pcall(function() entry.comp:call("set_Enabled", val) end)
            if ok then
                entry.enabled_ui = val
                log.info(string.format("[ikleg2_probe] set_Enabled(%s) on %s",
                    tostring(val), entry.tname))
            else
                log.info("[ikleg2_probe] set_Enabled FAILED on " .. entry.tname)
            end
        end
        imgui.text("    " .. entry.tname)
        if imgui.button(string.format("Dump fields+methods##ik%d", i)) then
            dump_component(entry)
        end
    end
    if #state.comps == 0 then
        imgui.text("(no components listed -- scan first)")
    end

    if state.last_dump_msg ~= "" then
        imgui.spacing()
        imgui.text(state.last_dump_msg)
    end

    imgui.tree_pop()
end)

log.info("[re2_vr_ikleg2_probe] Loaded")
