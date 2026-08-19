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
    show_when_camera_leaves_head = true,  -- master switch for the reveal behaviour
    reveal_on_grab = true,                -- JackDominator.get_Jacked -- zombie grabs only
    reveal_on_distance = false,           -- camera-far fallback (off: never fired in testing)
    head_reveal_distance_m = 0.35,        -- camera-to-head distance that counts as "not first person"
    restore_tail_s = 0.3,                 -- hold the head back this long after the trigger drops
    player_addr = nil,                    -- identity of the player the mesh list belongs to
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

-- Loading a save swaps the player out. Comparing the player object's address
-- catches that only when the new object lands somewhere else in memory -- load a
-- save while alive and the freed slot is often reused, so the address is
-- identical and the check sails straight past it. Watch the load itself instead:
-- same getters re2_vr_reload.lua uses for its save/load transition test.
local load_watch = { was_busy = false }

local function is_load_busy()
    local mgr = sdk.get_managed_singleton(sdk.game_namespace("gamemastering.SaveDataManager"))
    if mgr ~= nil then
        local ok, v = pcall(function() return mgr:call("get_IsLoadBusy") end)
        if ok and v == true then return true end
    end
    local mfm = sdk.get_managed_singleton(sdk.game_namespace("gamemastering.MainFlowManager"))
    if mfm ~= nil then
        for _, getter in ipairs({ "get_IsInLoadGameData", "get_IsLoadGame" }) do
            local ok, v = pcall(function() return mfm:call(getter) end)
            if ok and v == true then return true end
        end
    end
    return false
end

-- Grab/bite animations swing the view off the player's head onto their body,
-- where a hidden head reads as a decapitated character. Rather than guess at
-- which game states do that, test the thing that actually decides it: how far
-- the camera is from the head joint.
--
-- A damage flag (SurvivorCondition.get_IsDamage) was tried first and rejected --
-- it is true for ANY hit, so an ordinary Mr. X punch or Licker swipe that never
-- leaves first person would have popped the head on with the camera still inside
-- the skull. Distance can't make that mistake: in first person the camera sits on
-- the head (small distance, stay hidden), and it only grows when the view has
-- genuinely pulled away, whatever caused it.
--
-- Joint name "head" is what REFramework's own FirstPerson.cpp hashes and looks up
-- for RE2 (FirstPerson.cpp:1294); the rest are fallbacks.
local HEAD_JOINT_CANDIDATES = { "head", "Head", "head_0", "neck_1" }

local head_view = { seen_ok = false, last_far = 0.0, last_dist = -1.0, joint_name = nil,
                    fail = "none", last_fail_log = 0.0, jacked = false, jack_src = "none" }

-- Precise grab detector. RE Engine calls being grabbed/held "jacked", and
-- REFramework's own FirstPerson.cpp reads exactly this to skip body rotation and
-- roomscale while a zombie has hold of you (FirstPerson.cpp is_jacked). Unlike a
-- damage flag it is true ONLY for grabs -- an ordinary Mr. X punch or Licker swipe
-- never sets it -- which is precisely the distinction asked for.
local function is_jacked()
    local player = RE2.get_localplayer()
    if player == nil then return false end
    local jd_type = sdk.typeof(sdk.game_namespace("JackDominator"))
    if jd_type == nil then
        head_view.jack_src = "no JackDominator type"
        return false
    end

    -- Same lookup re2_smooth_movement.lua already uses: component off the
    -- GameObject, then the cached method object.
    local ok_go, jd = pcall(function()
        return player:call("getComponent(System.Type)", jd_type)
    end)
    if not ok_go or jd == nil then
        head_view.jack_src = "component not found"
        return false
    end
    head_view.jack_src = "ok"

    local ok_v, v = pcall(function()
        local td = sdk.find_type_definition(sdk.game_namespace("JackDominator"))
        local m = td and td:get_method("get_Jacked")
        if m then return m:call(jd) end
        return jd:call("get_Jacked")
    end)
    if not ok_v then
        head_view.jack_src = "get_Jacked threw"
        return false
    end
    return v == true
end

-- True while REFramework's FirstPerson is actually driving the camera. If it is,
-- the camera sits on the head and the head must stay hidden no matter what else
-- is going on -- this is what stops a lever/switch interaction that the game
-- reports as "cinematic", but which plays out in first person, from parking a set
-- of eyelashes in front of the lens.
local function first_person_active()
    if firstpersonmod == nil then return false end
    if type(firstpersonmod.will_be_used) ~= "function" then return false end
    local ok, v = pcall(function() return firstpersonmod:will_be_used() end)
    return ok and v == true
end

local function head_camera_distance()
    head_view.fail = "none"
    local player = RE2.get_localplayer()
    if player == nil then head_view.fail = "no player" return nil end
    local ok_tf, tf = pcall(function() return player:call("get_Transform") end)
    if not ok_tf or tf == nil then head_view.fail = "no player transform" return nil end

    local hp = nil
    for _, name in ipairs(HEAD_JOINT_CANDIDATES) do
        local ok_j, j = pcall(function() return tf:call("getJointByName", name) end)
        if ok_j and j ~= nil then
            local ok_p, p = pcall(function() return j:call("get_Position") end)
            if ok_p and p ~= nil then
                hp = p
                head_view.joint_name = name
                break
            end
        end
    end
    if hp == nil then head_view.fail = "head joint not found" return nil end

    local cam = sdk.get_primary_camera()
    if cam == nil then head_view.fail = "no primary camera" return nil end
    local ok_ctf, ctf = pcall(function() return cam:call("get_GameObject") end)
    if ok_ctf and ctf ~= nil then
        local ok2, t2 = pcall(function() return ctf:call("get_Transform") end)
        ctf = (ok2 and t2) or nil
    else
        ctf = nil
    end
    if ctf == nil then
        -- components expose get_Transform directly too; try that before giving up
        local ok_d, t = pcall(function() return cam:call("get_Transform") end)
        ctf = (ok_d and t) or nil
    end
    if ctf == nil then head_view.fail = "no camera transform" return nil end
    local ok_cp, cp = pcall(function() return ctf:call("get_Position") end)
    if not ok_cp or cp == nil then head_view.fail = "no camera position" return nil end

    head_view.seen_ok = true
    local dx, dy, dz = cp.x - hp.x, cp.y - hp.y, cp.z - hp.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Distance trace, so the calibration numbers land in re2_framework_log.txt
-- instead of only in the panel (grep the log for "[head_shadow] dist").
local trace = {
    was_revealing = false,
    last_sample_t = 0.0,
    last_logged_d = -99.0,
    rest_min = math.huge,   -- quietest first-person distance seen
    rest_max = 0.0,         -- furthest seen while NOT revealing
    peak = 0.0,             -- furthest seen during the current reveal
    last_jacked = "false",  -- last logged grab state
}

local function trace_distance(d, revealing)
    local now = os.clock()

    local fp = tostring(first_person_active())
    local jk = tostring(head_view.jacked)

    if revealing then
        if d > trace.peak then trace.peak = d end
        if not trace.was_revealing then
            logmsg(string.format("dist REVEAL START %.3fm (threshold %.3fm, joint=%s) jacked=%s firstperson=%s",
                d, state.head_reveal_distance_m, tostring(head_view.joint_name), jk, fp))
        end
    else
        if d < trace.rest_min then trace.rest_min = d end
        if d > trace.rest_max then trace.rest_max = d end
        if trace.was_revealing then
            logmsg(string.format("dist REVEAL END %.3fm (peak during reveal %.3fm) jacked=%s firstperson=%s",
                d, trace.peak, jk, fp))
            trace.peak = 0.0
        end
    end
    trace.was_revealing = revealing

    -- Grab transitions are the thing under investigation: log every flip of the
    -- jacked flag with what the camera was doing at that moment.
    if jk ~= trace.last_jacked then
        logmsg(string.format("JACKED %s -> %s   dist %.3fm  firstperson=%s",
            tostring(trace.last_jacked), jk, d, fp))
        trace.last_jacked = jk
    end

    -- Periodic sample: at most every 0.5s, and only when it actually moved, so a
    -- whole test session stays readable rather than one line per frame.
    if (now - trace.last_sample_t) >= 0.5 and math.abs(d - trace.last_logged_d) > 0.02 then
        logmsg(string.format("dist %.3fm  revealing=%s  first-person range seen %.3f..%.3fm",
            d, tostring(revealing),
            trace.rest_min == math.huge and 0.0 or trace.rest_min, trace.rest_max))
        trace.last_sample_t = now
        trace.last_logged_d = d
    end
end

local function camera_left_head()
    head_view.jacked = is_jacked()

    local d = head_camera_distance()
    if d == nil then
        -- Previously this returned silently, which is why a whole test session
        -- produced zero trace lines. Say why, rate-limited.
        local now = os.clock()
        if (now - head_view.last_fail_log) > 5.0 then
            logmsg("dist UNAVAILABLE (" .. tostring(head_view.fail) ..
                ")  jacked=" .. tostring(head_view.jacked) ..
                " jack_src=" .. tostring(head_view.jack_src))
            head_view.last_fail_log = now
        end
        head_view.last_dist = -1.0
        -- A grab still reveals the head even with no distance available.
        return state.reveal_on_grab and head_view.jacked
    end
    head_view.last_dist = d

    local revealing
    if state.reveal_on_grab and head_view.jacked then
        head_view.last_far = os.clock()
        revealing = true
    elseif state.reveal_on_distance and d > state.head_reveal_distance_m then
        head_view.last_far = os.clock()
        revealing = true
    else
        -- Short tail so jitter around the threshold can't strobe the head.
        revealing = (os.clock() - head_view.last_far) < state.restore_tail_s
    end

    trace_distance(d, revealing)
    return revealing
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

    -- Never hand the head back while FirstPerson is actually driving the camera:
    -- the camera is on the head, so a restore would put hair/eyelashes in the
    -- lens. Covers lever/switch interactions the game flags as cinematic but
    -- plays in first person, and protects the grab path below for the same reason.
    local fp_active = first_person_active()

    -- Cutscene handling: give the game its real, fully visible head back so
    -- third-person cutscenes look right, then re-apply afterwards.
    if state.show_in_cutscenes and is_cutscene() and not fp_active then
        if not state.restored_for_cutscene then
            restore_all()
            state.restored_for_cutscene = true
            state.status = "cutscene -- head restored"
        end
        return
    end

    -- Same treatment whenever the camera has genuinely left the head (grab/bite
    -- animations, death cams). See camera_left_head. Always evaluated (not gated
    -- on the toggle) so the distance trace still reaches the log while the
    -- feature itself is switched off for a comparison run.
    local camera_off_head = camera_left_head()
    if state.show_when_camera_leaves_head and camera_off_head and not fp_active then
        if not state.restored_for_cutscene then
            restore_all()
            state.restored_for_cutscene = true
            state.status = string.format("camera off head (%.2fm) -- head restored",
                head_view.last_dist)
        end
        return
    end
    state.restored_for_cutscene = false

    -- A save load (alive or dead) rebuilds the player. Wait for the load to
    -- finish, then throw the mesh list away unconditionally -- this does not
    -- depend on the new player landing at a different address.
    if is_load_busy() then
        load_watch.was_busy = true
        state.status = "loading -- waiting"
        return
    elseif load_watch.was_busy then
        load_watch.was_busy = false
        state.meshes = {}
        state.player_addr = nil
        state.last_scan = 0.0
        logmsg("load finished -- forcing mesh rescan")
    end

    -- Death -> Continue rebuilds the player, but the OLD mesh components stay
    -- valid enough that set_DrawDefault still succeeds on them -- so nothing ever
    -- looked "stale", the script believed it was applied, and the real head came
    -- back visible until a manual script reset. Detect the swap by identity and
    -- force a rescan.
    local cur_player = RE2.get_localplayer()
    local cur_addr = nil
    if cur_player ~= nil then
        local ok_a, a = pcall(function() return cur_player:get_address() end)
        if ok_a then cur_addr = a end
    end
    if cur_addr ~= nil and state.player_addr ~= nil and cur_addr ~= state.player_addr then
        logmsg(string.format("player object changed (%s -> %s) -- rescanning meshes",
            tostring(state.player_addr), tostring(cur_addr)))
        state.meshes = {}
        state.player_addr = cur_addr
        state.last_scan = 0.0
    elseif cur_addr ~= nil and state.player_addr == nil then
        state.player_addr = cur_addr
    end

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
                -- Read the flag back. Loading a save (and Death -> Continue)
                -- rebuilds the player, but the OLD components stay live enough
                -- that set_DrawDefault still returns success -- so the write
                -- "worked" while the head we can actually see stayed visible.
                -- Whatever the cause, a head that reads visible after we just
                -- hid it means these refs are not the meshes on screen.
                local ok_rb, rb = pcall(function() return entry.comp:call("get_DrawDefault") end)
                if ok_rb and rb == true then
                    any_stale = true
                end
            else
                any_stale = true
            end
        elseif entry.applied then
            -- User un-ticked this one in the panel -- put it back.
            restore_mesh(entry)
        end
    end

    if any_stale then
        -- Component references died or belong to a replaced player (level load,
        -- save load, Death -> Continue) -- drop and redo.
        state.meshes = {}
        state.last_scan = 0.0
        logmsg("stale mesh refs detected -- rescanning")
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
    changed, state.show_when_camera_leaves_head =
        imgui.checkbox("Restore full head during grabs (master switch)",
            state.show_when_camera_leaves_head)
    changed, state.reveal_on_grab =
        imgui.checkbox("  trigger: zombie grab (JackDominator.get_Jacked)", state.reveal_on_grab)
    changed, state.reveal_on_distance =
        imgui.checkbox("  trigger: camera far from head", state.reveal_on_distance)
    changed, state.head_reveal_distance_m =
        imgui.drag_float("  reveal distance (m)", state.head_reveal_distance_m, 0.01, 0.05, 2.0)
    imgui.text(string.format("  jacked: %s  (source: %s)   first-person active: %s",
        tostring(head_view.jacked), tostring(head_view.jack_src),
        tostring(first_person_active())))
    imgui.text(string.format("  head joint: %s   camera-to-head: %.3fm   (fail: %s)",
        tostring(head_view.joint_name), head_view.last_dist, tostring(head_view.fail)))
    if imgui.button("Log a distance marker now") then
        logmsg(string.format("dist MARKER %.3fm  joint=%s  threshold=%.3fm  first-person range seen %.3f..%.3fm",
            head_view.last_dist, tostring(head_view.joint_name), state.head_reveal_distance_m,
            trace.rest_min == math.huge and 0.0 or trace.rest_min, trace.rest_max))
    end
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
