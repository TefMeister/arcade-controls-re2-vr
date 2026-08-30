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
--
-- 2026-08-15 pass: two additions.
-- 1. Speed-based fade restored -- a prior productized version of this fix
--    (re2_vr_torso_straighten.lua, since lost when this diagnostic-named
--    script was revived from a work-PC handoff) had already confirmed that
--    a CONSTANT-strength override fights the game's own walk/run gait sway
--    and causes visible camera shake while moving. The fix there was to
--    fade the correction's effective strength down as observed movement
--    speed increases, not just low-pass-smooth the written value (which
--    only damps jitter, it doesn't remove the fight). Re-added here from
--    scratch using the same technique (flat XZ position-delta EMA speed).
-- 2. A third hook-timing option, "Prepare" (via
--    re.on_application_entry("PrepareRendering", ...)), for the still-open
--    red-dot/laser-drift symptom. Credit: alphaZomega's EMV-Engine
--    (https://github.com/alphazolam/EMV-Engine, MIT licensed) writes its
--    live bone-pose overrides at this exact hook -- the last point in the
--    frame before render, after all native animation/IK passes.
--    PLAYER-TESTED 2026-08-15: Prepare did NOT fix the red-dot drift.
--    Diagnosis: Prepare has the exact same problem as the original POST
--    hook (see the 2026-08-05 note below) -- it also lands after arm IK
--    already solved the hand/gun position against the OLD un-corrected
--    spine, just even later. Keep Pre as the default; Prepare is not a
--    useful lever for this symptom after all.
--
-- 2026-08-15 pass 2: player wants spine correction at strength=1.0
-- CONSTANTLY (no speed fade) with no shake while running, and, since
-- hook-timing tricks don't fix the red-dot, a direct manual way to nudge
-- the gun's aim line back onto the crosshair by hand.
-- 1. Per-axis correction: the ORIGINAL diagnosis of the running-shake
--    symptom (2026-08-05, see below) assumed it was a write-timing/fight
--    problem, fixed by fading the correction off. But re-reading the
--    measured quaternions in that investigation: Leon's natural spine_0
--    rotation is (0, 0.13, 0, 0.99) -- pure Y-axis. Claire's twisted
--    spine_0 is (-0.023, 0.172, -0.129, 0.976) -- same rough Y magnitude
--    PLUS real X/Z components Leon doesn't have at all. That means the
--    actual visible "twist" defect is specifically the X/Z components;
--    the Y component is the character's NORMAL weapon-hold/gait rotation,
--    present on both characters, and changes continuously with aim/gait --
--    which is exactly what a constant-strength full-identity blend was
--    fighting. Zeroing X/Z only, while leaving Y alone entirely, should
--    remove the twist without ever fighting the animation on the axis
--    that actually needs to keep moving. Untested in VR -- worth trying
--    before assuming straight+running is impossible.
-- 2. Manual aim compensation: a small live-tunable pitch/yaw/roll offset
--    applied directly to r_arm_wrist's local rotation, written at
--    PrepareRendering (the very last word, which IS correct here -- unlike
--    the spine, this isn't fighting a moving animation, it's a static
--    per-frame nudge on top of whatever the arm IK already produced).
--    Tune live while aiming until the red dot lines up with the crosshair.
--
-- 2026-08-15 pass 3, player feedback from testing pass 2:
-- 1. Character gate removed entirely (separate small change, applies to
--    Leon too now -- player confirmed Leon does have a small visible twist
--    and including him looks better).
-- 2. Running is STILL shaky even with per-axis (Y-preserving) correction.
--    Re-diagnosis: this was never purely an axis problem. Forcing spine_0
--    rigid on ANY axis while the hips/root keep bobbing with the run
--    animation's own vertical/lean motion decouples the head (and VR
--    camera, which sits above the spine chain) from the body's natural
--    motion -- a kinematic mismatch, not a write-fight. Speed-fade (pass 1)
--    "fixed" it by just turning the correction off while moving, which the
--    player has explicitly said they don't want. Per-axis (pass 2) helped
--    but wasn't sufficient alone. New lever, additive to per-axis, NOT a
--    replacement: fade the SMOOTHING TIME CONSTANT up with speed instead of
--    fading strength -- strength stays at 1.0 always, but the correction
--    responds more slowly (more lag) while moving, damping the visible
--    high-frequency component of the mismatch at the cost of responsiveness
--    instead of correctness. `speed_smooth_boost_enabled` (default true),
--    ramps `smooth_tau_s` up to `smooth_tau_run_s` by `run_mps`.
-- 2. Red-dot compensation drifts with HEAD PITCH: player got left/right
--    lined up, but looking down pushes the dot up (vs. the crosshair, which
--    player confirms always tracks the true muzzle direction correctly),
--    looking up pushes it down. Root cause: the pitch/yaw/roll offset was
--    applied in the WRIST's own LOCAL space. But re2_vr_ik_extention.lua's
--    FirstPerson-style hand IK computes the hand target camera-relative
--    (get_fp_style_hand_world_pos), so the arm chain's baseline pose --
--    and therefore what "local space" even means at the wrist -- shifts
--    with HMD look direction, even with the physical controller held
--    perfectly still. A fixed local-space offset gets reinterpreted
--    differently every time the player just looks up or down. Fix:
--    express the offset relative to the CHARACTER's body/root orientation
--    (via quaternion conjugation, same general technique as
--    re2_vr_ik_extention.lua's apply_elbow_pole_hint) instead of the
--    wrist's local axes -- the character's root only turns with the body,
--    not the head, so the nudge should now hold steady regardless of where
--    the player is looking. Untested in VR -- the conceptual fix (anchor to
--    a frame that doesn't move with head pitch) is solid, but the exact
--    quaternion multiplication order is a best-effort match to this file's
--    other confirmed-working parent/local conventions, not itself
--    independently verified live.

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
    -- 2026-08-15 pass 6: smoothing (EMA lag on the written value) removed
    -- entirely by player request -- confirmed in VR that the lag itself was
    -- producing visible shaking in the headset (the correction chasing a
    -- moving target with phase delay reads as judder when your own head is
    -- also moving). Writes the raw target every frame now, no blending.

    -- Speed-based fade (see 2026-08-15 header note above). Default OFF now
    -- that per-axis correction (below) is the primary anti-shake approach.
    -- 2026-08-15 pass 4: reverted back to true -- player tested straight+
    -- running in VR and confirmed real shake AND gun bounce (the arm IK
    -- visibly fighting the rigid spine against still-moving hips, a
    -- kinematic mismatch, not a bug -- see pass-3/4 header notes). Per-axis
    -- and the tau-boost helped but didn't solve it; correction is straight
    -- at standstill and fades off while moving, by player's explicit choice
    -- (posture doesn't need to be perfect, per their original ask).
    speed_fade_enabled = true,
    walk_max_mps = 0.8, -- fade to 25% strength by this speed
    run_mps = 1.3, -- fade to 0% strength by this speed (matches AIM_SPEED_OVERRIDE_MPS elsewhere in this mod)
    last_speed_mps = 0.0,
    last_speed_fade = 1.0,

    -- 2026-08-15 pass 5: preserve_y (per-axis correction) and the speed-
    -- smooth-boost (tau ramping with speed) were removed by player request
    -- -- both were part of the abandoned straight+running attempt (pass
    -- 2/3) and are dead weight now that speed-fade (above) is the only
    -- active anti-shake strategy. Correction is uniform across all axes
    -- again. (Pass 6, below: EMA output smoothing removed too -- it was
    -- causing VR shaking on its own via write-lag, see that pass's note.)

    -- Manual aim compensation (2026-08-15 pass 2, see header note).
    aim_comp_enabled = false,
    aim_comp_only_while_aiming = true,
    aim_comp_pitch_deg = 0.0,
    aim_comp_yaw_deg = 0.0,
    aim_comp_roll_deg = 0.0,
}

-- Flat (XZ) position-delta EMA speed tracker, isolated from any other
-- script's speed state -- deliberately not reusing re2_smooth_movement.lua's
-- internals so this script keeps working standalone.
local move = {
    last_pos = nil,
    last_t = nil,
    ema_speed = 0.0,
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

local function get_player_transform(player)
    local ok_tf, tf = pcall(function() return player:call("get_Transform") end)
    if not ok_tf then return nil end
    return tf
end

local function get_spine_joint(tf)
    if not tf then return nil end
    local ok_j, joint = pcall(function() return tf:call("getJointByName", "spine_0") end)
    if not ok_j or not joint then return nil end
    return joint
end

local function reset_speed_tracker()
    move.last_pos = nil
    move.last_t = nil
    move.ema_speed = 0.0
end

-- Updates and returns the flat (XZ) EMA speed estimate in m/s. Caps the
-- instantaneous per-frame speed before folding into the EMA so a single
-- teleport/cutscene-snap frame can't spike the fade multiplier to zero for
-- several frames afterward.
local function update_speed_estimate(tf)
    local now_t = os.clock()
    local ok, pos = pcall(function() return tf:call("get_Position") end)
    local dt = 0.0
    if move.last_t then dt = math.max(0.0, now_t - move.last_t) end
    move.last_t = now_t
    if not ok or not pos then return move.ema_speed end
    if move.last_pos and dt > 1e-4 then
        local dx = pos.x - move.last_pos.x
        local dz = pos.z - move.last_pos.z
        local inst_speed = math.min(math.sqrt(dx * dx + dz * dz) / dt, 5.0)
        local tau = 0.15
        local alpha = 1.0 - math.exp(-dt / tau)
        move.ema_speed = move.ema_speed + (inst_speed - move.ema_speed) * alpha
    end
    move.last_pos = pos
    return move.ema_speed
end

-- 1.0 at standstill -> 0.25 at walk_max_mps -> 0.0 at run_mps. Matches the
-- shape of the prior productized fix's confirmed-working fade curve.
local function speed_fade_multiplier(speed)
    local walk_max = math.max(0.01, state.walk_max_mps)
    local run = math.max(walk_max + 0.01, state.run_mps)
    if speed <= 0.0 then return 1.0 end
    if speed <= walk_max then
        return 1.0 - (speed / walk_max) * 0.75
    elseif speed < run then
        return 0.25 - ((speed - walk_max) / (run - walk_max)) * 0.25
    else
        return 0.0
    end
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
local function blend_toward_identity(q, sx, sy, sz)
    local x = q.x * (1.0 - sx)
    local y = q.y * (1.0 - sy)
    local z = q.z * (1.0 - sz)
    local avg_s = (sx + sy + sz) / 3.0
    local w = q.w * (1.0 - avg_s) + 1.0 * avg_s
    return quat_normalize(x, y, z, w)
end

local NS = sdk.game_namespace
local survivor_condition_type = nil

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

local function player_is_aiming(player)
    local cond = get_survivor_condition(player)
    if not cond then return false end
    local ok, aiming = pcall(function() return cond:call("get_IsHold") end)
    return ok and aiming == true
end

local function deg2rad(d)
    return (tonumber(d) or 0.0) * (math.pi / 180.0)
end

local function quat_from_euler_deg(pitch, yaw, roll)
    if not Quaternion or not Quaternion.new then return nil end
    local ok, q = pcall(function()
        return Quaternion.new(Vector3f.new(deg2rad(pitch), deg2rad(yaw), deg2rad(roll))):normalized()
    end)
    return ok and q or nil
end

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

local function quat_mul(a, b)
    if not a or not b then return a end
    local ok, q = pcall(function() return a * b end)
    return ok and q or a
end

local function quat_inverse(q)
    if not q then return nil end
    local ok, inv = pcall(function() return q:inverse() end)
    return ok and inv or nil
end

-- Applies the manual pitch/yaw/roll nudge to r_arm_wrist, written at the
-- very last hook (PrepareRendering) as the final word every frame -- unlike
-- the spine correction, this isn't fighting a moving animation, it's a
-- fixed offset.
--
-- 2026-08-15 pass 3 fix: the offset is now expressed relative to the
-- CHARACTER's body/root orientation, not the wrist's own local space (see
-- header note -- a raw local-space offset drifted with HMD look direction,
-- since re2_vr_ik_extention.lua's FirstPerson hand IK computes the hand
-- target camera-relative, so what "local space" means at the wrist shifts
-- as the player just looks up/down). Conjugating the offset through the
-- character's world rotation, then applying it to the wrist's WORLD
-- rotation and converting back to local via the parent's inverse, keeps
-- the nudge anchored to something that only moves when the body turns.
local function apply_aim_compensation(player)
    if state.aim_comp_only_while_aiming and not player_is_aiming(player) then return end
    local tf = get_player_transform(player)
    if not tf then return end
    local wrist = safe(function() return tf:call("getJointByName", "r_arm_wrist") end)
    if not wrist then return end

    local char_rot = safe(function() return tf:call("get_Rotation") end)
    local wrist_world_rot = safe(function() return wrist:call("get_Rotation") end)
    if not char_rot or not wrist_world_rot then return end

    local parent = safe(function() return wrist:call("get_Parent") end)
    local parent_world_rot = parent and safe(function() return parent:call("get_Rotation") end)

    local local_offset_q = quat_from_euler_deg(state.aim_comp_pitch_deg, state.aim_comp_yaw_deg, state.aim_comp_roll_deg)
    if not local_offset_q then return end

    local char_inv = quat_inverse(char_rot)
    local world_offset_q = char_inv and quat_mul(quat_mul(char_rot, local_offset_q), char_inv) or local_offset_q

    local new_world_rot = quat_mul(world_offset_q, wrist_world_rot)

    local new_local_rot = new_world_rot
    local inv_parent = parent_world_rot and quat_inverse(parent_world_rot)
    if inv_parent then
        new_local_rot = quat_mul(inv_parent, new_world_rot)
    end

    pcall(function() wrist:call("set_LocalRotation", new_local_rot) end)
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

local function apply_override(player)
    local tf = get_player_transform(player)
    if not tf then
        state.status = "no transform"
        return
    end
    local joint = get_spine_joint(tf)
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

    local speed = state.speed_fade_enabled and update_speed_estimate(tf) or 0.0
    local fade = state.speed_fade_enabled and speed_fade_multiplier(speed) or 1.0
    state.last_speed_mps = speed
    state.last_speed_fade = fade
    local effective_strength = state.strength * fade

    local nx, ny, nz, nw = blend_toward_identity(r, effective_strength, effective_strength, effective_strength)
    local applied = try_set_local_rotation(joint, nx, ny, nz, nw)
    if applied then
        state.last_applied = { x = nx, y = ny, z = nz, w = nw }
        state.status = string.format("applied via %s, strength=%.2f (x%.2f fade)",
            state.setter_method, effective_strength, fade)
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
state.timing = "pre" -- "pre", "post", or "prepare"

-- Note: exactly one of these three hooks actually applies the correction on
-- any given frame (whichever matches state.timing) -- the other two returning
-- early on the timing check is expected every frame, not a sign anything's wrong.
local function gate_check()
    if state.cutscene_gate_enabled and is_cutscene_active() then
        state.status = "skipped (cutscene/cinematic active)"
        return nil
    end
    local player = re2.get_localplayer()
    if not player then return nil end
    return player
end

-- 2026-08-15: published so other diagnostic scripts (e.g.
-- re2_vr_laser_dot_probe.lua) can log/correlate against this script's
-- on/off state directly, instead of relying on manual timing/narration --
-- same pattern re2_vr_holster.lua already uses for
-- __vr_is_cinematic_blocking.
rawset(_G, "__vr_spine_correction_enabled", state.enabled)
rawset(_G, "__vr_spine_correction_timing", state.timing)

re.on_pre_application_entry("LateUpdateBehavior", function()
    rawset(_G, "__vr_spine_correction_enabled", state.enabled)
    rawset(_G, "__vr_spine_correction_timing", state.timing)
    if not state.enabled then
        reset_speed_tracker()
        return
    end
    if state.timing ~= "pre" then return end
    local player = gate_check()
    if not player then return end
    apply_override(player)
end)

re.on_application_entry("LateUpdateBehavior", function()
    if not state.enabled then return end
    if state.timing ~= "post" then return end
    local player = gate_check()
    if not player then return end
    apply_override(player)
end)

-- Prepare timing: EMV-Engine-derived (see 2026-08-15 header note) -- the
-- latest point in the frame before render, tried here specifically as an
-- additional lever for the still-open red-dot drift symptom.
-- PLAYER-TESTED 2026-08-15: did not fix it (see header note for diagnosis).
-- Left in place for reference/further A-B testing, not removed.
re.on_application_entry("PrepareRendering", function()
    if not state.enabled then return end
    if state.timing ~= "prepare" then return end
    local player = gate_check()
    if not player then return end
    apply_override(player)
end)

-- Manual aim compensation: independent of state.timing/state.enabled above --
-- runs whenever its own checkbox is on, regardless of which spine-timing
-- mode (or none) is active.
re.on_application_entry("PrepareRendering", function()
    if not state.aim_comp_enabled then return end
    local player = gate_check()
    if not player then return end
    apply_aim_compensation(player)
end)

re.on_draw_ui(function()
    if not imgui then return end
    if not imgui.tree_node("Torso Twist Fix") then return end

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

    imgui.spacing()
    local sfc, sfv = imgui.checkbox("Fade correction while moving (fixes running shake)", state.speed_fade_enabled)
    if sfc then state.speed_fade_enabled = sfv end
    local wmc, wmv = imgui.slider_float("Walk speed (25% strength here)", state.walk_max_mps, 0.1, 2.0, "%.2f m/s")
    if wmc then state.walk_max_mps = wmv end
    local rc, rv = imgui.slider_float("Run speed (0% strength here)", state.run_mps, state.walk_max_mps + 0.05, 3.0, "%.2f m/s")
    if rc then state.run_mps = rv end
    imgui.text(string.format("Current speed: %.2f m/s -- fade: %.0f%% -- effective strength: %.2f",
        state.last_speed_mps, state.last_speed_fade * 100.0, state.strength * state.last_speed_fade))

    imgui.spacing()
    imgui.text("Hook timing (try Pre first -- should fix the gun/laser pointing left):")
    if imgui.button((state.timing == "pre" and "[x] " or "[ ] ") .. "Pre (before arm IK solves)") then
        state.timing = "pre"
    end
    if imgui.button((state.timing == "post" and "[x] " or "[ ] ") .. "Post (after arm IK solves -- original, gun points left)") then
        state.timing = "post"
    end
    if imgui.button((state.timing == "prepare" and "[x] " or "[ ] ") .. "Prepare (very late, right before render)") then
        state.timing = "prepare"
    end
    imgui.text_colored(
        "Prepare tested 2026-08-15: did NOT fix the red-dot drift. Kept for reference, not recommended.",
        0xFF88CCFF)

    imgui.spacing()
    imgui.separator()
    imgui.text("Aim Compensation (manual wrist nudge -- for red-dot/crosshair alignment)")
    local aec, aev = imgui.checkbox("Enable aim compensation", state.aim_comp_enabled)
    if aec then state.aim_comp_enabled = aev end
    local aowc, aowv = imgui.checkbox("Only while aiming", state.aim_comp_only_while_aiming)
    if aowc then state.aim_comp_only_while_aiming = aowv end
    local pc, pv = imgui.slider_float("Pitch (deg)", state.aim_comp_pitch_deg, -15.0, 15.0, "%.1f")
    if pc then state.aim_comp_pitch_deg = pv end
    local ycc, ycv = imgui.slider_float("Yaw (deg)", state.aim_comp_yaw_deg, -15.0, 15.0, "%.1f")
    if ycc then state.aim_comp_yaw_deg = ycv end
    local rc2, rv2 = imgui.slider_float("Roll (deg)", state.aim_comp_roll_deg, -15.0, 15.0, "%.1f")
    if rc2 then state.aim_comp_roll_deg = rv2 end
    if imgui.button("Reset nudge to zero") then
        state.aim_comp_pitch_deg = 0.0
        state.aim_comp_yaw_deg = 0.0
        state.aim_comp_roll_deg = 0.0
    end
    imgui.text_colored(
        "Right-hand wrist only. Aim in-game and nudge these until the red dot lines up with the crosshair.",
        0xFF88CCFF)

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

    imgui.tree_pop()
end)

re.on_script_reset(function()
    state.enabled = false
    state.status = "idle"
    reset_speed_tracker()
end)

log.info("[re2_vr_posture_spine_straighten_override] Loaded")
