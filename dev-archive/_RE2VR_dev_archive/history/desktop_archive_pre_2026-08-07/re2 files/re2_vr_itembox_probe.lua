-- Diagnostic only: is_menu_blocking() never detects the item box UI as
-- open (confirmed via live debug trace: block_hf stayed false throughout
-- two full open/close cycles). Look for a dedicated item-box singleton/
-- component with its own reliable "is open" flag instead of relying on
-- GUIMaster's generic state. GUIInventoryTreasure is already a known GUI
-- element name in re2_vr_holster.lua's list -- try it as a managed
-- singleton directly, plus a few other plausible names.
-- Safe to delete after checking the log.

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

local NS = sdk.game_namespace

local CANDIDATE_NAMES = {
    "gui.GUIInventoryTreasure",
    "GUIInventoryTreasure",
    "gui.GUITreasureBox",
    "GUITreasureBox",
    "gui.GUIItemBox",
    "GUIItemBox",
}

local function safe_call(obj, method)
    if not obj then return nil end
    local ok, v = pcall(function() return obj:call(method) end)
    if ok then return v end
    return nil
end

local function dump_type_level(tag, td, obj, depth)
    local ok_name, full_name = pcall(function() return td:get_full_name() end)
    log.info("[re2_vr_itembox_probe] " .. tag .. " L" .. depth .. " type: " .. tostring(ok_name and full_name or "?"))

    local ok_m, methods = pcall(function() return td:get_methods() end)
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            if ok_n and mname and (mname:lower():find("open") or mname:lower():find("active") or mname:lower():find("visible") or mname:lower():find("show")) then
                log.info("[re2_vr_itembox_probe]   [L" .. depth .. "] method: " .. mname)
            end
        end
    end
end

local function try_dump(tag, obj)
    if not obj then
        log.info("[re2_vr_itembox_probe] " .. tag .. ": not found (nil)")
        return
    end
    log.info("[re2_vr_itembox_probe] " .. tag .. ": FOUND")
    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    if ok_td and td then
        local depth = 0
        while td and depth < 6 do
            dump_type_level(tag, td, obj, depth)
            local ok_p, parent = pcall(function() return td:get_parent_type() end)
            if not ok_p or not parent then break end
            td = parent
            depth = depth + 1
        end
    end
end

log.info("[re2_vr_itembox_probe] Started. Open the item box now -- this will retry candidate singletons every ~2s and log every active GUI element name (unfiltered) while testing.")

-- Also: dump GUIMaster's own full method list, keyword-filtered, in case
-- there's a dedicated get_IsOpenTreasure/get_IsOpenItemBox-style method on
-- it that the existing is_menu_blocking() simply never checks.
local gm_td = sdk.find_type_definition(NS("gui.GUIMaster"))
if gm_td then
    log.info("[re2_vr_itembox_probe] --- GUIMaster methods containing box/treasure/item ---")
    local ok_m, methods = pcall(function() return gm_td:get_methods() end)
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            if ok_n and mname then
                local lower = mname:lower()
                if lower:find("box") or lower:find("treasure") or lower:find("item") then
                    log.info("[re2_vr_itembox_probe]   GUIMaster method: " .. mname)
                end
            end
        end
    end
end

-- Unfiltered: log EVERY active GUI element name as it changes (no
-- known-name filtering this time, unlike re2_vr_itemexamine_probe.lua),
-- so we see the item box's real element name even if it happens to match
-- something already assumed "known".
local last_active_names = {}
re.on_pre_gui_draw_element(function(element, context)
    local ok_go, go = pcall(function() return element:call("get_GameObject") end)
    if not ok_go or not go then return true end
    local ok_n, name = pcall(function() return go:call("get_Name") end)
    if not ok_n or type(name) ~= "string" or name == "" then return true end

    local active = false
    pcall(function() active = go:read_byte(0x10) == 1 end)

    if last_active_names[name] ~= active then
        last_active_names[name] = active
        log.info("[re2_vr_itembox_probe] GUI element '" .. name .. "' active=" .. tostring(active))
    end
    return true
end)

local dumped_any = false
local attempts = 0

re.on_frame(function()
    if dumped_any then return end
    attempts = attempts + 1
    if attempts % 120 ~= 0 then return end

    for _, name in ipairs(CANDIDATE_NAMES) do
        local ok, singleton = pcall(function() return sdk.get_managed_singleton(NS(name)) end)
        if not ok or not singleton then
            ok, singleton = pcall(function() return sdk.get_managed_singleton(name) end)
        end
        if ok and singleton then
            try_dump(name, singleton)
            dumped_any = true
        end
    end
end)
