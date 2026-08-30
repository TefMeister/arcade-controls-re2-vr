-- Diagnostic only: lists the named values of app.ropeway.EquipmentDefine.EquipCategory
-- (and WeaponParts, as a bonus) so we know the correct enum value to pass
-- for "Sub" when calling changeWeapon()/setForceEquipType().
-- Safe to delete after checking the log.

local NS = sdk.game_namespace

local function dump_enum(tag, full_name)
    log.info("[re2_enum_probe] === " .. full_name .. " ===")
    local td = sdk.find_type_definition(full_name)
    if not td then
        log.warn("[re2_enum_probe] " .. full_name .. " type NOT found")
        return
    end

    local ok, fields = pcall(function() return td:get_fields() end)
    if not ok or not fields then
        log.warn("[re2_enum_probe] Could not enumerate fields on " .. full_name)
        return
    end

    for _, f in ipairs(fields) do
        local ok_static, is_static = pcall(function() return f:is_static() end)
        if ok_static and is_static then
            local ok_n, fname = pcall(function() return f:get_name() end)
            local ok_v, value = pcall(function() return f:get_data(nil) end)
            if ok_n then
                log.info("[re2_enum_probe]   " .. tostring(fname) .. " = " .. tostring(ok_v and value or "?"))
            end
        end
    end
end

log.info("[re2_enum_probe] Starting...")
dump_enum("EquipCategory", NS("EquipmentDefine.EquipCategory"))
dump_enum("WeaponParts", NS("EquipmentDefine.WeaponParts"))
log.info("[re2_enum_probe] Done.")
