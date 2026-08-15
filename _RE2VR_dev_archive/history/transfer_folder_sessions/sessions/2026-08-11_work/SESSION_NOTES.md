# Session notes — 2026-08-11 (work PC, flat-screen only, no VR access this session)

Four separate threads today. Read the "for home PC" line at the top of each section
first if you're short on time.

---

## 1. Fluffy Mod Manager + FirstNatives — live mod install/uninstall while game runs

**For home PC: set this up there too if you want the same workflow — it's a one-time
per-machine setup, not something that transfers via files.**

Confirmed Fluffy Mod Manager (v3.024, fresh install at `D:\fluffy mm` on this machine)
can install/uninstall **asset mods** (`natives\STM\...` character models/textures) while
RE2 stays running, no relaunch. Requires:
1. REFramework installed (already was, on both machines presumably).
2. `FirstNatives` REFramework plugin — download via Fluffy's own **Downloads menu**
   inside `Modmanager.exe` (also lists REFramework there). Drops into
   `reframework\plugins\`. Confirmed loaded via REFramework menu → PluginLoader →
   "Loaded plugins: FirstNatives, REAudio".
3. Relaunch RE2 once after installing the plugin.

**Important limitation:** this only affects `natives\`-based asset mods that Fluffy
manages. It does **not** apply to `reframework\autorun\` Lua scripts (this mod's actual
VR features) — those still need "Reset Scripts" or a relaunch to pick up changes, same
as always. Also: toggling an asset mod via Fluffy doesn't retroactively update an
already-loaded character mesh in memory — you still need to reload a save (not a full
relaunch) to see the change take effect after toggling.

---

## 2. VR Hands Leon mesh — RT vs Non-RT root cause found and fixed

**For home PC: no action needed, this is resolved. FYI only.**

The `VR Hands Leon (Non-RT)` mod (Fluffy-tracked, replaces `pl0000`/`pl0050`/`pl0070`
Body/Face/Hair meshes) was silently not rendering. Root cause: this RE2 install runs
ray tracing (`PCRaytracingReflection=1` in `re2_config.ini`), and RT character meshes
use a different data format than the DX11-era ones most community mesh mods target. An
RT-compatible build of the same mod fixed it. If home PC's RE2 install also runs RT,
same fix applies there if it ever shows the same "toggle does nothing" symptom.

---

## 3. "Hands-only in gameplay, full body in cutscenes" — investigated thoroughly, CLOSED DEAD

**For home PC: don't restart this investigation from scratch if it comes up again —
three separate technical approaches were tried and ruled out with real evidence, not
guesses. Full detail is in this machine's memory file
(`project_re2_vr_mod.md`, section "VR Hands mesh: RT-format fix confirmed, then
'hands during gameplay / full body during cutscenes' investigated and CLOSED OUT
DEAD"). Condensed version:**

1. **REFramework's native `FirstPerson_HideJointMesh`/`ShowInCutscenes` config** — live
   VR-tested by the user at home earlier: hides the ENTIRE character mesh including
   hands, not selective. Ruled out.
2. **Live mesh-resource swapping via `via.render.Mesh:setMesh()`** — found the real API
   by reflection, found the real `MeshResourceHolder` construction pattern (raw
   `write_qword` memory hack) from `alphazolam/EMV-Engine`'s public source. Implemented
   it correctly per that pattern. **Result: unreliable in practice** — silent partial
   failure, matches an open/unresolved upstream REFramework GitHub issue (#1448)
   describing the same class of problem (invisible meshes, heap allocation failures) on
   other games. Game itself stayed stable, but this reads as real instability risk.
   **Do not retry this technique** without new information changing the risk calculus.
3. **Bone/joint local-scale hiding** — confirmed joint scale IS settable, but dumped the
   full 64-joint skeleton and found arms branch directly off the spine/chest chain, same
   as legs/head branch off separately. There's no way to hide the torso via bone-scale
   without also hiding the arms (a parent's zero scale unconditionally zeroes all
   descendants) — only legs and head could be hidden independently, a fundamentally
   different (and rejected) look from hands-only.

**Current stable state:** VR-Hands mesh (RT-correct version) active at all times,
including cutscenes. Same look in both contexts. No known regressions.

Diagnostic scripts from this investigation were archived (see section 4) rather than
left live — they're closed-dead, not paused.

---

## 4. Cleanup: UI tidiness pass + new standing convention for dev archives

**For home PC: if you sync `reframework\autorun\` from this session's files (listed
below), you're getting the UI-collapsing change described here. Purely cosmetic/
organizational, no feature logic changed. Also: adopt the same `_RE2VR_dev_archive\`
convention on the home PC if you want parity — see below.**

Two things happened:

**A. Archived 5 dead/superseded probe scripts** (moved, not deleted) out of live
`reframework\autorun\`: `re2_vr_mesh_swap_probe.lua`, `re2_vr_mesh_swap_test.lua`,
`re2_vr_bone_hide_probe.lua` (today's dead-end, section 3), `re2_vr_gui_state_probe.lua`
(superseded by `re2_vr_inventory_auto_complete.lua`), `re2_vr_posture_twist_probe.lua`
(superseded by `re2_vr_posture_spine_straighten_override.lua`). Also deleted the
now-orphaned `*_vanilla.mesh.2109108288` loose test files from `natives\`.

**B. Discovered the mod already has a shared UI-dispatch system** — a single guarded
`re.on_draw_ui` (installed once via `_G.__vr_ui_master_installed`) that iterates a
shared `_G.__vr_ui_callbacks` list of `{order, fn}` entries, each script registering its
own `draw_xxx_ui()` function. Most panels were rendering flat/always-expanded though
(only a few used `imgui.tree_node`), which was the real source of UI clutter — not file
count. Wrapped every un-collapsed panel body in
`if not imgui.tree_node("Label") then return end ... imgui.tree_pop()`. Touched 11
files (all included in this session's `reframework/autorun/` folder here):
`re2_vr_worlditem_probe.lua`, `re2_vr_inventory_confirm_test.lua`,
`re2_vr_posture_spine_straighten_override.lua`, `re2_vr_run_toggle_fix.lua`,
`re2_vr_run_state_probe.lua`, `re2_vr_aim_alignment_probe.lua`, `re2_vr_crosshair.lua`,
`re2_vr_haptics.lua`, `re2_vr_recoil.lua`, `re2_vr_holster.lua`, `re2_vr_reload.lua`.

One gotcha handled carefully: `draw_reload_ui()` has 6 separate early-return exit
points, not one — each needed its own `imgui.tree_pop()` before the `return` (a
tree_node/tree_pop pair must balance every frame, or ImGui's ID stack corrupts for the
rest of that frame). All others had a single exit point, confirmed by reading fully
before editing. Verified via automated `tree_node(`/`tree_pop()` count-per-file after
every edit.

**Not yet visually verified in-game this session** (needs a relaunch/Reset Scripts and
opening the REFramework menu to confirm every panel now shows collapsed).

**C. New standing convention: `<game folder>\_RE2VR_dev_archive\`.** User asked for a
permanent, in-game-folder (not the external `D:\RE Modding Tools` location used
before) record of every probe/diagnostic script this project ever creates, kept
regardless of success/failure, so old topics can be revisited without rebuilding
tooling from scratch. Has its own `README.txt`. Going forward, any new probe/diagnostic
script created in ANY future session (either machine) should also get a copy dropped
there under a dated/labeled subfolder — this is a default now, not something to ask
about each time. Consider setting up the same folder+convention on the home PC too if
you want both machines' archives to exist (they don't currently sync with each other —
this is a per-machine local archive, not something this mega folder's protocol covers).

---

## 5. World-pickup-object-not-removed bug — deep dive, PAUSED not solved

**For home PC: this doesn't need VR, and there's a real workaround to use meanwhile —
turn `re2_vr_inventory_auto_complete.lua`'s "Enable auto-complete pickup screen"
checkbox OFF before picking up an item type you already have some of (i.e. only trust
auto-complete for genuinely-new pickups). Use normal manual navigation for merges until
this is fixed. If you want to keep digging, start with the "new lead" below — don't
re-test anything in the "ruled out" list, all of it is confirmed identical between the
working and broken case with real evidence, not guesses.**

Precise repro (confirmed by live testing, narrower than the original 2026-08-10 framing
of "new vs known item"): auto-complete works correctly when the target inventory slot is
**empty** (box despawns). It fails specifically when the pickup needs to **merge into an
already-occupied slot** of the same item type (e.g. a 2nd ammo box while already
carrying that ammo) — box stays in the world, re-interacting toggles the item
add/remove instead of granting cleanly.

**Ruled out this session, each with real evidence (not assumption) — confirmed
IDENTICAL between the working and broken case, so none of these is the cause:**
1. `exchangeGetItem`/`setSlotItem` call success + slot targeting (`CombinedSlotNo`,
   `GetItemSlotNo`, `PreCombineStock` address) — all correctly aligned even in the merge
   case.
2. `SetItem.unregisterSetItem` firing + its full instance field dump before/after —
   byte-identical shape both times.
3. The box's own `GameObject` active-state byte (offset 0x10) — goes `false` and stays
   `false` in BOTH cases, confirmed via a screenshot showing the box still visibly
   rendering while this read `false`. This specific technique doesn't reflect true
   render state for this object type.
4. `via.render.Mesh` boolean fields — there are none, anywhere in its type hierarchy
   (`via.render.Mesh` -> `via.Component` -> `System.Object`). Native state, not
   C#-field-backed (same pattern as the unrelated `MeshResourceHolder` dead end from
   earlier today's mesh-swap thread).
5. `via.render.Mesh.get_ReadyToDraw()` — DOES flip `true -> false` ~1.4s after every
   pickup completes, in **both** the working and the confirmed-still-stuck case (tested
   4 times, one deliberately re-confirmed as visually stuck). Looked promising at first,
   is not the differentiator.
6. `get_PartsEnable`/`get_MaterialsEnable` (per-part/material visibility, 256-slot
   buffers) and their real active-index lists (`*Indices`, e.g. `PartsEnableIndices=
   [0,1]`) — confirmed via actual content reads that these never change during either
   pickup. Static baseline config.

**Reusable technical discovery (not specific to this bug):** RE Engine's
`via.render.Mesh.WrappedArrayContainer_*` types are NOT `.NET` arrays or `List<T>` —
`:get_elements()` and `get_Length`/`get_Item` both fail. They use **IList-style
`get_Count()` + `get_Item(i)`** instead (confirmed via full method dump: `Add`, `Clear`,
`Contains`, `CopyTo`, `Remove`, `get_Count`, `IndexOf`, `Insert`, `RemoveAt`, `get_Item`,
`set_Item`, backed by a single `_object` field). Worth remembering for any future RE
Engine reflection work that hits an "unreadable wrapper object."

**CAUTION, confirmed via an actual crash this session:** REFramework's built-in
DeveloperTools -> GameObjectsDisplay -> **"Enable" checkbox crashes the game to
desktop** (force-enables a bulk set of scene GameObjects at once; crash trace died
inside the Wwise audio engine during that mass-enable; confirmed via
`reframework_crash.dmp` timestamp + process gone). Not related to any of this mod's own
scripts. **Do not toggle that checkbox.**

**New unexplored lead for next session:** `SetItem.onContact` sometimes fires with
`arg1` as `GimmickControl`/`GimmickSoloNullControl`/`GimmickCustomJackControl` instead
of `SetItem` itself — suggesting a higher-level state-machine/controller may take over
after the first interaction. Also unreflected: `SetItem`'s own
`<StayAreaController>k__BackingField` and `<ItemPositionsBehavior>k__BackingField`
sibling components. Either could plausibly own the real despawn logic, since it's now
confirmed NOT to be `SetItem` or its `MeshComponent` alone.

**Scripts** (both included in this folder's `reframework/autorun/`):
`re2_vr_worlditem_probe.lua` (much more capable now than its 2026-08-10 original —
GameObject/mesh watches, wrapper-type reflection, a generic `describe_getter_value`
reader), `re2_vr_slot_exchange_probe.lua` (new this session).

**One process note worth repeating:** twice this session, new Lua helper functions got
inserted *before* the functions they called were defined in the same file, which in Lua
resolves to a nil global instead of the intended local — crashes the script with
`"global 'X' is not callable (a nil value)"`. When adding new local helpers to an
existing autorun file, always insert them *after* every local function they call.

---

## Nothing here is VR-blocked from today's work

Everything above was either resolved without needing VR, or closed out/paused without a
VR dependency. The **older, still-genuinely-paused** threads (aim-alignment fix,
run-toggle fix — both blocked on VR access, from the 2026-08-09 session) are unchanged
by today — see this machine's memory file or the `2026-08-09_work`/`2026-08-09_home`
session folders for those, they're not re-summarized here since nothing about them
changed today.
