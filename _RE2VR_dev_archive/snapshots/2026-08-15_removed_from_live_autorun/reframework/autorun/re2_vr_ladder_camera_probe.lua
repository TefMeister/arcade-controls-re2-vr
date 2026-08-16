-- Diagnostic: finds what native state/flag actually drives ladder-climbing
-- camera behavior. Player reports that while climbing a ladder, the VR view
-- turns to face whatever direction the HMD was pointing at the last standing-
-- origin reset/recenter, instead of consistently facing forward -- nothing
-- in this mod currently touches ladders at all, so this is entirely
-- unexplored territory. Same reflection-dump technique used successfully in
-- past investigations (e.g. re2_vr_re2character_pl1000_bugfix, the pl1000
-- naming bug) -- enumerate real component/method names instead of guessing.
--
-- How to use: get ON a ladder in-game (actively climbing), open the
-- "Ladder Camera Probe" panel, press "Dump ladder/climb state now". Report
-- back whatever it prints -- especially any component/method whose name
-- contains "ladder" or "climb", and the camera/standing_origin readout for
-- correlation with the drift.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local GameObject = require("utility/GameObject")
local NS = sdk.game_namespace

local state = {
    last_dump = "No dump yet -- get ON a ladder, then press the button below.",
    -- 2026-08-15 continued: BusyCameraType read back as 0 (a THIRD value,
    -- neither EVENT=6 nor ACTION=5) and the other three flags all read nil
    -- on the one-shot manual-button capture. Real risk, precedented
    -- elsewhere in this project (re2_vr_aim_alignment_probe.lua's own
    -- comment: pressing an overlay button requires taking a hand off,
    -- which can drop the very state being diagnosed -- aiming there,
    -- climbing here): the player likely wasn't actually mid-climb the
    -- instant the button-press was processed. Switching to a timed burst
    -- (press once, then have ~5s to actually grab the ladder and climb)
    -- instead of a single instantaneous snapshot.
    frame = 0,
    burst_remaining = 0,
}

local BURST_FRAMES = 300 -- ~5s at 60fps

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

local function name_matches(name)
    if type(name) ~= "string" then return false end
    local n = name:lower()
    return n:find("ladder") ~= nil or n:find("climb") ~= nil
end

-- 2026-08-15 continued: both the player-component scan and the reused
-- cutscene-busy-state signals came back as REAL, confirmed negatives (300
-- solid mid-climb frames for the latter). Neither the player GameObject nor
-- native camera-blocking state knows anything about ladders. Next angle:
-- the mechanism might live on the LADDER PROP ITSELF, not the player.
--
-- Raycast setup below reuses the exact SYNCHRONOUS castRay pattern already
-- proven working in this codebase (re2_vr_haptics.lua's
-- cast_physics_ray_on_layer, re8_vr.lua) -- via.physics.CastRayQuery/
-- CastRayResult, same FilterInfo/MaskBits setup. Deliberately the sync
-- version, not crosshair.lua's async one -- sync resolves same-call, no
-- multi-frame polling complexity needed for a diagnostic.
--
-- Every prior use of getContactPoint() in this codebase (crosshair.lua x3,
-- haptics.lua) only ever reads Distance/Normal/Position off it -- nobody
-- has ever checked whether it ALSO exposes a hit Collider/RigidBody/
-- GameObject reference, because nobody needed one before. dump_contact_point_fields
-- below does a full reflection dump of whatever fields/methods actually
-- exist on it, instead of assuming there's nothing more there.
local cast_ray_method = safe(function()
    return sdk.find_type_definition("via.physics.System"):get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
end)

local function cast_ray_sync(start_pos, end_pos)
    if not cast_ray_method then return nil end
    local via_physics_system = safe(function() return sdk.get_native_singleton("via.physics.System") end)
    if not via_physics_system then return nil end
    local ray_query = safe(function() return sdk.create_instance("via.physics.CastRayQuery") end)
    local ray_result = safe(function() return sdk.create_instance("via.physics.CastRayResult") end)
    if not ray_query or not ray_result then return nil end

    local ok = pcall(function()
        ray_query:call("setRay(via.vec3, via.vec3)", start_pos, end_pos)
        ray_query:call("clearOptions")
        ray_query:call("enableAllHits")
        ray_query:call("enableNearSort")
        local filter_info = ray_query:call("get_FilterInfo")
        filter_info:call("set_Group", 0)
        filter_info:call("set_MaskBits", 0xFFFFFFFF - 1) -- everything except the player
        ray_query:call("set_FilterInfo", filter_info)
        cast_ray_method:call(via_physics_system, ray_query, ray_result)
    end)
    if not ok then return nil end
    return ray_result
end

local function get_camera_pos_forward()
    local cam = safe(function() return sdk.get_primary_camera() end)
    if not cam then return nil, nil end
    local mat = safe(function() return cam:call("get_WorldMatrix") end)
    if not mat then return nil, nil end
    local pos = mat[3]
    local rot = safe(function() return mat:to_quat() end)
    local fwd = rot and safe(function() return (rot * Vector3f.new(0, 0, -1)):normalized() end)
    return pos, fwd
end

-- 2026-08-15 continued: camera-forward-only got ZERO hits across a full
-- burst -- expected in hindsight, since the player looks around freely
-- while climbing, not necessarily straight at a rung. Body/root forward is
-- stable regardless of head direction (same convention already confirmed
-- working in re2_vr_ik_extention.lua's get_spine_forward -- root forward is
-- +Z, NOT camera's -Z convention). Chest-height offset since get_Position
-- on the root transform is usually near the feet.
local function get_player_pos_forward()
    local player = safe(function() return re2.get_localplayer() end)
    if not player then return nil, nil end
    local tf = safe(function() return player:call("get_Transform") end)
    if not tf then return nil, nil end
    local pos = safe(function() return tf:call("get_Position") end)
    local rot = safe(function() return tf:call("get_Rotation") end)
    local fwd = rot and safe(function() return (rot * Vector3f.new(0, 0, 1)):normalized() end)
    if pos then pos = Vector3f.new(pos.x, pos.y + 1.2, pos.z) end
    return pos, fwd
end

local function dump_contact_point_fields(cp)
    local lines = {}
    local tdef = safe(function() return cp:get_type_definition() end)
    if not tdef then return lines end
    local fields = safe(function() return tdef:get_fields() end) or {}
    for _, f in ipairs(fields) do
        local fname = safe(function() return f:get_name() end)
        if fname then
            local ok_v, v = pcall(function() return cp:get_field(fname) end)
            table.insert(lines, string.format("  contactpoint field %s = %s", fname, ok_v and tostring(v) or "?"))
        end
    end
    local methods = safe(function() return tdef:get_methods() end) or {}
    for _, m in ipairs(methods) do
        local mname = safe(function() return m:get_name() end)
        if mname then
            table.insert(lines, "  contactpoint method: " .. mname)
        end
    end
    return lines
end

local function dump_component(lines, comp)
    local tdef = safe(function() return comp:get_type_definition() end)
    if not tdef then return end
    local tname = safe(function() return tdef:get_full_name() end)
    if not tname then return end

    local methods = safe(function() return tdef:get_methods() end) or {}
    local hits = {}
    for _, m in ipairs(methods) do
        local mname = safe(function() return m:get_name() end)
        if name_matches(mname) then
            table.insert(hits, mname)
        end
    end

    if name_matches(tname) or #hits > 0 then
        table.insert(lines, string.format("[component] %s%s", tname, name_matches(tname) and "  <-- NAME MATCH" or ""))
        for _, mname in ipairs(hits) do
            local ok_call, val = pcall(function() return comp:call(mname) end)
            table.insert(lines, string.format("    %s() = %s", mname, ok_call and tostring(val) or "call failed (may need args)"))
        end
    end
end

-- One-shot: player GameObject/component structural scan. Timing-insensitive
-- (components don't come and go based on climbing state), safe as a manual
-- button. CONFIRMED 2026-08-15: 91 components scanned, ZERO ladder/climb-
-- named matches -- a real negative, not expected to change run to run.
local function dump_components_once()
    local lines = {}
    local player = re2.get_localplayer()
    if not player then
        state.last_dump = "no local player"
        return
    end

    local go_tdef = safe(function() return player:get_type_definition() end)
    local go_methods = go_tdef and safe(function() return go_tdef:get_methods() end) or {}
    for _, m in ipairs(go_methods) do
        local name = safe(function() return m:get_name() end)
        if name_matches(name) then
            table.insert(lines, "[player GameObject method] " .. name)
        end
    end

    local components = GameObject.get_components(player) or {}
    table.insert(lines, string.format("(scanned %d components)", #components))
    for _, comp in ipairs(components) do
        dump_component(lines, comp)
    end

    if #lines == 0 then
        table.insert(lines, "no ladder/climb-named methods or components found")
    end

    state.last_dump = table.concat(lines, "\n")
    log.info("[re2_vr_ladder_camera_probe]\n" .. state.last_dump)
end

-- Per-frame camera-state readout, called every frame during a timed burst
-- (not a single instantaneous snapshot) -- 2026-08-15 continued: a manual
-- one-shot button capture read BusyCameraType=0 and everything else nil,
-- most likely because pressing the overlay button interrupts the actual
-- climb (same class of problem re2_vr_aim_alignment_probe.lua already hit
-- for aiming). A multi-second burst gives time to press, then actually grab
-- the ladder and climb, so at least SOME frames land while genuinely
-- mid-climb.
local function log_camera_state_frame()
    local parts = {}

    local cam = safe(function() return sdk.get_primary_camera() end)
    local cam_rot = cam and safe(function() return cam:call("get_Rotation") end)
    table.insert(parts, string.format("cam_rot=(%.3f,%.3f,%.3f,w=%s)",
        cam_rot and (cam_rot.x or 0) or 0, cam_rot and (cam_rot.y or 0) or 0,
        cam_rot and (cam_rot.z or 0) or 0, cam_rot and tostring(cam_rot.w) or "nil"))

    if vrmod and type(vrmod.get_standing_origin) == "function" then
        local origin = safe(function() return vrmod:get_standing_origin() end)
        table.insert(parts, string.format("standing_origin=(%.3f,%.3f,%.3f,w=%s)",
            origin and (origin.x or 0) or 0, origin and (origin.y or 0) or 0,
            origin and (origin.z or 0) or 0, origin and tostring(origin.w) or "nil"))
    end

    local tem = safe(function() return sdk.get_managed_singleton("app.ropeway.gamemastering.TimelineEventManager") end)
    local in_camera_event = tem and safe(function() return tem:call("get_InCameraEvent") end)
    table.insert(parts, "InCameraEvent=" .. tostring(in_camera_event))

    local pm = safe(function() return sdk.get_managed_singleton(NS("PlayerManager")) end)
    local cond = pm and safe(function() return pm:call("get_CurrentPlayerCondition") end)
    local is_event = cond and safe(function() return cond:call("get_IsEvent") end)
    table.insert(parts, "IsEvent=" .. tostring(is_event))

    local cam_sys = safe(function() return sdk.get_managed_singleton("app.ropeway.camera.CameraSystem") end)
    local busy = cam_sys and safe(function() return cam_sys:call("get_BusyCameraType") end)
    local busy_n = nil
    if type(busy) == "number" then
        busy_n = busy
    elseif busy then
        busy_n = safe(function() return busy:get_field("value__") end)
    end
    table.insert(parts, "BusyCameraType=" .. tostring(busy_n))

    local csm = safe(function() return sdk.get_managed_singleton("app.ropeway.CutSceneManager") end)
    local owner = csm and safe(function() return csm:call("get_TimelineOwnerObject") end)
    table.insert(parts, "TimelineOwner=" .. tostring(owner))

    log.info(string.format("[re2_vr_ladder_camera_probe] frame=%d %s", state.frame, table.concat(parts, " ")))
end

local ray_state = {
    dumped_fields_this_burst = false,
}

-- 2026-08-15 continued: camera-forward-only (2m) got ZERO hits across a
-- full burst -- expected in hindsight, the player looks around while
-- climbing, not necessarily straight at a rung. Now casts THREE rays every
-- frame: player body-forward (stable regardless of head direction), camera-
-- forward (kept as a second chance), and straight down from chest height
-- (rungs are often below hand height while climbing). First hit across any
-- of them wins for that frame. On the FIRST hit within a burst, does a
-- one-time full field/method dump of the contact point (see the big
-- comment above dump_contact_point_fields) -- every other hit just logs the
-- cheap, already-confirmed Distance field, to avoid spamming the log with a
-- full reflection dump 300 times over.
local RAY_LEN = 3.0

local function try_ray(label, pos, dir)
    if not pos or not dir then return nil, nil end
    local ray_result = cast_ray_sync(pos, pos + dir * RAY_LEN)
    if not ray_result then return nil, nil end
    local n = safe(function() return ray_result:call("get_NumContactPoints") end) or 0
    if n <= 0 then return nil, nil end
    local cp = safe(function() return ray_result:call("getContactPoint(System.UInt32)", 0) end)
    if not cp then return nil, nil end
    return cp, label
end

local function log_ladder_ray_frame()
    local ppos, pfwd = get_player_pos_forward()
    local cpos, cfwd = get_camera_pos_forward()
    local down = Vector3f.new(0, -1, 0)

    local cp, label = try_ray("player-forward", ppos, pfwd)
    if not cp then cp, label = try_ray("camera-forward", cpos, cfwd) end
    if not cp then cp, label = try_ray("player-down", ppos, down) end

    if not cp then
        log.info(string.format("[re2_vr_ladder_camera_probe] frame=%d ray: no hit (tried player-fwd/camera-fwd/down, %.1fm)", state.frame, RAY_LEN))
        return
    end

    local dist = safe(function() return cp:get_field("Distance") end)
    log.info(string.format("[re2_vr_ladder_camera_probe] frame=%d ray HIT (%s) dist=%s", state.frame, label, tostring(dist)))

    if not ray_state.dumped_fields_this_burst then
        ray_state.dumped_fields_this_burst = true
        local lines = dump_contact_point_fields(cp)
        log.info(string.format("[re2_vr_ladder_camera_probe] contact point full field/method dump (via %s):\n%s",
            label, table.concat(lines, "\n")))
    end
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    state.frame = state.frame + 1
    if state.burst_remaining > 0 then
        state.burst_remaining = state.burst_remaining - 1
        log_camera_state_frame()
        log_ladder_ray_frame()
    end
end)

re.on_draw_ui(function()
    if not imgui then return end
    if not imgui.tree_node("Ladder Camera Probe") then return end
    imgui.text("1) Press 'Dump components' any time (one-shot, not timing-sensitive).")
    imgui.text("2) Press 'Start 5s camera-state capture', THEN get on the ladder and climb")
    imgui.text("   within the next 5 seconds -- gives time to let go of the button first.")

    if imgui.button("Dump components now") then
        dump_components_once()
    end
    imgui.same_line()
    if imgui.button("Start 5s camera-state capture") then
        state.burst_remaining = BURST_FRAMES
        ray_state.dumped_fields_this_burst = false
    end
    imgui.text("Burst remaining: " .. tostring(state.burst_remaining))

    imgui.spacing()
    imgui.text(state.last_dump)
    imgui.tree_pop()
end)

log.info("[re2_vr_ladder_camera_probe] Loaded")
