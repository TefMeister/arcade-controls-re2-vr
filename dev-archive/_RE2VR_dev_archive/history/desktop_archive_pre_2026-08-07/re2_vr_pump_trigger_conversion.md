# RE2 VR Pump-Action Reload: Trigger-Driven Conversion

**Author of this change:** TefMeister, with help from Claude (Anthropic)
**Date:** July 26, 2026
**Target:** `re2_vr_reload.lua` + `re2_vr_reload_ext_1.lua` + `re2_vr_reload_ext_4.lua`
**Status:** Written and self-reviewed for logical/syntax consistency. **Not yet tested in-game** — no Lua interpreter or REFramework runtime was available to compile/run this outside the game itself.

---

## The problem

The pump-action shells mod works great for shell insertion, but the actual pump-slide motion — physically pulling the off-hand controller back and pushing it forward — is unreliable in play. In the middle of a zombie encounter this means a missed detection on the pump stroke, no chambered round, and a very bad time.

## Root cause

The existing gesture (in `re2_vr_reload_ext_4.lua`, `update_manual_pump_gesture()`) tracks continuous hand-position distance via `slide_gesture.gesture_update_pull()` (defined in `ext_2`), comparing the tracked pull distance against a configured `pull_dist`/`push_dist` threshold per weapon. This is inherently sensitive to:
- controller tracking jitter/prediction error
- players not pulling far enough or fast enough to cross the threshold
- axis-lock logic (`pull_dir_locked`) picking the wrong initial direction on a noisy first sample

None of that is a bug exactly — it's just what physical VR gesture tracking is like. It's just not reliable enough for a life-or-death shotgun cycle.

## The fix

Keep everything about **shell insertion** and **hand placement** exactly as-is. Replace only the **pump-slide gesture** itself with a discrete input:

1. Hold **right grip** → weapon readies to receive shells (unchanged)
2. Insert shells manually (unchanged — the existing shell-dock/insert logic is untouched)
3. Move left hand near the forend, hold **left grip** → hand docks to the pump handle (unchanged — existing dock/support-pose IK is untouched)
4. Press and hold **left trigger** → pump handle moves to the pulled-back position
5. Release **left trigger** → pump handle returns forward, cycle completes, weapon can fire

This turns the least reliable part of the interaction (continuous hand-tracked distance) into the most reliable part (a discrete controller button state), while keeping every other piece of hand-tracking-based immersion (dock poses, support IK, shell insertion) exactly as the original author built it.

## What changed, file by file

### 1. `re2_vr_reload_ext_1.lua` — new left-trigger reader

Added `is_left_trigger_pressed()`, which is a direct mirror of the existing `is_left_grip_pressed()` — same VR action-cache pattern (`vrmod:get_action_trigger()` + `vrmod:is_action_active(action, left_joystick)`), just for the trigger instead of the grip. Exported it from the module table the same way the grip getter is exported.

```diff
+-- Left trigger, digital hold state, mirrors read_left_grip_action_active.
+-- Used by the pump gesture to drive the "pull down while held / release to
+-- finish" pump-action reload, replacing the tracked-hand-distance gesture.
+local function read_left_trigger_action_active(lj)
+    if not vrmod or not lj then return false end
+    if not mag_hand.trigger_action_cache then
+        pcall(function() mag_hand.trigger_action_cache = vrmod:get_action_trigger() end)
+    end
+    if not mag_hand.trigger_action_cache then return false end
+    local ok, v = pcall(function()
+        return vrmod:is_action_active(mag_hand.trigger_action_cache, lj)
+    end)
+    return ok and v == true
+end
+
+local function is_left_trigger_pressed()
+    if not vrmod then return false, nil end
+    local lj = get_left_joystick()
+    if not lj then return false, lj end
+    return read_left_trigger_action_active(lj), lj
+end
+
 local function is_left_grip_pressed()
     ...

@@ module exports
     M.is_left_grip_pressed = function() return is_left_grip_pressed() end
+    M.is_left_trigger_pressed = function() return is_left_trigger_pressed() end
```

### 2. `re2_vr_reload.lua` — dependency wiring

The pump module (`ext_4`) receives its inputs through a `deps` table built here. Added one line so it also receives the new trigger getter, right next to the existing grip getter:

```diff
         is_left_grip_pressed = function()
             return reload_mag and reload_mag.is_left_grip_pressed and reload_mag.is_left_grip_pressed()
         end,
+        is_left_trigger_pressed = function()
+            return reload_mag and reload_mag.is_left_trigger_pressed and reload_mag.is_left_trigger_pressed()
+        end,
         get_left_track_position = function()
```

### 3. `re2_vr_reload_ext_4.lua` — the actual gesture rewrite

This is the core change, inside `update_manual_pump_gesture()`. The old version called `slide_gesture.gesture_begin()` / `gesture_update_pull()` (in `ext_2`) every frame to compute a signed hand-distance value, compared it to `pull_dist`/`push_dist` thresholds, and used that to both animate the pump joint and decide when the cycle completed.

The new version:
- Still requires **left grip** to be held to be "actively gesturing" (unchanged condition)
- On **left trigger press edge**: marks `pull_done = true`, plays the same pull sound/haptic the original played on reaching full pull
- While **trigger is held**: sets `gesture.pull_now` to the weapon's configured pull distance (not a raw 1.0/0.0 flag — `pull_now` is read elsewhere as a real distance in meters, e.g. by a hand-follow-offset helper, so this keeps that math correct even though that helper turned out to be unused/dead code in the current build)
- On **left trigger release edge** (after a pull was registered): calls the *original* `complete_pump_cycle(wp)` function — same chamber/SFX/haptic/state-reset the native gesture used on success
- If **grip is released before the trigger is**: aborts back to the parked position, matching the original's abort-on-early-release behavior

Deliberately **not touched**: the joint bind-pose blending math in `ext_2` (`gesture_apply_bind`), the shell-insert/dock logic, the left-hand support/IK docking logic. All of that is reused as-is — `gesture.pull_now`/`pull_done` are the same fields that logic already reads, so it keeps animating the pump joint correctly without needing its own changes.

```diff
     local grip = is_left_grip_pressed and is_left_grip_pressed() or false
     if gesture.pump_await_grip_release and not grip then
         gesture.pump_await_grip_release = false
     end
-    local ctx = pump_gesture_ctx()
     local pull_d, push_d = get_pump_effective_limits(wp)
-    local dz = get_pull_deadzone()
-    local get_push_delta = slide_gesture.gesture_get_push_delta

+    -- Trigger-driven pump cycle (replaces the tracked-hand pull/push gesture):
+    --   left grip  = hold the pump handle (existing dock/support-pose logic, unchanged)
+    --   left trigger held   = pump pulled down
+    --   left trigger release = pump returns and the cycle completes
     if gesture.needs_pump and grip then
         if not gesture.active then
             if not gesture.pump_await_grip_release then
                 gesture.active = true
-                slide_gesture.gesture_begin(gesture, wp, ctx)
-                if gesture.pull_axis_set and gesture.pull_ax then
-                    rawset(_G, "__vr_pump_pull_axis_x", gesture.pull_ax)
-                    rawset(_G, "__vr_pump_pull_axis_y", gesture.pull_ay)
-                    rawset(_G, "__vr_pump_pull_axis_z", gesture.pull_az)
-                end
+                gesture.pull_done = false
+                gesture.pull_now = 0.0
+                gesture.trigger_prev = false
             end
         end

         if gesture.active then
-            local signed, track_src = slide_gesture.gesture_update_pull(gesture, wp, ctx)
-            -- ... ~50 lines of tracked-distance threshold logic removed ...
+            local trig = is_left_trigger_pressed and is_left_trigger_pressed() or false
+            local trig_pressed_edge = trig and not gesture.trigger_prev
+            local trig_released_edge = (not trig) and gesture.trigger_prev
+            gesture.trigger_prev = trig
+            gesture.pull_now = trig and pull_d or 0.0
+
+            if trig_pressed_edge and not gesture.pull_done then
+                gesture.pull_done = true
+                if play_reload_sfx then play_reload_sfx("slide_rack_pull") end
+                if get_haptic_left_joystick and haptic_pulse then
+                    local lj = get_haptic_left_joystick()
+                    if lj then haptic_pulse(lj, 0.06, 220.0, 0.7) end
+                end
+            end
+
+            if gesture.pull_done and trig_released_edge then
+                complete_pump_cycle(wp)
+                publish_gesture_globals(wp)
+                gesture.last_grip = grip
+                return
+            end
         end
         apply_pump_bind(wp)
     elseif gesture.active and not grip then
-            -- old push-delta-based abort/complete logic
+        gesture.active = false
+        gesture.trigger_prev = false
+        clear_gesture_pull_state()
+        local bp = get_pump_bind_pose(wp)
+        if bp then set_pump_joint_local_z(bp.parked_z, bp) end
         apply_pump_bind(wp)
     elseif gesture.needs_pump then
         apply_pump_bind(wp)
     end
```

Plus two small supporting additions in the same file: a `local is_left_trigger_pressed` declaration and its wiring in `Pump.init_module(deps)`, and a `trigger_prev = false` field added to the `gesture` state table.

## Design notes / things to sanity-check in playtesting

- **`pull_d`/`push_d` per-weapon config still applies** for anything that reads `get_pump_effective_limits()`, but the trigger itself is a binary hold, not analog pressure — there's no "partial pull" state. This was a deliberate simplification since the original ask was reliability over gesture fidelity.
- **No animation easing was added.** Because the trigger is digital, `pull_now` jumps straight from `0.0` to `pull_d` on press. The existing bind-pose blend code (`ext_2`, `gesture_apply_bind`) saturates that instantly to the fully-pulled position — so the pump joint will likely **snap** to pulled/rest rather than glide. If that reads as too abrupt in-game, the next iteration would add a short time-based blend (e.g. ~0.08–0.12s ease) between `parked_z`/`back_z`/`rest_z` driven off `os.clock()`, rather than snapping `pull_now` instantly.
- **Haptics/SFX on pull** fire on the trigger-press edge, matching original timing (on reaching full pull). Haptics/SFX/chamber-completion on release reuse the *exact* original `complete_pump_cycle()` function, so anything else hooked to that (fire-blocking, ammo bookkeeping, etc.) is unaffected.
- Left-hand IK/support-pose gating (`pump_pull_arm_ik_wanted()`) reads `gesture.pull_now` the same way it always did, so the hand should still switch from the generic first-person auto-grip pose to the tracked slide-dock pose the moment the trigger is first pressed — same as intended in the design (step 4 → step 5 transition).

## Scope

This change only affects the **pump cycle**, gated by each weapon's existing `needs_manual_pump` flag in `CFG.weapons`. Shell insertion, magazine reloads, and non-pump weapons are untouched. Per the original request, this should be tested on one shotgun first before rolling out further.
