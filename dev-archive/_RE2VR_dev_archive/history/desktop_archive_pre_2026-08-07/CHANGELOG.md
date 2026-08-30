# ARCADE_CONTROLS for RE2 VR — Changelog & Dev Notes

Covers everything from the pumpable-shotgun feature (v1.2.0) onward. This
mod is built on REFramework + RE2VRMODRELOADED (Andyalpa); scripts live
under `reframework/autorun/`. There's no git history for this project, so
this document is compiled from development notes rather than diffs — file
paths and function/field names are accurate as of this writing, but exact
same-day ordering of a few small items is approximate.

---

## v1.2.0 (packaged 2026-08-02/03)

### Free-rack pumpable shotgun (any ammo state)
**File:** `reframework/autorun/re2_vr_reload_ext_4.lua` (`Pump` module)

Lets the player rack the shotgun's pump handle at any time — empty gun or
a live chambered round — not just when the game's own fire logic requires
a cycle. Deliberately **cosmetic only**: a free rack doesn't eject a live
round or change ammo state. A realistic short-stroke (eject + recoverable
live round) was considered and explicitly deferred as unnecessary
complexity.

Previously the pump gesture (LG = hold handle, LT = pull/rack) was gated
by `gesture.needs_pump`, set `true` only by real game events (fired with
shells left, or a shell just inserted into an empty gun). Changes:
- Added `gesture.pump_is_real` (true only when the game itself armed
  `needs_pump`) to distinguish a real cycle from a cosmetic one.
- `update_manual_pump_gesture()` now starts on grip alone; for a free
  rack it calls `arm_pump_gesture(wp)` itself to prime bind pose/pull-axis
  (normally pre-armed by the fire/insert handlers).
- Abort handling (grip released mid-pull) now branches on `pump_is_real`:
  a cosmetic abort fully clears state; a real abort keeps the original
  "still owed a pump" behavior.

**Two bugs found and fixed during live testing:**
1. First version skipped `try_end_chamber_clear()` (native
   `endChamberClear`/`executeEndReload`/`executeEndEject`) for cosmetic
   racks, wrongly assuming it was ammo-mutating. It's actually just an
   FSM/fire-readiness finalizer (see `sync_chamber_shoot_ready()` in
   `re2_vr_reload_ext_1.lua`) — skipping it left the gun permanently
   refusing to fire after any free rack. Fixed by always calling it.
2. `needs_pump` was being armed the instant grip was pressed — but this
   weapon's grip button doubles as the normal two-handed aim/support-hold
   input, held continuously during ordinary play, so just aiming (without
   racking) blocked all firing. Fixed by only arming `needs_pump` at the
   trigger-pull commit point, matching how real (game-required) cycles
   already behaved.

### Leon holster repositioning
**Files:** `reframework/autorun/re2_vr_holster.lua`,
`reframework/data/re2_vr/re2_vr_holster.json`

Tuned shoulder/hip/chest holster offsets specifically for Leon (6 other
character profiles untouched). Confirmed axis convention via live
testing: `_x` negative = right, positive = left; `_z` positive = forward,
negative = back (holds for shoulder, hip, and chest slots, since they all
feed the same `refresh_holster_zone` call). The `_y` (up/down) axis does
**not** follow simple world up/down on the chest slot's `spine_2` anchor
— its local axes are tilted relative to world space, so the hip-derived
sign intuition doesn't transfer. Don't assume `_y` behaves consistently
across slots.

### Chest/"left hip" holster fix
**File:** `reframework/autorun/re2_vr_holster.lua`

Moved the chest holster (magnum/revolver slot) to sit low, opposite side
from the hip pistol, since it used to swing close to the right controller
during body-turns. **Fixed via the mod's own in-game "Calibrate" button**
(`draw_holster_calibrate` → `start_capture`), not manual offset math — two
manual attempts failed first (repointing the anchor bone broke the zone
entirely; guessing `chest_off_y` as negative/"down" made the zone
disappear — the working value was actually `+0.314`, positive). Baked the
final values into `make_leon_default_profile()` so a fresh install starts
Leon correctly instead of at raw 0.0 offsets.

**Lesson for future holster tuning:** prefer the Calibrate button over
guessing offsets by hand, and don't assume a bone's local axes match
world-space intuition without checking.

### Ada's chapter — default values corrected
**Files:** `re2_vr_reload_ext_1.lua`, `re2_vr_reload.lua`

Two bugs found in what an earlier session's notes had claimed was
"already baked into code defaults" — it wasn't:
- `mag_dock_by_wp.wp0700` (Ada's Broom Hc mag insertion range) was still
  `0.10` (the first, too-tight guess) in the code default; the working
  `0.06` value had only ever made it into the persisted JSON. Corrected
  in code.
- The ammo pouch reach position (tuned live via the Calibrate Ammo
  Holster button) had **no code default at all**, only a shared 0/0/0
  fallback. Added `MAG_HOLSTER_CHAR_DEFAULTS.ada` (`off_right: 0.3356,
  off_up: -0.1421, off_forward: 0.0617`) in `re2_vr_reload_ext_1.lua`.

**Lesson:** don't trust a past note that something was "baked into both
the default and the JSON" without checking the actual `.lua` file.

### Dev-only: Lua 200-top-level-local ceiling
This REFramework Lua runtime hard-errors (script load failure) if a
single file's top-level scope exceeds 200 local variables. Adding
`MAG_HOLSTER_CHAR_DEFAULTS` as a new bare local pushed
`re2_vr_reload_ext_1.lua` from 200 to 201 and broke on launch. Fixed by
folding it into the existing `MAG_HOLSTER_DEF` table as a `char_defaults`
field instead — the established pattern in this codebase for this
situation (see also `re2_vr_holster.lua`'s `vr_flash` table).
`re2_vr_holster.lua` and `re2_vr_reload_ext_1.lua` are both already at or
near this ceiling — **before adding any new top-level `local` to a large
file in this project, run `grep -c "^local " <file>` first**, and fold
into an existing table if it's near 200. This is a hard Lua VM limit, not
RE2-specific — expect it to recur on any future RE Engine title this
codebase gets ported to.

---

## Since v1.2.0 — research in progress, no code shipped yet

Two related investigations, both currently paused mid-effort. Documented
here in detail because the technical findings (what was tried and why it
failed) are genuinely useful prior art for anyone else attempting similar
things on RE Engine/REFramework, even though neither has shipped a
feature yet.

### VR Hands (Oziman) cutscene integration — 5 approaches tried, all blocked in Lua
**Goal:** the player uses a third-party mod ("VR Hands," permission
granted by its author to redistribute/merge into this project) that
replaces Leon's/Claire's/Ada's body mesh with a hands-only version, for a
cleaner first-person VR look than this mod's native
`FirstPerson_HideJointMesh` option achieves. Problem: it's a static loose-
file mesh override (`natives/stm/.../player/pl0000/...`), so it also
applies during third-person cutscenes, causing "floating hands" whenever
a cutscene shows the character's body.

**All confirmed dead ends (each independently verified live):**
1. **File I/O from Lua** — REFramework's `io.open` explicitly rejects
   absolute paths and `..` parent-directory traversal
   ("This API does not allow..."), and `os.rename`/`os.remove` don't
   exist in the sandbox at all. No way to swap/rename the override file
   from a runtime script.
2. **Native per-part visibility toggle** — `app.ropeway.survivor.
   SurvivorCostumeChanger` (attached directly to the player GameObject)
   exposes `Body`/`Face`/`Hair`/`SheathKnife`/`Other` as separate parts
   with a `setPartsEnable` method (same mechanism this mod already uses
   for weapon-mag hiding). Live-tested: hiding "Body" hides hands/arms
   too — it's one continuous skinned mesh, not separable at this
   granularity.
3. **In-memory mesh-resource swap** — `via.render.Mesh` has 231 methods
   but no settable field/method for the skinned/animated mesh a character
   uses (`get_StaticMesh`/`set_StaticMesh` exists but is for non-animated
   props only).
4. **Forcing a reinstantiation to pick up a live file change** — proved,
   by renaming the override files away via PowerShell *while the game
   kept running* (bypassing the Lua sandbox entirely) and then
   force-calling `SurvivorCostumeChanger.onAwake/onStart/onRequestAction/
   onInstantiateAction` directly: these lifecycle methods only reset
   pose/skeleton state from an already-resident in-memory resource, they
   never re-read from disk. The engine appears to cache this resource for
   the life of the level.
5. **`sdk.create_resource(typename, path)`** is a real REFramework Lua
   API (confirmed via docs), but `via.render.Mesh` has zero reflected
   fields to assign a created resource to — it's a native `via.*` type,
   not a managed object. The "`res:[path]`" string convention seen in the
   EMV-Engine Lua script collection is for Material (MDF/texture) swaps
   specifically, not vertex/skeleton geometry — doesn't apply here.

**What's left:** a compiled C++ REFramework plugin — and even that likely
requires reverse-engineering the compiled game binary (IDA/Ghidra/x64dbg),
since REFramework's own reflection SDK — which normally exposes most of
what's discoverable in these native types — shows nothing usable here.
Paused rather than pursued, in favor of the approach below, which
sidesteps the problem instead of solving it.

**Reusable finding regardless of outcome:** `app.ropeway.timeline.
SurvivorActorController.doStartEvent`/`doFinishEvent` fire within 1-3ms of
a cutscene boundary, specifically for whichever actor is actively driven
by that cutscene's timeline — much more precise than the generic
`is_cinematic_blocking()` flag alone (already used elsewhere in this
project) for any future cutscene-boundary-sensitive work. Caveat: in
multi-character cutscenes, only the actively-puppeteered actor gets the
full event sequence — a passive/background character in the same scene
won't fire these at all.

### Custom VR cutscene camera — not yet started, reference pattern found
**Motivation:** if cutscenes rendered in true first-person (the
character's own eyes) instead of the native forced third-person, the
VR-Hands floating-hands problem (and similar issues) would never be
visible in the first place, regardless of what any body-mesh mod does.

Native `FirstPerson_ShowInCutscenes=true` exists but causes a disorienting
compounding-rotation drift bug (compiled into the third-party VR core, not
this project's Lua) — the world spins faster than the cutscene camera
itself pans, consistent with raw HMD rotation being added on top of a
changing scripted camera each frame instead of being re-derived fresh.
`FirstPerson_ToggleKey` (F9) works fine standalone in gameplay but is
completely inert if pressed during a cutscene — ruling out a simple
"detect boundary, toggle the native flag" workaround.

**Reference implementation found:** `reframework/autorun/re8_vr.lua` (kept
in this project as template material for other RE Engine titles, not
currently active for RE2) has a working cutscene-aware camera system,
including a tracked `is_in_cutscene` state:

```lua
local camera_rot_pre_hmd = camera_rot:clone()
local camera_pos_pre_hmd = camera_pos:clone()
vrmod:apply_hmd_transform(camera_rot_no_shake, Vector3f.new(0, 0, 0))
vrmod:apply_hmd_transform(camera_rot, camera_pos)
if re8vr.is_in_cutscene then
    joint_set_position:call(camera_joint, camera_pos_pre_hmd)
    joint_set_rotation:call(camera_joint, camera_rot_pre_hmd)
else
    -- normal gameplay: blends HMD rotation into a forward direction
end
```

Note this specific branch is a drift/comfort-prevention technique (pin
the render joint to the scripted camera's own pose during cutscenes,
ignore HMD rotation) — not full first-person embodiment anchored to the
character's own head bone. It confirms the building blocks exist and are
scriptable (`vrmod:apply_hmd_transform`, the `camera_transform` vs.
`camera_joint` distinction — joint is what actually renders — and
`PostureParam`/`CameraOffset`-style fields), but genuine head-bone-anchored
first-person cutscene embodiment would be new logic built on top of this
pattern. Entirely doable in Lua, no C++ required, but RE2's exact
camera-pipeline field names will need fresh probing — RE8's TDB won't
match RE2's.

**Status: not started.** Next step is probing RE2's actual camera object
graph (equivalent of `player_camera`/`camera_transform`/`camera_joint`)
before attempting any implementation.
