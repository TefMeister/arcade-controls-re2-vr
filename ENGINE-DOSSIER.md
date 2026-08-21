# Engine Dossier — Resident Evil 2 Remake (2019) (Capcom RE Engine, via REFramework)

> Distilled current truth about this game's engine, as worked through the
> `PLAYBOOK.md` phases. Blow-by-blow history lives in the `-dev-archive` and
> `reframework-ai-modding-notes` repos; this is the consolidated reference.

**Status:** Shipped. This is a mature, Nexus-released REFramework **Lua** mod
("ARCADE CONTROLS for RE2 VR") — custom VR weapon handling, two-handed grips,
IK, posture, reload/melee/holster behavior — layered on top of an existing
flat-to-VR base. **VR-readiness verdict:** not applicable in the usual sense —
**the VR conversion itself is provided by praydog's REFramework**, which
already delivers stereo rendering, 6DOF, and motion controls for all RE Engine
games. This project's work sits entirely in the gameplay/interaction layer
*above* that, so this dossier documents the **RE Engine object model as seen
through REFramework's Lua reflection API**, not a from-scratch renderer/camera
reverse-engineering effort like our other engine dossiers.

> **How this differs from our other engine dossiers.** For Psychonauts / TEW /
> XIII the PLAYBOOK's North Star (game in a headset with head tracking) is the
> hard-won deliverable. Here REFramework already owns Phases 1–6 (injection,
> renderer, camera, stereo, the VR runtime). What remained — and what this
> dossier is about — is the engine's *managed object model*: how to find and
> drive the game's own gameplay objects (weapons, player, IK, motion) blind,
> through reflection, with no headers and no source.

## 1. Identity
- Resident Evil 2 (2019 Remake), PC (Steam). Capcom RE Engine title.
- Owned copy confirmed. Nexus mod page:
  https://www.nexusmods.com/residentevil22019/mods/2640
- The mod is a set of REFramework `autorun/*.lua` scripts — **files we author**,
  no game assets redistributed.

## 2. Engine lineage
- **Capcom RE Engine** — Capcom's proprietary in-house engine (successor to MT
  Framework, first shipped with Resident Evil 7, 2017). Used across RE2/RE3/RE7/
  RE8/Village, Devil May Cry 5, Monster Hunter Rise/Wilds, Street Fighter 6,
  Dragon's Dogma 2, and more.
- **Managed type system.** RE Engine runs a .NET-like *managed* runtime with a
  **Type Database ("TDB")** — full metadata for classes, fields, methods,
  properties, events. Comparable in role to Unity's IL2CPP metadata, but it is
  **Capcom's own system, not Unity/IL2CPP** (a common and important conflation
  to avoid). Types live under namespaces: engine types under **`via.*`**
  (`via.GameObject`, `via.Transform`, `via.render.Mesh`, `via.motion.*`, …) and
  each game's own code under its game namespace (RE2's is **`app.ropeway.*`**).
- Renderer: **DirectX 11 / DirectX 12** (REFramework supports both).

## 3. Injection foothold & tooling (all via REFramework — we wrote none of it)
- **REFramework** (praydog) is the entire foothold: a `dinput8.dll`-style
  injector + mod loader + scripting platform + generic 6DOF VR for all RE
  Engine games. We ship Lua scripts into `reframework/autorun/`; no proxy DLL,
  no debugger, no manual hooks of our own.
- **The whole mod is Lua.** No native code, no memory patching, no x64dbg. All
  interaction with the engine is through REFramework's reflection/hook API.
- Base VR layer: **RE2VRMODRELOADED** (by Andyalpa), itself on top of
  REFramework — this mod is tuned against that specific base, used with
  permission.

## 4. The reflection model (the crucial section — how you find anything)
With no headers and no autocomplete, essentially all work is **reflection**:
ask a live object what it has, rather than read a spec. A "where does effect X
live" question has **three structurally different answers**, each a different
call:

1. **A named joint on a skeleton** — `transform:call("get_Joints")` →
   `get_elements()` → each `joint:call("get_Name")`. This is the animation rig
   only (character bones, weapon muzzle/socket points). It does **not** show
   parented GameObjects or components.
2. **A child GameObject in the Transform hierarchy** —
   `transform:call("get_ChildCount")` + `get_Child(i)` → `get_GameObject()`.
   For VFX props spawned and parented under something. **Caveat:** "zero
   children" does **not** prove nothing is attached — many native systems
   attach visual props by joint- or manager-based parenting that never appears
   as a Transform child.
3. **A component on the GameObject itself** —
   `gameobject:call("get_Components")` → `get_elements()` → each
   `component:get_type_definition():get_full_name()`. The easiest to forget
   (it's neither in the skeleton nor the scene tree — it's metadata on an
   object you may already hold). Gameplay objects carry **20–100 components**
   mixing render/physics/audio/gameplay; the real driver is often a
   generically-named class (an "effect manager" / "IK controller"), not the
   one with the effect's name in it.

Field enumeration on any instance (no class name needed):
```lua
local td = obj:get_type_definition()
for _, field in ipairs(td:get_fields()) do
    if not field:is_static() then
        log.info(field:get_name().." ("..field:get_type():get_full_name()..")")
    end
end
```
Two field traps, both hit in practice:
- **Type before action.** A "force this field to identity" probe that doesn't
  filter by field type silently no-ops on non-rotation fields (a `pcall`'d
  type-mismatched write fails quietly). A batch of "no effect" results needs a
  second look at *which fields were even the right type*.
- **Legitimately `nil` under some states.** A per-frame IK/correction target
  field may only exist while the character is in a specific pose context (arm
  colliding with geometry, weapon drawn/aiming). `nil` on a dump ≠ irrelevant —
  re-test under the exact game state the effect needs, not just "player exists."

## 5. Hooks & frame timing
- **`sdk.hook_method`** hooks any TDB method: a **pre-hook** sees/edits the
  args and can `return sdk.PreHookResult.SKIP_ORIGINAL` to suppress the call; a
  post-hook sees the return.
- **`re.on_pre_application_entry` / `re.on_application_entry`** hook named
  engine application steps (frame phases) — the standard "before/after this
  engine stage each frame" callbacks.
- **Same-frame ordering is a real class of bug.** Writing a value once per
  frame (a bone rotation, a field) is only half a fix if something reads it
  *later the same frame* (an IK solve, a derived aim vector). Two callbacks
  that both fire "before rendering" can still fire in the wrong order relative
  to each other. **Measure, don't guess:** sample the same value at an early
  and a late hook in one frame and compare — if they disagree, something
  between them changed it (your ordering bug, now measured); if they agree and
  the effect is still wrong, it's not a timing bug on *this* value — go back to
  "is this even the right value."

## 6. Camera & player-position gotcha (VR-specific, cost real hours)
- **The render camera's `WorldMatrix` is NOT a faithful proxy for the player's
  real physical orientation.** Reading the camera's world matrix and extracting
  position + forward/right/up to project an offset or reconstruct a hand
  position *happens to line up* while the player faces their calibration
  direction, then **silently diverges the instant they physically room-scale
  turn** (camera smoothing / recentering / the VR layer's composition mean it
  reflects where the in-game view points, which includes artificial
  locomotion, not raw play-space tracking).
- **Fix:** for "where is the player really" questions, use the actual tracked
  controller/HMD pose, never the render camera. (Hit twice in this project
  before the pattern was recognized — a helper's own doc comment literally said
  "includes artificial locomotion; not raw play-space tracking.")

## 7. Rendering: per-pass draw flags (first-person head hiding)
- **`via.render.Mesh` has independent per-pass draw flags.** To hide the
  player's head in first person **without** losing its shadow, don't zero the
  head bone (that collapses geometry out of *every* pass — headless shadow).
  Instead: `set_DrawDefault(false)` + `set_DrawShadowCast(true)` (shadow only);
  on RT builds also `set_DrawRaytracing(false)` so the head isn't in ray-traced
  reflections. Reference: praydog's `RE8VR.cpp` `fix_player_shadow()`. Leave
  REFramework's own `HideJointMesh` **off**.
- **Two scan gaps:** `getComponent()` returns only the **first**
  `via.render.Mesh` on a GameObject (eyes/eyelashes are often extra mesh
  components — enumerate **all** components); and face-part name matching must
  cover `face, hair, head, eye, lash, brow, matsuge, beard, mustache, hige,
  tooth, teeth, tongue`.
- **Joint name for the head is `"head"`** — `transform:getJointByName("head")`,
  the string REFramework's own `FirstPerson.cpp` hashes for RE2.

## 8. Animation / motion system
- Locomotion is driven by a **motion-bank selector**, not by picking different
  animation files. In RE2 the locomotion layer plays the **same motion ids from
  the same bank id (1000)** whether armed or unarmed — only the resolved
  animation *name* differs (weapon-variant vs. unarmed-variant prefix). The
  weapon grip lives on a separate layer fed by different bank ids (a "hold"
  bank and a "finger" bank).
- The active-bank list is large (~82 entries) and **byte-for-byte identical
  armed vs. unarmed** — every candidate motlist coexists permanently, several
  sharing bank id 1000. Selection among same-id entries comes from per-bank
  state, exposed as a **`TargetBankType`** property on the motion component.
  Flipping that one narrow switch is how "play unarmed walk while armed" was
  shipped — no file swapping, no weapon-type spoofing (which visibly swaps the
  weapon model).

## 9. "Several lookalike systems, one is live" (a recurring RE2 trap)
- A single weapon can carry **multiple similarly-purposed config tables** for
  what looks like one feature, and tuning the wrong one throws no error and no
  crash — just silence. Concrete case: a revolver's VR reload had **three**
  position systems — the spent-shell *extraction* joint/offset system is
  entirely separate from the new-round *insertion* grab point; meticulously
  debugging the extraction math (correct to four decimals) did nothing to the
  insertion feature being tested. Lesson: before deep-debugging a value, prove
  it's the one the feature you're testing actually reads. Also: some per-weapon
  tables have **missing entries that silently fall back to a hardcoded default
  joint** that's only correct for the *other* weapons sharing the table.

## 10. Logging / probe conventions (kept from the start)
- Every diagnostic script logs under one consistent bracketed tag
  (`[my_script_name]`) so a log with tens of thousands of lines from every
  loaded script greps down to just the relevant ones.
- **Wrap every reflection call in `pcall`.** Native calls into an engine never
  designed for this introspection fail unpredictably (wrong arg count, wrong
  overload, method not supported) — a caught, logged failure beats a script
  that dies silently on line one with only a missing log line as the symptom.
- A live UI status readout reflects only the **last** thing that ran; with
  several buttons/status lines, "it says X" is ambiguous — a screenshot beats
  another round of text description.

## 11. Dead ends & false leads (save future time)
- **Swapping compiled animation files on disk** to change locomotion —
  skeleton-specific binary data, and a file-level hammer for a runtime problem.
  Use the motion-bank selector (§8) instead.
- **Spoofing the equipped-weapon type** to change animations — visibly swaps
  the weapon model too. Wrong altitude.
- **Camera world-matrix as player pose** (§6) — lines up at calibration,
  drifts on physical turning. Use tracked controller/HMD pose.
- **`SurvivorCondition.get_IsDamage` as a "left first person" signal** for
  head-reveal — true for *any* hit (an ordinary punch that never leaves first
  person), so it pops the head on with the camera inside the skull.
- **Camera-to-head distance as a "left first person" signal** — measured
  0.111 m at rest vs. 0.112 m during an actual zombie grab; the camera never
  leaves the head, so no threshold could ever work.
- **Tuning a per-weapon joint table entry that the game silently ignores** (§9)
  — no error, no effect; confirm the value is actually read first.

## 12. External resources
See **[`EXTERNAL-RESOURCES.md`](EXTERNAL-RESOURCES.md)** for the annotated link
list — REFramework, its Lua/API documentation, the EMV Engine toolkit, and
general RE Engine references — that this project's engine-side knowledge draws
on.
