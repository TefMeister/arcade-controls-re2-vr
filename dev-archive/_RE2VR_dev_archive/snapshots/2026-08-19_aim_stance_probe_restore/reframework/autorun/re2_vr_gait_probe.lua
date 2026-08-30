-- Diagnostic for the "unarmed walk animation always" feature request
-- (2026-08-16): the player wants the no-weapon locomotion (leg/gait)
-- animations to keep playing even while a weapon is equipped, instead of the
-- weapon-specific combat gait.
--
-- Known dead ends that must NOT be retried for this (from
-- re2_vr_torso_twist_status.md's original investigation): raw .motlist file
-- swap (skeleton-specific binary, and a file-level hammer anyway) and
-- Equipment.ForceEquipType spoofing (visibly swaps the weapon model too).
-- This goes at a different layer: the LIVE motion system. Precedent already
-- proven in this codebase (re2_vr_reload_ext_4.lua's scrub_motion_layer):
-- via.motion.Motion getLayer(i) -> get_HighestWeightMotionNode ->
-- get_MotionName/get_Weight/get_Frame all work on the player, and
-- set_Weight/set_Frame writes take effect. So motion nodes are readable AND
-- writable by name from Lua.
--
-- Step 1 (this probe): capture which motion names/layers play while walking
-- UNARMED vs walking ARMED -- the diff identifies the gait selector's
-- output: which layer carries locomotion, what the unarmed gait's motion
-- name/bank is, and what the armed one is. Read-only.
--
-- Step 2 (only after the diff is read): decide the forcing mechanism --
-- either drive the locomotion layer's motion directly, or (cleaner, if the
-- data points there) find the game-side hold-state value the motion FSM
-- reads and spoof only the animation system's view of it.
--
-- Capture is time-based (os.clock), 6s window, logs once per frame from
-- the same LateUpdateBehavior pre-hook the other probes use.

if reframework:get_game_name() ~= "re2" then
    return
end

local re2 = require("utility/RE2")

local motion_type = sdk.typeof("via.motion.Motion")

local state = {
    capture_until = nil,
    label = "",
    last_line_count = 0,
    last_frame_logged = "",
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

local function describe_node(node)
    if not node then return "nil-node" end
    local name = safe(function() return node:call("get_MotionName") end)
    local weight = safe(function() return node:call("get_Weight") end)
    local frame = safe(function() return node:call("get_Frame") end)
    local endf = safe(function() return node:call("get_EndFrame") end)
    local bank = safe(function() return node:call("get_MotionBankID") end)
    local mid = safe(function() return node:call("get_MotionID") end)
    return string.format("name=%s w=%.2f frame=%.1f/%.1f bank=%s id=%s",
        tostring(name), tonumber(weight) or -1,
        tonumber(frame) or -1, tonumber(endf) or -1,
        tostring(bank), tostring(mid))
end

local function log_layers()
    local mc = get_player_motion()
    if not mc then return end

    local count = safe(function() return mc:call("getLayerCount") end)
    if not count then
        count = safe(function() return mc:call("get_LayerCount") end)
    end
    local max_layers = tonumber(count) or 8 -- fall back to fixed sweep if no count method

    local lines = {}
    for li = 0, max_layers - 1 do
        local layer = safe(function() return mc:call("getLayer", li) end)
        if layer then
            local lweight = safe(function() return layer:call("get_Weight") end)
            local node = safe(function() return layer:call("get_HighestWeightMotionNode") end)
            -- Only the dominant node per layer -- enough to identify the
            -- gait names; full node enumeration can come later if blending
            -- turns out to matter.
            table.insert(lines, string.format("  layer=%d lw=%s  %s",
                li, tostring(lweight), describe_node(node)))
        end
    end

    state.last_line_count = #lines
    state.last_frame_logged = os.date("%H:%M:%S")
    log.info(string.format("[gait_probe] ---- %s (%d layers w/ data) ----",
        state.label, #lines))
    for _, l in ipairs(lines) do
        log.info("[gait_probe] " .. l)
    end
end

-- Step 1's capture diff (2026-08-16, Claire/pl10) found: locomotion layer 0
-- plays the SAME motion id (160/190/192) from the SAME bank id (1000) armed
-- and unarmed -- only the resolved motion NAME differs (KFF_ unarmed vs OFF_
-- armed). So the game swaps the CONTENT of bank 1000 (the loaded motion
-- list) per hold state, while the weapon hold pose lives on a separate
-- layer/bank entirely (layer 2, bank 10000, pl10_50_Hold_HG01). Forcing
-- bank 1000 to keep the unarmed motlist = unarmed legs with the weapon
-- still properly held. This dump discovers the REAL dynamic-bank API on
-- this build (method names unverified -- everything pcall'd, plus a full
-- member dump of the first bank object) instead of assuming.
local function dump_motion_banks(label)
    local mc = get_player_motion()
    if not mc then
        log.info("[gait_probe] bank dump: no motion component")
        return
    end
    local lines = {}

    local tdef = safe(function() return mc:get_type_definition() end)
    local depth = 0
    while tdef and depth < 4 do
        local tname = safe(function() return tdef:get_full_name() end) or "?"
        local methods = safe(function() return tdef:get_methods() end) or {}
        for _, m in ipairs(methods) do
            local mn = safe(function() return m:get_name() end)
            if mn then
                local low = mn:lower()
                if low:find("bank") or low:find("motionlist") then
                    table.insert(lines, "  [api] " .. tname .. "." .. mn)
                end
            end
        end
        tdef = safe(function() return tdef:get_parent_type() end)
        depth = depth + 1
    end

    local count = safe(function() return mc:call("getDynamicMotionBankCount") end)
    if not count then
        count = safe(function() return mc:call("get_DynamicMotionBankCount") end)
    end
    table.insert(lines, "dynamic bank count = " .. tostring(count))
    local n = tonumber(count) or 0
    for i = 0, n - 1 do
        local bankobj = safe(function() return mc:call("getDynamicMotionBank", i) end)
        if bankobj then
            local btd = safe(function() return bankobj:get_type_definition() end)
            local btype = btd and safe(function() return btd:get_full_name() end)
            local bid = safe(function() return bankobj:call("get_BankID") end)
            local ml = safe(function() return bankobj:call("get_MotionList") end)
            local mlpath = nil
            if ml then
                mlpath = safe(function() return ml:call("get_ResourcePath") end)
                    or safe(function() return ml:call("ToString()") end)
            end
            table.insert(lines, string.format("  bank[%d] type=%s BankID=%s MotionList=%s",
                i, tostring(btype), tostring(bid), tostring(mlpath)))
            if i == 0 and btd then
                local bmethods = safe(function() return btd:get_methods() end) or {}
                for _, m in ipairs(bmethods) do
                    local mn = safe(function() return m:get_name() end)
                    if mn then table.insert(lines, "    [bank-method] " .. mn) end
                end
            end
        end
    end

    -- 2026-08-16 third pass: the active bank list (82 entries) is IDENTICAL
    -- armed vs unarmed -- all candidate motlists coexist and share BankIDs
    -- (multiple entries with BankID=1000: HDG_MOVE_*, STG_MOVE_*,
    -- CMN_MOVE*). So selection among same-ID entries is done by some
    -- per-bank state (type/enable/priority) and/or Motion's TargetBankType.
    -- This pass reads EVERY parameterless get_* on every bank object plus
    -- Motion.get_TargetBankType, both states -- whatever differs is the
    -- selector.
    local tbt = safe(function() return mc:call("get_TargetBankType") end)
    table.insert(lines, "Motion.get_TargetBankType = " .. tostring(tbt))

    local function bank_getter_sweep(bankobj, tag, i)
        if not bankobj then return end
        local btd = safe(function() return bankobj:get_type_definition() end)
        local parts = {}
        local td, d = btd, 0
        while td and d < 4 do
            local ms = safe(function() return td:get_methods() end) or {}
            for _, m in ipairs(ms) do
                local mn = safe(function() return m:get_name() end)
                local np = safe(function() return m:get_num_params() end)
                if mn and np == 0 and mn:sub(1, 4) == "get_" then
                    local ok_v, v = pcall(function() return bankobj:call(mn) end)
                    local vs
                    if not ok_v then
                        vs = "(err)"
                    elseif v == nil then
                        vs = "nil"
                    elseif type(v) == "userdata" then
                        local vtd = safe(function() return v:get_type_definition() end)
                        vs = safe(function() return v:call("get_ResourcePath") end)
                            or (vtd and safe(function() return vtd:get_full_name() end))
                            or "userdata"
                    else
                        vs = tostring(v)
                    end
                    table.insert(parts, mn:sub(5) .. "=" .. tostring(vs))
                end
            end
            td = safe(function() return td:get_parent_type() end)
            d = d + 1
        end
        table.insert(lines, string.format("  %s[%d] %s", tag, i, table.concat(parts, "  ")))
    end

    local acount = safe(function() return mc:call("getActiveMotionBankCount") end)
    table.insert(lines, "active bank count = " .. tostring(acount))
    for i = 0, (tonumber(acount) or 0) - 1 do
        local b = safe(function() return mc:call("getActiveMotionBank", i) end)
        bank_getter_sweep(b, "active", i)
    end

    log.info(string.format("[gait_probe] ==== MOTION BANK DUMP (%s) ====", label))
    for _, l in ipairs(lines) do
        log.info("[gait_probe] " .. l)
    end
end

re.on_pre_application_entry("LateUpdateBehavior", function()
    if state.capture_until and os.clock() < state.capture_until then
        log_layers()
    end
end)

re.on_draw_ui(function()
    if not imgui then return end
    if not imgui.tree_node("Gait Probe (diagnostic)") then return end

    imgui.text("Finds which motion names/layers carry locomotion, armed vs unarmed.")
    imgui.text("Run BOTH captures while walking continuously, then diff the log:")
    imgui.text("grep re2_framework_log.txt for [gait_probe]")

    imgui.spacing()
    if imgui.button("Capture 6s: walking UNARMED (holster everything first)") then
        state.capture_until = os.clock() + 6.0
        state.label = "UNARMED"
    end
    if imgui.button("Capture 6s: walking ARMED (weapon in hand)") then
        state.capture_until = os.clock() + 6.0
        state.label = "ARMED"
    end

    -- 2026-08-19: aim-STANCE captures (player ask: kill the full-body aim
    -- pose -- bent body, butt out, legs stretched forward/off the ground --
    -- while keeping the soft-mode posture + red-dot stability). Stand
    -- STILL for both; the only difference between the two captures should
    -- be RG held vs not. Whatever layer/bank/motion differs in the diff is
    -- what drives the stance.
    imgui.spacing()
    if imgui.button("Capture 6s: standing ARMED, NOT aiming (stand still)") then
        state.capture_until = os.clock() + 6.0
        state.label = "STAND_ARMED_NOAIM"
    end
    if imgui.button("Capture 6s: standing ARMED, AIMING (RG held, stand still)") then
        state.capture_until = os.clock() + 6.0
        state.label = "STAND_ARMED_AIM"
    end
    imgui.spacing()
    if imgui.button("Dump motion banks NOW (press once ARMED)") then
        dump_motion_banks("ARMED")
    end
    if imgui.button("Dump motion banks NOW (press once UNARMED)") then
        dump_motion_banks("UNARMED")
    end

    local remaining = state.capture_until and math.max(0.0, state.capture_until - os.clock()) or 0.0
    imgui.text(string.format("Capture time remaining: %.1fs (label: %s)", remaining, state.label))
    imgui.text(string.format("Last logged: %s (%d layers with data)",
        state.last_frame_logged, state.last_line_count))
    imgui.text_colored(
        "Keep walking the whole 6 seconds -- idle frames just log the idle gait instead.",
        0xFF88CCFF)

    imgui.tree_pop()
end)

log.info("[re2_vr_gait_probe] Loaded")
