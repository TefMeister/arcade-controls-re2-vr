local is_re2 = reframework:get_game_name() == "re2"
local is_re3 = reframework:get_game_name() == "re3"

if not is_re2 and not is_re3 then
    return
end

local statics = require("utility/Statics")
local re2 = require("utility/RE2")

local transform_get_joint_by_hash = sdk.find_type_definition("via.Transform"):get_method("getJointByHash")
local gameobject_get_transform = sdk.find_type_definition("via.GameObject"):get_method("get_Transform")
local cast_ray_async_method = sdk.find_type_definition("via.physics.System"):get_method("castRayAsync(via.physics.CastRayQuery, via.physics.CastRayResult)")

local joint_get_position = sdk.find_type_definition("via.Joint"):get_method("get_Position")
local joint_get_rotation = sdk.find_type_definition("via.Joint"):get_method("get_Rotation")

local function write_vec4(obj, vec, offset)
    obj:write_float(offset, vec.x)
    obj:write_float(offset + 4, vec.y)
    obj:write_float(offset + 8, vec.z)
    obj:write_float(offset + 12, vec.w)
end

local cfg_path = "re2_vr/crosshair_config.json"

local cfg = {
    default_crosshair_behavior = false,
    disable_crosshair = false,
    disable_crosshair_firstperson = false,
    -- 2026-08-15: only draw the crosshair while (a) the currently equipped
    -- weapon has an optic/sight attachment on it and (b) the player is
    -- actively aiming (RG held) -- for weapons with no sight attachment,
    -- and whenever not aiming, the crosshair stays off. Meant to pair with
    -- a broken/suppressed sight dot: use this as the reliable replacement
    -- reticle only where the native one is actually broken, not everywhere.
    only_show_for_sight_weapons = false,
    -- Which bit of the weapon's real _WeaponParts represents "has a sight
    -- attachment" -- confirmed as bit 2 for wp3000 (Lightning Hawk) in a
    -- past investigation (see re2_vr_laser_sight_drift_status.md), NOT
    -- verified for other weapons. Adjustable here rather than hardcoded.
    sight_bit_index = 2,
}

local function load_cfg()
    local loaded_cfg = json.load_file(cfg_path)

    if loaded_cfg == nil then
        json.dump_file(cfg_path, cfg)
        return
    end

    for k, v in pairs(loaded_cfg) do
        cfg[k] = v
    end
end

load_cfg()

re.on_config_save(function()
    json.dump_file(cfg_path, cfg)
end)

-- Sight-gated crosshair (2026-08-15, see cfg.only_show_for_sight_weapons
-- above). Same GameObject.get_component / getComponent(System.Type)
-- pattern already used throughout this mod, and the same
-- Equipment.get_MainWeapon()._WeaponParts bit-check already proven in
-- re2_vr_suppress_sight_attachment.lua -- read-only here, no forcing.
local GameObject = require("utility/GameObject")
local NS = sdk.game_namespace
local survivor_condition_type = nil

local function get_equipment()
    local ok_p, player = pcall(function() return re2.get_localplayer() end)
    if not ok_p or not player then return nil end
    local ok_e, equipment = pcall(function()
        return GameObject.get_component(player, NS("survivor.Equipment"))
    end)
    return ok_e and equipment or nil
end

-- Returns the raw _WeaponParts int, or nil if unreadable (no weapon/arm,
-- field missing, etc.) -- exposed separately from the boolean check so the
-- UI can show the actual value for verifying/finding the right bit per
-- weapon (see re2_vr_laser_sight_drift_status.md -- JMB Hp3 showed no
-- correlation on bits 0-7, unlike the confirmed wp3000 bit 2).
local function get_current_weapon_parts()
    local equipment = get_equipment()
    if not equipment then return nil end
    local ok_arm, arm = pcall(function() return equipment:call("get_MainWeapon") end)
    if not ok_arm or not arm then return nil end
    local ok_wp, weapon_parts = pcall(function() return arm:get_field("_WeaponParts") end)
    if not ok_wp or weapon_parts == nil then return nil end
    return weapon_parts
end

local function current_weapon_has_sight()
    local weapon_parts = get_current_weapon_parts()
    if weapon_parts == nil then return false end
    local bit = 1 << cfg.sight_bit_index
    return (weapon_parts & bit) ~= 0
end

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

local function player_is_aiming()
    local ok_p, player = pcall(function() return re2.get_localplayer() end)
    if not ok_p or not player then return false end
    local cond = get_survivor_condition(player)
    if not cond then return false end
    local ok, aiming = pcall(function() return cond:call("get_IsHold") end)
    return ok and aiming == true
end

-- true = crosshair allowed to draw. When only_show_for_sight_weapons is
-- off (default), this is always true -- a pure no-op, existing behavior
-- unchanged.
local function is_crosshair_enabled()
    if not cfg.only_show_for_sight_weapons then return true end
    return current_weapon_has_sight() and player_is_aiming()
end

local tdb_version = sdk.get_tdb_version()

local CollisionLayer = nil
local CollisionFilter = nil

CollisionLayer = statics.generate("app.CollisionManager.Layer")
CollisionFilter = statics.generate("app.CollisionManager.Filter")

local crosshair_bullet_ray_result = nil
local crosshair_attack_ray_result = nil
local last_crosshair_time = os.clock()

local function cast_ray(start_pos, end_pos, layer)
    if layer == nil then
        layer = CollisionLayer.Bullet
    end

    local via_physics_system = sdk.get_native_singleton("via.physics.System")
    local ray_query = sdk.create_instance("via.physics.CastRayQuery")
    local ray_result = sdk.create_instance("via.physics.CastRayResult")

    ray_query:call("setRay(via.vec3, via.vec3)", start_pos, end_pos)
    ray_query:call("clearOptions")
    ray_query:call("enableAllHits")
    ray_query:call("enableNearSort")
    --ray_query:call("enableFrontFacingTriangleHits")
    --ray_query:call("disableBackFacingTriangleHits")
    local filter_info = ray_query:call("get_FilterInfo")
    filter_info:call("set_Group", 0)
    filter_info:call("set_MaskBits", 0xFFFFFFFF & ~1) -- everything except the player.

    filter_info:call("set_Layer", layer)
    ray_query:call("set_FilterInfo", filter_info)
    cast_ray_method:call(via_physics_system, ray_query, ray_result)

    return ray_result
end

local function cast_ray_async(ray_result, start_pos, end_pos, layer)
    if layer == nil then
        layer = CollisionLayer.Bullet
    end

    local via_physics_system = sdk.get_native_singleton("via.physics.System")
    local ray_query = sdk.create_instance("via.physics.CastRayQuery")
    local ray_result = ray_result or sdk.create_instance("via.physics.CastRayResult")

    ray_query:call("setRay(via.vec3, via.vec3)", start_pos, end_pos)
    ray_query:call("clearOptions")
    ray_query:call("enableAllHits")
    ray_query:call("enableNearSort")
    --ray_query:call("enableFrontFacingTriangleHits")
    --ray_query:call("disableBackFacingTriangleHits")
    local filter_info = ray_query:call("get_FilterInfo")
    filter_info:call("set_Group", 0)
    filter_info:call("set_MaskBits", 0xFFFFFFFF & ~1) -- everything except the player.

    filter_info:call("set_Layer", layer)
    ray_query:call("set_FilterInfo", filter_info)
    cast_ray_async_method:call(via_physics_system, ray_query, ray_result)

    return ray_result
end

local function update_crosshair_world_pos(start_pos, end_pos)
    if not vrmod:is_hmd_active() then return end
    
    -- asynchronous raycast
    if crosshair_attack_ray_result == nil or crosshair_bullet_ray_result == nil then
        crosshair_attack_ray_result = cast_ray_async(crosshair_attack_ray_result, start_pos, end_pos, 6)
        crosshair_bullet_ray_result = cast_ray_async(crosshair_bullet_ray_result, start_pos, end_pos, 3)
        crosshair_attack_ray_result:add_ref()
        crosshair_bullet_ray_result:add_ref()
    end

    local finished = crosshair_attack_ray_result:call("get_Finished") == true and crosshair_bullet_ray_result:call("get_Finished")
    local attack_hit = finished and crosshair_attack_ray_result:call("get_NumContactPoints") > 0
    local any_hit = finished and (attack_hit or crosshair_bullet_ray_result:call("get_NumContactPoints") > 0)

    if finished and any_hit then
        local best_result = attack_hit and crosshair_attack_ray_result or crosshair_bullet_ray_result
        local contact_point = best_result:call("getContactPoint(System.UInt32)", 0)

        if contact_point then
            re2.crosshair_dir = (end_pos - start_pos):normalized()
            re2.crosshair_normal = contact_point:get_field("Normal")
            re2.crosshair_distance = contact_point:get_field("Distance")

            --re2.crosshair_pos = contact_point:get_field("Position") -- We don't use the position because the cast was asynchronous
            -- instead we get the distance to the impact and add it to the current position
            re2.crosshair_pos = start_pos + (re2.crosshair_dir * re2.crosshair_distance)
        end
    else
        re2.crosshair_dir = (end_pos - start_pos):normalized()

        if re2.crosshair_distance then
            re2.crosshair_pos = start_pos + (re2.crosshair_dir * re2.crosshair_distance)
        else
            re2.crosshair_pos = start_pos + (re2.crosshair_dir * 10.0)
            re2.crosshair_distance = 10.0
        end
    end
    
    if finished then
        -- restart it.
        cast_ray_async(crosshair_attack_ray_result, start_pos, end_pos, 6)
        cast_ray_async(crosshair_bullet_ray_result, start_pos, end_pos, 3)
    end
end

local via_murmur_hash = sdk.find_type_definition("via.murmur_hash")
local via_murmur_hash_calc32 = via_murmur_hash:get_method("calc32")
local vfx_muzzle1_hash = via_murmur_hash_calc32:call(nil, "vfx_muzzle1")
local vfx_muzzle2_hash = via_murmur_hash_calc32:call(nil, "vfx_muzzle2")

local function update_muzzle_data()
    if re2.weapon then
        local param = re2.weapon:get_field("<FireBulletParam>k__BackingField")
        if not param then return end

        local fire_type = param:get_field("_FireBulletType")
        local is_camera_type = fire_type == 0

        local muzzle_joint = (not is_camera_type) and re2.weapon:get_field("<MuzzleJoint>k__BackingField") or nil

        if muzzle_joint ~= nil then
            muzzle_joint = muzzle_joint:get_field("_Parent")
        end

        if (not is_camera_type) and muzzle_joint == nil then
            local weapon_gameobject = re2.weapon:call("get_GameObject")

            if weapon_gameobject ~= nil then
                local transform = gameobject_get_transform(weapon_gameobject)

                if transform ~= nil then
                    muzzle_joint = transform_get_joint_by_hash(transform, vfx_muzzle1_hash)

                    if not muzzle_joint then
                        muzzle_joint = transform_get_joint_by_hash(transform, vfx_muzzle2_hash)
                    end
                end
            end
        end

        if muzzle_joint then
            local muzzle_position = joint_get_position(muzzle_joint)

            re2.last_muzzle_pos = muzzle_position
            re2.last_muzzle_forward = muzzle_joint:call("get_AxisZ")

            --if vrmod:is_using_controllers() then
                re2.last_shoot_dir = re2.last_muzzle_forward
                re2.last_shoot_pos = re2.last_muzzle_pos
            --end
        else
            local camera_mat = sdk.get_primary_camera():get_WorldMatrix()

            re2.last_muzzle_pos = camera_mat[3]
            re2.last_muzzle_pos.w = 1.0
            local muzzle_rot = camera_mat:to_quat()
            re2.last_muzzle_forward = (muzzle_rot * Vector3f.new(0, 0, -1)):normalized()

            re2.last_shoot_dir = re2.last_muzzle_forward
            re2.last_shoot_pos = re2.last_muzzle_pos + (re2.last_muzzle_forward * 0.1)
        end
    end
end

local reticle_names = {
    "GUI_Reticle"
}

for i, v in ipairs(reticle_names) do
    reticle_names[v] = true
end

re.on_draw_ui(function()
    local changed = false
    changed, cfg.default_crosshair_behavior = imgui.checkbox("Default crosshair behavior", cfg.default_crosshair_behavior)
    changed, cfg.disable_crosshair = imgui.checkbox("Disable crosshair", cfg.disable_crosshair)
    changed, cfg.disable_crosshair_firstperson = imgui.checkbox("Disable crosshair (First Person only)", cfg.disable_crosshair_firstperson)

    imgui.spacing()
    changed, cfg.only_show_for_sight_weapons = imgui.checkbox(
        "Only show crosshair for sight-equipped weapons while aiming", cfg.only_show_for_sight_weapons)
    imgui.text_colored(
        "Off by default. Weapons with no sight attachment never show the crosshair; sight-equipped weapons only show it while RG (aim) is held.",
        0xFF88CCFF)
    if cfg.only_show_for_sight_weapons then
        changed, cfg.sight_bit_index = imgui.slider_int("Sight WeaponParts bit index", cfg.sight_bit_index, 0, 15)
        local raw = get_current_weapon_parts()
        imgui.text(string.format("Live WeaponParts: %s  (0x%s)",
            raw and tostring(raw) or "unreadable", raw and string.format("%X", raw) or "?"))
        imgui.text(string.format("Weapon has sight (bit %d): %s -- aiming: %s",
            cfg.sight_bit_index, tostring(current_weapon_has_sight()), tostring(player_is_aiming())))
    end
end)

re.on_application_entry("LockScene", function()
    if not vrmod:is_hmd_active() then return end
    local disable_crosshair = cfg.default_crosshair_behavior or
                              cfg.disable_crosshair or
                              (firstpersonmod:will_be_used() and cfg.disable_crosshair_firstperson) or
                              not is_crosshair_enabled()

    if not disable_crosshair and (os.clock() - last_crosshair_time) < 1.0 then
        update_muzzle_data()

        if re2.last_shoot_pos then
            local pos = re2.last_shoot_pos + (re2.last_shoot_dir * 0.02)
            update_crosshair_world_pos(pos, pos + (re2.last_shoot_dir * 1000.0))
        end
    end
end)

re.on_pre_gui_draw_element(function(element, context)
    if not vrmod:is_hmd_active() then return true end

    local game_object = element:call("get_GameObject")
    if game_object == nil then return true end

    local name = game_object:call("get_Name")

    --log.info("drawing element: " .. name)

    if reticle_names[name] then
        if not is_crosshair_enabled() then
            return false
        end

        if cfg.default_crosshair_behavior then
            return not cfg.disable_crosshair
        end

        if cfg.disable_crosshair then
            return false
        end

        if firstpersonmod:will_be_used() and cfg.disable_crosshair_firstperson then
            return false
        end
    end

    -- set the world position of the crosshair/reticle to the trace end position
    -- also fixes scopes.
    if reticle_names[name] then
        last_crosshair_time = os.clock()

        if re2.crosshair_pos then
            local transform = game_object:call("get_Transform")

            if transform then
                vrmod:unhide_crosshair()
                --[[if transform.set_position ~= nil then
                    transform:set_position(re2.crosshair_pos, true)
                else
                    transform_set_position(transform, re2.crosshair_pos)
                end]]

                local new_mat = re2.crosshair_dir:to_quat():to_mat4()
                local distance = re2.crosshair_distance * 0.1
                if distance > 10 then
                    distance = 10
                end

                if distance < 0.3 then
                    distance = 0.3
                end

                local crosshair_pos = Vector4f.new(re2.crosshair_pos.x, re2.crosshair_pos.y, re2.crosshair_pos.z, 1.0)

                if tdb_version == 70 then
                    write_vec4(transform, new_mat[0] * distance, 0x80)
                    write_vec4(transform, new_mat[1] * distance, 0x90)
                    write_vec4(transform, new_mat[2] * distance, 0xA0)
                    write_vec4(transform, crosshair_pos, 0xB0)
                elseif tdb_version == 66 then
                    write_vec4(transform, new_mat[0] * distance, 0x80)
                    write_vec4(transform, new_mat[1] * distance, 0x90)
                    write_vec4(transform, new_mat[2] * distance, 0xA0)
                    write_vec4(transform, crosshair_pos, 0xB0)
                elseif tdb_version == 67 then
                    write_vec4(transform, new_mat[0] * distance, 0x80)
                    write_vec4(transform, new_mat[1] * distance, 0x90)
                    write_vec4(transform, new_mat[2] * distance, 0xA0)
                    write_vec4(transform, crosshair_pos, 0xB0)
                end
            end
        end
    end

    return true
end)