-- Live diagnostic for the Red Dot Sight / laser-sight DOT drift shared by
-- the Lightning Hawk's Red Dot Sight attachment and the JMB Hp3's built-in
-- laser sight. New info from live testing (2026-08-15): the JMB Hp3's
-- laser has TWO separate visual parts -- the BEAM (the line from the
-- muzzle) stays accurate/straight when spine correction is on, but the DOT
-- at the beam's end drifts left, exactly like the Red Dot Sight
-- attachment's dot. That means whatever's broken is specific to the DOT's
-- calculation, is very likely SHARED between the built-in laser and the
-- attachable sight (same underlying native subsystem, since both weapons
-- show the identical symptom), and is provably NOT whatever draws the beam
-- line (which tracks correctly).
--
-- re2_vr_laser_sight_drift_status.md's 17-mechanism investigation already
-- ruled out every static field/component reachable from the weapon/player
-- GameObjects, except one: WeaponArm.<LaserSightTipPosition>k__BackingField
-- (via.vec3) correlated with drift strength but writing to it (both the
-- raw field and its proper setter) had zero visible effect -- concluded to
-- be a downstream READOUT, not what the renderer actually consumes. That
-- investigation's final recommendation, never attempted: live method
-- hooking instead of more static field dumps. This probe does that:
--
--   1. Full WeaponArm method+field dump, walking its whole class hierarchy,
--      filtered for laser/sight/beam/dot/line keywords -- broader than the
--      original investigation's per-mechanism searches, and specifically
--      includes METHODS this time, not just field names (mechanism 4 only
--      searched component NAMES, not WeaponArm's own methods).
--   2. Live burst-logging of LaserSightTipPosition alongside a real ground-
--      truth muzzle position/forward direction (resolved independently in
--      this file, VR-gate-free -- see 2026-08-15 note below) and the
--      resulting angular deviation in degrees -- auto-triggered the instant
--      aiming starts (same technique as re2_vr_aim_alignment_probe.lua), so
--      we get a direct, frame-by-frame, quantitative picture of exactly how
--      the broken value diverges from the known-correct one, at 5 pipeline
--      stages within the same frame.
--   3. If a setter method for LaserSightTipPosition exists
--      (set_LaserSightTipPosition/setLaserSightTipPosition), hooks it to
--      log every call (and the field's value immediately after) -- never
--      tried before, only raw field reads/writes were.
--   4. Existence + method dump of via.render.Stamp (an engine-level decal
--      type name-dropped in the old investigation as an architectural
--      comparison for "a projected dot landing on a wall") -- checked, not
--      assumed.
--
-- Read-only except item 3's hook, which only LOGS -- it never blocks or
-- changes the call, and never writes anything.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")
local NS = sdk.game_namespace

-- 2026-08-15, resumed: player confirmed this drift IS visible on flat-screen
-- (previously assumed VR-only), and re2_vr_crosshair.lua's own muzzle/
-- crosshair correlation data (re2.crosshair_pos/last_shoot_pos/last_shoot_dir)
-- turned out to be VR-gated -- every call site in that script bails early on
-- `if not vrmod:is_hmd_active() then return end`, so those globals stayed
-- nil for the whole capture regardless of whether a headset was even the
-- issue. Rather than touch the shipped crosshair script (broader blast
-- radius, its VR gate exists for real reasons elsewhere in that file), this
-- probe now resolves its OWN ground-truth muzzle position/forward direction,
-- copying re2_vr_crosshair.lua's update_muzzle_data() joint-resolution logic
-- verbatim minus the VR gate (that logic itself was never VR-dependent, only
-- its call site was). Read-only, no new hooks.
local transform_get_joint_by_hash = sdk.find_type_definition("via.Transform"):get_method("getJointByHash")
local gameobject_get_transform = sdk.find_type_definition("via.GameObject"):get_method("get_Transform")
local joint_get_position = sdk.find_type_definition("via.Joint"):get_method("get_Position")
local via_murmur_hash_calc32 = sdk.find_type_definition("via.murmur_hash"):get_method("calc32")
local vfx_muzzle1_hash = via_murmur_hash_calc32:call(nil, "vfx_muzzle1")
local vfx_muzzle2_hash = via_murmur_hash_calc32:call(nil, "vfx_muzzle2")

local state = {
    survivor_condition_type = nil,
    setter_hook_installed = false,
    setter_method_name = nil,
    auto_capture_on_aim = false,
    was_aiming = false,
    burst_remaining = 0,
    frame = 0,
    log_this_frame = false,
    last_dump = "No dump yet.",

    -- 2026-08-15, resumed further: the aim-triggered burst is only
    -- ~1.5s (90 frames @60fps assumed) -- too short for a deliberate
    -- "toggle spine correction, then turn your head around for a while"
    -- A/B test. Time-based (os.clock()) instead of frame-count-based so it
    -- stays a real 10 seconds regardless of the VR headset's actual
    -- refresh rate (90/120Hz would blow through a 90-frame budget in under
    -- a second).
    manual_capture_until = nil,

    -- 2026-08-15 continued: set_LaserSightTipPosition confirmed hooked but
    -- NEVER fired despite the field changing every frame in the correlation
    -- log -- something writes that backing field directly, bypassing its
    -- own property setter. Pivoting to via.render.Stamp instead (confirmed
    -- to exist, has get_Color/set_Color -- a real decal-painting system,
    -- matching the old investigation's own "projected dot = decal" theory).
    stamp_hook_installed = false,
    pending_stamp_this = nil,
}

local AUTO_CAPTURE_FRAMES = 90 -- ~1.5s at 60fps

local SETTER_CANDIDATES = { "set_LaserSightTipPosition", "setLaserSightTipPosition" }
local TIP_FIELD = "<LaserSightTipPosition>k__BackingField"

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

local function get_survivor_condition(player)
    if not player then return nil end
    if not state.survivor_condition_type then
        state.survivor_condition_type = sdk.typeof(NS("survivor.SurvivorCondition"))
    end
    if not state.survivor_condition_type then return nil end
    return safe(function() return player:call("getComponent(System.Type)", state.survivor_condition_type) end)
end

local function player_is_aiming()
    local cond = get_survivor_condition(re2.get_localplayer())
    if not cond then return false end
    return safe(function() return cond:call("get_IsHold") end) == true
end

local function name_matches(name)
    if type(name) ~= "string" then return false end
    local n = name:lower()
    return n:find("laser") or n:find("sight") or n:find("beam") or n:find("dot") or n:find("line")
end

local function fmt_vec(v)
    if not v then return "nil" end
    return string.format("(%.4f, %.4f, %.4f)", v.x, v.y, v.z)
end

-- VR-independent ground truth for "where the gun actually points" -- mirrors
-- re2_vr_crosshair.lua's update_muzzle_data() joint resolution exactly, just
-- without the vrmod:is_hmd_active() gate that only exists at THAT script's
-- call site.
--
-- 2026-08-15, resumed further: dev_deg_vs_cam came back EXACTLY 0.00 for a
-- full 90-frame capture -- suspiciously perfect for an independent
-- measurement, and it turns out this function has a camera-forward
-- FALLBACK path for "camera type" weapons (_FireBulletType == 0). If that
-- path is the one actually firing, muzzle_fwd IS camera forward by
-- construction, making any comparison against camera forward trivially
-- zero and uninformative -- not a real finding. Now returns a third value,
-- `src`, so every log line records which path actually resolved
-- ("joint" vs "camera_fallback" vs "no_weapon"/"no_param") instead of
-- silently assuming.
local function get_muzzle_ground_truth()
    if not re2.weapon then return nil, nil, "no_weapon" end
    local param = safe(function() return re2.weapon:get_field("<FireBulletParam>k__BackingField") end)
    if not param then return nil, nil, "no_param" end
    local fire_type = safe(function() return param:get_field("_FireBulletType") end)
    local is_camera_type = fire_type == 0

    local muzzle_joint = nil
    if not is_camera_type then
        muzzle_joint = safe(function() return re2.weapon:get_field("<MuzzleJoint>k__BackingField") end)
        if muzzle_joint then
            muzzle_joint = safe(function() return muzzle_joint:get_field("_Parent") end)
        end
    end
    if (not is_camera_type) and not muzzle_joint then
        local weapon_go = safe(function() return re2.weapon:call("get_GameObject") end)
        if weapon_go then
            local transform = safe(function() return gameobject_get_transform(weapon_go) end)
            if transform then
                muzzle_joint = safe(function() return transform_get_joint_by_hash(transform, vfx_muzzle1_hash) end)
                if not muzzle_joint then
                    muzzle_joint = safe(function() return transform_get_joint_by_hash(transform, vfx_muzzle2_hash) end)
                end
            end
        end
    end

    if muzzle_joint then
        local pos = safe(function() return joint_get_position(muzzle_joint) end)
        local fwd = safe(function() return muzzle_joint:call("get_AxisZ") end)
        return pos, fwd, "joint(fire_type=" .. tostring(fire_type) .. ")"
    end

    -- Camera-type fallback (matches re2_vr_crosshair.lua's own fallback).
    local cam = safe(function() return sdk.get_primary_camera() end)
    local mat = cam and safe(function() return cam:get_WorldMatrix() end)
    if not mat then return nil, nil, "no_camera" end
    local pos = mat[3]
    local fwd = safe(function() return (mat:to_quat() * Vector3f.new(0, 0, -1)):normalized() end)
    return pos, fwd, "camera_fallback(fire_type=" .. tostring(fire_type) .. ")"
end

local function vec3_sub(a, b)
    return Vector3f.new(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function vec3_len(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function vec3_dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

-- Angle (degrees) between two direction vectors -- the actual "how many
-- degrees off" number, matching how this bug has always been described
-- ("30-50 degrees off from actual aim").
local function angle_between_deg(a, b)
    local la, lb = vec3_len(a), vec3_len(b)
    if la < 1e-6 or lb < 1e-6 then return nil end
    local cosang = vec3_dot(a, b) / (la * lb)
    cosang = math.max(-1.0, math.min(1.0, cosang))
    return math.deg(math.acos(cosang))
end

-- 2026-08-15, resumed further: first flat-screen capture showed tip tracking
-- the muzzle joint's own forward direction almost perfectly (dev_deg maxed
-- at 0.31 degrees across a whole 90-frame/5-stage burst) -- tip is NOT
-- internally broken relative to the muzzle joint. That reframes the
-- question: is the MUZZLE JOINT ITSELF (i.e. the weapon mesh's actual pose
-- in-hand, driven by arm IK) misoriented relative to where the player is
-- really looking/aiming? Camera forward is a real independent ground truth
-- for that -- unlike the muzzle joint, it isn't part of the arm-IK chain
-- spine correction disturbs. If muzzle_fwd diverges sharply from cam_fwd
-- while tip keeps tracking muzzle_fwd closely, that confirms the actual bug
-- is upstream in arm-IK/weapon-mesh pose (the older, separately-documented
-- "gun points left" symptom), not a laser-dot-specific rendering bug at all.
local function get_camera_forward()
    local cam = safe(function() return sdk.get_primary_camera() end)
    local mat = cam and safe(function() return cam:get_WorldMatrix() end)
    if not mat then return nil end
    return safe(function() return (mat:to_quat() * Vector3f.new(0, 0, -1)):normalized() end)
end

-- 2026-08-15, resumed further still: dev_deg_vs_cam came back EXACTLY 0.00
-- for an entire capture, which turned out to mean the muzzle_fwd path fell
-- through to the camera_fallback branch (this weapon is fire_type=0,
-- "camera type") -- comparing it against camera forward was circular, not a
-- real measurement. The MuzzleJoint/vfx_muzzle abstraction is also plausibly
-- kept camera-aligned on purpose by re2_vr_ik_extention.lua's FirstPerson-
-- style hand IK (per re2_vr_torso_twist_status.md), independent of how the
-- weapon MESH actually looks. r_arm_wrist is a better ground truth: it's the
-- joint the weapon mesh is physically attached to/skinned from, and the same
-- joint re2_vr_posture_spine_straighten_override.lua's manual aim-
-- compensation sliders already manipulate for this exact symptom -- nothing
-- camera-locks it, so comparing IT against camera forward is a real,
-- unambiguous test of whether the visible mesh itself is misaimed.
local function get_wrist_ground_truth()
    local player = re2.get_localplayer()
    if not player then return nil, nil end
    local tf = safe(function() return player:call("get_Transform") end)
    if not tf then return nil, nil end
    local wrist = safe(function() return tf:call("getJointByName", "r_arm_wrist") end)
    if not wrist then return nil, nil end
    local pos = safe(function() return wrist:call("get_Position") end)
    local fwd = safe(function() return wrist:call("get_AxisZ") end)
    return pos, fwd
end

-- Item 1: full WeaponArm hierarchy dump on demand.
local function dump_weapon_arm()
    local lines = {}
    if not re2.weapon then
        state.last_dump = "no re2.weapon (equip/aim a weapon first)"
        return
    end
    local tdef = safe(function() return re2.weapon:get_type_definition() end)
    if not tdef then
        state.last_dump = "could not get WeaponArm type definition"
        return
    end

    local depth = 0
    while tdef and depth < 6 do
        local tname = safe(function() return tdef:get_full_name() end) or "?"
        table.insert(lines, string.format("== L%d: %s ==", depth, tname))

        local methods = safe(function() return tdef:get_methods() end) or {}
        for _, m in ipairs(methods) do
            local mname = safe(function() return m:get_name() end)
            if name_matches(mname) then
                table.insert(lines, "  [method] " .. mname)
            end
        end

        local fields = safe(function() return tdef:get_fields() end) or {}
        for _, f in ipairs(fields) do
            local fname = safe(function() return f:get_name() end)
            if name_matches(fname) then
                local is_static = safe(function() return f:is_static() end)
                local ok_v, value
                if is_static then
                    ok_v, value = pcall(function() return f:get_data(nil) end)
                else
                    ok_v, value = pcall(function() return f:get_data(re2.weapon) end)
                end
                table.insert(lines, string.format("  [field] %s = %s", fname, ok_v and tostring(value) or "?(get_data failed)"))
            end
        end

        tdef = safe(function() return tdef:get_parent_type() end)
        depth = depth + 1
    end

    if #lines == 0 then
        table.insert(lines, "no laser/sight/beam/dot/line-named methods or fields found in WeaponArm's hierarchy")
    end

    state.last_dump = table.concat(lines, "\n")
    log.info("[laser_dot_probe]\n" .. state.last_dump)
end

-- Item 4: check via.render.Stamp's existence + methods (engine-level type,
-- just confirming presence/shape -- not assumed, not hooked here).
local function dump_stamp_type()
    local lines = {}
    local tdef = sdk.find_type_definition("via.render.Stamp")
    if not tdef then
        state.last_dump = "via.render.Stamp: type not found in this game's TDB"
        return
    end
    table.insert(lines, "via.render.Stamp FOUND. Methods:")
    local methods = safe(function() return tdef:get_methods() end) or {}
    for _, m in ipairs(methods) do
        local mname = safe(function() return m:get_name() end)
        if mname then table.insert(lines, "  " .. mname) end
    end
    state.last_dump = table.concat(lines, "\n")
    log.info("[laser_dot_probe]\n" .. state.last_dump)
end

-- Item 6 (2026-08-15, resumed once more): recursive FULL descendant tree
-- dump. The original 17-mechanism investigation's mechanism 2 ("Separate
-- child GameObject under weapon or player Transform -- zero children on
-- both") only ever checked DIRECT children -- if the dot/beam VFX lives on
-- a GRANDCHILD (e.g. a sight-attachment prefab's own child decal object,
-- parented under an attachment socket that's itself a child of the weapon),
-- that check would have missed it entirely. This walks the WHOLE transform
-- tree (not just one level) from both the weapon's and the player's root,
-- using the same get_Child/get_Next linked-list traversal already proven
-- in this codebase (re2_vr_holster.lua's get_transform_children /
-- find_flashlight_on_transform), logging every GameObject's name and every
-- component's type name at every depth -- not filtered by keyword, since a
-- keyword filter is exactly what could miss something whose name doesn't
-- obviously say "laser"/"sight"/"dot". Read-only, one-shot (button-
-- triggered), depth- and node-count-capped so it can't run away.
local function get_transform_children(xform)
    local out = {}
    if not xform then return out end
    local child = safe(function() return xform:call("get_Child") end)
    while child do
        out[#out + 1] = child
        child = safe(function() return child:call("get_Next") end)
    end
    return out
end

local MAX_HIERARCHY_DEPTH = 8
local MAX_HIERARCHY_NODES = 400

local function dump_transform_tree(xform, depth, lines, node_count)
    if not xform or depth > MAX_HIERARCHY_DEPTH or node_count[1] >= MAX_HIERARCHY_NODES then
        return
    end
    node_count[1] = node_count[1] + 1

    local go = safe(function() return xform:call("get_GameObject") end)
    local name = go and safe(function() return go:call("get_Name") end) or nil
    local indent = string.rep("  ", depth)
    table.insert(lines, string.format("%s[%d] %s", indent, depth, name or "?"))

    if go then
        local components = safe(function()
            local list = go:call("get_Components")
            return list and list:call("get_elements")
        end)
        if components then
            for _, comp in ipairs(components) do
                local tdef = safe(function() return comp:get_type_definition() end)
                local tname = tdef and safe(function() return tdef:get_full_name() end)
                if tname then
                    table.insert(lines, indent .. "    - " .. tname)
                end
            end
        end
    end

    for _, child in ipairs(get_transform_children(xform)) do
        dump_transform_tree(child, depth + 1, lines, node_count)
    end
end

local function dump_full_hierarchy()
    local lines = {}
    local node_count = { 0 }

    if re2.weapon then
        local weapon_go = safe(function() return re2.weapon:call("get_GameObject") end)
        local weapon_tf = weapon_go and safe(function() return weapon_go:call("get_Transform") end)
        if weapon_tf then
            table.insert(lines, "== WEAPON transform tree ==")
            dump_transform_tree(weapon_tf, 0, lines, node_count)
        else
            table.insert(lines, "== WEAPON: no transform found (equip/aim a weapon first) ==")
        end
    else
        table.insert(lines, "== WEAPON: no re2.weapon (equip/aim a weapon first) ==")
    end

    local player = re2.get_localplayer()
    local player_tf = player and safe(function() return player:call("get_Transform") end)
    if player_tf then
        node_count[1] = 0
        table.insert(lines, "")
        table.insert(lines, "== PLAYER transform tree ==")
        dump_transform_tree(player_tf, 0, lines, node_count)
    end

    if node_count[1] >= MAX_HIERARCHY_NODES then
        table.insert(lines, string.format("(stopped at %d nodes -- depth/node cap reached)", MAX_HIERARCHY_NODES))
    end

    state.last_dump = table.concat(lines, "\n")
    log.info("[laser_dot_probe] FULL HIERARCHY DUMP:\n" .. state.last_dump)
end

-- Item 3: hook the setter if one exists. Logs only -- never blocks/changes
-- the call, never writes.
local function try_install_setter_hook()
    if state.setter_hook_installed then return end
    if not re2.weapon then return end
    local tdef = safe(function() return re2.weapon:get_type_definition() end)
    if not tdef then return end

    for _, name in ipairs(SETTER_CANDIDATES) do
        local method = safe(function() return tdef:get_method(name) end)
        if method then
            sdk.hook(method,
                function(args)
                    log.info(string.format("[laser_dot_probe] %s CALLED, frame=%d", name, state.frame))
                end,
                function(retval)
                    local after = safe(function() return re2.weapon:get_field(TIP_FIELD) end)
                    log.info(string.format("[laser_dot_probe] %s RETURNED, frame=%d, field now=%s",
                        name, state.frame, fmt_vec(after)))
                    return retval
                end)
            state.setter_hook_installed = true
            state.setter_method_name = name
            log.info("[laser_dot_probe] Hooked " .. name)
            return
        end
    end
end

-- Item 5 (2026-08-15 continued): hook via.render.Stamp.set_Color, gated to
-- only log during an active capture burst (this method is very likely
-- called for lots of unrelated decals -- blood, footprints, bullet impacts
-- -- across the whole game, not just the laser dot; unconditional logging
-- would be spam). Reads via normal SDK calls on the captured `this`
-- (get_Color before/after), not raw argument decoding -- safer than trying
-- to parse a value-type color struct out of the raw hook args.
local function try_install_stamp_hook()
    if state.stamp_hook_installed then return end
    local tdef = sdk.find_type_definition("via.render.Stamp")
    if not tdef then return end
    local method = safe(function() return tdef:get_method("set_Color") end)
    if not method then return end

    sdk.hook(method,
        function(args)
            local this_obj = sdk.to_managed_object(args[1])
            state.pending_stamp_this = this_obj
            if state.burst_remaining <= 0 then return end
            local before = this_obj and safe(function() return this_obj:call("get_Color") end)
            log.info(string.format("[laser_dot_probe] Stamp.set_Color CALLED this=%s before_color=%s frame=%d",
                tostring(this_obj), tostring(before), state.frame))
        end,
        function(retval)
            if state.burst_remaining > 0 and state.pending_stamp_this then
                local after = safe(function() return state.pending_stamp_this:call("get_Color") end)
                log.info(string.format("[laser_dot_probe] Stamp.set_Color RETURNED this=%s after_color=%s frame=%d",
                    tostring(state.pending_stamp_this), tostring(after), state.frame))
            end
            return retval
        end)
    state.stamp_hook_installed = true
    log.info("[laser_dot_probe] Hooked via.render.Stamp.set_Color")
end

-- Item 2 (2026-08-15, extended): correlated live burst logging -- the broken
-- field side by side with this mod's own known-accurate aim data. Extended
-- with the "next reasoned-but-untried step" from the pause point: log the
-- field at SEVERAL stages WITHIN the same frame (same multi-stage technique
-- as re2_vr_aim_alignment_probe.lua, which cracked the spine-timing question
-- the same way) to find WHEN LaserSightTipPosition changes/snaps rather than
-- only observing its value once per frame. The known behavior (from the
-- prior capture) is a ~17-frame garbage-range period right as aiming starts,
-- then a discontinuous jump to a regime that co-varies with real aim but
-- offset -- the goal here is to see which pipeline stage the jump lands
-- between.
local function should_log()
    return state.log_this_frame == true
end

local function log_stage(stage)
    if not should_log() then return end
    local tip = re2.weapon and safe(function() return re2.weapon:get_field(TIP_FIELD) end)
    local muzzle_pos, muzzle_fwd, muzzle_src = get_muzzle_ground_truth()
    local cam_fwd = get_camera_forward()
    local wrist_pos, wrist_fwd = get_wrist_ground_truth()
    local spine_on = rawget(_G, "__vr_spine_correction_enabled")
    local spine_timing = rawget(_G, "__vr_spine_correction_timing")

    local dev_deg = nil
    if tip and muzzle_pos and muzzle_fwd then
        dev_deg = angle_between_deg(vec3_sub(tip, muzzle_pos), muzzle_fwd)
    end
    local dev_deg_cam = (muzzle_fwd and cam_fwd) and angle_between_deg(muzzle_fwd, cam_fwd) or nil
    local dev_deg_wrist_vs_cam = (wrist_fwd and cam_fwd) and angle_between_deg(wrist_fwd, cam_fwd) or nil

    -- 2026-08-15, resumed further: dev_deg_vs_cam (gun direction vs. camera
    -- direction) is a flawed metric for THIS test -- in a correctly-working
    -- system, gun direction and camera direction are SUPPOSED to be
    -- independent (that's the whole point of 6DOF hand tracking), so a
    -- large value is expected/normal whenever the player looks somewhere
    -- different from where they're aiming, regardless of any bug. The
    -- methodology that actually worked for the earlier hand/head coupling
    -- test was different: correlate FRAME-TO-FRAME CHANGE in the measured
    -- direction against frame-to-frame change in camera yaw, not compare
    -- snapshots directly. Logging cam_fwd as a raw vector (not just the
    -- derived angle) so that delta-correlation analysis can be done the
    -- same way here.
    -- 2026-08-15, resumed once more: player clarified the REAL symptom --
    -- in VR the weapon MESH itself never moves at all, only the DOT does.
    -- Everything measured via muzzle_fwd/wrist_fwd above is the mesh's own
    -- orientation, which is NOT what drives the dot -- that's `tip`
    -- (LaserSightTipPosition), confirmed back in the original 17-mechanism
    -- investigation to NOT simply track any joint transform. muzzle_pos is
    -- restored to the log line so tip can be turned into a direction
    -- (tip - muzzle_pos) and compared against cam_fwd the same way, which
    -- is the actually-relevant test for the VR-specific symptom.
    local tip_dir = (tip and muzzle_pos) and vec3_sub(tip, muzzle_pos) or nil
    local dev_deg_tip_vs_cam = (tip_dir and cam_fwd) and angle_between_deg(tip_dir, cam_fwd) or nil

    log.info(string.format(
        "[laser_dot_probe] frame=%d stage=%-24s spine_on=%-5s spine_timing=%-7s src=%-28s tip=%s  muzzle_pos=%s  muzzle_fwd=%s  cam_fwd=%s  wrist_fwd=%s  dev_deg=%s  dev_deg_vs_cam=%s  dev_deg_wrist_vs_cam=%s  dev_deg_tip_vs_cam=%s",
        state.frame, stage, tostring(spine_on == true), tostring(spine_timing or "?"), tostring(muzzle_src),
        fmt_vec(tip),
        fmt_vec(muzzle_pos),
        fmt_vec(muzzle_fwd),
        fmt_vec(cam_fwd),
        fmt_vec(wrist_fwd),
        dev_deg and string.format("%.2f", dev_deg) or "nil",
        dev_deg_cam and string.format("%.2f", dev_deg_cam) or "nil",
        dev_deg_wrist_vs_cam and string.format("%.2f", dev_deg_wrist_vs_cam) or "nil",
        dev_deg_tip_vs_cam and string.format("%.2f", dev_deg_tip_vs_cam) or "nil"))
end

local function check_auto_capture()
    if not state.auto_capture_on_aim then
        state.was_aiming = false
        return
    end
    local aiming = player_is_aiming()
    if aiming and not state.was_aiming then
        state.burst_remaining = AUTO_CAPTURE_FRAMES
    end
    state.was_aiming = aiming
end

-- Decided ONCE per frame (at PRE LateUpdateBehavior, which also increments
-- state.frame) so a burst of N means N full frames with every stage logged,
-- not N individual log calls split across ~5 call sites per frame.
local function begin_frame_log_decision()
    if state.manual_capture_until and os.clock() < state.manual_capture_until then
        state.log_this_frame = true
        return
    end
    if state.burst_remaining > 0 then
        state.burst_remaining = state.burst_remaining - 1
        state.log_this_frame = true
        return
    end
    state.log_this_frame = false
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    state.frame = state.frame + 1
    check_auto_capture()
    try_install_setter_hook()
    try_install_stamp_hook()
    begin_frame_log_decision()
    log_stage("PRE LateUpdateBehavior")
end)

re.on_application_entry("LateUpdateBehavior", function()
    log_stage("POST LateUpdateBehavior")
end)

re.on_pre_application_entry("UpdateJointExpression", function()
    log_stage("PRE UpdateJointExpression")
end)

re.on_application_entry("UpdateJointExpression", function()
    log_stage("POST UpdateJointExpression")
end)

re.on_pre_application_entry("PrepareRendering", function()
    log_stage("PRE PrepareRendering")
end)

re.on_draw_ui(function()
    if not imgui then return end
    if not imgui.tree_node("Laser Dot Probe (diagnostic)") then return end

    imgui.text("Read-only except one hook (logs only, never blocks/changes the call).")
    imgui.text("Logs to re2_framework_log.txt -- grep for [laser_dot_probe]")
    imgui.text("Currently aiming: " .. tostring(player_is_aiming()))
    imgui.text_colored(
        "This round: multi-stage same-frame capture (5 pipeline stages per frame) to find",
        0xFF88CCFF)
    imgui.text_colored(
        "WHEN tip snaps from garbage range to its offset-but-tracking regime, not just THAT it does.",
        0xFF88CCFF)
    imgui.text("Setter hook installed: " .. tostring(state.setter_hook_installed) ..
        (state.setter_method_name and (" (" .. state.setter_method_name .. ")") or " (not found yet -- equip/aim a weapon)") ..
        " -- confirmed dead, never fires (2026-08-15)")
    imgui.text("Stamp.set_Color hook installed: " .. tostring(state.stamp_hook_installed) ..
        " -- confirmed dead, never fires during aim burst (2026-08-15)")

    if imgui.button("Dump WeaponArm laser/sight fields+methods") then
        dump_weapon_arm()
    end
    imgui.same_line()
    if imgui.button("Check via.render.Stamp") then
        dump_stamp_type()
    end
    if imgui.button("Dump FULL weapon+player transform tree (all descendants)") then
        dump_full_hierarchy()
    end
    imgui.text_colored(
        "2026-08-15: original investigation only checked DIRECT children -- this walks the WHOLE tree, aim first.",
        0xFF88CCFF)

    imgui.spacing()
    local ac, av = imgui.checkbox("Auto-capture correlation log when aiming starts", state.auto_capture_on_aim)
    if ac then state.auto_capture_on_aim = av end
    if imgui.button("Log next 90 frames now (manual)") then
        state.burst_remaining = 90
    end
    imgui.text("Burst remaining: " .. tostring(state.burst_remaining))

    imgui.spacing()
    imgui.separator()
    if imgui.button("Start 10s continuous capture NOW") then
        state.manual_capture_until = os.clock() + 10.0
    end
    local remaining_s = state.manual_capture_until and math.max(0.0, state.manual_capture_until - os.clock()) or 0.0
    imgui.text(string.format("10s capture time remaining: %.1fs", remaining_s))
    imgui.text("Spine correction currently: " .. tostring(rawget(_G, "__vr_spine_correction_enabled") == true))
    imgui.text_colored(
        "Press the button, THEN aim/hold the weapon steady and turn your head freely for the full 10s --",
        0xFF88CCFF)
    imgui.text_colored(
        "toggle spine correction mid-window if you want both phases in one capture (spine_on= is logged per line).",
        0xFF88CCFF)
    imgui.text_colored(
        "Confirmed 2026-08-15: reproduces flat-screen too (not VR-only) -- no headset needed to test.",
        0xFF88CCFF)
    imgui.text_colored(
        "First capture: dev_deg (tip vs muzzle joint) maxed at 0.31 deg -- tip is NOT broken relative to the muzzle.",
        0xFF88CCFF)
    imgui.text_colored(
        "New: dev_deg_vs_cam (muzzle joint vs camera look direction) -- tests if the WEAPON MESH itself is misaimed.",
        0xFF88CCFF)
    imgui.text_colored(
        "Best test: equip a sight/laser weapon, enable auto-capture, aim (with spine correction ON, Pre timing) -- then check the log.",
        0xFF88CCFF)

    imgui.spacing()
    imgui.text(state.last_dump)

    imgui.tree_pop()
end)

log.info("[re2_vr_laser_dot_probe] Loaded")
