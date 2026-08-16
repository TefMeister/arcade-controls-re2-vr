-- Diagnostic only: inspects the REAL parameter types and return type for
-- changeWeapon(), useSubWeapon(), and updateEquip() on
-- app.ropeway.survivor.Equipment, plus anything else with "equip"/"weapon"/
-- "change" in its name. We already know these methods EXIST from the
-- earlier equipment probe; this time we want their actual signatures so we
-- can call changeWeapon() correctly instead of guessing blind.
-- Safe to delete after checking the log.

local NS = sdk.game_namespace

log.info("[re2_changeweapon_probe] Starting...")

local td = sdk.find_type_definition(NS("survivor.Equipment"))
if not td then
    log.warn("[re2_changeweapon_probe] survivor.Equipment type NOT found")
    return
end
log.info("[re2_changeweapon_probe] survivor.Equipment type found")

local keywords = { "change", "equip", "weapon", "useSub", "update" }

local function matches(name)
    local lower = name:lower()
    for _, kw in ipairs(keywords) do
        if lower:find(kw:lower()) then return true end
    end
    return false
end

local ok_m, methods = pcall(function() return td:get_methods() end)
if not ok_m or not methods then
    log.warn("[re2_changeweapon_probe] Could not enumerate methods")
    return
end

for _, m in ipairs(methods) do
    local ok_n, mname = pcall(function() return m:get_name() end)
    if ok_n and mname and matches(mname) then
        log.info("[re2_changeweapon_probe] === " .. mname .. " ===")

        local ok_s, is_static = pcall(function() return m:is_static() end)
        log.info("[re2_changeweapon_probe]   static: " .. tostring(ok_s and is_static or "?"))

        local ok_r, ret = pcall(function()
            local rt = m:get_return_type()
            return rt and rt:get_full_name() or "void/?"
        end)
        log.info("[re2_changeweapon_probe]   return: " .. tostring(ok_r and ret or "?"))

        local ok_np, num_params = pcall(function() return m:get_num_params() end)
        if ok_np and num_params then
            log.info("[re2_changeweapon_probe]   num_params: " .. tostring(num_params))

            local ok_pt, param_types = pcall(function() return m:get_param_types() end)
            if ok_pt and param_types then
                for i, pt in ipairs(param_types) do
                    local ok_pn, pname = pcall(function() return pt:get_full_name() end)
                    log.info("[re2_changeweapon_probe]     param " .. i .. ": " .. tostring(ok_pn and pname or "?"))
                end
            else
                log.warn("[re2_changeweapon_probe]   Could not get param_types")
            end
        else
            log.warn("[re2_changeweapon_probe]   Could not get num_params")
        end
    end
end

log.info("[re2_changeweapon_probe] Done.")
