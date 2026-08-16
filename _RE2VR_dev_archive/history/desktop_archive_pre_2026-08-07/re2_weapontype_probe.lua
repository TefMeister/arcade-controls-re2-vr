-- Diagnostic only: lists every member of the WeaponType enum (Main, Sub,
-- etc.) with its underlying numeric value, so we know exactly what to write
-- into ForceEquipType. Safe to delete after checking the log.

local NS = sdk.game_namespace

log.info("[re2_weapontype_probe] Starting...")

local td = sdk.find_type_definition(NS("EquipmentDefine.WeaponType"))
if not td then
    log.warn("[re2_weapontype_probe] WeaponType type NOT found")
    return
end
log.info("[re2_weapontype_probe] WeaponType type found")

local ok_f, fields = pcall(function() return td:get_fields() end)
if not ok_f or not fields then
    log.warn("[re2_weapontype_probe] Could not enumerate fields")
    return
end

for _, f in ipairs(fields) do
    local ok1, fname = pcall(function() return f:get_name() end)
    local ok2, is_static = pcall(function() return f:is_static() end)
    if ok1 and fname and ok2 and is_static then
        local ok3, val = pcall(function() return f:get_data(nil) end)
        log.info("[re2_weapontype_probe] " .. fname .. " = " .. tostring(ok3 and val or "?"))
    end
end

log.info("[re2_weapontype_probe] Done.")
