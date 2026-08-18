-- Ladder-climb body-yaw fix (2026-08-18).
--
-- Problem: REFramework's FirstPerson plugin ("Rotate Body" option) writes
-- the player transform's rotation from the camera (= HMD in VR) yaw EVERY
-- frame, in its on_pre_update_transform hook. Its only gates are
-- camera-control-type PLAYER and not-jacked -- there is no ladder/climb
-- gating at all, and ladder climbing keeps the camera in ordinary PLAYER
-- control (confirmed live 2026-08-15: BusyCameraType stayed 0 for 300
-- frames mid-climb). So during a climb the animation-driven sequence and
-- FirstPerson fight over body yaw, and the body twists toward wherever the
-- player looks. Player confirmed this happens on base REFramework too; the
-- fix has to live here ("Rotate Body" is not exposed to Lua -- bindings are
-- only is_enabled/will_be_used/on_pre_flashlight_apply_transform).
--
-- Fix: a per-frame snapshot/restore sandwich, active ONLY while climbing:
--   * post-LateUpdateBehavior: snapshot the body rotation. Game logic
--     (including the climb controller) has finished writing rotation for
--     the frame; FirstPerson's transform pre-update hook has NOT run yet
--     (transform updates happen after behavior, before render lock).
--   * pre-LockScene: write the snapshot back, undoing FirstPerson's
--     overwrite. Same proven late-write point re2_smooth_movement.lua
--     already uses for position.
-- No latching, no yaw math, no assumptions about ladder facing -- the
-- game's own intended rotation just passes through untouched.
--
-- Climb detection: dominant motion-node names on the player's motion
-- layers (via.motion.Motion getLayer(i) -> get_HighestWeightMotionNode ->
-- get_MotionName -- the exact read pattern proven by re2_vr_gait_probe /
-- re2_vr_reload_ext_4's scrub_motion_layer). Matched case-insensitively
-- against NAME_PATTERNS. "HASHIGO" is Japanese for ladder -- RE Engine
-- asset names frequently use romaji terms. If the first live climb does
-- not trip detection, read the [ladder_fix] name-change lines from the log
-- and add the real climb motion name to NAME_PATTERNS.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")

local motion_type = sdk.typeof("via.motion.Motion")

local NAME_PATTERNS = { "LADDER", "CLIMB", "HASHIGO" }

-- Keep "climbing" asserted briefly past the last matching frame so the
-- blend-out at the top/bottom of a ladder can't flicker the fix on/off
-- while FirstPerson is still mid-fight.
local CLIMB_HOLD_S = 0.35

local state = {
    enabled = true,
    log_names = true, -- log dominant layer-0 name changes (for capturing the real climb motion names on early tests)
    climbing = false,
    climb_last_match_t = 0.0,
    matched_name = "",
    snapshot_rot = nil,
    snapshot_valid = false,
    restores = 0,
    last_layer0_name = "",
    last_name_log_t = 0.0,
}

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

local function get_player_motion()
    local player = re2.get_localplayer()
    if not player or not motion_type then return nil end
    return safe(function()
        return player:call("getComponent(System.Type)", motion_type)
    end)
end

local function get_player_transform()
    local player = re2.get_localplayer()
    if not player then return nil end
    return safe(function() return player:call("get_Transform") end)
end

local function name_matches_climb(name)
    if type(name) ~= "string" or name == "" then return false end
    local up = name:upper()
    for _, pat in ipairs(NAME_PATTERNS) do
        if up:find(pat, 1, true) then return true end
    end
    return false
end

-- Scans the motion layers' dominant nodes; returns the first climb-matching
-- name, or nil. Also feeds the layer-0 name-change diagnostic log.
local function scan_for_climb_motion()
    local mc = get_player_motion()
    if not mc then return nil end
    local count = safe(function() return mc:call("getLayerCount") end)
        or safe(function() return mc:call("get_LayerCount") end)
    local max_layers = tonumber(count) or 4

    local match = nil
    for li = 0, max_layers - 1 do
        local layer = safe(function() return mc:call("getLayer", li) end)
        if layer then
            local node = safe(function() return layer:call("get_HighestWeightMotionNode") end)
            local name = node and safe(function() return node:call("get_MotionName") end) or nil
            if type(name) == "string" then
                if li == 0 and state.log_names and name ~= state.last_layer0_name then
                    local now = os.clock()
                    if now - state.last_name_log_t > 0.25 then
                        state.last_name_log_t = now
                        log.info("[ladder_fix] layer0 motion: " .. name)
                    end
                    state.last_layer0_name = name
                end
                if not match and name_matches_climb(name) then
                    match = name
                end
            end
        end
    end
    return match
end

local function update_climb_state()
    local now = os.clock()
    local match = scan_for_climb_motion()
    if match then
        state.climb_last_match_t = now
        if not state.climbing then
            state.climbing = true
            log.info("[ladder_fix] CLIMB START (motion=" .. match .. ") -- body-yaw guard active")
        end
        state.matched_name = match
    elseif state.climbing and (now - state.climb_last_match_t) > CLIMB_HOLD_S then
        state.climbing = false
        state.snapshot_valid = false
        log.info(string.format(
            "[ladder_fix] CLIMB END -- guard off (restored %d frames)", state.restores))
        state.restores = 0
    end
end

-- Post-LateUpdateBehavior: game logic is done writing rotation for this
-- frame; FirstPerson's transform pre-update hasn't fired yet. Snapshot.
re.on_application_entry("LateUpdateBehavior", function()
    if not state.enabled then
        state.climbing = false
        state.snapshot_valid = false
        return
    end
    if not firstpersonmod or not firstpersonmod:will_be_used() then
        state.climbing = false
        state.snapshot_valid = false
        return
    end

    update_climb_state()
    if not state.climbing then
        state.snapshot_valid = false
        return
    end

    local tf = get_player_transform()
    local rot = tf and safe(function() return tf:call("get_Rotation") end) or nil
    if rot then
        state.snapshot_rot = rot
        state.snapshot_valid = true
    else
        state.snapshot_valid = false
    end
end)

-- FirstPerson's overwrite has happened by now (its write is a transform
-- pre-update hook, after behavior, before render lock) -- put the game's
-- own rotation back. Restored at TWO late points, since it's unverified
-- which one lands inside the same rendered frame: pre-LockScene (the
-- late-frame hook this codebase already uses) and pre-PrepareRendering
-- (proven effective for late pose writes by the torso-twist fix). Writing
-- the same value twice is idempotent; the later one closes out the
-- snapshot and counts the frame.
local function restore_snapshot(final)
    if not state.enabled or not state.snapshot_valid then return end
    local tf = get_player_transform()
    if tf then
        pcall(function() tf:call("set_Rotation", state.snapshot_rot) end)
    end
    if final then
        state.snapshot_valid = false
        state.restores = state.restores + 1
    end
end

re.on_pre_application_entry("LockScene", function()
    restore_snapshot(false)
end)

re.on_application_entry("PrepareRendering", function()
    restore_snapshot(true)
end)

re.on_draw_ui(function()
    if not imgui.tree_node("Ladder Body-Yaw Fix") then return end

    local changed, val = imgui.checkbox("Enabled", state.enabled)
    if changed then state.enabled = val end

    changed, val = imgui.checkbox("Log motion name changes", state.log_names)
    if changed then state.log_names = val end

    if state.climbing then
        imgui.text("CLIMBING (matched: " .. tostring(state.matched_name) .. ")")
        imgui.text(string.format("restored frames: %d", state.restores))
    else
        imgui.text("not climbing")
    end
    imgui.text("layer0: " .. tostring(state.last_layer0_name))

    imgui.tree_pop()
end)

re.on_script_reset(function()
    state.climbing = false
    state.snapshot_valid = false
    state.restores = 0
end)

log.info("[re2_vr_ladder_body_yaw_fix] loaded")
