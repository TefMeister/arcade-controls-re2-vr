-- One-shot, read-only diagnostic: enumerate whatever "firstpersonmod" (the
-- REFramework built-in VR first-person camera plugin, already used
-- elsewhere in this mod for will_be_used()/set_block_left_hand_ik()/etc.)
-- actually exposes. Goal: find out whether it has any camera-anchor/offset/
-- head-joint-override API at all before assuming one exists or doesn't.

if reframework:get_game_name() ~= "re2" then
    return
end

local dumped = false

re.on_frame(function()
    if dumped then return end
    if firstpersonmod == nil then return end
    dumped = true

    log.info("[fpmod_probe] type(firstpersonmod) = " .. type(firstpersonmod))

    if type(firstpersonmod) == "table" or type(firstpersonmod) == "userdata" then
        local ok, err = pcall(function()
            local count = 0
            for k, v in pairs(firstpersonmod) do
                log.info(string.format("[fpmod_probe]   key=%s  type=%s", tostring(k), type(v)))
                count = count + 1
            end
            log.info(string.format("[fpmod_probe] --- %d keys via pairs() ---", count))
        end)
        if not ok then
            log.warn("[fpmod_probe] pairs() failed: " .. tostring(err))
        end
    end

    -- Also try treating it as a reflectable managed object, in case pairs()
    -- doesn't see everything (common for userdata proxies).
    local ok2, td = pcall(function() return firstpersonmod:get_type_definition() end)
    if ok2 and td then
        local ok_name, name = pcall(function() return td:get_full_name() end)
        log.info("[fpmod_probe] managed type: " .. (ok_name and name or "?"))
        local methods = td:get_methods()
        if methods then
            for _, m in ipairs(methods) do
                local ok3, mname = pcall(function() return m:get_name() end)
                if ok3 then
                    log.info("[fpmod_probe]   method: " .. mname)
                end
            end
        end
    else
        log.info("[fpmod_probe] not a reflectable managed object (expected for a Lua-side proxy)")
    end
end)

log.info("[re2_vr_firstpersonmod_probe] Loaded")
