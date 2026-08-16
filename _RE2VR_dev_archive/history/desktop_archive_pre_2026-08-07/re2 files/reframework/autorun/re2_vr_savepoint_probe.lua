-- Diagnostic only: is_menu_blocking() in re2_vr_holster.lua already checks
-- GUISave/GUISaveMenu (element names), isBusySave/get_IsBusy (getters), and
-- RefFileUI (ref field) for save-related UI, but the player reports the
-- same X-button-closes-typewriter-also-toggles-flashlight bug that
-- GUI_ItemBox had before it was found via re2_vr_itembox_probe.lua. Same
-- technique here: log every active GUI element name change, unfiltered, so
-- we see the typewriter/save-point screen's real element name even if it
-- doesn't match any of the guessed names above.
-- Safe to delete after checking the log.

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

local NS = sdk.game_namespace

log.info("[re2_vr_savepoint_probe] Started. Use the typewriter/save point now (open it, then close it with X) -- every active GUI element name change will be logged, plus GUIMaster methods containing save/file/type/writer/ribbon.")

-- Unfiltered: log EVERY active GUI element name as it changes, same as
-- re2_vr_itembox_probe.lua's approach (that's what found GUI_ItemBox).
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
        log.info("[re2_vr_savepoint_probe] GUI element '" .. name .. "' active=" .. tostring(active))
    end
    return true
end)

-- GUIMaster's own method list, keyword-filtered, in case there's a
-- dedicated get_IsOpenTypewriter/get_IsOpenSavePoint-style method that
-- is_menu_blocking() simply never checks (same idea as the item box's
-- isBusyItemBox/getItemBoxEnable getters).
local gm_td = sdk.find_type_definition(NS("gui.GUIMaster"))
if gm_td then
    log.info("[re2_vr_savepoint_probe] --- GUIMaster methods containing save/file/type/writer/ribbon ---")
    local ok_m, methods = pcall(function() return gm_td:get_methods() end)
    if ok_m and methods then
        for _, m in ipairs(methods) do
            local ok_n, mname = pcall(function() return m:get_name() end)
            if ok_n and mname then
                local lower = mname:lower()
                if lower:find("save") or lower:find("file") or lower:find("type") or lower:find("writer") or lower:find("ribbon") then
                    log.info("[re2_vr_savepoint_probe]   GUIMaster method: " .. mname)
                end
            end
        end
    end
end
