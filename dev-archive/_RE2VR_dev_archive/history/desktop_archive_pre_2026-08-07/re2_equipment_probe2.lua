-- Diagnostic only: lists BOTH methods and fields on app.ropeway.survivor.Equipment.
-- We're specifically hunting for a simple boolean-ish property that governs
-- "sub-weapon ready" (knife/grenade held out), since that may be a plain
-- flag the native game checks every frame rather than a function to call.
-- Safe to delete after checking the log.

local NS = sdk.game_namespace

log.info("[re2_equipment_probe2] Starting...")

local td = sdk.find_type_definition(NS("survivor.Equipment"))
if not td then
    log.warn("[re2_equipment_probe2] survivor.Equipment type NOT found")
    return
end
log.info("[re2_equipment_probe2] survivor.Equipment type found")

local keywords = { "sub", "melee", "knife", "grenade", "ready", "change", "switch", "select", "item", "throw", "hand" }

local function matches(name)
    local lower = name:lower()
    for _, kw in ipairs(keywords) do
        if lower:find(kw) then return true end
    end
    return false
end

-- Methods
local ok_m, methods = pcall(function() return td:get_methods() end)
if ok_m and methods then
    log.info("[re2_equipment_probe2] --- All methods ---")
    for _, m in ipairs(methods) do
        local ok, mname = pcall(function() return m:get_name() end)
        if ok and mname then log.info("[re2_equipment_probe2] METHOD: " .. mname) end
    end
else
    log.warn("[re2_equipment_probe2] Could not enumerate methods")
end

-- Fields
local ok_f, fields = pcall(function() return td:get_fields() end)
if ok_f and fields then
    log.info("[re2_equipment_probe2] --- All fields ---")
    for _, f in ipairs(fields) do
        local ok, fname = pcall(function() return f:get_name() end)
        local ok2, ftype = pcall(function()
            local t = f:get_type()
            return t and t:get_full_name() or "?"
        end)
        if ok and fname then
            log.info("[re2_equipment_probe2] FIELD: " .. fname .. "  (type: " .. tostring(ok2 and ftype or "?") .. ")")
        end
    end
else
    log.warn("[re2_equipment_probe2] Could not enumerate fields")
end

-- Filtered candidates from both
log.info("[re2_equipment_probe2] --- Likely candidates (methods + fields) ---")
if ok_m and methods then
    for _, m in ipairs(methods) do
        local ok, mname = pcall(function() return m:get_name() end)
        if ok and mname and matches(mname) then
            log.info("[re2_equipment_probe2] CANDIDATE METHOD: " .. mname)
        end
    end
end
if ok_f and fields then
    for _, f in ipairs(fields) do
        local ok, fname = pcall(function() return f:get_name() end)
        if ok and fname and matches(fname) then
            log.info("[re2_equipment_probe2] CANDIDATE FIELD: " .. fname)
        end
    end
end

log.info("[re2_equipment_probe2] Done.")
