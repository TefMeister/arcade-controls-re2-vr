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
    -- 2026-08-16: enabled by default (was false through the whole diagnostic
    -- era) -- soft mode confirmed live in VR by the player ("works so damn
    -- well"), this is a real feature now, not an experiment.
    enabled = true,
    strength = 1.0, -- 0 = no change, 1 = fully identity (straight)
    status = "idle",
    -- 2026-08-16 (evening): SOFT MODE -- player's verdict on the freeze
    -- approach: spine_1/2 freeze lessens the residual sway a lot but "a
    -- rigid body is weird to play with, would rather have the twist".
    -- Every prior strategy either froze the joint rigid (fights the gait ->
    -- shake/sway) or faded the correction off while moving (no correction
    -- at all). This is the third option neither of those covered: keep a
    -- slowly-adapting EMA baseline of the ANIMATED spine rotation (the
    -- "sustained twist" component, tau below), straighten THAT baseline,
    -- and re-apply the animation's live deviation from baseline on top.
    -- Gait sway/breathing/turns pass through at full amplitude -- only the
    -- near-constant twist offset is subtracted. No rigid trunk, no
    -- kinematic fight, so the speed/turn fade is bypassed entirely in this
    -- mode (correction stays on while moving -- that's the point).
    -- The quaternion multiply ORDER for re-applying the deviation is a
    -- best-effort guess (parent-side pre-multiply), same caveat as pass
    -- 3's world-frame aim compensation -- soft_flip_order is the live A/B
    -- switch if the twist visibly over/under-corrects while animating.
    soft_mode = true,
    soft_baseline_tau_s = 0.4, -- how slowly the baseline follows the animation; shorter = closer to rigid, longer = slower pose adaptation
    soft_flip_order = false,
    -- Player concern (2026-08-16, raised live): the red dot visibly moves
    -- during any straight<->twisted transition. In soft mode the on/off
    -- transition is gone entirely, but the baseline still adapts during
    -- pose changes -- so while RG is held, freeze the baseline completely
    -- (correction offset becomes a true constant, dot's reference cannot
    -- drift mid-aim). Adaptation resumes on RG release, when no dot is
    -- rendered anyway.
    soft_freeze_baseline_while_aiming = true,
    setter_method = nil, -- filled in once we find one that works
    last_original = nil,
    last_applied = nil,
    -- 2026-08-16: player's own experiment -- also freeze spine_1/spine_2
    -- (the rest of the upper torso chain, up to the shoulder/chest attach
    -- point), not just spine_0. Legs/pelvis stay fully animated either way
    -- since this script has never touched them. Default true since this is
    -- specifically what's being tested; flip off to A/B against the
    -- original spine_0-only behavior.
    correct_upper_chain = true,
    -- 2026-08-16: opt-in follow-up experiment -- freezing spine_0/1/2 got
    -- the shake down to "nearly stable, a little bit left". pelvis is the
    -- direct parent of spine_0 in this rig (same chain re2_vr_holster.lua
    -- already resolves through), and it's the joint that naturally
    -- bobs/sways/tilts with the gait animation -- freezing the spine
    -- chain's LOCAL rotation doesn't cancel pelvis's own motion, it just
    -- rides along with it. Only the ROTATION is frozen here, never
    -- position -- position drives actual movement through the world and
    -- must stay untouched. Legs are a separate branch off pelvis (not a
    -- child of the spine chain), so they don't read pelvis's rotation the
    -- same way spine_0 does -- expect leg/walk animation to keep playing
    -- normally even with this on. Default false: unverified, separate A/B
    -- from correct_upper_chain above.
    correct_pelvis_rotation = false, -- 2026-08-16: targets "hips", the real joint name -- see LEG_JOINTS comment, "pelvis" doesn't exist in this skeleton
    -- 2026-08-16: diagnostic-only leg freeze, see LEG_JOINTS comment above
    -- apply_override. Default false, and should stay off outside of this
    -- specific test -- it kills the walk animation entirely.
    correct_legs_diagnostic = false,
    -- 2026-08-16: root/Null_Offset/COG rotation freeze -- see ROOT_CHAIN_JOINTS
    -- comment. Default false, opt-in, separate A/B from everything else.
    correct_root_chain = false,
    cutscene_gate_enabled = true, -- 2026-08-16: back on by default -- player wants cutscenes auto-protected now that this is being tuned for real play, not gameplay recording
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

    -- 2026-08-16: player tested constant-strength correction while moving
    -- (no fade) and confirmed real, visible gun/hand bounce in VR -- a
    -- genuine kinematic fight between the rigid spine and the still-
    -- animating hips/gait, not a symptom of the IK-multi-call bug fixed
    -- earlier this session. Simplified from a 2-threshold walk/run partial-
    -- strength curve to what the player actually wants: a simple ON when
    -- standing, OFF when moving binary, with the on/off TRANSITION smoothed
    -- (fade_smooth_tau_s below) so it doesn't jitter the VR hands -- not
    -- partial correction strength while moving, which is what caused the
    -- bounce in the first place.
    move_threshold_mps = 0.12, -- at/below this speed = correction on, above = off (smoothed by fade_smooth_tau_s)
    -- 2026-08-16: turning in place (rotating without translating) has zero
    -- XZ speed, so move_threshold_mps alone never caught it -- confirmed by
    -- the player as its own visible symptom (dot drags left during the turn
    -- animation). Same on/off treatment, just keyed off body yaw rate
    -- instead of position.
    turn_threshold_deg_s = 15.0, -- at/below this turn rate = correction on, above = off (same smoothing)
    last_speed_mps = 0.0,
    last_turn_deg_s = 0.0,
    last_speed_fade = 1.0,

    -- Smooths only the FADE MULTIPLIER (the 0..1 on/off scalar), not the
    -- written rotation itself -- deliberately different from pass 6's
    -- removed EMA, which smoothed the rotation target and caused its own
    -- judder from chasing a moving value with phase delay. Smoothing a
    -- binary on/off scalar as it eases across the move_threshold_mps
    -- crossing is a much smaller, narrower lag than smoothing a
    -- continuously-orientation-changing quaternion every frame.
    -- fade_smooth_tau_s = OFF direction (turning correction off as you
    -- start moving) -- crossed almost instantly so it has a whole
    -- acceleration's worth of runway already, short tau reads fine.
    -- fade_smooth_tau_on_s = ON direction (turning correction back on as
    -- you stop) -- longer, since speed only drops back below
    -- move_threshold_mps right at the tail end of stopping, so this is the
    -- direction that actually needs the extra runway to avoid a teleport/
    -- pop feel (see smooth_fade()'s comment for the full reasoning).
    fade_smooth_tau_s = 0.12,
    fade_smooth_tau_on_s = 0.35,

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
    last_fade_t = nil,
    smoothed_fade = 1.0,
    last_yaw_deg = nil,
    ema_turn_deg_s = 0.0,
}

-- Soft-mode per-joint state: baselines[name] = {
--   base = {x,y,z,w}       -- slow EMA of the joint's ANIMATED local rotation
--   last_raw = {x,y,z,w}   -- most recent confirmed-fresh animation value this frame
--   last_written = {x,y,z,w} -- what we last wrote, to detect stale re-reads
-- }
-- The last_written/last_raw pair matters because apply_override runs once
-- per IkArmFit.updateIk call (6x/frame, see the IK-reapply hook below): on a
-- repeat call the joint may still hold OUR previous write (native didn't
-- clobber it yet) -- naively treating that as "the animation value" would
-- compound the correction onto itself every call. If the read matches
-- last_written (quaternion dot ~1), reuse last_raw as the animation source
-- instead; if it differs, the native chain re-wrote the joint mid-frame and
-- the read IS a fresh animation value. Baseline EMA advances at most once
-- per real frame (soft.alpha is 0 on same-frame repeats, same os.clock()
-- dt-gate discipline as update_speed_estimate).
local soft = { baselines = {}, last_t = nil, alpha = 0.0 }

local function quat_normalize(x, y, z, w)
    local len = math.sqrt(x * x + y * y + z * z + w * w)
    if len < 1e-8 then return 0, 0, 0, 1 end
    return x / len, y / len, z / len, w / len
end

local function reset_soft_baselines()
    soft.baselines = {}
    soft.last_t = nil
    soft.alpha = 0.0
end

local function quat_dot4(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
end

-- Advances base toward q by alpha (component nlerp + renormalize, with
-- hemisphere sign-fix so a q/-q flip can't drag the baseline through zero).
-- Same cheap-lerp discipline as blend_toward_identity below -- fine for the
-- small per-frame angular deltas a tau>=0.1s baseline ever sees.
local function nlerp_baseline(base, q, alpha)
    local sx, sy, sz, sw = q.x, q.y, q.z, q.w
    if quat_dot4(base, q) < 0 then sx, sy, sz, sw = -sx, -sy, -sz, -sw end
    local x = base.x + (sx - base.x) * alpha
    local y = base.y + (sy - base.y) * alpha
    local z = base.z + (sz - base.z) * alpha
    local w = base.w + (sw - base.w) * alpha
    base.x, base.y, base.z, base.w = quat_normalize(x, y, z, w)
end

local function update_soft_alpha()
    local now_t = os.clock()
    local dt = 0.0
    if soft.last_t then dt = math.max(0.0, now_t - soft.last_t) end
    soft.last_t = now_t
    if dt > 1e-4 then
        soft.alpha = 1.0 - math.exp(-dt / math.max(0.05, state.soft_baseline_tau_s))
    else
        soft.alpha = 0.0 -- same-frame repeat call: baseline must not advance again
    end
end

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

local function get_joint(tf, name)
    if not tf then return nil end
    local ok_j, joint = pcall(function() return tf:call("getJointByName", name) end)
    if not ok_j or not joint then return nil end
    return joint
end

-- 2026-08-16: one-shot diagnostic -- this codebase has never referenced any
-- leg/foot joint names, so rather than guess (the exact mistake that caused
-- the imgui.text_wrapped bug in an earlier investigation), dump the REAL
-- joint list from the live skeleton and read it back from the log.
-- get_Joints() itself is a confirmed-real via.Transform method (re8_vr.lua
-- uses it), but its return shape isn't confirmed here, so this tries the
-- List-sugar pattern (get_elements(), proven in re2_vr_laser_dot_probe.lua)
-- first, falls back to get_Count()/numeric indexing, then plain ipairs as a
-- last resort -- logs whatever actually works instead of assuming.
local function dump_all_joints(tf)
    if not tf then
        log.info("[re2_vr_posture_spine_straighten_override] dump_all_joints: no transform")
        return
    end
    local ok_j, joints = pcall(function() return tf:call("get_Joints") end)
    if not ok_j or not joints then
        log.info("[re2_vr_posture_spine_straighten_override] dump_all_joints: get_Joints failed")
        return
    end
    local ok_el, elements = pcall(function() return joints:get_elements() end)
    local list = (ok_el and elements) and elements or joints

    local ok_count, n = pcall(function() return list:get_Count() end)
    if not (ok_count and n) then
        ok_count, n = pcall(function() return #list end)
    end

    log.info(string.format("[re2_vr_posture_spine_straighten_override] dump_all_joints: count=%s",
        tostring(ok_count and n or "?")))

    if ok_count and n and n > 0 then
        for i = 0, n - 1 do
            local ok_item, joint = pcall(function() return list[i] end)
            if ok_item and joint then
                local ok_name, jname = pcall(function() return joint:call("get_Name") end)
                log.info(string.format("[re2_vr_posture_spine_straighten_override]   [%d] %s",
                    i, ok_name and tostring(jname) or "?"))
            end
        end
    else
        local iterated = false
        for i, joint in ipairs(list) do
            iterated = true
            local ok_name, jname = pcall(function() return joint:call("get_Name") end)
            log.info(string.format("[re2_vr_posture_spine_straighten_override]   [%s] %s",
                tostring(i), ok_name and tostring(jname) or "?"))
        end
        if not iterated then
            log.info("[re2_vr_posture_spine_straighten_override] dump_all_joints: could not enumerate (no count, no ipairs)")
        end
    end
end

-- 2026-08-16: player asked to try freezing the WHOLE upper torso chain, not
-- just spine_0 -- reasoning: legs/pelvis are never touched by this script
-- at all (so locomotion stays fully animated), and VR hand tracking drives
-- the arms from controller position/IK, not from this chain's animation, so
-- there's no obvious reason the extra rigidity should hurt arm tracking.
-- spine_1/spine_2 are real, confirmed joint names already used elsewhere in
-- this codebase (re2_vr_holster.lua's shoulder/chest attach point resolves
-- through exactly this pelvis->spine_0->spine_1->spine_2 chain), not
-- guessed. Toggleable so spine_0-only can still be A/B'd against this.
local UPPER_CHAIN_JOINTS = { "spine_0", "spine_1", "spine_2" }

-- 2026-08-16: DIAGNOSTIC ONLY, real confirmed joint names from the live
-- get_Joints() dump. Player wants to test whether leg animation is the
-- source of the remaining subtle sway (observed in sync with footstep
-- sounds). Freezing these WILL look broken (no walk animation at all,
-- character will visibly slide) -- this is purely to isolate the cause,
-- not a candidate fix to keep enabled.
local LEG_JOINTS = { "l_leg_femur", "l_leg_tibia", "l_leg_ankle", "r_leg_femur", "r_leg_tibia", "r_leg_ankle" }

-- 2026-08-16: legs AND hips both confirmed ruled out (no change either
-- way) as the source of the remaining subtle sway the player described as
-- footstep-synced. The joint dump showed 3 more real joints above hips
-- never touched at all: root -> Null_Offset -> COG (Center Of Gravity).
-- COG doing a subtle procedural bob timed to footsteps is a more plausible
-- match for "in sync with footsteps" than the leg bones themselves (which
-- are a dead end now, confirmed) -- and since spine_0/1/2 + hips are all
-- children of this chain, any rotation COG/root/Null_Offset still carries
-- rides straight through everything we've already frozen, same "local
-- freeze doesn't cancel ancestor motion" issue as pelvis/hips.
-- CAUTION: "root" is very likely what defines which way the character
-- actually faces -- more risk than anything frozen so far. Goes through
-- the same speed/turn-threshold fade as everything else though, so it only
-- ever applies near-standstill, never while actually moving/turning.
local ROOT_CHAIN_JOINTS = { "root", "Null_Offset", "COG" }

local function reset_speed_tracker()
    move.last_pos = nil
    move.last_t = nil
    move.ema_speed = 0.0
    move.last_fade_t = nil
    move.smoothed_fade = 1.0
    move.last_yaw_deg = nil
    move.ema_turn_deg_s = 0.0
end

-- Signed yaw angle in degrees from a quaternion's forward vector -- same
-- proven pattern as re2_vr_hand_head_coupling_probe.lua's yaw_deg(), reused
-- here rather than guessed at fresh.
local function body_yaw_deg(q)
    local ok, fwd = pcall(function() return (q * Vector3f.new(0, 0, -1)):normalized() end)
    if not ok or not fwd then return nil end
    return math.deg(math.atan(fwd.x, -fwd.z))
end

-- Smooths only the fade SCALAR (0..1), not the written rotation -- see the
-- fade_smooth_tau_s state comment above for why this is safe where pass 6's
-- rotation-smoothing wasn't. Self-contained dt tracking (like
-- update_speed_estimate) so repeated same-frame calls (from the per-IK-call
-- reapply hook) are safe: tiny same-frame dt just no-ops via the dt > 1e-4
-- gate, so the EMA only actually advances once per real frame either way.
--
-- 2026-08-16: asymmetric tau, not one shared value. move_threshold_mps is
-- low (0.12 m/s) so it's crossed almost immediately when starting to move,
-- giving the OFF-transition a full acceleration's worth of runway to ease
-- smoothly. But speed only drops back below that same low threshold right
-- at the tail end of coming to a stop -- the ON-transition barely gets any
-- time to run before you're already standstill, so it read as a teleport/
-- pop even though the same tau value was "working" for the other
-- direction. Using a longer tau specifically for turning back ON gives it
-- runway independent of how briefly speed actually lingers near the
-- threshold on the way down.
local function smooth_fade(raw_fade)
    local now_t = os.clock()
    local dt = 0.0
    if move.last_fade_t then dt = math.max(0.0, now_t - move.last_fade_t) end
    move.last_fade_t = now_t
    if dt > 1e-4 then
        local turning_on = raw_fade > move.smoothed_fade
        local tau = math.max(0.001, turning_on and state.fade_smooth_tau_on_s or state.fade_smooth_tau_s)
        local alpha = 1.0 - math.exp(-dt / tau)
        move.smoothed_fade = move.smoothed_fade + (raw_fade - move.smoothed_fade) * alpha
    end
    return move.smoothed_fade
end

-- Updates and returns the flat (XZ) EMA speed estimate in m/s, AND the EMA
-- turn-rate estimate in deg/s. Caps both instantaneous per-frame values
-- before folding into their EMAs so a single teleport/cutscene-snap frame
-- can't spike the fade multiplier for several frames afterward.
--
-- 2026-08-16: turn-rate added. The move-threshold fade only ever tracked
-- flat XZ translation, so turning IN PLACE (rotating without walking --
-- confirmed by the player to visibly drag the dot left during the turn
-- animation) read as zero speed and never faded the correction off at all.
-- Sharing this function's existing dt tracking rather than adding a second
-- os.clock() call/gate elsewhere.
local function update_speed_estimate(tf)
    local now_t = os.clock()
    local ok, pos = pcall(function() return tf:call("get_Position") end)
    local ok_rot, rot = pcall(function() return tf:call("get_Rotation") end)
    local dt = 0.0
    if move.last_t then dt = math.max(0.0, now_t - move.last_t) end
    move.last_t = now_t
    if ok and pos and move.last_pos and dt > 1e-4 then
        local dx = pos.x - move.last_pos.x
        local dz = pos.z - move.last_pos.z
        local inst_speed = math.min(math.sqrt(dx * dx + dz * dz) / dt, 5.0)
        local tau = 0.15
        local alpha = 1.0 - math.exp(-dt / tau)
        move.ema_speed = move.ema_speed + (inst_speed - move.ema_speed) * alpha
    end
    if ok and pos then move.last_pos = pos end
    if ok_rot and rot then
        local yaw = body_yaw_deg(rot)
        if yaw and move.last_yaw_deg and dt > 1e-4 then
            local d = yaw - move.last_yaw_deg
            d = (d + 180.0) % 360.0 - 180.0 -- shortest signed wrap to [-180, 180)
            local inst_turn = math.min(math.abs(d) / dt, 720.0)
            local tau = 0.15
            local alpha = 1.0 - math.exp(-dt / tau)
            move.ema_turn_deg_s = move.ema_turn_deg_s + (inst_turn - move.ema_turn_deg_s) * alpha
        end
        if yaw then move.last_yaw_deg = yaw end
    end
    return move.ema_speed, move.ema_turn_deg_s
end

-- 2026-08-16: simplified from a 3-segment walk/run curve (two thresholds,
-- partial strength in between) to a plain binary target -- full strength at
-- standstill, zero the instant you're moving faster than the threshold.
-- Constant-strength correction while moving causes real, visible gun/hand
-- bounce in VR (a genuine fight between the rigid spine and the still-
-- animating hips/gait), so there's no useful "partial correction while
-- moving" middle ground worth keeping -- the old curve's in-between values
-- were just a softer version of the same bounce. smooth_fade() (above) is
-- what actually smooths the on/off transition now, applied to this raw
-- binary target, so a hard threshold here is fine -- it's not what the
-- player feels as a snap.
local function speed_fade_multiplier(speed, turn_deg_s)
    if speed > state.move_threshold_mps then return 0.0 end
    if turn_deg_s > state.turn_threshold_deg_s then return 0.0 end
    return 1.0
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

    local speed, turn_deg_s = 0.0, 0.0
    if state.speed_fade_enabled then
        speed, turn_deg_s = update_speed_estimate(tf)
    end
    -- Soft mode bypasses the speed/turn fade entirely -- correction staying
    -- on while moving is its whole purpose (the fade only existed because
    -- rigid freezing fought the gait; soft mode doesn't fight it). Speed is
    -- still estimated above so the panel readout stays live for A/B.
    local raw_fade = 1.0
    if state.speed_fade_enabled and not state.soft_mode then
        raw_fade = speed_fade_multiplier(speed, turn_deg_s)
    end
    local fade = smooth_fade(raw_fade)
    if state.soft_mode then
        update_soft_alpha()
    end
    state.last_speed_mps = speed
    state.last_turn_deg_s = turn_deg_s
    state.last_speed_fade = fade
    local effective_strength = state.strength * fade

    local joint_names = {}
    if state.correct_upper_chain then
        for _, n in ipairs(UPPER_CHAIN_JOINTS) do joint_names[#joint_names + 1] = n end
    else
        joint_names[1] = "spine_0"
    end
    if state.correct_pelvis_rotation then
        -- 2026-08-16: was "pelvis" -- confirmed via a live get_Joints() dump
        -- that this skeleton has no joint by that name at all (64 real
        -- joints logged, root->Null_Offset->COG->hips->{legs, spine_0}).
        -- The real joint is "hips". "pelvis" was silently failing
        -- getJointByName every frame, which is why this toggle felt like a
        -- no-op when tested -- it never actually applied anything.
        joint_names[#joint_names + 1] = "hips"
    end
    if state.correct_legs_diagnostic then
        for _, n in ipairs(LEG_JOINTS) do joint_names[#joint_names + 1] = n end
    end
    if state.correct_root_chain then
        for _, n in ipairs(ROOT_CHAIN_JOINTS) do joint_names[#joint_names + 1] = n end
    end
    local applied_count = 0
    -- While aiming, the baseline holds perfectly still (default on) so the
    -- correction offset -- and therefore the red dot's reference frame --
    -- cannot drift mid-aim. Adaptation resumes as soon as RG is released,
    -- when there's no dot on screen to care about.
    local freeze_baseline = state.soft_mode
        and state.soft_freeze_baseline_while_aiming
        and player_is_aiming(player)
    for _, name in ipairs(joint_names) do
        local joint = get_joint(tf, name)
        if joint then
            local ok_r, r = pcall(function() return joint:call("get_LocalRotation") end)
            if ok_r and r and type(r.y) == "number" then
                if name == "spine_0" then
                    state.last_original = { x = r.x, y = r.y, z = r.z, w = r.w }
                end
                local nx, ny, nz, nw
                if state.soft_mode then
                    local bl = soft.baselines[name]
                    if not bl then
                        bl = {
                            base = { x = r.x, y = r.y, z = r.z, w = r.w },
                            last_raw = { x = r.x, y = r.y, z = r.z, w = r.w },
                            last_written = nil,
                        }
                        soft.baselines[name] = bl
                    end
                    -- Stale-read guard (see the soft{} comment): on repeat
                    -- same-frame calls the joint may still hold our own
                    -- previous write -- re-correcting that would compound.
                    local anim
                    if bl.last_written and math.abs(quat_dot4(r, bl.last_written)) > 0.999999 then
                        anim = bl.last_raw
                    else
                        bl.last_raw = { x = r.x, y = r.y, z = r.z, w = r.w }
                        anim = bl.last_raw
                    end
                    if soft.alpha > 0.0 and not freeze_baseline then
                        nlerp_baseline(bl.base, anim, soft.alpha)
                    end
                    local bx, by, bz, bw = blend_toward_identity(bl.base,
                        effective_strength, effective_strength, effective_strength)
                    local q_base = Quaternion.new(bl.base.w, bl.base.x, bl.base.y, bl.base.z)
                    local q_corr = Quaternion.new(bw, bx, by, bz)
                    local q_off = quat_mul(q_corr, quat_inverse(q_base))
                    local q_anim = Quaternion.new(anim.w, anim.x, anim.y, anim.z)
                    local q_out = state.soft_flip_order and quat_mul(q_anim, q_off) or quat_mul(q_off, q_anim)
                    nx, ny, nz, nw = quat_normalize(q_out.x, q_out.y, q_out.z, q_out.w)
                else
                    nx, ny, nz, nw = blend_toward_identity(r, effective_strength, effective_strength, effective_strength)
                end
                local applied = try_set_local_rotation(joint, nx, ny, nz, nw)
                if applied then
                    applied_count = applied_count + 1
                    if state.soft_mode then
                        local bl = soft.baselines[name]
                        if bl then bl.last_written = { x = nx, y = ny, z = nz, w = nw } end
                    end
                    if name == "spine_0" then
                        state.last_applied = { x = nx, y = ny, z = nz, w = nw }
                    end
                end
            end
        end
    end

    if applied_count > 0 then
        state.status = string.format("applied to %d/%d joint(s) via %s, strength=%.2f (x%.2f fade)",
            applied_count, #joint_names, state.setter_method, effective_strength, fade)
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

-- 2026-08-16: re2_vr_aim_alignment_probe.lua's fixed IK hook (now catching
-- both IkArmFit.updateIk overloads, see that file's header) finally captured
-- real per-call data and found the actual bug: native IkArmFit.updateIk
-- fires SIX times per frame, not once, but our Pre hook above only writes
-- the corrected spine_0 ONCE at the very top of the frame. Live capture
-- (2026-08-16, both spine-on and spine-off 10s captures) showed spine0_y
-- sitting at the corrected value (~-0.02) for the first 2 IK calls each
-- frame, then flipping to the raw, continuously-animating uncorrected value
-- (~-0.33) for the remaining 4 -- with r_wrist shifting by roughly half a
-- unit between the two groups. Something inside the native LateUpdateBehavior
-- chain re-evaluates/rewrites spine_0 between those calls, clobbering our
-- single per-frame write before most of the IK solving that actually
-- determines the rendered weapon/wrist position ever sees it -- this is very
-- likely the real mechanism behind the weapon-mesh twist and the red-dot
-- drift that rides on top of it, both closed as "same class of problem" in
-- re2_vr_torso_twist_status pass 7.
--
-- Fix: hook IkArmFit.updateIk directly (same get_methods()-iterate-all-
-- overloads technique already proven in re2_vr_aim_alignment_probe.lua and
-- re2_vr_ik_extention.lua -- get_method(name) alone silently grabs only one
-- overload and never fires) and re-apply the correction immediately before
-- EVERY call, not just once at the top of the frame. Only active for "pre"
-- timing (post/prepare are a different, once-at-frame-end concept and
-- shouldn't get per-IK-call treatment). apply_override() is safe to call
-- repeatedly within the same frame -- update_speed_estimate()'s EMA update
-- is gated on real elapsed time (os.clock() dt > 1e-4), so extra same-frame
-- calls just no-op on the speed side, and try_set_local_rotation() reuses
-- the cached setter method.
local IK_NS = sdk.game_namespace
local ik_reapply = { installed = false, arm_fit_type = nil, warned = false }

local function on_pre_ik_reapply_correction()
    if not state.enabled then return end
    if state.timing ~= "pre" then return end
    local player = gate_check()
    if not player then return end
    apply_override(player)
end

local function on_post_ik_passthrough(retval)
    return retval
end

local function install_ik_reapply_hook()
    if ik_reapply.installed then return end
    ik_reapply.arm_fit_type = sdk.find_type_definition(IK_NS("IkArmFit"))
    if not ik_reapply.arm_fit_type then
        if not ik_reapply.warned then
            log.warn("[re2_vr_posture_spine_straighten_override] IkArmFit type not found")
            ik_reapply.warned = true
        end
        return
    end
    local hooked = 0
    local methods = ik_reapply.arm_fit_type:get_methods()
    if methods then
        for _, method in ipairs(methods) do
            if method and method:get_name() == "updateIk" then
                sdk.hook(method, on_pre_ik_reapply_correction, on_post_ik_passthrough)
                hooked = hooked + 1
            end
        end
    end
    if hooked == 0 then
        local method = ik_reapply.arm_fit_type:get_method("updateIk")
        if method then
            sdk.hook(method, on_pre_ik_reapply_correction, on_post_ik_passthrough)
            hooked = 1
        end
    end
    if hooked == 0 then
        if not ik_reapply.warned then
            log.warn("[re2_vr_posture_spine_straighten_override] IkArmFit.updateIk not found")
            ik_reapply.warned = true
        end
        return
    end
    ik_reapply.installed = true
    log.info(string.format(
        "[re2_vr_posture_spine_straighten_override] Hooked IkArmFit.updateIk for per-call re-correction (%d)",
        hooked))
end

install_ik_reapply_hook()

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
        reset_soft_baselines()
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

    -- 2026-08-16 UI cleanup (player request): essentials at top level, the
    -- entire legacy-freeze/fade/timing/diagnostic apparatus tucked into a
    -- collapsed Advanced node. Nothing was deleted -- soft mode is the
    -- confirmed-working default, but every legacy control still works for
    -- A/B if soft mode ever misbehaves.
    local c, v = imgui.checkbox("Enable twist removal", state.enabled)
    if c then state.enabled = v end

    local sc, sv = imgui.slider_float("Strength", state.strength, 0.0, 1.0, "%.2f")
    if sc then state.strength = sv end

    local smc, smv = imgui.checkbox("Soft mode: remove twist only, keep animation (recommended)", state.soft_mode)
    if smc then
        state.soft_mode = smv
        reset_soft_baselines()
    end
    if state.soft_mode then
        local stc, stv = imgui.slider_float("Baseline adapt time (s)", state.soft_baseline_tau_s, 0.1, 2.0, "%.2f")
        if stc then state.soft_baseline_tau_s = stv end
        local sbc, sbv = imgui.checkbox("Freeze baseline while aiming (keeps red dot rock-stable)", state.soft_freeze_baseline_while_aiming)
        if sbc then state.soft_freeze_baseline_while_aiming = sbv end
    end

    imgui.text("Status: " .. tostring(state.status))

    imgui.spacing()
    if imgui.tree_node("Aim compensation (manual red-dot/crosshair nudge)") then
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
            "Right-hand wrist only. Aim in-game and nudge until the red dot lines up with the crosshair.",
            0xFF88CCFF)
        imgui.tree_pop()
    end

    if imgui.tree_node("Advanced / legacy / diagnostics") then
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

        if state.soft_mode then
            local foc, fov = imgui.checkbox("Soft mode: flip deviation multiply order (A/B if twist looks wrong while moving)", state.soft_flip_order)
            if foc then state.soft_flip_order = fov end
        end

        imgui.spacing()
        imgui.text("Joint selection (applies in both modes):")
        local ucc, ucv = imgui.checkbox("Correct spine_1/spine_2 too (whole upper torso)", state.correct_upper_chain)
        if ucc then state.correct_upper_chain = ucv end
        local pcc, pcv = imgui.checkbox("Also correct hips rotation", state.correct_pelvis_rotation)
        if pcc then state.correct_pelvis_rotation = pcv end
        local lcc, lcv = imgui.checkbox("DIAGNOSTIC: freeze legs (WILL look broken)", state.correct_legs_diagnostic)
        if lcc then state.correct_legs_diagnostic = lcv end
        local rcc, rcv = imgui.checkbox("Also correct root/Null_Offset/COG rotation (caution, may affect facing)", state.correct_root_chain)
        if rcc then state.correct_root_chain = rcv end

        imgui.spacing()
        imgui.text("Legacy rigid-freeze mode controls (only active when soft mode is OFF):")
        local sfc, sfv = imgui.checkbox("Turn correction off while moving/turning (legacy anti-shake)", state.speed_fade_enabled)
        if sfc then state.speed_fade_enabled = sfv end
        local mtc, mtv = imgui.slider_float("Move threshold (on below, off above)", state.move_threshold_mps, 0.05, 1.0, "%.2f m/s")
        if mtc then state.move_threshold_mps = mtv end
        local ttc, ttv = imgui.slider_float("Turn threshold (on below, off above)", state.turn_threshold_deg_s, 5.0, 90.0, "%.0f deg/s")
        if ttc then state.turn_threshold_deg_s = ttv end
        local ftc, ftv = imgui.slider_float("Turning off smoothing (s)", state.fade_smooth_tau_s, 0.0, 0.5, "%.2f")
        if ftc then state.fade_smooth_tau_s = ftv end
        local ftoc, ftov = imgui.slider_float("Turning back on smoothing (s)", state.fade_smooth_tau_on_s, 0.0, 1.0, "%.2f")
        if ftoc then state.fade_smooth_tau_on_s = ftov end
        imgui.text(string.format("Current speed: %.2f m/s -- turn rate: %.0f deg/s -- fade: %.0f%%",
            state.last_speed_mps, state.last_turn_deg_s, state.last_speed_fade * 100.0))

        imgui.spacing()
        imgui.text("Hook timing (Pre is correct -- Post/Prepare kept for reference only):")
        if imgui.button((state.timing == "pre" and "[x] " or "[ ] ") .. "Pre (before arm IK solves)") then
            state.timing = "pre"
        end
        if imgui.button((state.timing == "post" and "[x] " or "[ ] ") .. "Post (after arm IK -- causes gun-points-left)") then
            state.timing = "post"
        end
        if imgui.button((state.timing == "prepare" and "[x] " or "[ ] ") .. "Prepare (very late -- tested, didn't help)") then
            state.timing = "prepare"
        end

        imgui.spacing()
        if imgui.button("Dump ALL joint names to log") then
            local p = re2.get_localplayer()
            local tf2 = p and get_player_transform(p)
            dump_all_joints(tf2)
        end

        if state.last_original then
            imgui.text(string.format("Last original spine_0 = (%.4f, %.4f, %.4f, %.4f)",
                state.last_original.x, state.last_original.y, state.last_original.z, state.last_original.w))
        end
        if state.last_applied then
            imgui.text(string.format("Last applied  spine_0 = (%.4f, %.4f, %.4f, %.4f)",
                state.last_applied.x, state.last_applied.y, state.last_applied.z, state.last_applied.w))
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

re.on_script_reset(function()
    -- No longer forces enabled=false (that was diagnostic-era safety) --
    -- the feature is on by default now and should survive a script reset.
    state.status = "idle"
    reset_speed_tracker()
    reset_soft_baselines()
end)

log.info("[re2_vr_posture_spine_straighten_override] Loaded")
