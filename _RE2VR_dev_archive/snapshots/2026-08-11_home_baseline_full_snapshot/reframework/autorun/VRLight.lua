-- Promenljive za praćenje stanja tastature i moda
local mod_active = true
local key_was_down = false

re.on_frame(function()
    -- 1. ISPRAVLJENA PROVERA TASTERA (Taster "L" - kod 0x4C)
    -- Koristimo ispravan "reframework:is_key_down" poziv
    local is_key_down = reframework:is_key_down(0x4C) 
    
    if is_key_down and not key_was_down then
        mod_active = not mod_active -- Prebacuje upaljeno/ugašeno
    end
    key_was_down = is_key_down 

    -- 2. LOGIKA ZA SAKRIVANJE SVETLA POD MAPU
    local scene = sdk.call_native_func(
        sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"),
        "get_CurrentScene"
    )
    if not scene then return end

    for _, name in ipairs({"SweetLight", "PlayerSweetLight", "EnvironmentSweetLight"}) do
        local go = scene:call("findGameObject(System.String)", name)
        if go then 
            local transform = go:call("get_Transform")
            if transform then
                local new_pos
                
                if mod_active then
                    -- MOD UKLJUČEN: 
                    new_pos = Vector3f.new(-0.7, 0.0, 0.0) 
                else
                    -- MOD ISKLJUČEN: 
                    new_pos = Vector3f.new(0.0, -1000.0, 0.0) 
                end
                
                transform:call("set_LocalPosition", new_pos)
            end
        end
    end
end)
