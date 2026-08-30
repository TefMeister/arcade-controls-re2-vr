# RE2 VR Mod — Session Summary (2026-08-09)

Four threads worked today, plus a fifth written up as a starting point for next time (research
only, no code yet). All files referenced are included in this zip under `reframework/autorun/`,
and are also already live in the actual game install (this zip is a snapshot/handoff copy, not a
new install step).

---

## 1. Cutscene gating for the spine-twist fix — DONE (RE2 only)

**Goal:** the existing torso-twist correction (`re2_vr_posture_spine_straighten_override.lua`,
counter-rotates `spine_0` every frame to fix Claire/Ada's VR torso twist) should turn itself off
during cutscenes, since a gameplay comfort fix has no business fighting a director-posed cinematic.

**Found:** `re2_vr_holster.lua` already had a fully-built `is_cinematic_blocking()` (~line 1176),
checking four native signals (`TimelineEventManager.InCameraEvent`, `PlayerCondition.IsEvent`,
`CameraSystem.BusyCameraType`, `CutSceneManager.TimelineOwnerObject`), published globally as
`__vr_is_cinematic_blocking` — built for a different feature, never consumed until today.

**Change:** wired the spine-straighten script to check that global before applying the correction.
**CONFIRMED WORKING LIVE** — user tested, correction turned off during a real cutscene.

**Then made toggleable + currently DISABLED by default:** user wanted to record gameplay without
the gate interfering. Added a `cutscene_gate_enabled` field (checkbox in the panel) — **currently
defaults to `false` in the script**. The underlying detection is still confirmed working; only the
on/off switch was changed. **Flip it back on (checkbox, or the `cutscene_gate_enabled = false` line
near the top of the file) whenever recording is done**, otherwise cutscenes will show the twisted
posture again.

Not done: same gate for RE3's `re3_vr_torso_straighten.lua` — different class namespaces
(`offline.gui.GUIMaster` vs `app.ropeway.gui.GUIMaster`), needs fresh verification, not a copy-paste.
Not done: legs / general posture-during-cutscenes — original stretch goal, not started.

---

## 2. Gun/laser "points left" after spine correction — BLOCKED ON VR ACCESS

**Goal:** when the spine correction straightens the torso, the visible gun/laser sight ends up
pointing left of the actual VR aim direction. This is a known unresolved side effect from the
original spine-fix work days ago (a PRE vs POST hook-timing experiment on `LateUpdateBehavior`
didn't fix it).

**Why that earlier fix never had a chance:** the mod has a full custom arm-IK system
(`re2_vr_ik_extention.lua`) that hooks the *native* `IkArmFit.updateIk` method directly, plus does
work at `UpdateJointExpression`/`PrepareRendering`/`BeginRendering` — not just `LateUpdateBehavior`.
Flipping pre/post *within* `LateUpdateBehavior` was probably never touching the actual variable.

**Built `re2_vr_aim_alignment_probe.lua`** (read-only, no writes) — logs `spine_0`'s rotation and
both wrists' world positions at every relevant pipeline stage, including its own hook on
`IkArmFit.updateIk`. Originally had a manual "log next 60 frames" button, but clicking it while
aiming in VR drops aim state (confirmed: "it zooms out for a second") — **fixed with auto-capture**:
the probe now arms a burst automatically the instant it detects aiming start
(`SurvivorCondition.IsHold` rising edge), no button press needed.

**Flat-screen test results (spine correction ON):**
- `spine0_y` confirmed correcting properly (-0.33 → 0.00 in one step, holds through later stages).
- The wrist moves substantially in that same step — confirmed as simple rigid parent-child
  kinematics (arm is a child of spine, straightening the parent drags the child). Not a bug itself.
- **`IkArmFit.updateIk` never fired once, the entire flat-screen session** — confirmed via the full
  log, hook installs fine every relaunch but the native method itself is never called outside VR.

**Root cause understood, but genuinely blocked:** `re2_vr_ik_extention.lua`'s hand-position
compensation (the thing that's supposed to pull the hand back to the real tracked controller
position after the spine-correction drag) only runs when `vrmod:is_hmd_active()` AND
`is_using_controllers()` are both true. Flat-screen has zero equivalent, so this can only be
observed and fixed with an actual headset connected.

**How to resume at home:** relaunch/reset scripts (probe already has auto-capture, nothing to
change), turn spine correction ON, aim normally in VR — no need to touch the probe's panel at all.
Then check `re2_framework_log.txt` for `[aim_align_probe]` lines with `stage=PRE/POST
IkArmFit.updateIk`. If `r_wrist` snaps back toward the real controller position across that call,
the compensator runs but something else is wrong. If it's unchanged across the call, the
compensator isn't correcting for this drag and needs a direct fix there.

---

## 3. VR-friendly run toggle — BLOCKED ON VR ACCESS + a manual settings change

**Goal:** running should stop the instant the left stick returns to neutral, or when the toggle
button (LThumb / Shift on keyboard) is pressed again — currently it doesn't, and moving again after
a stop silently resumes running with no re-press needed.

**Long investigation, most of it now understood to have been unnecessary in hindsight** (see
"what didn't work" below) **— the actual root cause is a native RE2 control-scheme bug, not
something in the mod:**

- RE2 has a native Options → Controls → **"Run Type"** setting (Toggle / Hold / Always).
- User's current setting, **Toggle, is confirmed to be a one-way latch, not a real toggle** —
  pressing the toggle key again *while still moving* does nothing at all (user-tested live: "running
  kept going with shift pressed again"). It only clears on a full stop.
- **Native "Hold" mode is correct** — running stops the instant the key is released (user-confirmed).
  Awkward to hold continuously in VR, but mechanically sound.
- Also ruled out: running does NOT auto-start from sustained movement alone (held W for ~18s with no
  Shift press, confirmed via log: zero Jog transitions the entire time — the toggle/hold key is
  required, it's not duration-based).

**The fix, built as `re2_vr_run_toggle_fix.lua`:** keep RE2's native Run Type on **Hold**, and let
the mod supply toggle-feeling UX on top. Rather than simulating a held key, this uses a real,
already-proven-safe game API: `SurvivorDefine.ActionOrder.Petient` has a named `JOG` order, and
`PlayerActionOrderer:call("setInhibitPetient", bool, order)` blocks that order from firing at all.
This exact API is already used safely elsewhere in this mod (`re2_vr_reload.lua` inhibits/clears
`PATIENT_ORDER_JOG` around manual reload sequences) — a real "block this action category" API, not
a raw property write.

The script tracks its own `run_armed` boolean (LThumb press toggles it), auto-disarms the instant
left-stick magnitude drops to ~0, and inhibits the native `JOG` order whenever disarmed. **Ships
disabled by default** (checkbox in its panel) — same "ship disabled, verify live" pattern that
worked cleanly for the RE3 torso-twist port.

**What didn't work (kept for context, not because it's still relevant — see above, the real
problem was the native setting, not any of this):**
- Guessed field names (`IsRun`/`IsDash`/`IsSprint`) — none exist.
- Found the real locomotion gait state machine (`IsIdle`/`IsWalk`/`IsJogStart`/`IsJog`/`IsJogEnd`/
  `IsTurn`/`IsWheel`/`IsStep` on `SurvivorCondition`) via a full parent-walking reflection dump —
  confirmed `IsJog` re-triggers itself ~234ms after a stop+resume with no button press, matching the
  reported bug exactly, but it's just an FSM output, not the toggle.
- A manual test of `cond:call("set_IsJog", false)` appeared to freeze the character — but this is
  now believed to be a **false positive**: `set_IsJog` doesn't resolve via reflection at all (0/7
  setter hooks installed later), so the call was very likely a silent no-op, and the freeze was
  probably the overlay-button click stealing keyboard focus, not the write itself. Correction is
  recorded in memory; don't treat "direct IsJog writes are unsafe" as an established fact.
- `PlOperationType`/`PlStateType` on `PlayerCondition` — exist, but stayed constant `0.0` the whole
  session, unrelated.

**Two things required before this can be tested at all:**
1. **Manually change RE2's native Options → Controls → Run Type from Toggle to Hold.** The script
   assumes Hold underneath — left on native Toggle, the two will fight each other.
2. **Needs actual VR** — toggle-press detection uses `vrmod:get_action_joystick_click()` (LThumb),
   confirmed not to see keyboard Shift presses at all.

**How to resume at home:** (1) change Run Type to Hold in-game, (2) reset scripts, (3) enable the
checkbox in `re2_vr_run_toggle_fix`'s panel, (4) test: LThumb should start/keep running while
moving, releasing the stick or pressing LThumb again should immediately stop it. Watch the panel's
live status line (`armed=`/`stick_mag=`/`jog_inhibited=`) to confirm the inhibit is actually being
applied when expected.

---

## 4. Movement shaking + camera-decouple idea — BLOCKED ON VR ACCESS

**Goal:** with spine correction on, movement causes camera/body shaking (separate from the
gun-points-left issue). User also asked whether the VR camera could be decoupled from following
Leon's head bone entirely — anchored "above his shoulders" instead — to sidestep jitter generally.

**Shake fix applied to `re2_vr_posture_spine_straighten_override.lua` (code done, NOT yet
live-tested — needs VR):** `apply_override` recomputed straight from the raw `spine_0` value every
frame and wrote it instantly, zero damping. Likely cause: the native game applies its own secondary
motion/sway to the spine during walking, and the override faithfully reproduced that per-frame
noise instead of smoothing it. Added exponential smoothing on the WRITTEN value (real-elapsed-time
based, same pattern already used elsewhere in this mod — `re2_vr_ik_extention.lua`'s
`smooth_exp_alpha`, `re2_smooth_movement.lua`'s `EMA`). New panel controls: "Smooth output"
checkbox (default ON) and a "Smoothing time constant" slider (default 0.08s — raise for more
damping/lag, lower for snappier/more shake-prone). `last_written` is only cleared on genuine stop
conditions (disabled, cutscene skip), not on the normal pre/post timing-mismatch branch that fires
every frame by design (a real bug was caught and fixed during implementation: an early version
cleared it on every mismatch, which would have made the smoothing a complete no-op).

**Camera decoupling: investigated, unresolved, needs VR to continue.** The VR camera-to-head
attachment is handled by `firstpersonmod`, a native REFramework plugin (not this project's own
Lua) — already used elsewhere in this mod (`will_be_used()`, `set_block_left_hand_ik()`,
`get_weapon_support_grip_world_pos()`, etc.) but no camera-anchor-override method has ever been
used in this codebase, so it's unknown whether one exists at all. Built
`re2_vr_firstpersonmod_probe.lua` — one-shot, read-only, dumps `type(firstpersonmod)`, every key
via `pairs()` if it's a table/userdata, and separately tries reflecting it as a managed object
(full method dump) in case `pairs()` misses something. Not yet run.

**How to resume at home:** relaunch/reset scripts, then just play in VR (both are passive — the
probe fires automatically on load, the shake fix just needs you to walk around with correction on).
Check `re2_framework_log.txt` for `[fpmod_probe]` lines: if it reveals a camera-offset/anchor-joint
method, that's the real lever for the "above his shoulders" idea; if `firstpersonmod` turns out to
be a closed proxy with nothing like that exposed, decoupling the camera may not be achievable via
Lua at all, and the smoothing fix above becomes the only practical lever for shake, not a full
workaround. Tune the smoothing time-constant slider live if the shake is reduced but not gone.

---

## 5. Full physics grab for world pickup items — NOT STARTED, written up as next session's starting point

**Goal:** healing items/ammo/quest items should be genuinely grabbable in VR — reach a hand toward
the item, grip attaches it physically to the hand (follows hand, can be moved/thrown, Half-Life:
Alyx style), with some separate action collecting it into inventory afterward. Explicitly chosen
over a simpler alternative (reach + grip = instant pickup, same outcome as walking over it today,
just a different trigger) — the user wants the full physical version.

**Distinct from, but related to, the item-pickup-screen investigation from an earlier session**
(documented at length further down this doc's source memory — not included in this zip's files
since nothing there is being actively worked, but relevant context): that older, paused
investigation is about what happens AFTER pickup fires (the examine + inventory-grid screen — 3
failed live attempts historically, one caused a full game hang). This new thread is about HOW
pickup gets triggered in the first place. They'll likely intersect eventually, but should be
treated as separate problems for now.

**Investigated tonight (research only, no code written):**
- Checked `re2_vr_grenade.lua` as the most likely existing "hold + throw" physics precedent —
  solves a different problem (throws an already-*equipped* grenade weapon: spawns a shell prop at
  the wrist with velocity derived from real VR controller motion via `via.dynamics.RigidBodySet:
  setLinearVelocity/setAngularVelocity`). Doesn't hold/carry an object that follows the hand before
  release. Still useful: confirms the throw-velocity technique (reusable for whenever a grabbed
  item gets released) and confirms `RigidBodySet` is the physics-body component to look for.
- Grepped the whole mod for `ItemPopObj`/`GimmickItemBox`/`ItemGimmick`/`PickUpItem`/`DropItem`/
  `ItemPop` — zero hits. **Nothing in this mod has ever investigated how a world pickup item is
  actually represented.** Genuinely fresh territory.

**One solid lead to start from (not a guess):** the item-pickup-screen investigation already
confirmed and hooked the exact native method that fires the instant ANY pickup happens:
`GUIMaster.openInventoryGetItemMode`. Hooking that again (read-only, same safe pattern used all
session) and inspecting its call context is the natural first step — won't directly reveal the
item's GameObject/component structure, but tracing backward from a known, proven trigger beats
guessing at class names blind.

**How to start next session:** hook `GUIMaster.openInventoryGetItemMode` again (read-only, log
context/args) during a normal pickup to identify the real item GameObject/component class. Then
check whether it has a `RigidBodySet` (real physics-driven grab, reusing the grenade-throw velocity
technique) or whether world pickups are physics-less static props (in which case grabbing would
need to be visually faked — parent the item's transform to the hand joint each frame — rather than
true rigid-body physics). Only after that foundation is understood should hand-proximity detection
and grip-gesture attachment be designed. No files created for this thread yet.

---

## EMV-Engine (alphazolam) — evaluated, deliberately not used

Asked about early in the session as a possible tool for posture work. Verdict: it's a freeze-and-
hold Poser tool built for static screenshot posing — same class of "overwrite a joint the engine
also owns" trick the custom spine script already does, just without the hook-timing care already
invested here. Not used for any of today's work; only relevant as a bone-browsing aid if ever
needed.

---

## Files in this zip (`reframework/autorun/`)

| File | Status | Purpose |
|---|---|---|
| `re2_vr_posture_spine_straighten_override.lua` | MODIFIED | The live torso-twist fix — cutscene gate + output smoothing added, cutscene gate currently disabled by default (see thread 1), smoothing not yet live-tested (thread 4) |
| `re2_vr_aim_alignment_probe.lua` | NEW | Read-only diagnostic for the gun-points-left issue, auto-captures on aim start |
| `re2_vr_run_state_probe.lua` | NEW | Read-only diagnostic that found the real `IsJog` locomotion state machine (superseded by the settings-menu discovery, kept for reference) |
| `re2_vr_run_toggle_fix.lua` | NEW | The actual run-toggle fix, disabled by default, needs Run Type = Hold + VR to test |
| `re2_vr_firstpersonmod_probe.lua` | NEW | One-shot read-only dump of `firstpersonmod`'s API, for the camera-decouple idea |

## Open items, next session

1. Cutscene gate: remember to re-enable (`cutscene_gate_enabled`) after any recording is done.
2. Aim alignment: test in VR, check `[aim_align_probe]` log for `IkArmFit.updateIk` lines.
3. Run toggle: change native Run Type to Hold, then test in VR with `re2_vr_run_toggle_fix` enabled.
4. Shake fix: test in VR with spine correction on, tune the smoothing time-constant slider if needed.
5. Camera decouple: check `[fpmod_probe]` log output for a usable camera-anchor API, if any.
6. RE3: cutscene gate not yet ported (namespace differences); legs investigation not started.
7. Physics grab (thread 5): NOT STARTED — begin by hooking `GUIMaster.openInventoryGetItemMode`
   again to identify the real world-item GameObject/component class before designing anything.
