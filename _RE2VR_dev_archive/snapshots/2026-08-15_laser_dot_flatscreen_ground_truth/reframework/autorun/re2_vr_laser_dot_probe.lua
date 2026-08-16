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
local function get_muzzle_ground_truth()
    if not re2.weapon then return nil, nil end
    local param = safe(function() return re2.weapon:get_field("<FireBulletParam>k__BackingField") end)
    if not param then return nil, nil end
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
        return pos, fwd
    end

    -- Camera-type fallback (matches re2_vr_crosshair.lua's own fallback).
    local cam = safe(function() return sdk.get_primary_camera() end)
    local mat = cam and safe(function() return cam:get_WorldMatrix() end)
    if not mat then return nil, nil end
    local pos = mat[3]
    local fwd = safe(function() return (mat:to_quat() * Vector3f.new(0, 0, -1)):normalized() end)
    return pos, fwd
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
    local muzzle_pos, muzzle_fwd = get_muzzle_ground_truth()
    local dev_deg = nil
    if tip and muzzle_pos and muzzle_fwd then
        dev_deg = angle_between_deg(vec3_sub(tip, muzzle_pos), muzzle_fwd)
    end
    log.info(string.format(
        "[laser_dot_probe] frame=%d stage=%-24s tip=%s  muzzle_pos=%s  muzzle_fwd=%s  dev_deg=%s",
        state.frame, stage,
        fmt_vec(tip),
        fmt_vec(muzzle_pos),
        fmt_vec(muzzle_fwd),
        dev_deg and string.format("%.2f", dev_deg) or "nil"))
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

    imgui.spacing()
    local ac, av = imgui.checkbox("Auto-capture correlation log when aiming starts", state.auto_capture_on_aim)
    if ac then state.auto_capture_on_aim = av end
    if imgui.button("Log next 90 frames now (manual)") then
        state.burst_remaining = 90
    end
    imgui.text("Burst remaining: " .. tostring(state.burst_remaining))
    imgui.text_colored(
        "Confirmed 2026-08-15: reproduces flat-screen too (not VR-only) -- no headset needed to test.",
        0xFF88CCFF)
    imgui.text_colored(
        "Best test: equip a sight/laser weapon, enable auto-capture, aim (with spine correction ON, Pre timing) -- then check the log for dev_deg=.",
        0xFF88CCFF)

    imgui.spacing()
    imgui.text(state.last_dump)

    imgui.tree_pop()
end)

log.info("[re2_vr_laser_dot_probe] Loaded")
