-- re2_vr_tyrant_state_probe.lua
--
-- Diagnostic for the planned "Mr. X despawns when evaded" feature. The plan:
-- keep every scripted Tyrant appearance untouched, but once the player has
-- genuinely shaken him (no line of sight + distance + timer, or a real
-- "lost target" AI state if one exists), teleport him to a parking spot
-- outside the RPD gates and pacify his pursuit until the next scripted event
-- reclaims him. Before building that, this probe answers, empirically:
--   1. Which EnemyController is the Tyrant, and what does his AI state look
--      like from Lua? (Track an enemy -> auto-watch every primitive
--      getter/field whose name smells like AI state, log value CHANGES.)
--   2. Does the game warp him around on its own (catch-up logic / scripted
--      events)? (Tracked-enemy position log + "WARP DETECTED" on big jumps,
--      plus log-only auto-hooks on warp/spawn/appear-ish methods.)
--   3. Can we teleport him ourselves, and does it stick? ("Save parking spot"
--      while standing outside the gates, then "Teleport tracked -> parking
--      spot" and watch whether he stays / walks back / gets warped back.)
--
-- Read-only apart from the explicit user-triggered teleport button (no
-- SKIP_ORIGINAL, no automatic writes). Safe to leave enabled.
--
-- Usage: reset scripts, load into gameplay where Mr. X is active. In the
-- panel, find the enemy marked "<< LIKELY MR. X" and enable Track. Play:
-- let him chase you, then escape him. Later, stand outside the RPD front
-- gates and click "Save player position as parking spot", then try the
-- teleport button. Send back the [tyrant_probe] lines from
-- re2_framework_log.txt.

local RE2 = require("utility/RE2")

local log_prefix = "[tyrant_probe]"

local function log_line(msg)
    log.info(log_prefix .. " " .. msg)
end

local function fmt_vec(v)
    if v == nil then return "?" end
    local ok, s = pcall(function() return string.format("(%.2f, %.2f, %.2f)", v.x, v.y, v.z) end)
    return ok and s or "?"
end

local EC_TYPENAME = sdk.game_namespace("EnemyController") -- app.ropeway.EnemyController

--------------------------------------------------------------------------------
-- 1) Enemy registry, fed by a cheap pre-hook on EnemyController.update
--------------------------------------------------------------------------------
local enemies = {}          -- addr -> record
local pending_intro = {}    -- records waiting for name resolution on the frame tick

local FRESH_WINDOW = 1.0    -- ctrl considered alive if updated within this many s
local STALE_ANNOUNCE = 2.0  -- announce "went stale" after this many s without update
local PRUNE_AFTER = 300.0   -- drop the reference entirely after this many s

local function on_pre_ec_update(args)
    pcall(function()
        local ctrl = sdk.to_managed_object(args[2])
        if ctrl == nil then return end
        local addr = ctrl:get_address()
        local rec = enemies[addr]
        if rec == nil then
            rec = { ctrl = ctrl, addr = addr, first_seen = os.clock(), name = "?", type_name = "?" }
            enemies[addr] = rec
            table.insert(pending_intro, rec)
        end
        rec.last_seen = os.clock()
    end)
end

local ec_td = sdk.find_type_definition(EC_TYPENAME)
if ec_td ~= nil then
    sdk.hook(ec_td:get_method("update"), on_pre_ec_update, nil)
    log_line("registry hook installed on " .. EC_TYPENAME .. ".update")
else
    log_line("TYPE NOT FOUND: " .. EC_TYPENAME .. " -- probe is dead in the water")
end

local function is_fresh(rec)
    return rec.last_seen ~= nil and (os.clock() - rec.last_seen) < FRESH_WINDOW
end

local function get_ctrl_pos(rec)
    local pos = nil
    pcall(function()
        pos = rec.ctrl:call("get_GameObject"):call("get_Transform"):call("get_Position")
    end)
    return pos
end

local function resolve_intro(rec)
    pcall(function()
        rec.type_name = rec.ctrl:get_type_definition():get_full_name()
        rec.name = rec.ctrl:call("get_GameObject"):call("get_Name")
    end)
    -- em codes per the community file lists: em6200 = Mr. X, em4000 = zombie
    -- dog, em3000 = licker, em5000 = ivy (em7* kept as a fallback guess).
    local lname = tostring(rec.name):lower()
    rec.is_tyrant_guess = (lname:find("^em62") ~= nil) or (lname:find("^em7") ~= nil)
    rec.is_dog_guess = (lname:find("^em40") ~= nil)
    local tag = rec.is_tyrant_guess and "  << LIKELY MR. X"
        or (rec.is_dog_guess and "  << DOG" or "")
    log_line(string.format("NEW ENEMY: go=%s type=%s addr=0x%X pos=%s%s",
        tostring(rec.name), tostring(rec.type_name), rec.addr, fmt_vec(get_ctrl_pos(rec)), tag))
end

--------------------------------------------------------------------------------
-- 2) AI-state watchers: auto-discover primitive getters/fields with AI-ish
--    names on the controller's whole type hierarchy, then log value changes.
--------------------------------------------------------------------------------
local WATCH_KEYWORDS = {
    "think", "state", "mode", "find", "found", "target", "recogni", "combat",
    "dead", "warp", "escape", "search", "lost", "alert", "action", "chase",
    "battle", "aware", "sight", "discover",
}
local MAX_WATCHERS = 80

local function name_matches_keywords(name)
    local l = name:lower()
    for _, kw in ipairs(WATCH_KEYWORDS) do
        if l:find(kw, 1, true) ~= nil then return true end
    end
    return false
end

local function build_watchers(rec)
    rec.watchers = {}
    rec.watch_values = {}
    local chain = {}
    pcall(function()
        local td = rec.ctrl:get_type_definition()
        while td ~= nil and #rec.watchers < MAX_WATCHERS do
            table.insert(chain, td:get_full_name())
            local ok_m, methods = pcall(function() return td:get_methods() end)
            if ok_m and methods then
                for _, m in ipairs(methods) do
                    if #rec.watchers >= MAX_WATCHERS then break end
                    local ok_n, mname = pcall(function() return m:get_name() end)
                    local ok_p, np = pcall(function() return m:get_num_params() end)
                    if ok_n and mname and ok_p and np == 0
                        and (mname:sub(1, 4) == "get_" or mname:sub(1, 2) == "is")
                        and name_matches_keywords(mname) then
                        table.insert(rec.watchers, { kind = "m", name = mname })
                    end
                end
            end
            local ok_f, fields = pcall(function() return td:get_fields() end)
            if ok_f and fields then
                for _, f in ipairs(fields) do
                    if #rec.watchers >= MAX_WATCHERS then break end
                    local ok_n, fname = pcall(function() return f:get_name() end)
                    if ok_n and fname and name_matches_keywords(fname) then
                        table.insert(rec.watchers, { kind = "f", name = fname })
                    end
                end
            end
            local parent = nil
            pcall(function() parent = td:get_parent_type() end)
            td = parent
        end
    end)
    log_line(string.format("TRACK START %s: %d watchers, type chain: %s",
        tostring(rec.name), #rec.watchers, table.concat(chain, " -> ")))
end

local function read_watcher(rec, w)
    local v = nil
    if w.kind == "m" then
        pcall(function() v = rec.ctrl:call(w.name) end)
    else
        pcall(function() v = rec.ctrl:get_field(w.name) end)
    end
    local t = type(v)
    if t == "boolean" or t == "number" or t == "string" then return tostring(v) end
    if v == nil then return nil end
    return nil -- managed objects etc. are not worth diffing as strings
end

local function tick_watchers(rec)
    if rec.watchers == nil then return end
    for _, w in ipairs(rec.watchers) do
        local s = read_watcher(rec, w)
        if s ~= nil then
            local key = w.kind .. ":" .. w.name
            local old = rec.watch_values[key]
            if old ~= s then
                rec.watch_values[key] = s
                -- Suppress the initial flood: only log changes after first fill.
                if old ~= nil or rec.watch_primed then
                    log_line(string.format("STATE %s: %s  %s -> %s",
                        tostring(rec.name), w.name, tostring(old), s))
                end
            end
        end
    end
    rec.watch_primed = true
end

--------------------------------------------------------------------------------
-- 3) Position tracking + warp detection
--------------------------------------------------------------------------------
local WARP_JUMP_METERS = 8.0
local POS_LOG_INTERVAL = 2.0

local function tick_position(rec, player_pos)
    local pos = get_ctrl_pos(rec)
    if pos == nil then return end
    local d_player = nil
    pcall(function() d_player = (pos - player_pos):length() end)
    rec.last_dist = d_player

    if rec.last_pos ~= nil then
        local jump = nil
        pcall(function() jump = (pos - rec.last_pos):length() end)
        if jump ~= nil and jump > WARP_JUMP_METERS then
            log_line(string.format("*** WARP DETECTED %s: jumped %.1f m, %s -> %s (d_player now %s)",
                tostring(rec.name), jump, fmt_vec(rec.last_pos), fmt_vec(pos), tostring(d_player)))
        end
    end
    rec.last_pos = pos

    local now = os.clock()
    if rec.last_pos_log == nil or (now - rec.last_pos_log) >= POS_LOG_INTERVAL then
        rec.last_pos_log = now
        log_line(string.format("POS %s: %s  d(player)=%s",
            tostring(rec.name), fmt_vec(pos), tostring(d_player)))
    end
end

--------------------------------------------------------------------------------
-- 4) One-shot dumps (per enemy, button-triggered)
--------------------------------------------------------------------------------
local function dump_fields(rec)
    log_line("======== FIELD DUMP " .. tostring(rec.name) .. " (" .. tostring(rec.type_name) .. ") ========")
    pcall(function()
        local td = rec.ctrl:get_type_definition()
        while td ~= nil do
            local ok_f, fields = pcall(function() return td:get_fields() end)
            if ok_f and fields then
                for _, f in ipairs(fields) do
                    pcall(function()
                        local fname = f:get_name()
                        local ftype = f:get_type():get_full_name()
                        local v = rec.ctrl:get_field(fname)
                        local t = type(v)
                        local vs = (t == "boolean" or t == "number" or t == "string") and tostring(v) or ("<" .. t .. ">")
                        log_line("  " .. td:get_name() .. "." .. fname .. " : " .. ftype .. " = " .. vs)
                    end)
                end
            end
            local parent = nil
            pcall(function() parent = td:get_parent_type() end)
            td = parent
        end
    end)
    log_line("======== END FIELD DUMP ========")
end

local function dump_components(rec)
    log_line("======== COMPONENT DUMP " .. tostring(rec.name) .. " ========")
    pcall(function()
        local go = rec.ctrl:call("get_GameObject")
        local comps = go:call("get_Components")
        local elems = comps:get_elements()
        for _, c in ipairs(elems) do
            pcall(function()
                log_line("  component: " .. c:get_type_definition():get_full_name())
            end)
        end
    end)
    log_line("======== END COMPONENT DUMP ========")
end

local AI_METHOD_KEYWORDS = {
    "warp", "teleport", "escape", "appear", "vanish", "spawn", "activ",
    "target", "find", "search", "state", "think", "request", "leave", "wait",
}

local function dump_ai_methods(rec)
    log_line("======== AI-KEYWORD METHOD DUMP " .. tostring(rec.name) .. " ========")
    pcall(function()
        local td = rec.ctrl:get_type_definition()
        while td ~= nil do
            local ok_m, methods = pcall(function() return td:get_methods() end)
            if ok_m and methods then
                for _, m in ipairs(methods) do
                    pcall(function()
                        local mname = m:get_name()
                        local l = mname:lower()
                        for _, kw in ipairs(AI_METHOD_KEYWORDS) do
                            if l:find(kw, 1, true) ~= nil then
                                log_line("  " .. td:get_name() .. "." .. mname
                                    .. " (params: " .. tostring(m:get_num_params()) .. ")")
                                break
                            end
                        end
                    end)
                end
            end
            local parent = nil
            pcall(function() parent = td:get_parent_type() end)
            td = parent
        end
    end)
    log_line("======== END METHOD DUMP ========")
end

--------------------------------------------------------------------------------
-- 5) Log-only auto-hooks: catch scripted warps/spawns red-handed
--------------------------------------------------------------------------------
local HOOK_PATTERNS = { "warp", "teleport", "appear", "vanish", "escape", "spawn", "activate" }
local MAX_LOGS_PER_METHOD = 12
local hook_counts = {}
local hooks_installed = false

local function install_event_hooks()
    if hooks_installed or ec_td == nil then return end
    hooks_installed = true
    local hooked = 0
    local ok_m, methods = pcall(function() return ec_td:get_methods() end)
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            if ok_n and mname then
                local l = mname:lower()
                local want = false
                for _, pat in ipairs(HOOK_PATTERNS) do
                    if l:find(pat, 1, true) ~= nil then want = true break end
                end
                if want then
                    local key = EC_TYPENAME .. "." .. mname
                    local ok_h = pcall(function()
                        sdk.hook(m,
                            function(args)
                                local c = (hook_counts[key] or 0) + 1
                                hook_counts[key] = c
                                if c <= MAX_LOGS_PER_METHOD then
                                    local who = "?"
                                    pcall(function()
                                        who = sdk.to_managed_object(args[2]):call("get_GameObject"):call("get_Name")
                                    end)
                                    log_line(string.format("*** %s CALLED on %s (#%d, os.clock=%.3f)",
                                        key, tostring(who), c, os.clock()))
                                    if c == MAX_LOGS_PER_METHOD then
                                        log_line("    (further " .. key .. " calls suppressed)")
                                    end
                                end
                            end,
                            nil)
                    end)
                    if ok_h then hooked = hooked + 1 end
                end
            end
        end
    end
    log_line("installed " .. hooked .. " log-only event hooks on " .. EC_TYPENAME)
end

--------------------------------------------------------------------------------
-- 6) Parking spot + teleport test (the only write in this probe, button-only)
--------------------------------------------------------------------------------
local parking_spot = nil -- { x, y, z }

local function save_parking_spot()
    local player = RE2.get_localplayer()
    if player == nil then log_line("save parking spot: no player") return end
    local pos = nil
    pcall(function() pos = player:call("get_Transform"):call("get_Position") end)
    if pos == nil then log_line("save parking spot: no player position") return end
    parking_spot = { x = pos.x, y = pos.y, z = pos.z }
    log_line(string.format("PARKING SPOT SAVED: (%.3f, %.3f, %.3f)", pos.x, pos.y, pos.z))
end

local function teleport_to_parking(rec)
    if parking_spot == nil then log_line("teleport: no parking spot saved") return end
    if not is_fresh(rec) then log_line("teleport: enemy is stale, not touching it") return end
    local before = get_ctrl_pos(rec)
    local target = Vector3f.new(parking_spot.x, parking_spot.y, parking_spot.z)
    local applied = nil
    -- Try the plain transform setter first; fall back to a universal setter if
    -- the engine exposes one on this transform.
    for _, setter in ipairs({ "set_Position", "set_UniversalPosition" }) do
        local ok = pcall(function()
            rec.ctrl:call("get_GameObject"):call("get_Transform"):call(setter, target)
        end)
        if ok then applied = setter break end
    end
    local after = get_ctrl_pos(rec)
    log_line(string.format("TELEPORT TEST %s: setter=%s before=%s after=%s target=(%.2f, %.2f, %.2f)",
        tostring(rec.name), tostring(applied), fmt_vec(before), fmt_vec(after),
        parking_spot.x, parking_spot.y, parking_spot.z))
    log_line("  -> now watch the POS/WARP log lines: does he stay, walk back, or get warped back?")
end

--------------------------------------------------------------------------------
-- Driver
--------------------------------------------------------------------------------
local TICK_INTERVAL = 0.5
local last_tick = 0.0

re.on_frame(function()
    install_event_hooks()

    local now = os.clock()
    if (now - last_tick) < TICK_INTERVAL then return end
    last_tick = now

    -- Introduce newly seen enemies (kept out of the hot hook path).
    if #pending_intro > 0 then
        for _, rec in ipairs(pending_intro) do
            pcall(resolve_intro, rec)
        end
        pending_intro = {}
    end

    local player = RE2.get_localplayer()
    local player_pos = nil
    if player ~= nil then
        pcall(function() player_pos = player:call("get_Transform"):call("get_Position") end)
    end

    for addr, rec in pairs(enemies) do
        local age = now - (rec.last_seen or 0)
        if age > PRUNE_AFTER then
            enemies[addr] = nil
        elseif age > STALE_ANNOUNCE then
            if not rec.stale_announced then
                rec.stale_announced = true
                log_line("ENEMY WENT STALE (updates stopped): " .. tostring(rec.name)
                    .. " last pos " .. fmt_vec(rec.last_pos))
            end
        else
            rec.stale_announced = false
            if rec.tracked and player_pos ~= nil then
                pcall(tick_position, rec, player_pos)
                pcall(tick_watchers, rec)
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.tree_node("Tyrant State Probe (diagnostic)") then return end

    imgui.text("1. Track the enemy marked LIKELY MR. X, then play normally.")
    imgui.text("2. Let him chase you, then escape -- state changes go to the log.")
    imgui.text("3. Stand outside the RPD gates, save the parking spot.")
    imgui.text("4. With him tracked and alive, try the teleport test.")
    imgui.text("Log prefix: [tyrant_probe] in re2_framework_log.txt")
    imgui.spacing()

    if imgui.button("Save player position as parking spot") then
        pcall(save_parking_spot)
    end
    if parking_spot ~= nil then
        imgui.same_line()
        imgui.text(string.format("saved: (%.1f, %.1f, %.1f)", parking_spot.x, parking_spot.y, parking_spot.z))
    end
    imgui.spacing()

    local shown = 0
    for _, rec in pairs(enemies) do
        shown = shown + 1
        local fresh = is_fresh(rec)
        local label = string.format("%s  [%s]%s%s##enemy%X",
            tostring(rec.name),
            fresh and (rec.last_dist and string.format("%.1f m", rec.last_dist) or "alive") or "STALE",
            rec.is_tyrant_guess and "  << LIKELY MR. X" or (rec.is_dog_guess and "  << DOG" or ""),
            rec.tracked and "  (tracking)" or "",
            rec.addr)
        if imgui.tree_node(label) then
            imgui.text("type: " .. tostring(rec.type_name))
            local changed, tracked = imgui.checkbox("Track (log states + positions)##t" .. rec.addr, rec.tracked or false)
            if changed then
                rec.tracked = tracked
                if tracked and rec.watchers == nil and fresh then
                    pcall(build_watchers, rec)
                end
            end
            if fresh then
                if imgui.button("Dump fields##f" .. rec.addr) then pcall(dump_fields, rec) end
                imgui.same_line()
                if imgui.button("Dump components##c" .. rec.addr) then pcall(dump_components, rec) end
                imgui.same_line()
                if imgui.button("Dump AI methods##m" .. rec.addr) then pcall(dump_ai_methods, rec) end
                if parking_spot ~= nil then
                    if imgui.button("TELEPORT to parking spot##tp" .. rec.addr) then
                        pcall(teleport_to_parking, rec)
                    end
                end
            else
                imgui.text("(stale -- controller not updating, buttons hidden)")
            end
            imgui.tree_pop()
        end
    end
    if shown == 0 then
        imgui.text("No EnemyControllers seen yet -- load into gameplay with enemies around.")
    end

    imgui.tree_pop()
end)

log_line("loaded")
