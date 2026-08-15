-- Diagnostic only: tries several plausible names/namespaces for the
-- low-level gamepad-state manager class, since the first guess
-- (sdk.game_namespace("HIDPadManager")) didn't resolve for RE2.
-- Safe to delete after checking the log.

local candidates = {
    "via.hid.HIDPadManager",
    "app.HIDPadManager",
    "app.ropeway.HIDPadManager",
    "via.hid.HID",
    "via.hid.HIDManager",
    "app.PadManager",
    "app.InputManager",
    "app.ropeway.PadManager",
    "app.ropeway.InputManager",
}

log.info("[re2_hidpad_probe2] Starting namespace sweep...")

for _, name in ipairs(candidates) do
    local ok, td = pcall(function() return sdk.find_type_definition(name) end)
    if ok and td then
        log.info("[re2_hidpad_probe2] FOUND: " .. name)
        local ok2, methods = pcall(function() return td:get_methods() end)
        if ok2 and methods then
            for _, m in ipairs(methods) do
                local ok3, mname = pcall(function() return m:get_name() end)
                if ok3 and mname and mname:lower():find("update") then
                    log.info("[re2_hidpad_probe2]   method: " .. mname)
                end
            end
        end
    else
        log.info("[re2_hidpad_probe2] not found: " .. name)
    end
end

log.info("[re2_hidpad_probe2] Sweep complete.")
