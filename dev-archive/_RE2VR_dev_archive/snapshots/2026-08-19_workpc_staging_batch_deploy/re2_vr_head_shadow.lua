-- re2_vr_head_shadow.lua
--
-- Goal: head shadow WITHOUT a visible head in VR.
--
-- Technique (proven in praydog's own REFramework source, src/mods/vr/games/RE8VR.cpp
-- fix_player_shadow()): via.render.Mesh has independent per-pass draw flags --
--   set_DrawDefault(bool)     -> draw in the normal camera view
--   set_DrawShadowCast(bool)  -> draw into the shadow pass
-- RE8VR sets DrawDefault=false + DrawShadowCast=true on the real body meshes to make
-- them invisible to the HMD while their shadows keep rendering. This script applies
-- the same flags to RE2's player Face/Hair mesh GameObjects (separate GameObjects
-- from Body, confirmed in the 2026-08-11 mesh-swap investigation).
--
-- IMPORTANT: REFramework's FirstPerson "Hide Joint Mesh" option must be OFF for this
-- to work. That option zeroes the head bone matrix (FirstPerson.cpp,
-- update_player_bones), which collapses the head geometry in EVERY render pass,
-- shadow map included -- no mesh flag can bring the shadow back while that is on.
--
-- Enable checkbox is OFF by default (project convention). No config persistence yet.

local RE2 = require("utility/RE2")
local GameObject = require("utility/GameObject")

local log_prefix = "[head_shadow]"

local function logmsg(msg)
    log.info(log_prefix .. " " .. msg)
end

--------------------------------------------------------------------------------
-- One-time reflection check: do the needed methods exist on RE2's via.render.Mesh?
--------------------------------------------------------------------------------
local api = nil -- nil = not checked yet; table = checked

local function check_mesh_api()
    if api ~= nil then return api end

    api = { ok = false, has_raytracing = false, reason = "" }

    local ok_td, td = pcall(function() return sdk.find_type_definition("via.render.Mesh") end)
    if not ok_td or td == nil then
        api.reason = "via.render.Mesh type definition not found"
        logmsg(api.reason)
        return api
    end

    local function has_method(name)
        local ok, m = pcall(function() return td:get_method(name) end)
        return ok and m ~= nil
    end

    local need = { "set_DrawDefault", "get_DrawDefault", "set_DrawShadowCast", "get_DrawShadowCast" }
    local missing = {}
    for _, name in ipairs(need) do
        if not has_method(name) then table.insert(missing, name) end
    end

    if #missing > 0 then
        api.reason = "missing on via.render.Mesh: " .. table.concat(missing, ", ")
        logmsg("APPROACH BLOCKED -- " .. api.reason)
        -- Dump every Draw/Shadow/Hide-ish method so the next session has real data
        -- for an alternative flag instead of guessing.
        local ok_m, methods = pcall(function() return td:get_methods() end)
        if ok_m and methods then
            logmsg("-- all via.render.Mesh methods matching draw/shadow/hide/enable/parts/material --")
            for _, m in ipairs(methods) do
                local ok_n, mname = pcall(function() return m:get_name() end)
                if ok_n and mname then
                    local l = mname:lower()
                    if l:find("draw") or l:find("shadow") or l:find("hide")
                        or l:find("enable") or l:find("parts") or l:find("material") then
                        local ok_p, np = pcall(function() return m:get_num_params() end)
                        logmsg("  " .. mname .. " (params: " .. tostring(ok_p and np or "?") .. ")")
                    end
                end
            end
        end
        return api
    end

    api.ok = true
    api.has_raytracing = has_method("set_DrawRaytracing") and has_method("get_DrawRaytracing")
    logmsg("via.render.Mesh API confirmed: DrawDefault + DrawShadowCast present"
        .. (api.has_raytracing and " (+ DrawRaytracing)" or " (no DrawRaytracing)"))
    return api
end

--------------------------------------------------------------------------------
-- Player mesh discovery (same hierarchy walk proven in re2_vr_mesh_swap_probe.lua)
--------------------------------------------------------------------------------
local state = {
    enabled = false,
    show_in_cutscenes = true,
    hide_in_raytracing = true,   -- only used if the RT flag exists
    meshes = {},                 -- { name, comp, hide (bool), orig (table|nil), applied (bool) }
    last_scan = 0.0,
    scan_generation = 0,
    status = "idle",
    restored_for_cutscene = false,
}

-- Everything head-ish. Eyelashes/eyebrows/eyes/beards are frequently their own
-- mesh GameObjects on RE Engine characters (confirmed live 2026-08-19: eyelashes
-- kept blinking in view after Face+Hair were hidden), so match wide. Deliberately
-- NOT matched: body, arms, weapon-ish names.
local HIDE_NAME_PATTERNS = {
    "face", "hair", "head",
    "eye",   -- also catches eyelash/eyebrow/eyelid namings
    "lash", "brow", "matsuge", -- matsuge = eyelash in Capcom's Japanese naming
    "beard", "mustache", "hige",
    "tooth", "teeth", "tongue",
}

local function default_hide_for_name(name)
    local l = tostring(name):lower()
    for _, pat in ipairs(HIDE_NAME_PATTERNS) do
        if l:find(pat, 1, true) ~= nil then return true end
    end
    return false
end

local function get_children(transform)
    local children = {}
    if transform == nil then return children end
    local ok, first = pcall(function() return transform:call("get_Child") end)
    if not ok or first == nil then return children end
    local cur = first
    local guard = 0
    while cur ~= nil and guard < 500 do
        table.insert(children, cur)
        local ok2, nxt = pcall(function() return cur:call("get_Next") end)
        if not ok2 then break end
        cur = nxt
        guard = guard + 1
    end
    return children
end

local function component_type_name(comp)
    local ok, td = pcall(function() return comp:get_type_definition() end)
    if not ok or td == nil then return "?" end
    local ok2, name = pcall(function() return td:get_full_name() end)
    return (ok2 and name) or "?"
end

-- Collect EVERY via.render.Mesh component on every GameObject under the player.
-- (getComponent() only returns the first one per GameObject -- a GameObject can
-- carry several mesh components, and eyelash/eye meshes may be exactly that.)
local function walk_for_meshes(transform, depth, results)
    if transform == nil or depth > 12 then return end

    local ok_go, go = pcall(function() return transform:call("get_GameObject") end)
    if ok_go and go ~= nil then
        local ok_name, name = pcall(function() return go:call("get_Name") end)
        name = (ok_name and name) or "?"

        local ok_c, comps = pcall(function() return GameObject.get_components(go) end)
        if ok_c and comps then
            local idx = 0
            for _, comp in ipairs(comps) do
                if component_type_name(comp) == "via.render.Mesh" then
                    idx = idx + 1
                    local label = tostring(name)
                    if idx > 1 then label = label .. " (mesh #" .. idx .. ")" end
                    table.insert(results, { name = label, comp = comp })
                end
            end
        end
    end

    for _, child in ipairs(get_children(transform)) do
        walk_for_meshes(child, depth + 1, results)
    end
end

-- Restore a single mesh entry's original flags (best effort, guarded).
local function restore_mesh(entry)
    if not entry.applied or entry.orig == nil then return end
    pcall(function() entry.comp:call("set_DrawDefault", entry.orig.draw_default) end)
    pcall(function() entry.comp:call("set_DrawShadowCast", entry.orig.draw_shadow) end)
    if entry.orig.draw_rt ~= nil then
        pcall(function() entry.comp:call("set_DrawRaytracing", entry.orig.draw_rt) end)
    end
    entry.applied = false
end

local function restore_all()
    for _, entry in ipairs(state.meshes) do
        restore_mesh(entry)
    end
end

local function rescan()
    -- Put everything back on the OLD components before dropping them, so a stale
    -- hidden mesh can't get orphaned in the invisible state across a rescan.
    restore_all()
    state.meshes = {}
    state.scan_generation = state.scan_generation + 1

    local player = RE2.get_localplayer()
    if player == nil then
        state.status = "no player (menu/loading?)"
        return false
    end

    local ok_tf, root_tf = pcall(function() return player:call("get_Transform") end)
    if not ok_tf or root_tf == nil then
        state.status = "player has no Transform"
        return false
    end

    local found = {}
    walk_for_meshes(root_tf, 0, found)

    for _, f in ipairs(found) do
        table.insert(state.meshes, {
            name = f.name,
            comp = f.comp,
            hide = default_hide_for_name(f.name),
            orig = nil,
            applied = false,
        })
    end

    state.status = "found " .. tostring(#state.meshes) .. " mesh GameObjects"
    logmsg("rescan (gen " .. state.scan_generation .. "): " .. state.status)
    for _, e in ipairs(state.meshes) do
        logmsg("  mesh go=" .. e.name .. (e.hide and "  [target: will hide]" or ""))
    end
    return #state.meshes > 0
end

-- Apply the invisible-but-shadow-casting flags to one entry. Returns false if the
-- component reference went stale (component call failed) -> caller should rescan.
local function apply_mesh(entry)
    -- Capture originals once, before the first write.
    if entry.orig == nil then
        local ok_d, d = pcall(function() return entry.comp:call("get_DrawDefault") end)
        local ok_s, s = pcall(function() return entry.comp:call("get_DrawShadowCast") end)
        if not ok_d or not ok_s then return false end
        local rt = nil
        if api.has_raytracing then
            local ok_rt, v = pcall(function() return entry.comp:call("get_DrawRaytracing") end)
            if ok_rt then rt = v end
        end
        entry.orig = { draw_default = d, draw_shadow = s, draw_rt = rt }
        logmsg("captured originals for " .. entry.name
            .. ": DrawDefault=" .. tostring(d) .. " DrawShadowCast=" .. tostring(s)
            .. " DrawRaytracing=" .. tostring(rt))
    end

    local ok1 = pcall(function() entry.comp:call("set_DrawDefault", false) end)
    local ok2 = pcall(function() entry.comp:call("set_DrawShadowCast", true) end)
    local ok3 = true
    if api.has_raytracing and state.hide_in_raytracing then
        ok3 = pcall(function() entry.comp:call("set_DrawRaytracing", false) end)
    end
    entry.applied = ok1 and ok2 and ok3
    return entry.applied
end

local function is_cutscene()
    local fn = rawget(_G, "__vr_is_cinematic_blocking")
    if type(fn) ~= "function" then return false end
    local ok, v = pcall(fn)
    return ok and v == true
end

--------------------------------------------------------------------------------
-- Per-frame driver
--------------------------------------------------------------------------------
local was_enabled = false

re.on_frame(function()
    local a = check_mesh_api()
    if not a.ok then return end

    if not state.enabled then
        if was_enabled then
            restore_all()
            state.status = "disabled, originals restored"
        end
        was_enabled = false
        return
    end
    was_enabled = true

    -- While re2_vr_menu_hide_player.lua has the whole player hidden for a menu
    -- screen, stand down: re-asserting DrawShadowCast=true on the head mid-menu
    -- would paint a floating head shadow into the menu background and fight that
    -- script's capture/restore bookkeeping.
    if rawget(_G, "__vr_menu_player_hidden") == true then return end

    -- Cutscene handling: give the game its real, fully visible head back so
    -- third-person cutscenes look right, then re-apply afterwards.
    if state.show_in_cutscenes and is_cutscene() then
        if not state.restored_for_cutscene then
            restore_all()
            state.restored_for_cutscene = true
            state.status = "cutscene -- head restored"
        end
        return
    end
    state.restored_for_cutscene = false

    -- Rescan when we have nothing, at most every 2s (avoids per-frame walk + log
    -- spam during menus/loading). Steady-state validity is checked cheaply below
    -- via the guarded calls themselves.
    local now = os.clock()
    if #state.meshes == 0 then
        if (now - state.last_scan) > 2.0 then
            rescan()
            state.last_scan = now
        else
            return
        end
    end

    local any_stale = false
    local applied_count = 0
    for _, entry in ipairs(state.meshes) do
        if entry.hide then
            if apply_mesh(entry) then
                applied_count = applied_count + 1
            else
                any_stale = true
            end
        elseif entry.applied then
            -- User un-ticked this one in the panel -- put it back.
            restore_mesh(entry)
        end
    end

    if any_stale then
        -- Component references died (level load / character swap) -- drop and redo.
        state.meshes = {}
        state.status = "stale mesh refs, rescanning"
    elseif applied_count > 0 then
        state.status = "active on " .. applied_count .. " mesh(es)"
    end
end)

-- Put the real flags back if scripts get reset while we're mid-hide, so the head
-- can't get stuck invisible with no script left to restore it.
re.on_script_reset(function()
    restore_all()
end)

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.tree_node("Head Shadow (invisible head, real shadow)") then return end

    local a = check_mesh_api()
    if not a.ok then
        imgui.text("NOT AVAILABLE in this build: " .. tostring(a.reason))
        imgui.text("A method dump was written to re2_framework_log.txt (" .. log_prefix .. ").")
        imgui.tree_pop()
        return
    end

    imgui.text("Hides Face/Hair from the camera but keeps them in the shadow pass")
    imgui.text("(same DrawDefault/DrawShadowCast trick praydog's RE8 VR code uses).")
    imgui.text("REQUIRED: turn OFF 'Hide Joint Mesh' in REFramework's FirstPerson")
    imgui.text("section first -- that option kills the shadow at the bone level.")

    local changed
    changed, state.enabled = imgui.checkbox("Enable", state.enabled)
    changed, state.show_in_cutscenes = imgui.checkbox("Restore full head during cutscenes", state.show_in_cutscenes)
    if a.has_raytracing then
        changed, state.hide_in_raytracing = imgui.checkbox("Also hide head in ray-traced reflections", state.hide_in_raytracing)
    end

    imgui.text("Status: " .. tostring(state.status))

    if imgui.button("Rescan player meshes now") then
        rescan()
    end

    if #state.meshes > 0 and imgui.tree_node("Player mesh GameObjects found (tick = hide from view)") then
        for i, entry in ipairs(state.meshes) do
            local label = entry.name .. "##headshadow" .. tostring(i)
            local ch, v = imgui.checkbox(label, entry.hide)
            if ch then entry.hide = v end

            -- Live readback for EVERY entry, so it's obvious which meshes are
            -- actually hidden vs. still drawing (DrawDefault=true means visible).
            local okd, d = pcall(function() return entry.comp:call("get_DrawDefault") end)
            local oks, s = pcall(function() return entry.comp:call("get_DrawShadowCast") end)
            imgui.same_line()
            imgui.text(" | view=" .. tostring(okd and d or "?")
                .. " shadow=" .. tostring(oks and s or "?")
                .. ((entry.hide and not entry.applied) and "  [APPLY FAILED]" or ""))
        end
        imgui.tree_pop()
    end

    if imgui.button("Dump full state to log") then
        logmsg("=== state dump ===")
        logmsg("enabled=" .. tostring(state.enabled) .. " status=" .. tostring(state.status))
        for _, entry in ipairs(state.meshes) do
            local okd, d = pcall(function() return entry.comp:call("get_DrawDefault") end)
            local oks, s = pcall(function() return entry.comp:call("get_DrawShadowCast") end)
            logmsg(string.format("  go=%s hide=%s applied=%s DrawDefault=%s DrawShadowCast=%s",
                entry.name, tostring(entry.hide), tostring(entry.applied),
                tostring(okd and d or "?"), tostring(oks and s or "?")))
        end
        logmsg("=== end state dump ===")
    end

    imgui.tree_pop()
end)

logmsg("loaded")
