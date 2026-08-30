-- Diagnostic only: is_menu_blocking() (re2_vr_holster.lua) misses the item
-- examine/inspect overlay (confirmed: pressing X to close it also toggles
-- the flashlight, meaning is_menu_blocking() returned false at that
-- moment). Logs (a) every active GUI element name not already in
-- is_menu_blocking()'s known BLOCKING_GUI_NAMES list, and (b) a snapshot of
-- GUIMaster's state/flags, whenever something changes, so we can find the
-- correct name/flag to add.
-- Safe to delete after checking the log.

if reframework:get_game_name() ~= "re2" and reframework:get_game_name() ~= "re3" then
    return
end

local NS = sdk.game_namespace

-- Mirrors re2_vr_holster.lua's known list so we only log NEW names.
local KNOWN_BLOCKING_GUI_NAMES = {
    GUIInventory = true, GUIInventoryMenu = true, GUIInventoryTreasure = true,
    GUIInventoryCraft = true, GUIInventoryKeyItem = true, GUIMap = true,
    GUIShopBg = true, GUIPause = true, GUISaveLoad = true, GUIFile = true,
    GUIFileList = true, GUIFileMenu = true, GUISave = true, GUISaveMenu = true,
    GUIMainMenu = true, GUIPhotoMode = true, GUIBinder = true,
    Gui_ui3030 = true, Gui_ui3040 = true, Gui_ui3050 = true, Gui_ui3060 = true,
}

local seen_names = {}

local function safe_call(obj, method)
    if not obj then return nil end
    local ok, v = pcall(function() return obj:call(method) end)
    if ok then return v end
    return nil
end

re.on_pre_gui_draw_element(function(element, context)
    local go = safe_call(element, "get_GameObject")
    if not go then return true end
    local name = safe_call(go, "get_Name")
    if type(name) ~= "string" or name == "" then return true end
    if KNOWN_BLOCKING_GUI_NAMES[name] then return true end

    local active = false
    pcall(function() active = go:read_byte(0x10) == 1 end)
    if not active then return true end

    if not seen_names[name] then
        seen_names[name] = true
        log.info("[re2_vr_itemexamine_probe] NEW active GUI element name: " .. name)
    end
    return true
end)

local last_snapshot = ""

re.on_frame(function()
    local gm = sdk.get_managed_singleton(NS("gui.GUIMaster"))
    if not gm then return end

    local state = nil
    pcall(function() state = gm:get_field("<State_>k__BackingField") end)

    local is_inv = safe_call(gm, "get_IsOpenInventory")
    local is_map = safe_call(gm, "get_IsOpenMap")
    local is_pause = safe_call(gm, "get_IsOpenPause")

    local snapshot = string.format("State=%s IsOpenInventory=%s IsOpenMap=%s IsOpenPause=%s",
        tostring(state), tostring(is_inv), tostring(is_map), tostring(is_pause))

    if snapshot ~= last_snapshot then
        log.info("[re2_vr_itemexamine_probe] GUIMaster snapshot: " .. snapshot)
        last_snapshot = snapshot
    end
end)

log.info("[re2_vr_itemexamine_probe] Started. Open inventory, examine an item, close it with X, then check the log.")
