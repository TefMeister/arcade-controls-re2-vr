-- Diagnostic only: checks whether HIDPadManager.doUpdate can be found and
-- hooked for RE2, before we build the real trigger/dpad suppression on it.
-- Safe to delete after checking the log.

local NS = sdk.game_namespace

local td = sdk.find_type_definition(NS("HIDPadManager"))
if not td then
    log.warn("[re2_hidpad_probe] HIDPadManager type NOT found")
    return
end
log.info("[re2_hidpad_probe] HIDPadManager type found")

local method = td:get_method("doUpdate")
if not method then
    log.warn("[re2_hidpad_probe] HIDPadManager.doUpdate method NOT found")
    return
end
log.info("[re2_hidpad_probe] HIDPadManager.doUpdate method found")

local ok, err = pcall(function()
    sdk.hook(method,
        function(args)
            if not rawget(_G, "__probe_logged_once") then
                rawset(_G, "__probe_logged_once", true)
                log.info("[re2_hidpad_probe] doUpdate pre-hook firing OK")
            end
        end,
        function(retval)
            return retval
        end)
end)

if ok then
    log.info("[re2_hidpad_probe] Hook installed successfully")
else
    log.warn("[re2_hidpad_probe] Hook install FAILED: " .. tostring(err))
end
