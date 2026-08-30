# Session notes — 2026-08-19 (work PC, flat-screen only)

Condensed technical record for resuming on the home PC. The full blow-by-blow lives in the project memory ledger.

## 1. Head shadow with an invisible head — SOLVED (flat-screen confirmed)

**Problem:** No way to have a head shadow in first person without the visible head. REFramework FirstPerson's "Hide Joint Mesh" zeroes the head bone matrix (`FirstPerson.cpp`, `update_player_bones()` — praydog's comment: *"Hide the head model by moving it out of view of the camera (and hopefully shadows...)"*). Collapsed geometry disappears from every render pass, shadow map included.

**Solution:** `via.render.Mesh` has independent per-pass draw flags — `set_DrawDefault(bool)` (main view) and `set_DrawShadowCast(bool)` (shadow pass). Setting `DrawDefault=false` + `DrawShadowCast=true` renders the shadow only. Found in praydog's `RE8VR.cpp` `fix_player_shadow()`, where the same flags hide RE8's real body meshes while keeping their shadows. RE2's build has the methods (reflection-verified live), plus `DrawRaytracing` (also handled — the script hides the head from ray-traced reflections by default).

**Iteration that mattered (v2):** first version missed the eyelashes — two scan gaps fixed:
1. `getComponent()` only returns the FIRST `via.render.Mesh` per GameObject; eyelash/eye meshes can be additional mesh components on the same GameObject. Now enumerates all components (`GameObject.get_components` + type-name filter).
2. Auto-target names widened from face/hair to: face, hair, head, eye, lash, brow, matsuge, beard, mustache, hige, tooth, teeth, tongue.

**User-confirmed result (flat-screen):** head gone from view, shadow keeps its head. Reportedly a first for RE2 first-person modding.

## 2. First person during inventory/map — two-track approach (both untested)

The inventory and map screens jump to a third-person camera. User accepts either item-box-style (player invisible) or a frozen/true first-person view.

**Track 1, built:** `re2_vr_menu_hide_player.lua`. While `GUIMaster.get_IsOpenInventory` or `get_IsOpenMap` is true (proven detectors from the holster script), all player + equipped-weapon meshes get `DrawDefault/DrawShadowCast/DrawRaytracing = false`. Originals captured at open, restored at close/disable/script-reset; flags reasserted per frame while open. Sets the global `__vr_menu_player_hidden`; the head-shadow script checks it and stands down while set (otherwise it would repaint a floating head shadow mid-menu and corrupt the capture/restore bookkeeping).

**Track 2, data collection:** `re2_vr_inventory_camera_probe.lua` (read-only). Dumps `app.ropeway.camera.CameraSystem`'s method list once; installs log-only hooks (capped at 8 logs per method) on methods matching request/change/switch/activate/deactivate/push/pop/start/end/begin/finish/set_Busy; on each open/close of inventory, map, and item box, logs `BusyCameraType`, current-controller getters, primary camera name/FOV/position, plus a 1.5 s trailing snapshot window (~5 Hz) to distinguish "camera moved" from "camera swapped".

**Next step after probe data:** diff the item box transition (acceptable behavior) against the inventory transition (bad), identify the trigger method, then selectively suppress menu-triggered camera switches only — the same philosophy as the `openInventoryGetItemMode` vs `openInventory` split from the pickup work.

## Priorities at home (VR)
1. Head shadow in the headset (both eyes, cutscene restore, mirrors).
2. Menu hide in the headset — including the hand-off back to head-shadow on close (newest seam, least tested).
3. Run the camera probe (inventory, map, item box, once each) and save the `[inv_cam_probe]` log lines.

## 3. Door push with hands — probe built (untested)

Goal: push doors open with a hand in VR. No real hand/door collision needed — plan is hand-near-door + forward push gesture (controller `.position`/`.velocity` from `VRControllerManager`, proven by the grenade throw) → fire the game's own door-open path. Class names confirmed to exist in the RE2-RT class dump (alphazolam/RE_RSZ, not guessed): `app.ropeway.GimmickDoorManager` (singleton), `app.ropeway.GimmickDoorController` (per-door, FSM-driven — has a `DoorFsmStateName` type), `app.ropeway.gimmick.action.InteractManager` (singleton, has `ButtonType`).

`re2_vr_door_push_probe.lua` (read-only): "Dump door/interact API" button (fields + keyword-filtered methods for all four door/interact types, singleton existence check); log-only capped auto-hooks on GimmickDoorController + InteractManager open/exec/request-ish methods — open a door normally and the log shows the trigger; "Snapshot nearby doors" button (findComponents scan → per-door name/position/distance-to-player/distance-to-each-hand-joint, plus guarded attempts at state getters). Hand joints resolved by trying l_hand/l_arm_wrist/l_wrist name candidates — the snapshot reports which name worked.

Next session with the log: pick the door-open trigger method, then decide between (a) calling the door's own FSM/open method directly on push, or (b) pulsing the interact input (PlayerActionOrderer PrecedeBits, proven) when the push gesture happens while the door prompt is up.

## 4. Mr. X despawns when evaded — design approved, probe built (untested)

Goal (user request): every scripted Mr. X appearance stays vanilla, but once the player genuinely shakes him he is gone until the next scripted event — no free-roam re-acquisition. Approved design uses the user's own idea: instead of hiding or disabling him, **teleport him to a parking spot outside the RPD front gates** ("locked out of the station" — he stays fully alive, rendered, and colliding, and doubles as an easter egg if anyone walks out front). Because the vanilla Tyrant AI never gives up (it semi-cheats on player position, opens doors, and the game is believed to warp him closer when he falls far behind), the teleport is paired with a pacifier while parked: clear his target/awareness if that is enough, otherwise skip his `EnemyController` update (the proven freeze behind `re2_vr_melee.lua`'s "Disable enemy AI" checkbox). Escape condition: no line of sight + distance threshold + timer (~30 m / ~15 s to start), or a real lost-target AI state if the probe finds one; he only vanishes while off-screen. His GameObject is never destroyed, so scripted events can always reclaim him.

`re2_vr_tyrant_state_probe.lua` (read-only except one user-triggered teleport button): registry pre-hook on `app.ropeway.EnemyController.update` sees every enemy; `em62*` is flagged "LIKELY MR. X" (em6200 = Mr. X body per the community file lists; `em7*` kept as fallback) and `em40*` as "DOG". Tracking an enemy auto-discovers primitive getters/fields across his whole type hierarchy whose names match AI keywords (think/state/target/find/lost/warp/…, capped at 80) and logs value changes only, plus positions every 2 s with "WARP DETECTED" on jumps over 8 m — catching both scripted warps and catch-up teleports red-handed. Buttons: dump fields / components / AI-keyword methods; log-only capped hooks on warp/teleport/appear/vanish/escape/spawn/activate methods. Parking flow: stand outside the gates → "Save player position as parking spot" → "TELEPORT to parking spot" (tries `set_Position`, then `set_UniversalPosition`; logs before/after so the log shows whether he stays, walks back, or gets warped back).

## 5. Replace all dogs with zombies — feasibility confirmed, spawn probe built (untested)

Goal (user request): every dog becomes a zombie, except the cutscene one. Community mods prove the swap is viable (a ModDB "all zombies" mod replaces dogs/Ivy/Mr. X with zombies; a Nexus "Enemy Swap Collection" exists but is DX11-only, i.e. pre-RT build) — those are pak/asset swaps, so the plan here is a runtime swap instead: find the native call that creates an enemy while its kind is still a parameter, and rewrite dog → zombie in a pre-hook before the dog ever exists. Cutscene exclusion gates on spawn context once the hook point is known.

`re2_vr_enemy_spawn_probe.lua` (read-only): resolves the enemy-manager singleton from candidate names (`app.ropeway.EnemyManager` and variants — reported in the log, not guessed), full API dump button (all fields + all methods with param counts), and log-only capped hooks on creation-style methods (create/spawn/generat/instantiat/entry/regist/setup/request/add/born/appear) that decode every argument — managed type names, GameObject names, raw integers. A dog spawn showing an integer argument of 4000 is exactly the rewrite point. Correlate timestamps with the tyrant probe's "NEW ENEMY … << DOG" lines; a field dump on a live dog (tyrant probe button) shows which Kind-ish field holds the 4000.

## Updated priorities at home
1. Head shadow in the headset (both eyes, cutscene restore, mirrors).
2. Menu hide in the headset — including the hand-off back to head-shadow on close.
3. Camera probe: inventory, map, item box once each → save `[inv_cam_probe]` lines.
4. Door probe: dump API, snapshot near a door, open it normally → save `[door_probe]` lines.
5. Tyrant probe (Mr. X section): track him, get chased, escape, save parking spot outside the gates, run the teleport test → save `[tyrant_probe]` lines.
6. Spawn probe: dump manager API, reach a dog area, let dogs spawn, field-dump a DOG-flagged enemy → save `[spawn_probe]` lines.
