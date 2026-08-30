# RE2 VR Mod Project — Status & History

Context for picking up this project. This is a REFramework VR mod for Resident
Evil 2 (RE2VRMODRELOADED by Andyalpa), running on OpenXR (not SteamVR). Player
is a non-programmer learning Lua through this project — explain reasoning, not
just answers, when something new comes up.

Working root: `reframework/` folder. Scripts live in `reframework/autorun/`,
with shared helpers under `autorun/utility/` and `autorun/vr/`.

---

## COMPLETED — Matilda slide-rack: trigger-driven pull/release

**Goal:** convert the Matilda handgun's final reload step (racking the slide
after inserting a new mag) from the existing hand-tracked pull-back gesture
to a trigger-driven one — hold LT to pull the slide back, release to let go
and finish — mirroring the already-working pump-action shotgun conversion.
Other slide-rack pistols (M19, JMB Hp3) keep the original hand-tracked
gesture untouched.

**Mechanically working, confirmed by the player:**
- `re2_vr_reload.lua`: `wp0000` (Matilda) has `trigger_slide_rack = true`;
  `is_left_trigger_pressed` threaded into `reload_slide.init({...})`.
- `re2_vr_reload_ext_2.lua`: new `weapon_uses_trigger_rack(wp_name)` gate,
  new `trig_rack_ease` table (mirrors `re2_vr_reload_ext_4.lua`'s
  `pump_ease`), new `update_slide_rack_trigger(wp)` function (mirrors
  `update_manual_pump_gesture()` almost line-for-line: grip still grabs the
  slide via the existing `try_start_rack_gesture`/proximity check, unchanged;
  once grabbed, grip must stay held throughout while left trigger drives
  pull — a tap commits to a full pull even if released early; release lets
  it ease back and call the existing `complete_rack_cycle()`; letting go of
  grip early aborts back to parked). `M.update_slide_rack()`'s hand-tracked
  branch is completely unchanged/untouched for non-trigger weapons.
- The actual grip+trigger+reload mechanic itself works — mag reloads,
  chambers correctly, completes correctly.

**Still broken: the visual hand-follow "teleports" instead of gliding.**
Player-confirmed specifics: grabbing the slide (the *existing*, untouched
hand-tracked reach/grip animation) is smooth. But the **pull** (holding LT)
and **release** (letting LT go) — both driven by the new
`update_slide_rack_trigger` — show the hand jumping directly between two
fixed positions with no visible in-between motion, despite the underlying
`rack.trig_travel` value being eased mathematically via the same
`smoothstep01` function the pump uses successfully.

**Three fix attempts tried, none resolved it yet (in order):**
1. Added a new `M.tick_trigger_rack()`, wired into the same
   *pre*-application-entry hooks (`UpdateMotion`, `LateUpdateBehavior`) the
   pump's `Pump.on_pre_arm_ik()` uses, instead of only the original
   post-entry `LateUpdateBehavior` hook — theory: higher update frequency,
   matching pump's proven timing. Did not fix it.
2. Added direct calls to `publish_hand_dock(wp)` +
   `update_rack_arm_delta(...)` *inside* `update_slide_rack_trigger` itself
   (previously this only ran from the separate, frame-deduped
   `M.tick_hand_follow()`) — theory: the hand-follow target wasn't being
   republished often enough to stay in sync with the new higher-frequency
   joint updates. Did not fix it.
3. Added a direct call to `rawget(_G, "__vr_apply_slide_dock_left_arm")`
   (the actual arm-IK-bending function, normally only invoked from
   `M.tick()`/`M.tick_hand_follow()`) *inside* `update_slide_rack_trigger`
   too — theory: the target position was updating smoothly but the actual
   IK arm application was still only running at the old, slower cadence.
   Did not fix it.

Confirmed technical fact along the way: `rack.anchor` (read by
`get_hand_dock_pose`/`publish_hand_dock` to compute the hand's world
position) **is** the same object `get_slide_joint()`/`set_slide_joint_local_z`
animate — so the hand position computation is mathematically downstream of
the smoothly-eased joint position. The teleport is NOT explained by the
joint-easing math itself being wrong; something else in the hand-follow/
arm-IK pipeline isn't picking up the intermediate values, or there's a
separate blend/smoothing layer we haven't found yet.

**Root cause found (2026-07-31), from the debug log data:** with debug
logging in place, the player did a full pull cycle. `rack.trig_travel`/
`eased` climbed smoothly and monotonically on every single call (0.04 →
0.14 → 0.28 → 0.45 → 0.62 → 0.78 → 0.91 → 0.99 → 1.0) — confirms the
easing math/frequency was never the bug. But `update_slide_rack_trigger`
is called **twice per rendered frame** (once from the `UpdateMotion`
pre-hook, once from the `LateUpdateBehavior` pre-hook — both added in fix
attempt 1), and the logged hand position alternated in lockstep with which
hook triggered the call: every `UpdateMotion`-timed call read back a
**frozen** hand position (the pre-pull grabbed pose, unmoved for the whole
pull regardless of `eased`), while every `LateUpdateBehavior`-timed call
read back the **correctly progressing** eased position. Two calls per
frame, one publishing the real position and the other immediately
overwriting it with a stale one, alternating every frame — that
alternation *is* the visible teleport.

Mechanism: `publish_hand_dock()` reads `rack.anchor`'s (the slide joint's)
`get_WorldMatrix` immediately after this same function writes the joint's
`LocalPosition` via `set_slide_joint_local_z`. The engine only recomputes
that cached world matrix during its own native processing, which lands in
time for the `LateUpdateBehavior`-timed call to see the update but not for
the `UpdateMotion`-timed call.

**Fix attempt 4 applied (2026-07-31):** `update_slide_rack_trigger` now
takes a `publish_visual` parameter. `trig_travel`/`local_z` still advance
on every call (both hooks) for the higher-frequency easing, but
`publish_hand_dock`/`update_rack_arm_delta`/the arm-IK apply block only
run when `publish_visual` is true. `M.tick_trigger_rack(publish_visual)`
forwards the flag. In `re2_vr_reload.lua`, the `UpdateMotion` pre-hook now
calls `tick_trigger_rack(false)`, the `LateUpdateBehavior` pre-hook calls
`tick_trigger_rack(true)`. **Test result:** the debug log's `src=motion`/
`src=late` tags confirmed this fix worked — the two call sites stopped
clashing, motion calls correctly stopped publishing. But the player still
saw teleporting, plus a new-looking symptom: the pull snaps instead of
gliding, and while holding RG+LG+LT together they could move the rack back
and forth with real hand movement.

**Fifth root cause found and fixed (2026-07-31):** `M.apply_slide_park()`
is called every frame from three *more* hook sites via
`M.sync_rack_motion()` (tagged `"LU"`/`"PR"`/`"BR"` — LateUpdateBehavior/
PrepareRendering/BeginRendering — in `re2_vr_reload.lua`), and was never
gated with `weapon_uses_trigger_rack(wp)`, unlike its two sibling
functions which already have that guard. While `rack.active` is true, it
independently computes the slide's `local_z` from
`_G.__vr_slide_rack_pull_signed`/`rack.pull_now`, and once
`rack.pull_done` is true it switches to `get_push_delta_from_peak()` —
which reads the **live controller/HMD position** relative to a captured
peak. So three more per-frame call sites were writing the same joint from
real hand movement, racing the two trigger-driven writes — this explains
the snap, the hand-movement-drives-the-rack behavior, and also the exact
one-call jump found in the debug log right at the `pull_done` transition
(precisely where `apply_slide_park`'s own formula switches from a
grab-based calc to the push-delta one).

**Fix:** added `if rack.active and weapon_uses_trigger_rack(wp) then
return end` inside `M.apply_slide_park`, right after its existing
`get_slide_joint()` guard — preserves the function's pre-grab "park the
slide open" display logic (still valid/needed for trigger-rack weapons
before the player grabs the slide) but stops it from touching the joint at
all once an active trigger-rack cycle is underway, making
`update_slide_rack_trigger` the sole owner of `local_z` during pull/
release for these weapons.

**Status: confirmed working by the player.** Debug logging removed from
`update_slide_rack_trigger`. Reusable lesson for any future trigger-driven
gesture conversion (e.g. porting this pattern to another weapon or to
RE3): any function that writes `set_slide_joint_local_z` or reads/writes
`_G.__vr_slide_rack_pull_signed`/`rack.pull_now` needs an explicit
`weapon_uses_trigger_rack(wp)` guard, or it will silently fight the
trigger-driven write — both root causes here were exactly that class of
bug (one via a missing publish-side guard across duplicate hook call
sites, one via a genuinely missing weapon-type guard in a third,
unrelated function).

**Third bug found and fixed same day:** player reported the whole gesture
occasionally auto-completing in about a second right on grab, with LT
never pressed. Root-caused by reading the code (the debug logging had
already been removed and there was nothing else useful in the log this
time): `rack.trig_travel`/`trig_committed`/`trigger_prev` are never reset
between cycles by anything actually reachable — the only two reset points
live inside `update_slide_rack_trigger` itself, and one is dead code
(blocked by the wrapper's own `rack.active` gate), the other only fires on
an aborted grab, never a normal completion. So after the *first* successful
trigger-rack reload in a session, `trig_committed` stays `true` forever.
On the next grab, `pull_done` gets freshly reset but `trig_committed`
doesn't, so the very first tick hits `target = rack.trig_committed and 1.0
or 0.0` → `1.0` with no regard for LT's actual state, auto-completing the
whole cycle. Explains "a few times" — only the 2nd+ trigger-rack reload
within the same script-load session is affected; reloading scripts resets
`rack` to its zeroed defaults, masking the bug during earlier testing
rounds. **Fix:** added explicit resets of all three fields to
`try_start_rack_gesture`, alongside the resets already there for
`pull_done`/`pull_max`/`pull_now`. **Confirmed working by the player.**

## COMPLETED — Full-speed movement while two-handing/aiming (RG held)

**Goal:** originally "disable movement speed capping while RG held" — refined
during investigation to the real goal: gripping a weapon two-handed (RG
held, weapon out) currently forces the player down to a slow aim-shuffle
pace, same as flat-screen Leon slowing down while aiming. Player wants to
still be able to run while two-handing.

**Root cause (confirmed via live probing, several dead ends first):**
- `app.ropeway.survivor.SurvivorMotionSpeedController` (found via its very
  on-the-nose name, has `applyTensionSpeed`/`TensionSpeed`/`DefaultSpeed`)
  was a dead end — confirmed via live polling that `MotionSpeed`/
  `PlaySpeed`/`TensionSpeed`/`DefaultSpeed` all stay `1.0` regardless of RG
  state or weapon-out. Not the mechanism.
- `PlayerController`/`SurvivorCharacterController`/`via.physics.
  CharacterController` dumps (keyword-filtered for speed/move/rate/limit/
  walk/run) didn't reveal an obvious runtime scalar either — mostly
  movement-direction/blend-angle fields (`MoveAngleNormal`/`MoveAngleJog`)
  and generic physics params (`SlopeLimit` etc.), not a toggleable speed
  cap.
- **The real insight:** `reframework/autorun/re2_smooth_movement.lua` (this
  mod's own custom VR locomotion) doesn't add any slowdown itself — every
  frame it *measures* the player's actual transform position delta (driven
  by RE2's native root-motion animation system) and just redirects that
  same observed magnitude toward the joystick's camera-relative direction
  instead of native root-motion's own direction. So it was faithfully
  *mirroring* whatever pace native root-motion produced, including the
  native aim-slowdown — the slowdown almost certainly lives in which
  locomotion animation is currently blended (root-motion-driven speed),
  not a separate numeric field, which is why no scalar cap was ever found.

**Fix implemented:** in `re2_smooth_movement.lua`'s `UpdateMotion` hook,
added a `player_is_aiming()` check (same `get_IsHold()` pattern already used
in `re2_vr_recoil.lua`/`re2_vr_haptics.lua`/`re2_vr_ik_extention.lua`).
While aiming, bypass the native-observed magnitude entirely and instead
drive `speed` from raw stick magnitude times a fixed reference pace
(`AIM_SPEED_OVERRIDE_MPS`). Deliberately does not feed the throttled sample
into `last_ema_speed`, so the EMA resumes cleanly (no jump/lag) once aiming
ends.

**Tuning (live, iterative):** started at 3.5 (too fast) → 2.5 → 1.8 → 1.7 →
1.6 → 1.4 → **1.3 m/s, confirmed as the final value.**

**Footstep audio — turned out to be a non-issue:** initial assumption was
that footstep sound would be desynced from the (now faster) overridden
movement, since audio seemed tied to the native (slow) locomotion
animation. Player checked directly in-game: the animation itself switches
to a walking-pace animation while aiming, but the footstep *sound already
correctly matches the legs' visual movement* (i.e. audio-to-animation sync
was never broken — only world-space translation speed was ever being
overridden, and that alone reads as correct/natural). No further work
needed here. `re2_vr_footstep_probe.lua`/`re2_vr_footstep_signature_probe.lua`
were built investigating this (found `via.motion.script.
FootEffectController` has `UseSpeedOnly = true` plus callable
`callSE`/`callFootEffect` with `WalkSoundType=1`/`JogSoundType=2`
constants) — kept as reference in case a *real* audio desync issue comes up
elsewhere, but not needed for this feature.

**Deliberately deferred bigger idea — do not start without being asked
again:** player asked whether *all* movement (not just while aiming) could
use this same stick-driven override system, for a more consistent/
predictable feel. Explicitly decided to treat this as a **separate future
project**, not an extension of this fix, because it implies building a
parallel locomotion system: a custom walk/run toggle (native
right-stick-click run-toggle would need disabling and remapping to
flashlight on/off instead, per player's stated plan), a custom
distance-based footstep trigger for ALL movement (not just aiming), and
accepting/managing visible foot-sliding since the legs would still play
whichever native animation the game thinks is appropriate. Revisit only if
explicitly asked to pick this back up.

**Status: confirmed working by the player**, including the footstep
audio check.

Files: `reframework/autorun/re2_smooth_movement.lua` (the fix),
`re2_vr_movespeed_probe.lua` and `re2_vr_tensionspeed_probe.lua`
(diagnostics, dead-end findings kept as reference — don't re-investigate
`SurvivorMotionSpeedController` again, it's confirmed not the mechanism),
`re2_vr_footstep_probe.lua` (diagnostic, not yet run).

**Crash note:** an earlier version of `re2_vr_tensionspeed_probe.lua`
hooked `applyTensionSpeed()` directly and **crashed the game on loading
into an actual level** (main menu was fine). Likely cause: that component
almost certainly exists on every character in the scene, not just the
player, so the hook fired at high frequency for NPCs too, combined with
extra native calls and VR-controller-state reads per invocation inside the
hook. Rewritten as a pure per-frame poll instead (no hooking), which
worked fine. **Lesson: avoid hooking methods on components that aren't
confirmed player-only, especially combined with VR-API reads inside the
hook** — poll instead when just diagnosing.

## COMPLETED — Shotgun shells eject on pump pull-down, not on fire

Spent shotgun shell casings now visually eject at the moment the pump
handle is pulled all the way down (RG-ready, LG-grip the pump handle, LT
pulls back), not immediately when the weapon fires. Only affects the four
manual-pump shotguns (wp1000/wp1100/wp1200/wp1500); all other weapons
untouched.

**Native call chain (found via live hook tracing in
`re2_vr_shell_eject_probe.lua`, kept as reference):** firing calls
`Equipment.requestFire` → ~114ms later `app.ropeway.weapon.shell.
ShellCartridgeController.request()` → ~13ms later `.generate()`.
`generate()` is the actual casing spawn — confirmed by blocking it
entirely: ammo still decremented, sound/recoil unaffected, only the
casing prop stopped appearing. So it's purely cosmetic and safe to gate.
`weapon.generator.ShotgunShellGenerator`/`BulletShellGenerator` (a lead
from `re2_vr_recoil.lua`'s fallback hook target) do **not** exist under
this game's namespace — a dead end, likely copied from a different
RE-engine game's template code. The real object is reached via
`equipment:call("get_MainWeapon")` → `arm:call("get_ShellCartridgeController")`.

**Implementation pitfalls hit along the way, worth remembering:**
1. Blocking `generate()` at fire time and simply calling it again later
   produced no visible casing — `generate()` alone isn't enough.
2. `ShellCartridgeController` extends `via.Behavior` (has
   `startCoroutine`/`registerCoroutine`). The ~13ms gap between `request()`
   and `generate()` in the natural sequence matches `request()` kicking off
   a coroutine that calls `generate()` on a *later frame*, not
   synchronously. Calling `request()` **and** manually calling `generate()`
   immediately after, then closing the "let it through" re-entrancy guard
   right away, caused the guard to close before that natural
   coroutine-driven `generate()` call arrived — our hook caught it again as
   if it were a brand-new fire event. Fix: call **only** `request()`, hold
   the guard open for several frames (not just synchronously), and let
   `request()`'s own coroutine drive `generate()` naturally.
3. Held a stored `ShellCartridgeController` instance across the delay
   initially — safer to freshly re-fetch it at the moment of use instead of
   trusting a reference held across several seconds.
4. A real bug: the frame-loop's countdown decrement was placed after an
   early `return` that fires on almost every frame (whenever no pump-pull
   just happened), so the countdown got stuck permanently above zero after
   the first cycle — silently disabling suppression for every shot after
   the first. The decrement must run unconditionally every frame, never
   behind an early return tied to a rare per-frame event.
5. The delay needed to trigger on **pull-down** (`gesture.pull_done`
   becoming `true` in `re2_vr_reload_ext_4.lua`'s Pump state machine), not
   on full cycle completion (`complete_pump_cycle()`, which only fires
   after release and the return stroke) — these are two distinct signal
   points in the same file; picking the wrong one delays the eject to the
   wrong moment (release instead of pull).

Files: `reframework/autorun/re2_vr_delayed_shell_eject.lua` (final
implementation), one added `rawset(_G, "__vr_pump_pulled_down_wp", wp)`
line in `re2_vr_reload_ext_4.lua` at the pull-done transition,
`re2_vr_shell_eject_probe.lua` (diagnostic, kept as reference — its
one-time `EXPERIMENT_BLOCK_GENERATE` is now off).

**Status: confirmed working by the player.**

## COMPLETED — Trigger-driven pump-action shotgun reload

Replaced the unreliable hand-tracked pump gesture with a trigger-based state
machine: left grip = hold pump handle, left trigger press = commit to pull,
hold = eased travel to pulled position, release = eased return + complete
cycle. Smoothstep easing added for realism.

Files touched: `re2_vr_reload.lua`, `re2_vr_reload_ext_1.lua` (added
`is_left_trigger_pressed()`), `re2_vr_reload_ext_4.lua` (pump state machine +
`pump_ease` helper table, consolidated to stay under Lua's 200-local-per-chunk
limit — hit exactly 201 once, fixed by merging 4 helper functions into one
table).

**Status: confirmed working by the player.**

## COMPLETED — weapondial_start (quick-select wheel) rebind

Problem: native "hold trigger + push stick = weapon quick-select" shared the
left trigger binding with the new pump-reload trigger, causing accidental
wheel pop-ups.

Direct edits to the OpenXR interaction-profile JSON do NOT reliably work
(silently ignored/overwritten). The reliable method is REFramework's in-game
**VR > Bindings** panel — rebind there and hit Save Bindings.

Player rebound `weapondial_start` to right thumbstick-click via that panel.
**Confirmed working.** Bonus discovery: left grip + right-thumb-press + left
stick brings up the *sub-weapon* wheel specifically (native mechanic, same
weapondial system, left grip as modifier).

---

## COMPLETED — Sub-weapon must not appear while RG is held

**Final shipped behavior (2026-07-31):** the sub-weapon (knife/grenade/
flashbang) never appears while RG (right grip) is held, so two-handing the
main weapon (RG then LG joins) never gets interrupted by the native
support-hold mechanic — this was the actual goal all along; an earlier
RT-triggered approach (see below) was explored first but ultimately
dropped as unnecessary.

Native LG-alone support-hold (readying the current sub-weapon in the
off-hand) is left completely untouched — that's fine on its own, only the
RG-held case was ever the problem. The LG+RG combo is ambiguous by itself
(it's both "add support grip to the main weapon" and the native
grenade-throw gesture — arm/throw whatever's already readied via LG) —
resolved by **engagement order**: if RG is pressed while LG is *not yet*
held, this hold suppresses the sub-weapon (two-handing case); if LG was
*already* held when RG engages, nothing is forced (grenade-throw case).
This is decided once, on RG's rising edge, and stays fixed for that whole
RG hold regardless of what LG does afterward.

**Key technical facts, in case this pattern is needed again (e.g. for RE3):**
- `Equipment._SubType`/`_MainType` are unreliable (always read -1/Invalid).
  To read the *live* current weapon (main or sub), call
  `equipment:call("get_MainWeapon")` / `get_SubWeapon()` → returns an `Arm`
  object → read `_WeaponType` (and `_WeaponParts`) directly off that Arm.
- `ForceEquipType` (`Equipment.<ForceEquipType>k__BackingField`) is a
  `Nullable<WeaponType>` **struct**, not a plain int, with no setter
  methods for `HasValue`/`Value`. The only way to set it is via reflection
  on its own real fields, named `_HasValue`/`_Value` (found by dumping the
  struct's full field list — not documented anywhere, and not the same as
  `Equipment`'s own fields). A bare int write into the parent field does
  **not** set `_HasValue`, so it silently does nothing.
- `Equipment` also has a paired `<ForceEquipParts>k__BackingField`
  (`Nullable<WeaponParts>`, same `_HasValue`/`_Value` pattern) — found by
  dumping `Equipment`'s own fields/methods for anything containing "part"
  (hinted at by `setForceEquipType`'s real signature:
  `(Nullable<WeaponType>, Nullable<WeaponParts>, bool)`). Forcing
  `ForceEquipType` alone strips attachments, since `WeaponType` only
  identifies the base weapon; forcing both together preserves them.
- `ForceEquipType`/`ForceEquipParts` do not self-clear once raw-written —
  nothing consumes/resets them for us (we're bypassing whatever normally
  does, e.g. `requestEquip()`). They must be explicitly cleared
  (`_HasValue = false`) once the forced condition ends, or the stale
  override can get misread later by unrelated engine logic.
- The native `SUPPORT_HOLD` input flag (`InputSystem.get_ButtonBits()`,
  see `app.ropeway.InputDefine.Kind`) is what actually drives LG's
  sub-weapon-ready behavior. **Directly clearing that raw input bit every
  frame does NOT work reliably** — confirmed via live testing that our
  clear could land successfully and the native ready-state would still
  flip true moments later (a losing race against native per-frame
  recomputation). Correcting the *result* (force the main weapon back via
  `ForceEquipType`/`ForceEquipParts`) instead of trying to preempt the
  *input* is the approach that actually works.

Final implementation: `reframework/autorun/re2_vr_suppress_supporthold.lua`.

### Superseded — Right-trigger-hold = instant sub-weapon equip (RT approach)
An earlier iteration made holding RT alone bring the sub-weapon out, with
release forcing the main weapon back (using the same `ForceEquipType`
struct-mutation technique above, first discovered here). **Confirmed
working at the time**, but the player later decided RT-triggered
sub-weapon equip wasn't actually needed — the real requirement was just
"SW must not appear while RG is held," solved directly above. This
approach is disabled (early `return` added, 2026-07-31) rather than
deleted in `reframework/autorun/re2_vr_subweapon_force.lua`, since the
struct-mutation technique it pioneered is reusable reference — remove the
early return to re-enable if RT-triggered sub-weapon equip is ever wanted
again.

Diagnostic-only scripts (`re2_arm_probe.lua`, `re2_equipment_probe*.lua`,
`re2_changeweapon_probe.lua`, `re2_enum_probe.lua`,
`re2_vr_subweapon_probe.lua`) are no longer needed for either version of
this feature, but are being kept (not deleted) as reference templates for
similar native-field probing when this same mod work is redone for RE3.

## Historical notes on this feature's investigation (kept for context)

**Goal:** Holding right trigger alone (right grip AND left grip both *not*
held) should instantly put the sub-weapon (knife/grenade) in hand — no wheel,
no selection needed.

**Hard requirements:**
- right grip + right trigger together must still fire the main weapon
- left grip + right grip together (two-handing a long gun) must NOT trigger
  the sub-weapon
- Condition used throughout: `want_sub = right_trigger AND NOT right_grip AND
  NOT left_grip`

### Confirmed background facts (from live probing, not guesses)

- No Lua file in this mod implements sub-weapon-ready/weapondial logic for
  RE2 — it's native/compiled. (`re8_vr.lua` has an unrelated example for a
  different game.)
- The relevant native class is `app.ropeway.survivor.Equipment`, reachable
  via the already-proven pattern:
  ```lua
  local vrc_manager = require("vr/VRControllerManager")
  local re2 = require("utility/RE2")
  local GameObject = require("utility/GameObject")
  local player = re2.get_localplayer()
  local equipment = GameObject.get_component(player, sdk.game_namespace("survivor.Equipment"))
  ```
- `WeaponType` enum is NOT a generic Main/Sub tag — it's one value **per
  specific weapon item** (`Invalid = -1`, `BareHand = 0`, `WP0000 = 1` ...
  `WP9990 = 381`).
- `EquipCategory` enum: `Main = 0`, `Sub = 1` (confirmed via `re2_enum_probe.lua`).
- `WeaponParts.None = 0` (confirmed via same probe).
- Relevant members found on `Equipment` via live method/field probing:
  `EquipType` (get/set), `ForceEquipType` (`Nullable<WeaponType>`, backing
  field `<ForceEquipType>k__BackingField`), `_MainType` / `_SubType` (raw
  fields), `MainWeapon` / `SubWeapon` (`get_MainWeapon()`/`get_SubWeapon()`,
  return an `app.ropeway.implement.Arm` object — the real weapon instance),
  `get_IsEquipSub`, `changeWeapon(EquipCategory, WeaponType, WeaponParts)`,
  `setForceEquipType(Nullable<WeaponType>, Nullable<WeaponParts>, bool)`,
  `useSubWeapon()` (params not yet probed), `requestEquip()` (no params),
  `updateEquip()` (native per-frame recompute, presumed).
- **Important recent finding:** `_SubType` reads `-1` (Invalid) even when the
  player has a knife equipped and reachable via left grip. This means
  `_SubType`/`_MainType` most likely reflect "the live type for whichever
  category is *currently active*," not "whatever's assigned to that
  category" — i.e. they are NOT a reliable way to read "what's my current
  sub-weapon" while the main weapon is the one in hand. The real sub-weapon
  is more likely readable off the `Arm` object returned by `get_SubWeapon()`
  — **this hasn't been resolved yet, see Next Steps.**

### Attempts tried, in order, all via a standalone script
(`re2_vr_subweapon_trigger.lua`, does not modify other files)

1. **`equipment:call("set_ForceEquipType", sub_type)`** — threw an exception
   every frame ("Invoke threw an exception"). Likely `Nullable<T>` marshaling
   issue when calling through `call()`.
2. **Direct write to `EquipType`** (raw backing field, then the real
   `set_EquipType`/`get_EquipType` methods) — ran with zero errors, but had
   **no visible effect**. Theory: `EquipType` is recomputed every frame by
   native `updateEquip()`, so our write gets stomped before render — a race,
   not a failure.
3. **Raw field write to `ForceEquipType`** (`<ForceEquipType>k__BackingField`)
   — ran clean, and produced a **real reaction**: a brief equip sound played
   on trigger-press, but it reverted instantly with no visual change. This
   confirmed `ForceEquipType` is a real hook the game reacts to.
4. **Same raw field write, but reasserted every frame** instead of once on
   the press edge — the sound went away completely. Theory: the game reacts
   to the field *changing* (nil → value), not to it merely being present, so
   writing the same value repeatedly looks like "no change."
5. **`changeWeapon(EquipCategory.Sub, sub_type, WeaponParts.None)`** — this
   method's signature matches the `onChangeWeapon` event exactly, so it
   looked like the authoritative "commit" method — ran clean, but produced
   **total silence**, not even the sound from attempt 3. Theory: `changeWeapon`
   may be more of an inventory/slot-assignment function than a "put this in
   hand right now" trigger.
6. **`setForceEquipType(sub_type, WeaponParts.None, true)`** — a real,
   separate method (not the property from attempt 1) — threw the exact same
   "Invoke threw an exception" error every frame. Confirms the problem is
   specifically: **any method call() with a `Nullable<WeaponType>` parameter
   throws**, regardless of which method.
7. **Raw field write to `ForceEquipType` (same as attempt 3) + explicit
   `equipment:call("requestEquip")` right after**, hoping `requestEquip` was
   the missing "apply it now" commit step — ran clean, but this time got
   **less** than attempt 3: no sound at all. Theory: `requestEquip()` likely
   *consumes/clears* `ForceEquipType` itself before whatever plays the sound
   gets a chance to see it — actively counterproductive.

### Diagnostic-only scripts built along the way (no gameplay effect)
- `re2_hidpad_probe.lua` / `re2_hidpad_probe2.lua` — dead end, `HIDPadManager`
  doesn't exist for RE2. Abandoned once the weapondial rebind was solved via
  the in-game Bindings panel instead.
- `re2_equipment_probe.lua` / `re2_equipment_probe2.lua` — first pass over
  `Equipment`'s methods/fields, found everything listed above.
- `re2_weapontype_probe.lua` — confirmed `WeaponType` is per-item, not a
  Main/Sub tag.
- `re2_changeweapon_probe.lua` — dumped real parameter types for
  `changeWeapon`, `setForceEquipType`, etc. (the source of the attempt 5/6
  signatures above).
- `re2_enum_probe.lua` — confirmed `EquipCategory.Sub = 1`,
  `WeaponParts.None = 0`.
- `re2_equip_hook.lua` — hooks `updateEquip()` pre/post to log field values
  as native code reads them. **Result was inconclusive**: it logged the
  press/release of our own field write fine, but the pre/post hook itself
  never printed a single line, meaning either `updateEquip()` wasn't called
  during the test window, or the hook didn't actually attach to the live
  instance. Not yet resolved — worth revisiting if the Arm-object approach
  below doesn't pan out.
- `re2_arm_probe.lua` — **last thing built, not yet tested.** Calls
  `get_MainWeapon()` and `get_SubWeapon()` on trigger-tap and dumps the
  runtime type + any method/field names containing "type"/"kind"/"id"/
  "weapon" on the returned `Arm` object(s). Goal: find the correct way to
  read the *actual* currently-equipped sub-weapon, since `_SubType` was
  proven unreliable (reads Invalid despite a knife being equipped).

### How this was actually resolved (superseding the "Next steps" that used
to be here)
`re2_arm_probe.lua` confirmed `_WeaponType` read directly off the `Arm`
object from `get_SubWeapon()`/`get_MainWeapon()` is the reliable live
value. Attempts 1-7 above all predate discovering that `ForceEquipType`'s
raw field write needs to mutate the struct's own `_HasValue`/`_Value`
fields rather than assigning a bare int to the parent field — once that was
found, the straightforward raw-field-write approach (closest to attempt 3)
worked. See the COMPLETED section above for the full resolution, including
the follow-up attachment-stripping bug and its fix. `re2_equip_hook.lua`
and `useSubWeapon()` were never revisited — turned out not to be needed.

### Player's own testing conventions (worth keeping)
- Every diagnostic/feature script logs under a unique bracketed tag (e.g.
  `[re2_vr_subweapon_trigger]`) and uses `pcall` guards throughout.
- Test in VR unless a script explicitly says flat is fine (pure type/field
  dumps don't need VR; anything reading live controller input does).
- Always check `reframework/re2_framework_log.txt` after a test, grep for the
  script's tag.
- Watch for accidental duplicate script files in `autorun/` (browser-renamed
  `_1` copies have caused false-negative tests before) — confirm only one
  copy of each script exists before testing.
