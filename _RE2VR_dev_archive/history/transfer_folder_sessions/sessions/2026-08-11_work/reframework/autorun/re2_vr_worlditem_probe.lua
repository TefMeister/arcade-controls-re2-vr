-- Diagnostic (passive only -- no writes, no calls, no input simulation).
--
-- New bug: after auto-complete grants an item, the world pickup object
-- (e.g. an ammo box) stays in the world instead of being removed/disabled
-- like a normal pickup. Re-interacting with it re-triggers our sequence
-- against a slot that already holds that item, which appears to make
-- exchangeGetItem behave like a toggle (alternating add/remove) instead of
-- a clean grant.
--
-- Root theory: auto-complete only ever drives the UI/inventory-data chain
-- (SlotBehavior/DetailBehavior/NewInventoryBehavior/Inventory) -- it never
-- touches whatever WORLD-side component is responsible for destroying/
-- deactivating the pickup object after a real completion. Every pickup
-- hook all day has carried a SetItemSaveData argument
-- (app.ropeway.gimmick.action.SetItem.SetItemSaveData) -- SetItem is
-- almost certainly the actual world-object gimmick component (the thing
-- attached to the ammo box), and SetItemSaveData a nested type of it.
--
-- This dumps SetItem's full method list (static reflection, looking for
-- destroy/remove/collect/finish/complete-shaped names) and wide-net hooks
-- every non-getter method on it, so we can compare what fires during a
-- REAL manual pickup (auto-complete OFF) vs. an auto-complete-driven one
-- and find the exact missing call.

if reframework:get_game_name() ~= "re2" then
    return
end

local NS = sdk.game_namespace

local state = {
    dumped = false,
    hooked = false,
    call_counts = {},
    log_buffer = {},
    watches = {}, -- list of { go = <GameObject>, label = string, last_active = bool, started_at = number }
}

local WATCH_DURATION_S = 8.0
local MAX_LOG_LINES = 400
local MAX_LOGGED_PER_METHOD = 15

local function log_line(s)
    local full = "[worlditem_probe] " .. s
    log.info(full)
    table.insert(state.log_buffer, 1, full)
    if #state.log_buffer > MAX_LOG_LINES then table.remove(state.log_buffer) end
end

local function get_go_active(go)
    -- Standard RE Engine convention: byte at offset 0x10 on the GameObject's
    -- underlying object indicates active state -- same technique already
    -- proven working elsewhere in this mod (re2_vr_holster.lua's
    -- gameobject_ref_is_active helper).
    local ok, v = pcall(function() return go:read_byte(0x10) end)
    if ok then return v == 1 end
    return nil
end

local function start_watch(go, label)
    if not go then return end
    table.insert(state.watches, {
        go = go,
        label = label,
        last_active = get_go_active(go),
        started_at = os.clock(),
    })
end

-- Mesh component visibility investigation: via.render.Mesh's own direct
-- methods (already fully reflected during the earlier mesh-swap
-- investigation today) had nothing obviously enable/visibility-shaped --
-- but that only looked at methods DECLARED directly on via.render.Mesh, not
-- inherited from its parent type(s). Walk up to 3 parent levels collecting
-- every Boolean-typed field, then poll all of them frame-by-frame the same
-- way the GameObject active-state watch already works, to catch whichever
-- one (if any) actually flips when the box should disappear.
state.mesh_dumped = false
state.mesh_watches = {} -- list of { obj, label, bool_fields = {name=...}, last = {name=val}, started_at }

local function collect_boolean_fields_with_hierarchy(obj)
    local names = {}
    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    local level = 0
    while ok_td and td and level < 4 do
        local ok_f, fields = pcall(function() return td:get_fields() end)
        if ok_f and fields then
            for _, f in ipairs(fields) do
                local ok_n, fname = pcall(function() return f:get_name() end)
                local ok_t, ftype = pcall(function() return f:get_type():get_full_name() end)
                if ok_n and ok_t and ftype == "System.Boolean" then
                    names[fname] = true
                end
            end
        end
        local ok_tn, tname = pcall(function() return td:get_full_name() end)
        log_line(string.format("  [mesh hierarchy level %d] type=%s", level, tostring(ok_tn and tname or "?")))
        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if ok_p and parent then td = parent else break end
        level = level + 1
    end
    return names
end

local ENABLE_KEYWORDS = { "enable", "draw", "show", "hide", "visible", "active", "display" }

local function is_enable_like_getter(mname)
    if not mname:match("^get_") and not mname:match("^is") then return false end
    local lower = mname:lower()
    for _, kw in ipairs(ENABLE_KEYWORDS) do
        if lower:find(kw, 1, true) then return true end
    end
    return false
end

-- Walks the type hierarchy (own type + parents, e.g. via.render.Mesh ->
-- via.Component -> System.Object) collecting every 0-param getter whose name
-- looks enable/visibility-shaped. Returns { {name=..., level=...}, ... }.
local function collect_enable_like_getters_with_hierarchy(obj)
    local candidates = {}
    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    local level = 0
    while ok_td and td and level < 4 do
        local ok_tn, tname = pcall(function() return td:get_full_name() end)
        local ok_m, methods = pcall(function() return td:get_methods() end)
        if ok_m and methods then
            for _, m in ipairs(methods) do
                local ok_n, mname = pcall(function() return m:get_name() end)
                local ok_p, nparams = pcall(function() return m:get_num_params() end)
                if ok_n and mname and ok_p and nparams == 0 and is_enable_like_getter(mname) then
                    table.insert(candidates, { name = mname, level = level, type_name = tname })
                end
            end
        end
        local ok_p2, parent = pcall(function() return td:get_parent_type() end)
        if ok_p2 and parent then td = parent else break end
        level = level + 1
    end
    return candidates
end

-- Array-returning getters (e.g. get_PartsEnable -> bool[]) hand back a fresh
-- wrapper object every single call -- comparing by identity/address is pure
-- noise (looks like "changed" every frame even when the actual contents
-- never do). Read the real element values instead so watches only fire on
-- an actual content change.
local dumped_wrapper_types = {}

local function dump_wrapper_type_once(v, tname)
    if dumped_wrapper_types[tname] then return end
    dumped_wrapper_types[tname] = true

    log_line("======================================== ")
    log_line("Unknown wrapper type encountered, one-time dump: " .. tname)
    local ok_td, td = pcall(function() return v:get_type_definition() end)
    if ok_td and td then
        local ok_m, methods = pcall(function() return td:get_methods() end)
        if ok_m and methods then
            for _, m in ipairs(methods) do
                local ok_n, mname = pcall(function() return m:get_name() end)
                local ok_p, nparams = pcall(function() return m:get_num_params() end)
                if ok_n and mname then
                    log_line(string.format("  method: %s (params: %s)", mname, tostring(ok_p and nparams or "?")))
                end
            end
        end
        local ok_f, fields = pcall(function() return td:get_fields() end)
        if ok_f and fields then
            for _, f in ipairs(fields) do
                local ok_n, fname = pcall(function() return f:get_name() end)
                if ok_n and fname then
                    local ok_t, ftype = pcall(function() return f:get_type():get_full_name() end)
                    local ok_v, fval = pcall(function() return v:get_field(fname) end)
                    log_line(string.format("  field: %s  type: %s  value: %s",
                        fname, tostring(ok_t and ftype or "?"), tostring(ok_v and fval or "?")))
                end
            end
        end
    end
    log_line("======================================== ")
end

local function describe_getter_value(v)
    if v == nil then return "nil" end
    if type(v) ~= "userdata" and type(v) ~= "table" then return tostring(v) end

    local ok_elems, elems = pcall(function() return v:get_elements() end)
    if ok_elems and elems then
        local parts = {}
        for i, e in ipairs(elems) do
            parts[i] = tostring(e)
        end
        return "[elements:" .. table.concat(parts, ",") .. "]"
    end

    -- Not a via.Array/List wrapper -- try raw .NET array indexer access
    -- (get_Length + get_Item(i)), which is the pattern for plain T[] arrays
    -- as opposed to List<T>.
    local ok_len, len = pcall(function() return v:call("get_Length") end)
    if ok_len and len ~= nil then
        local n = tonumber(len) or 0
        local parts = {}
        for i = 0, n - 1 do
            local ok_item, item = pcall(function() return v:call("get_Item", i) end)
            parts[i + 1] = tostring(ok_item and item or "?")
        end
        return "[len=" .. tostring(n) .. ":" .. table.concat(parts, ",") .. "]"
    end

    -- RE Engine's WrappedArrayContainer_* types (confirmed via the one-time
    -- dump below) use IList-style get_Count/get_Item(i), not get_Length --
    -- this is the real accessor for PartsEnable/MaterialsEnable specifically.
    local ok_count, count = pcall(function() return v:call("get_Count") end)
    if ok_count and count ~= nil then
        local n = tonumber(count) or 0
        local parts = {}
        for i = 0, n - 1 do
            local ok_item, item = pcall(function() return v:call("get_Item", i) end)
            parts[i + 1] = tostring(ok_item and item or "?")
        end
        return "[count=" .. tostring(n) .. ":" .. table.concat(parts, ",") .. "]"
    end

    -- Still unknown -- dump this wrapper type's real API once (methods +
    -- fields) so the next session/edit can add a proper reader instead of
    -- guessing, and report the type name so we're not flying blind meanwhile.
    local ok_tn, tname = pcall(function() return v:get_type_definition():get_full_name() end)
    if ok_tn and tname then
        pcall(dump_wrapper_type_once, v, tname)
    end
    return "<unreadable obj, type=" .. tostring(ok_tn and tname or "?") .. ">"
end

local function dump_mesh_component_once(mesh_obj)
    if state.mesh_dumped then return end
    state.mesh_dumped = true

    log_line("======================================== ")
    log_line("MeshComponent: full method list, walking type hierarchy")
    local ok_td, td = pcall(function() return mesh_obj:get_type_definition() end)
    local level = 0
    while ok_td and td and level < 4 do
        local ok_tn, tname = pcall(function() return td:get_full_name() end)
        log_line("  -- level " .. level .. " (" .. tostring(ok_tn and tname or "?") .. ") --")
        local ok_m, methods = pcall(function() return td:get_methods() end)
        if ok_m and methods then
            for _, m in ipairs(methods) do
                local ok_n, mname = pcall(function() return m:get_name() end)
                if ok_n and mname then log_line("    method: " .. mname) end
            end
        end
        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if ok_p and parent then td = parent else break end
        level = level + 1
    end

    log_line("MeshComponent: walking type hierarchy for Boolean fields")
    local bool_names = collect_boolean_fields_with_hierarchy(mesh_obj)
    for name, _ in pairs(bool_names) do
        local ok_v, v = pcall(function() return mesh_obj:get_field(name) end)
        log_line(string.format("  bool field: %s = %s", name, tostring(ok_v and v or "?")))
    end

    log_line("MeshComponent: enable/visibility-shaped getters found (0-param, name matches keywords)")
    local getters = collect_enable_like_getters_with_hierarchy(mesh_obj)
    for _, c in ipairs(getters) do
        local ok_v, v = pcall(function() return mesh_obj:call(c.name) end)
        log_line(string.format("  getter: %s (level %d, %s) = %s",
            c.name, c.level, c.type_name, ok_v and describe_getter_value(v) or "?"))
    end
    log_line("======================================== ")

    return bool_names, getters
end

local function start_mesh_watch(mesh_obj, label, bool_names, getters)
    local last = {}
    for name, _ in pairs(bool_names) do
        local ok_v, v = pcall(function() return mesh_obj:get_field(name) end)
        last[name] = ok_v and v or nil
    end
    local last_getters = {}
    for _, c in ipairs(getters or {}) do
        local ok_v, v = pcall(function() return mesh_obj:call(c.name) end)
        last_getters[c.name] = ok_v and describe_getter_value(v) or "?"
    end
    table.insert(state.mesh_watches, {
        obj = mesh_obj,
        label = label,
        bool_fields = bool_names,
        last = last,
        getters = getters or {},
        last_getters = last_getters,
        started_at = os.clock(),
    })
end

local function describe_args(args, max_slots)
    local parts = {}
    for i = 2, (max_slots or 6) do
        local ok_obj, obj = pcall(function() return sdk.to_managed_object(args[i]) end)
        if ok_obj and obj ~= nil then
            local ok_tn, tname = pcall(function() return obj:get_type_definition():get_full_name() end)
            table.insert(parts, string.format("arg%d=<obj:%s>", i - 1, tostring(ok_tn and tname or "?")))
        else
            local ok_i, ival = pcall(function() return sdk.to_int64(args[i]) end)
            table.insert(parts, string.format("arg%d=%s", i - 1, tostring(ok_i and ival or "?")))
        end
    end
    return table.concat(parts, ", ")
end

local function dump_setitem_fields_for(obj, when)
    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    if not ok_td or not td then
        log_line("  [" .. when .. "] could not get SetItem type definition for field dump")
        return
    end
    local ok_f, fields = pcall(function() return td:get_fields() end)
    if not ok_f or not fields then
        log_line("  [" .. when .. "] could not get SetItem fields")
        return
    end
    log_line("  -- SetItem instance fields [" .. when .. "] --")
    for _, f in ipairs(fields) do
        local ok_n, fname = pcall(function() return f:get_name() end)
        if ok_n and fname then
            local ok_v, fval = pcall(function() return obj:get_field(fname) end)
            log_line("    " .. fname .. " = " .. tostring(ok_v and fval or "?"))
        end
    end
end

local function dump_and_hook_setitem()
    if state.dumped then return end

    local set_item_type = sdk.find_type_definition(NS("gimmick.action.SetItem"))
    if not set_item_type then
        log_line("could not find gimmick.action.SetItem type -- trying alternate namespace guesses")
        return
    end
    state.dumped = true

    log_line("========================================")
    log_line("SetItem: full method list")
    local ok_m, methods = pcall(function() return set_item_type:get_methods() end)
    local hookable = {}
    local unregister_method = nil
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            if ok_n and mname then
                log_line("  method: " .. mname)
                local lower = mname:lower()
                if not lower:match("^get_") and not lower:match("^set_")
                    and mname ~= ".ctor" and mname ~= ".cctor"
                    and not lower:find("update") then
                    table.insert(hookable, m)
                end
                if mname == "unregisterSetItem" then
                    unregister_method = m
                end
            end
        end
    end

    log_line("========================================")
    log_line("SetItem: full field list (static, no instance yet)")
    local ok_f, fields = pcall(function() return set_item_type:get_fields() end)
    if ok_f and fields then
        for _, f in ipairs(fields) do
            local ok_n, fname = pcall(function() return f:get_name() end)
            if ok_n and fname then
                local ok_t, ftype = pcall(function() return f:get_type():get_full_name() end)
                log_line("  field: " .. fname .. "  type: " .. tostring(ok_t and ftype or "?"))
            end
        end
    end
    log_line("========================================")

    local hooked = 0
    for _, m in ipairs(hookable) do
        local ok_n, mname = pcall(function() return m:get_name() end)
        if ok_n and mname then
            local ok_h = pcall(function()
                sdk.hook(m,
                    function(args)
                        local key = "SetItem." .. mname
                        local count = (state.call_counts[key] or 0) + 1
                        state.call_counts[key] = count
                        if count <= MAX_LOGGED_PER_METHOD then
                            log_line(string.format("### SetItem.%s CALLED (#%d) %s (os.clock=%.3f)",
                                mname, count, describe_args(args), os.clock()))
                        end
                        return sdk.PreHookResult.CALL_ORIGINAL
                    end,
                    function(retval) return retval end)
            end)
            if ok_h then hooked = hooked + 1 end
        end
    end
    log_line(string.format("Wide-net hooked %d non-getter/setter method(s) on SetItem.", hooked))

    -- Extra: dump this specific SetItem instance's live field VALUES right
    -- before and right after unregisterSetItem fires, so a working pickup
    -- and a stuck (merge-case) pickup can be compared field-value-for-
    -- field-value, not just by which methods fired.
    if unregister_method then
        local pending_this = nil
        sdk.hook(unregister_method,
            function(args)
                local ok_this, this_obj = pcall(function() return sdk.to_managed_object(args[2]) end)
                if ok_this and this_obj then
                    pending_this = this_obj
                    dump_setitem_fields_for(this_obj, "PRE unregisterSetItem")
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                if pending_this then
                    dump_setitem_fields_for(pending_this, "POST unregisterSetItem")
                    local ok_go, go = pcall(function() return pending_this:call("get_GameObject") end)
                    if ok_go and go then
                        local active_now = get_go_active(go)
                        log_line(string.format("  GameObject active RIGHT NOW at unregisterSetItem POST: %s -- watching for %.0fs",
                            tostring(active_now), WATCH_DURATION_S))
                        start_watch(go, "box@" .. tostring(os.clock()))
                    else
                        log_line("  could not get_GameObject() off this SetItem instance")
                    end

                    local ok_mesh, mesh_obj = pcall(function() return pending_this:get_field("<MeshComponent>k__BackingField") end)
                    if ok_mesh and mesh_obj then
                        local bool_names, getters = dump_mesh_component_once(mesh_obj)
                        if bool_names == nil then
                            -- Already dumped once before (state.mesh_dumped was
                            -- already true) -- still need the name lists to
                            -- watch this instance, so collect them again quietly.
                            bool_names = collect_boolean_fields_with_hierarchy(mesh_obj)
                            getters = collect_enable_like_getters_with_hierarchy(mesh_obj)
                        end
                        local bcount = 0
                        for _ in pairs(bool_names) do bcount = bcount + 1 end
                        log_line(string.format("  Starting mesh-component watch (%d bool fields, %d enable-like getters) for %.0fs",
                            bcount, #(getters or {}), WATCH_DURATION_S))
                        start_mesh_watch(mesh_obj, "mesh@" .. tostring(os.clock()), bool_names, getters)
                    else
                        log_line("  could not read <MeshComponent>k__BackingField off this SetItem instance")
                    end
                end
                pending_this = nil
                return retval
            end)
        log_line("Also hooked unregisterSetItem specifically for before/after field-value dumps")
    end

    state.hooked = true
end

re.on_frame(function()
    if not state.dumped then
        pcall(dump_and_hook_setitem)
    end

    local now = os.clock()

    if #state.watches > 0 then
        local still_watching = {}
        for _, w in ipairs(state.watches) do
            local ok, active_now = pcall(get_go_active, w.go)
            if ok then
                if active_now ~= w.last_active then
                    log_line(string.format("  [%s] GameObject active CHANGED: %s -> %s (t+%.2fs)",
                        w.label, tostring(w.last_active), tostring(active_now), now - w.started_at))
                    w.last_active = active_now
                end
            else
                log_line("  [" .. w.label .. "] GameObject became unreadable (likely destroyed) at t+" ..
                    string.format("%.2fs", now - w.started_at))
                goto continue_watch -- drop this watch, don't re-add to still_watching
            end
            if (now - w.started_at) < WATCH_DURATION_S then
                table.insert(still_watching, w)
            else
                log_line(string.format("  [%s] watch expired after %.0fs, final active=%s",
                    w.label, WATCH_DURATION_S, tostring(w.last_active)))
            end
            ::continue_watch::
        end
        state.watches = still_watching
    end

    if #state.mesh_watches == 0 then return end
    local still_watching_mesh = {}
    for _, w in ipairs(state.mesh_watches) do
        local alive = true
        for name, _ in pairs(w.bool_fields) do
            local ok_v, v = pcall(function() return w.obj:get_field(name) end)
            if ok_v then
                if v ~= w.last[name] then
                    log_line(string.format("  [%s] mesh bool field %s CHANGED: %s -> %s (t+%.2fs)",
                        w.label, name, tostring(w.last[name]), tostring(v), now - w.started_at))
                    w.last[name] = v
                end
            else
                alive = false
            end
        end
        for _, c in ipairs(w.getters) do
            local ok_v, v = pcall(function() return w.obj:call(c.name) end)
            if ok_v then
                local desc = describe_getter_value(v)
                if desc ~= w.last_getters[c.name] then
                    log_line(string.format("  [%s] mesh getter %s CHANGED: %s -> %s (t+%.2fs)",
                        w.label, c.name, tostring(w.last_getters[c.name]), desc, now - w.started_at))
                    w.last_getters[c.name] = desc
                end
            else
                alive = false
            end
        end
        if not alive then
            log_line("  [" .. w.label .. "] mesh component became unreadable at t+" ..
                string.format("%.2fs", now - w.started_at))
        elseif (now - w.started_at) < WATCH_DURATION_S then
            table.insert(still_watching_mesh, w)
        else
            log_line(string.format("  [%s] mesh watch expired after %.0fs", w.label, WATCH_DURATION_S))
        end
    end
    state.mesh_watches = still_watching_mesh
end)

re.on_draw_ui(function()
    if not imgui then return end
    if not imgui.tree_node("World Item Probe (pickup-object bug, OPEN)") then return end
    imgui.text_colored(
        "Passive only -- no writes, no calls, no input simulation.",
        0xFF88CCFF)
    imgui.text("Test 1: disable auto-complete, pick up an item MANUALLY (real navigation),")
    imgui.text("confirm the box disappears normally. Check log for what fired -- this is the reference.")
    imgui.text("Test 2: enable auto-complete, pick up a DIFFERENT item, see what's missing vs test 1.")
    imgui.spacing()
    imgui.text("Dumped: " .. tostring(state.dumped))
    imgui.text("Hooked: " .. tostring(state.hooked))
    imgui.spacing()
    if imgui.button("Clear on-screen log") then
        state.log_buffer = {}
    end
    for _, line in ipairs(state.log_buffer) do
        imgui.text(line)
    end
    imgui.tree_pop()
end)

log.info("[re2_vr_worlditem_probe] Loaded")
