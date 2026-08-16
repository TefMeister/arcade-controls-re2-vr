-- Diagnostic only (read-only, no writes) -- investigating why weapons
-- granted via re2_vr_inventory_auto_complete.lua's new "bypass allowlist,
-- auto-pickup ALL items" stress-test toggle equip fine (visually held) but
-- never actually enter aim mode (RG does nothing). Already checked and
-- RULED OUT: GetItemStock.DefaultItem's WeaponId/BulletId/WeaponParts
-- fields (the inventory-slot-level stock data) -- these read identically
-- (-1/0/0) for both the broken auto-granted weapon and an ordinary ammo
-- box, so they're not the smoking gun.
--
-- This probe looks at a DIFFERENT object instead: the LIVE equipped weapon
-- component (survivor.Equipment.EquipWeapon, read via utility/RE2.lua's
-- get_weapon_object -- already proven elsewhere in this mod, e.g.
-- re2_vr_recoil.lua/re2_vr_ik_extention.lua use the same accessor). This is
-- the actual native weapon INSTANCE, not inventory stock data, and is a
-- much more likely place for whatever "is this weapon ready to fire" state
-- lives.
--
-- Technique: on RG (aim button) rising edge, dump the current EquipWeapon
-- component's full type hierarchy (fields+methods, unfiltered, same proven
-- on_pre_gui_draw_element-adjacent technique used throughout this session,
-- adapted here to a plain per-frame check since this isn't a GUI element)
-- ONCE per distinct weapon GameObject (cached by tostring identity, so
-- switching weapons re-dumps). Also tracks get_IsHold() (SurvivorCondition,
-- the native "currently aiming" flag -- proven read elsewhere in this mod)
-- every frame RG is held, logging on every CHANGE, to see whether native
-- aim-recognition ever fires at all for the broken weapon, or whether it's
-- stuck the whole time.
--
-- Safe to delete/archive once findings are captured.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local vrc_manager = require("vr/VRControllerManager")
local NS = sdk.game_namespace

local survivor_condition_type = nil
local function get_survivor_condition(player)
    if not player then return nil end
    if not survivor_condition_type then
        survivor_condition_type = sdk.typeof(NS("survivor.SurvivorCondition"))
    end
    if not survivor_condition_type then return nil end
    local ok, cond = pcall(function()
        return player:call("getComponent(System.Type)", survivor_condition_type)
    end)
    return ok and cond or nil
end

local function get_is_hold()
    local cond = get_survivor_condition(re2.get_localplayer())
    if not cond then return nil end
    local ok, aiming = pcall(function() return cond:call("get_IsHold") end)
    return ok and aiming or nil
end

local function is_right_grip_pressed()
    if vrc_manager:has_controllers() then
        local rc = vrc_manager.controllers_list[2]
        if rc then
            return rc:is_action_active(vrc_manager.Actions.GRIP) == true
        end
    end
    if not vrmod then return false end
    local ok_rj, rj = pcall(function() return vrmod:get_right_joystick() end)
    if not ok_rj or not rj then return false end
    local ok_a, action = pcall(function() return vrmod:get_action_grip() end)
    if not ok_a or not action then return false end
    local ok_v, v = pcall(function() return vrmod:is_action_active(action, rj) end)
    return ok_v and v == true
end

local function dump_full_type_hierarchy(tag, obj, max_depth)
    if not obj then
        log.info("[weapon_aim_probe] " .. tag .. ": object unavailable")
        return
    end
    local ok_td, td = pcall(function() return obj:get_type_definition() end)
    if not ok_td or not td then
        log.info("[weapon_aim_probe] " .. tag .. ": no type definition")
        return
    end
    local depth = 0
    while td and depth < (max_depth or 5) do
        local ok_name, full_name = pcall(function() return td:get_full_name() end)
        log.info("[weapon_aim_probe] " .. tag .. " L" .. depth .. " type: " .. tostring(ok_name and full_name or "?"))
        local ok_f, fields = pcall(function() return td:get_fields() end)
        if ok_f and fields then
            for _, f in ipairs(fields) do
                local ok_n, fname = pcall(function() return f:get_name() end)
                if ok_n and fname then
                    local ok_static, is_static = pcall(function() return f:is_static() end)
                    local ok_v, v
                    if ok_static and is_static then
                        ok_v, v = pcall(function() return f:get_data(nil) end)
                    else
                        ok_v, v = pcall(function() return f:get_data(obj) end)
                    end
                    log.info(string.format("[weapon_aim_probe]   [L%d] field: %s = %s", depth, fname, tostring(ok_v and v or "?")))
                end
            end
        end
        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if not ok_p or not parent then break end
        td = parent
        depth = depth + 1
    end
end

local dumped_weapons = {}
local last_rg = false
local last_is_hold = nil

re.on_frame(function()
    local rg = is_right_grip_pressed()
    local is_hold = get_is_hold()

    if rg and not last_rg then
        log.info("[weapon_aim_probe] === RG rising edge (aim attempt) === IsHold at press moment: " .. tostring(is_hold))
        local _, weapon = re2.get_weapon_object(re2.get_localplayer())
        if weapon then
            local key = tostring(weapon)
            if not dumped_weapons[key] then
                dumped_weapons[key] = true
                log.info("[weapon_aim_probe] Dumping equipped weapon component (first time seeing this instance)")
                dump_full_type_hierarchy("EquipWeapon", weapon, 5)
            else
                log.info("[weapon_aim_probe] Equipped weapon instance already dumped this session (key=" .. key .. ")")
            end
        else
            log.info("[weapon_aim_probe] get_weapon_object returned nil -- no equipped weapon component found")
        end
    end
    last_rg = rg

    if is_hold ~= last_is_hold then
        log.info(string.format("[weapon_aim_probe] IsHold changed: %s -> %s (RG=%s)",
            tostring(last_is_hold), tostring(is_hold), tostring(rg)))
        last_is_hold = is_hold
    end
end)

re.on_draw_ui(function()
    if not imgui then return end
    imgui.text("Weapon aim probe (read-only)")
    imgui.text("Prefix to grep: [weapon_aim_probe]")
    imgui.text("RG: " .. tostring(last_rg) .. "  IsHold: " .. tostring(last_is_hold))
    imgui.text_colored("Equip the broken weapon, then press/hold RG (aim) a few times.", 0xFF88CCFF)
end)

log.info("[weapon_aim_probe] Loaded. Equip the broken weapon, then press/hold RG (aim) a few times.")
