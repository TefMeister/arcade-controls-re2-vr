-- Diagnostic/experiment: directly overwrites spine_0's local rotation every
-- frame instead of trying to trick the animation-selection system into
-- picking a different pose. Everything tried before this worked at the
-- "which animation/category is playing" layer (raw motlist swap, weapon-
-- category ForceEquipType spoof) and both failed. This works one layer
-- lower: after the animation system computes the pose, before render,
-- directly counter-rotate the bone that IS the visible twist.
--
-- Mechanism confirmed to work in this exact codebase already:
-- SurvivorBuriedArmCorrector's RightArmCorrectRotation was forced to
-- identity every LateUpdateBehavior tick and *stayed* there (readback
-- confirmed, even ~34s later) -- the native logic did not fight back. That
-- experiment targeted the wrong bone (no visible effect), but the
-- forcing-every-LateUpdateBehavior-tick technique itself is proven. This
-- script re-aims the same technique at spine_0 directly.
--
-- Unknowns, not yet verified:
-- 1. Whether the Joint object returned by getJointByName even exposes a
--    settable local rotation (only reading has been confirmed so far, via
--    re2_vr_posture_twist_probe.lua). Tries several candidate method names
--    defensively and reports which (if any) actually works.
-- 2. Whether forcibly straightening spine_0 breaks anything downstream
--    that depends on its real value (arm IK, head look-at, cloth/ragdoll).
--    Only live testing will show this.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")

local state = {
    enabled = false,
    strength = 1.0, -- 0 = no change, 1 = fully identity (straight)
    status = "idle",
    setter_method = nil, -- filled in once we find one that works
    last_original = nil,
    last_applied = nil,
    cutscene_gate_enabled = false, -- temporarily off for gameplay recording (2026-08-09) -- flip on in the panel when done
    -- Movement shaking reported (2026-08-09): apply_override recomputes
    -- straight from the RAW spine_0 value every frame and writes it
    -- instantly, with zero damping. If the native game applies its own
    -- secondary motion/sway to the spine during walking (plausible -- gait
    -- naturally has continuous micro-adjustment), this override faithfully
    -- reproduces that per-frame noise instead of smoothing it out. Added
    -- exponential smoothing on the WRITTEN value (same pattern already used
    -- elsewhere in this mod: re2_vr_ik_extention.lua's smooth_exp_alpha,
    -- re2_smooth_movement.lua's EMA) to damp high-frequency jitter without
    -- adding meaningful lag to the actual correction.
    smooth_enabled = true,
    smooth_tau_s = 0.08, -- lower = snappier/more shake-prone, higher = smoother/more lag
    last_written = nil,
    last_smooth_t = nil,
}

local SETTER_CANDIDATES = { "set_LocalRotation", "setLocalRotation" }

-- re2_vr_holster.lua publishes this global specifically so other scripts can
-- gate themselves off during cutscenes -- checks TimelineEventManager,
-- PlayerCondition.IsEvent, CameraSystem.BusyCameraType, and CutSceneManager
-- in combination. Falls back to "not blocking" if holster.lua isn't loaded
-- (e.g. non-VR flat-screen testing) so this script still works standalone.
local function is_cutscene_active()
    local fn = rawget(_G, "__vr_is_cinematic_blocking")
    if type(fn) ~= "function" then return false end
    local ok, v = pcall(fn)
    return ok and v == true
end

local function get_spine_joint(player)
    local ok_tf, tf = pcall(function() return player:call("get_Transform") end)
    if not ok_tf or not tf then return nil end
    local ok_j, joint = pcall(function() return tf:call("getJointByName", "spine_0") end)
    if not ok_j or not joint then return nil end
    return joint
end

local function quat_normalize(x, y, z, w)
    local len = math.sqrt(x * x + y * y + z * z + w * w)
    if len < 1e-8 then return 0, 0, 0, 1 end
    return x / len, y / len, z / len, w / len
end

-- Cheap component-wise lerp + renormalize -- not a true slerp, but a
-- reasonable approximation for the modest twist angles measured here
-- (25-55 degrees), and simple enough to eyeball-verify against the logged
-- numbers.
local function blend_toward_identity(q, strength)
    local x = q.x * (1.0 - strength)
    local y = q.y * (1.0 - strength)
    local z = q.z * (1.0 - strength)
    local w = q.w * (1.0 - strength) + 1.0 * strength
    return quat_normalize(x, y, z, w)
end

local function try_set_local_rotation(joint, x, y, z, w)
    if state.setter_method then
        local ok = pcall(function() joint:call(state.setter_method, Quaternion.new(w, x, y, z)) end)
        if ok then return true end
        state.setter_method = nil -- stopped working, re-probe
    end
    for _, m in ipairs(SETTER_CANDIDATES) do
        local ok = pcall(function() joint:call(m, Quaternion.new(w, x, y, z)) end)
        if ok then
            state.setter_method = m
            return true
        end
    end
    return false
end

-- Blends state.last_written toward (nx,ny,nz,nw) using exponential
-- smoothing based on real elapsed time (dt), not frame count, so behavior
-- is consistent regardless of framerate. Returns the raw target unchanged
-- if there's no previous written value to smooth from (first frame after
-- enabling, or right after a skip) -- avoids a slow drifting catch-up from
-- a stale value, only smooths frame-to-frame during continuous operation.
local function smooth_toward(nx, ny, nz, nw)
    if not state.smooth_enabled or not state.last_written then
        state.last_smooth_t = os.clock()
        return nx, ny, nz, nw
    end
    local now_t = os.clock()
    local dt = math.max(0.0, now_t - (state.last_smooth_t or now_t))
    state.last_smooth_t = now_t
    if dt > 0.2 then dt = 0.2 end
    local tau = math.max(0.001, state.smooth_tau_s)
    local alpha = 1.0 - math.exp(-dt / tau)
    local lw = state.last_written
    return quat_normalize(
        lw.x + (nx - lw.x) * alpha,
        lw.y + (ny - lw.y) * alpha,
        lw.z + (nz - lw.z) * alpha,
        lw.w + (nw - lw.w) * alpha)
end

local function apply_override(player)
    local joint = get_spine_joint(player)
    if not joint then
        state.status = "spine_0 joint not found"
        return
    end
    local ok_r, r = pcall(function() return joint:call("get_LocalRotation") end)
    if not ok_r or not r or type(r.y) ~= "number" then
        state.status = "could not read spine_0 local rotation"
        return
    end
    state.last_original = { x = r.x, y = r.y, z = r.z, w = r.w }

    local tx, ty, tz, tw = blend_toward_identity(r, state.strength)
    local nx, ny, nz, nw = smooth_toward(tx, ty, tz, tw)
    local applied = try_set_local_rotation(joint, nx, ny, nz, nw)
    if applied then
        state.last_applied = { x = nx, y = ny, z = nz, w = nw }
        state.last_written = state.last_applied
        state.status = string.format("applied via %s, strength=%.2f, smoothing=%s",
            state.setter_method, state.strength, tostring(state.smooth_enabled))
    else
        state.status = "NO SETTER WORKED (tried: " .. table.concat(SETTER_CANDIDATES, ", ") .. ") -- joint rotation may be read-only"
    end
end

-- CONFIRMED LIVE (2026-08-05): strength=1.0 with the POST hook straightens
-- the torso, but the gun/laser-sight visually point left even though shots
-- still fire straight -- the arm/weapon IK that positions the visible gun
-- runs as part of LateUpdateBehavior and reads spine_0's rotation as an
-- input. The POST hook straightens spine_0 *after* that IK already solved
-- the hand position against the old twisted spine, so the hand ends up
-- misplaced relative to the new orientation. The PRE hook applies our
-- correction before that IK runs, so it should solve against the already-
-- straightened spine instead. Both hooks are wired up so you can flip
-- between them live via the "Hook timing" selector with no relaunch.
state.timing = "pre" -- "pre" or "post"

-- Note: exactly one of these two hooks actually applies the correction on
-- any given frame (whichever matches state.timing) -- the other returning
-- early on the timing check is expected every frame, NOT a sign the
-- correction stopped running, so state.last_written must only be cleared
-- when the correction is genuinely off (disabled or cutscene-gated), never
-- on a plain timing mismatch -- otherwise the smoothing above would reset
-- itself every single frame and never actually smooth anything.
re.on_pre_application_entry("LateUpdateBehavior", function()
    if not state.enabled then
        state.last_written = nil
        return
    end
    if state.timing ~= "pre" then return end
    if state.cutscene_gate_enabled and is_cutscene_active() then
        state.status = "skipped (cutscene/cinematic active)"
        state.last_written = nil
        return
    end
    local player = re2.get_localplayer()
    if not player then return end
    apply_override(player)
end)

re.on_application_entry("LateUpdateBehavior", function()
    if not state.enabled then return end
    if state.timing ~= "post" then return end
    if state.cutscene_gate_enabled and is_cutscene_active() then
        state.status = "skipped (cutscene/cinematic active)"
        state.last_written = nil
        return
    end
    local player = re2.get_localplayer()
    if not player then return end
    apply_override(player)
end)

re.on_draw_ui(function()
    if not imgui then return end

    local player = re2.get_localplayer()
    local name = "?"
    if player then
        local ok, n = pcall(function() return player:call("get_Name") end)
        if ok and n then name = n end
    end
    imgui.text("Live player Name: " .. tostring(name))
    imgui.text("Cutscene/cinematic detected right now: " .. tostring(is_cutscene_active()))

    local gc, gv = imgui.checkbox("Turn correction off during cutscenes", state.cutscene_gate_enabled)
    if gc then state.cutscene_gate_enabled = gv end

    local c, v = imgui.checkbox("Enable spine straighten override", state.enabled)
    if c then state.enabled = v end

    local sc, sv = imgui.slider_float("Twist removal strength", state.strength, 0.0, 1.0, "%.2f")
    if sc then state.strength = sv end

    local smc, smv = imgui.checkbox("Smooth output (fix for movement shaking)", state.smooth_enabled)
    if smc then state.smooth_enabled = smv end
    local tc, tv = imgui.slider_float("Smoothing time constant (s)", state.smooth_tau_s, 0.0, 0.30, "%.3f")
    if tc then state.smooth_tau_s = tv end
    imgui.text_colored(
        "Higher = smoother but more lag behind the real spine value. Lower = snappier but more shake-prone.",
        0xFF88CCFF)

    imgui.text("Hook timing (try Pre first -- should fix the gun/laser pointing left):")
    if imgui.button((state.timing == "pre" and "[x] " or "[ ] ") .. "Pre (before arm IK solves)") then
        state.timing = "pre"
    end
    if imgui.button((state.timing == "post" and "[x] " or "[ ] ") .. "Post (after arm IK solves -- original, gun points left)") then
        state.timing = "post"
    end

    imgui.text("Status: " .. tostring(state.status))

    if state.last_original then
        imgui.text(string.format("Last original spine_0 = (%.4f, %.4f, %.4f, %.4f)",
            state.last_original.x, state.last_original.y, state.last_original.z, state.last_original.w))
    end
    if state.last_applied then
        imgui.text(string.format("Last applied  spine_0 = (%.4f, %.4f, %.4f, %.4f)",
            state.last_applied.x, state.last_applied.y, state.last_applied.z, state.last_applied.w))
    end

    imgui.text_colored(
        "If status says NO SETTER WORKED, this approach is dead -- the joint rotation is read-only from Lua.",
        0xFF88CCFF)
end)

re.on_script_reset(function()
    state.enabled = false
    state.status = "idle"
    state.last_written = nil
    state.last_smooth_t = nil
end)

log.info("[re2_vr_posture_spine_straighten_override] Loaded")
