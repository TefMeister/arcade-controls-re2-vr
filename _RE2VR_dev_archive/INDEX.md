# Snapshot index (oldest first)

- **2026-08-11_home_baseline_full_snapshot** — full copy of every live file in
  `reframework\autorun\` (27 top-level scripts + `utility\`/`vr\` subfolders) and
  `reframework\data\re2_vr\` (7 config JSONs) as of 2026-08-11, home PC. Not tied to a
  single feature — this is the starting baseline for the archive itself, seeded on the
  day the archive was created.

## `history\` consolidation (2026-08-11)

Everything that previously lived only outside this folder was pulled in the same day
the archive was created — see `README.md` for the full breakdown. Summary:

- `history\releases\` — 10 zips: `ARCADE_CONTROLS_for_RE2_VR_1.0.0.zip` through
  `_v1.3.0.zip` (every shipped version, start to now) + `GripSuppressionVR-v1.0.0.zip`.
- `history\desktop_archive_pre_2026-08-07\` — 713 files, the original unorganized
  project dump from `Desktop\everything Claude re2`.
- `history\github_notes_repo\` — the full `arcade-controls-re2-vr-modding-notes` repo clone
  incl. `.git` history (10 case studies + 1 technique write-up as of this copy).
- `history\transfer_folder_sessions\` — 5 dated session folders (`2026-08-09_home`,
  `2026-08-09_home_2`, `2026-08-09_work`, `2026-08-10_work`, `2026-08-11_work`) plus
  the standing `reference\` docs, merged from both transfer-folder locations.

This is the project's whole known paper trail, start (v1.0.0) to today, in one place.

- **2026-08-11_stale_comment_fix_suppress_supporthold** — `re2_vr_suppress_supporthold.lua`,
  from a sanity-check pass over the live mod files. Fixed a comment that referenced
  `re2_vr_subweapon_force.lua`, a file that no longer exists (renamed/merged at some
  point before this archive existed) — cosmetic only, no functional change. Also from
  this pass: confirmed the `re2_vr_reload_ext_1..5.lua` split, `re8_vr.lua`/
  `re4_vr_crosshair.lua` reference copies, and `VRLight.lua` (separate user-owned Fluffy
  mod) are all legitimate/harmless, not leftover cruft. Left `re2_sharpness_removal.lua`
  in place per player's choice — it's a self-disabled (`if true then return end`) file
  that appears to belong to a different, unidentified mod ("pd-upscaler"), already
  inert either way.

- **2026-08-11_cosmetic_dock_rotation_lock** — `re2_vr_cosmetic_dock.lua` +
  `re2_vr_ik_extention.lua`. Added a hand-rotation freeze to the cosmetic proximity
  dock: previously only the hand's *position* locked to the weapon grip point, rotation
  kept following the real controller (so the hand still visibly moved/twisted even
  while "docked"). Now computes a locked rotation from the muzzle joint's own base
  orientation plus an optional per-weapon pitch/yaw/roll offset (3 new sliders,
  same live-tune/persist pattern as the existing position sliders), publishes it as
  `__vr_cosmetic_dock_hand_world_rot`, and wires it through
  `re2_vr_ik_extention.lua`'s `slide.get_dock_state()` (previously hardcoded to return
  `nil` rotation for the cosmetic-dock path). **Not yet tested in VR** — needs live
  confirmation.

- **2026-08-11_cosmetic_dock_per_character** — `re2_vr_cosmetic_dock.lua`. Player asked
  whether grip values were universal or per-character before starting to tune (they
  weren't — keyed only by weapon ID, shared across every character). Added a 3-tier
  resolver for all 6 grip axes (back/right/up/pitch/yaw/roll): new
  per-character-per-weapon tier (`GRIP_*_BY_CHAR_WP[profile][wp_id]`, using
  `utility/RE2Character.lua`'s `get_active_profile_key()`, same lookup
  `re2_vr_holster.lua` already uses) checked first, falling back to the existing
  weapon-only tier, falling back to the global default. All 18 sliders (6 axes x
  per-weapon/default, now also per-character) now write into the per-character tier;
  the 2 previously-tuned legacy values (wp1000/wp1100 back-offset) are preserved as the
  shared fallback until each character gets tuned individually. UI shows the current
  character name and flags with an inline note when a value is still the legacy
  shared one. **Not yet tested in VR.**

- **2026-08-11_cosmetic_dock_roomscale_fix** — `re2_vr_cosmetic_dock.lua`. Player found
  this live in VR: the dock's trigger point tracked correctly while facing the
  calibration-center direction, but drifted (ended up "behind" the player) after
  physically turning in their room. Root cause: the proximity check compared the
  anchor (a genuine world-space point) against `get_fp_style_hand_world_pos()`, which
  reconstructs hand position relative to camera yaw rather than reading real roomscale
  tracking — correct for matching the native first-person hand rig's own rendering
  elsewhere in this mod, wrong for a true physical-space distance check. Fix: swapped
  priority to try the real tracked position (`get_hand_world_pos`, reads the shared
  `__vr_lh_world` global / raw controller position) first, falling back to the
  camera-relative approximation only if real tracking data isn't available. One-line
  priority swap at both call sites (main frame handler + debug UI panel). Found and
  fixed same VR session as the rotation-lock/per-character work above.

- **2026-08-11_special_holster_shoulder_reanchor** — `re2_vr_holster.lua`. Player
  wanted the special (heavy weapons) holster moved from above-the-head to the left
  shoulder. That slot was HMD/camera-anchored, deliberately restricted to a
  vertical-only offset because sideways offsets were previously found to drift during
  physical (room-scale) turning (same underlying issue class as the cosmetic-dock
  bug above) — moving it sideways under that anchor would have reintroduced the same
  drift. Real fix: re-anchored the special slot to `PLAYER_JOINT.shoulder` (the same
  left-shoulder prop bone the existing long-arm shoulder holster already uses) instead
  of the HMD — a real skeletal joint tracks true body orientation, so all 3 axes
  (not just vertical) are now safe, same proven pattern as the chest zone's earlier
  chest-to-left-hip recalibration. `refresh_special_zone` (near-duplicate of
  `refresh_holster_zone`) was folded into the general-purpose function at both call
  sites; `holster_capture_pose`'s special-case now shares the shoulder joint too, so
  Calibrate captures against the same basis runtime detection uses. Also removed ~7
  now-fully-unused top-level locals (the whole old HMD-pose helper chain) — net
  reduction against this file's Lua-200-local-ceiling pressure, not an increase.
  Reset the special slot's default offset from (0, 0.27, 0) [[old meaning: above the
  head]] to (0, 0, 0) [[new meaning: right at the shoulder joint]] since the axes mean
  something different now. **Requires re-Calibrating the special slot in-game** (existing
  saved per-profile offsets were tuned against the old HMD basis and won't mean the
  same thing under the new joint basis) — not yet done as of this fix.

- **2026-08-11_cosmetic_dock_lg_rg_gate** — `re2_vr_cosmetic_dock.lua`. Even after the
  roomscale-drift fix above, player found the whole proximity-based trigger unreliable
  in live VR testing: inconsistent snap timing, apparent gaze/recenter dependence,
  unreliable release (sometimes needed an extreme pose, sometimes released on its own),
  and a real leak where holding RG alone (weapon readied, no deliberate grab) could
  still nudge the hand if it happened to be near the anchor. Player's own diagnosis and
  requested fix: stop trying to fix hand-proximity detection and replace it entirely
  with a deliberate LG+RG-held gate (matching how this mod's actual weapon gestures --
  pump-action, slide-rack -- were already long since converted from tracked-distance to
  discrete trigger presses for the exact same reliability reason). Implemented: added
  `is_left_grip_pressed()`/`is_right_grip_pressed()` (same `vrc_manager`
  `VRControllerManager`-first, raw `vrmod` fallback pattern `re2_vr_holster.lua` already
  uses), replaced the whole enter/exit-distance hysteresis trigger with
  `is_left_grip_pressed() and is_right_grip_pressed()` feeding the existing smooth
  blend-in/out. Removed the now-fully-unused hand-proximity/camera-relative chain
  (`get_hand_world_pos`, `get_vr_controller_world_pos`, `get_camera_look_quat`,
  `get_fp_style_hand_world_pos`, `FP_HAND_POS_OFFSET`, `vec3_add`, `quat_rotate_vec3`,
  `vec3_dist`) and the `enter_dist_m`/`exit_dist_m` config + sliders -- net reduction in
  top-level locals (57 -> 52). Debug UI panel simplified to show LG/RG/active/blend
  state instead of hand-distance readout. The anchor/rotation computation itself
  (muzzle-joint-relative, per-character sliders) is unchanged -- only the trigger
  condition changed, from measuring proximity to reading deliberate button state.
  **CONFIRMED WORKING live in VR** (player tested and asked for the next escalation,
  see below).

- **2026-08-12_lg_only_gate** — `re2_vr_cosmetic_dock.lua`. Player clarified LG+RG is
  their normal two-handed aiming pose, so the LG+RG gate above was active almost the
  entire time they aimed, not a distinct gesture. Changed to LG alone.

- **2026-08-12_real_weapon_grip_v1** — `re2_vr_cosmetic_dock.lua` +
  `re2_vr_recoil.lua` + `re2_vr_suppress_supporthold.lua`. Player reported the
  LG-gated cosmetic dock still felt "off" (hand visually holds the gun but isn't
  really there) and asked for REAL two-handed holding: the weapon's actual aim
  blended toward the real left-hand position, not just a cosmetic hand placement.
  Full detail + hard requirements in memory [[re2_vr_real_weapon_grip_attempt]] (not
  duplicated here). Restore point saved first at
  `_RE2VR_dev_archive\RESTORE_POINTS\2026-08-12_before_real_weapon_grip_attempt\`
  per player's explicit request, given this touches already-working recoil/IK code.

  Summary of the change: `re2_vr_cosmetic_dock.lua` now does a ONE-TIME rising-edge
  check on LG press (real hand distance to the foregrip anchor) to decide real-grip
  vs. plain sub-weapon-equip, publishes `__vr_real_grip_active` +
  `__vr_muzzle_world_pos`/`__vr_muzzle_world_fwd` (ground-truth muzzle data for
  recoil.lua), and the whole cosmetic hand-lock/blend machinery
  (`tick_dock_blend`/`publish`/`dock` state) was deleted as fully dead code once real
  grip replaced it entirely -- no more "cosmetic-only" middle state.
  `re2_vr_recoil.lua` gained `blend_aim_toward_left_hand()` (new, in
  `patch_ik_target_matrix`'s right-arm branch, gated on real-grip) which rotates the
  weapon's `TargetMatrix` toward the real left hand using a convention-independent
  world-space quaternion delta (`world_look_delta`, via the SAME `angle_axis_quat`
  primitive already proven for recoil pitch/yaw) -- keeps position untouched, degrades
  to a no-op on any failure. The left arm's IK patching is bypassed entirely during
  real grip (`return false`) so the real tracked hand shows through unmodified,
  reversing the pre-existing (unrelated to this feature) "support hand follows
  weapon" behavior that normally applies while aiming. `re2_vr_suppress_supporthold.lua`
  now suppresses the sub-weapon on real-grip too, unified with its existing RG-order
  suppression into one `suppress_active` flag to avoid the two triggers racing over
  the same clear-scheduling state.

  **`re2_vr_recoil.lua` is now at 193/200 top-level locals — 7 of headroom left.**
  Any future addition to this specific file MUST fold into an existing table rather
  than add a new top-level local, or it will hit Lua's hard parse-time ceiling. See
  [[feedback_lua_200_local_ceiling]].

  **Not yet tested in VR at all** — this is a from-scratch feature built on
  investigation + reasoning from proven-working patterns elsewhere in the codebase,
  not verified live. Player explicitly framed this as exploratory ("if it fails, we
  just don't add it").

- **2026-08-12_real_grip_radius_fix** — `re2_vr_cosmetic_dock.lua` +
  `reframework\data\re2_vr\re2_vr_cosmetic_dock.json`. First live test found real
  grip engaging on essentially every LG press regardless of hand position ("LG
  anywhere", plus a small unrelated-looking pump-handle nudge). Added diagnostic
  logging to the rising-edge check (anchor/hand positions, measured distance,
  threshold) rather than guessing at a fix blind. Root cause found directly from a
  second test's log output: NOT a logic bug — `grip_zone_radius_m` was persisted at
  `0.4000000059604645`, the UI slider's max value, almost certainly bumped by
  accident exploring the new panel earlier in the session. 40cm is close enough to
  "wherever the arm casually rests" to explain the symptom exactly; the small pump
  nudge was a side effect of real-grip incorrectly engaging and bypassing the left
  arm's normal IK patching. Fixed using the player's own two real test data points
  (hand away = 0.653m correctly rejected, hand reaching for the foregrip = 0.337m
  correctly accepted, both measured at the buggy 0.4 threshold) — set to 0.22m,
  comfortably between the two with margin on both sides. Also tightened the slider's
  own range from 0.05-0.40 to 0.05-0.30 so a future accidental drag can't reach
  nearly as generous a value again. **Not yet re-tested after this fix.**

- **2026-08-12_real_grip_has_recoil_gate_fix** — `re2_vr_recoil.lua`. Second live
  test: no hand-snap (correct/intentional), but the weapon never actually followed
  the real left hand at all. Real bug: `on_pre_update_ik`'s `if not
  frame_apply.has_recoil then return end` gate only let the whole IK patch (including
  `blend_aim_toward_left_hand`) run during the brief post-shot recoil-animation
  window, never during normal continuous holding/aiming. Fixed:
  `if not frame_apply.has_recoil and not is_real_grip_active() then return end` —
  lets a real grip bypass the gate so the blend runs every frame while held. The
  small pump-handle nudge on any LG press and LG+LT pumping "from anywhere" are
  unrelated pre-existing Pump-module behavior (button-state-only, confirmed via the
  original investigation), not a real-grip symptom. **Not yet re-tested.**

- **2026-08-12_real_grip_wild_spin_paused** — `reframework\data\re2_vr\
  re2_vr_cosmetic_dock.json` only (no code changes this entry). Third live test after
  the has_recoil-gate fix: the gun spun wildly in the right hand, intermittently, with
  LG alone or LG+RG. Player's call: investigate further tomorrow rather than give up,
  but paused the session here — no further code changes made without the ability to
  test them. Safety action: flipped `"enabled": false` in the persisted JSON so the
  whole real-grip pipeline is inert for any casual play before the next session
  (confirmed this fully short-circuits `vr_active()` and therefore everything
  downstream). Full hypothesis list (leading suspect: near-parallel/anti-parallel
  instability in the cross-product rotation-axis computation) in memory
  [[re2_vr_real_weapon_grip_attempt]] — not duplicated here. **Must re-enable before
  resuming testing.**

- **2026-08-13_home_pre_merge_fix_from_work** — snapshot of the STALE inventory
  auto-complete scripts (`re2_vr_inventory_auto_complete.lua`,
  `re2_vr_slot_exchange_probe.lua`, `re2_vr_worlditem_probe.lua`) taken right before
  overwriting them with the real merge-bug fix recovered from a work-PC handoff doc
  (`D:\mega dl\claude work 13.8.26\` + `RE2VR-Pickup-Merge-And-Allowlist-Handoff.md`).
  See [[re2_vr_item_pickup_skip_status]] for the full recovery story — the fix had
  briefly been lost because the old `D:\mega dl\Claude transfer\` protocol never
  captured it; this snapshot exists so the pre-fix (still-broken) state is preserved
  for reference, not because it's worth reverting to.

- **2026-08-14_v1.4.0_auto_pickup_and_rg_lg_latch** — full snapshot of
  `reframework\autorun\` + `reframework\data\re2_vr\` as shipped in v1.4.0. Two major
  threads this session: (1) inventory auto-complete fully resolved — merge-grant fix,
  item-type allowlist, and a new `isBlankSlot`-based gate for the full-inventory
  top-left-slot swap bug, all confirmed live, see [[re2_vr_item_pickup_skip_status]];
  (2) real two-handed weapon grip pivoted away from real-hand-position tracking
  entirely (player's own call — concluded the game's engine will never make hand
  tracking feel non-janky) to an RG+LG button-latch instead: RG+LG held together
  "catches" the native RG-driven cosmetic hand-follow-weapon pose, which then persists
  after RG releases until LG itself is released. Engagement and hold-through-movement
  are confirmed working; a wrist-side misassignment bug (weapon aims backwards when
  looking far off-axis while gripped) was investigated but NOT resolved by end of
  session — two attempted fixes (preferring a cached native right-wrist position,
  then replacing a frozen hand-relative rigid transform with the weapon's own live
  anchor point) both had no effect on the player's final retest. Full blow-by-blow,
  including the abandoned real-hand-tracking era before the pivot, in
  [[re2_vr_real_weapon_grip_attempt]]. **Shipped in v1.4.0 with the real-grip system
  disabled by default** (`re2_vr_cosmetic_dock.json` `"enabled": false`) since it
  activates automatically on ordinary RG+LG two-handing and the unresolved bug would
  otherwise affect normal play for every user, not just people opting into the new
  feature. All code is live in this snapshot regardless, just gated off. **Superseded
  same day by 2026-08-14_removed_before_release_freeze_suspects /
  2026-08-14_v1.4.0_final_shipped_state below** — this snapshot still contains two
  files pulled from the shipped build shortly after, see those entries.

- **2026-08-14_removed_before_release_freeze_suspects** — `re2_vr_slot_exchange_probe.lua`
  and `re2_vr_inventory_confirm_test.lua`, archived here right before deleting them
  from the live install and rebuilding v1.4.0 without them. Player's game hard-froze
  (process alive, fully unresponsive, had to be killed without saving) during/shortly
  after combining two herbs in the inventory menu — reproduced twice. Log analysis:
  the native combine calls themselves completed cleanly with no error, and normal play
  (stick movement, run-toggle presses) continued for a further ~70 seconds afterward
  before the actual freeze — no hooked method logged a "CALLED" without a matching
  "returned" anywhere near the freeze point, so this is NOT a confirmed root cause,
  just a strong correlation (happens specifically around item-combining, which these
  two files wide-net hook) combined with the fact that neither file has ever had any
  player-facing value — pure diagnostic leftovers. Pulled as a precaution before any
  Nexus upload rather than risk shipping a possible cause. If the freeze recurs
  without these two files loaded, they're cleared and the real cause is still
  unidentified — investigate fresh, don't reintroduce these to test blame
  retroactively (they're read-only observers; if the freeze still happens, they were
  never going to explain it anyway).

- **2026-08-14_v1.4.0_final_shipped_state** — `reframework\autorun\` only, taken
  immediately after the above removal + rebuild. This, not
  `2026-08-14_v1.4.0_auto_pickup_and_rg_lg_latch` above, is what's actually in the
  v1.4.0 zip that may get uploaded to Nexus. 49 file entries (51 minus the two removed
  diagnostics).

- **2026-08-14_probe_and_grip_sliders_collapsed** — pre-edit copies of
  `re2_vr_aim_alignment_probe.lua` and `re2_vr_cosmetic_dock.lua`, taken right before
  disabling/collapsing their UI at the player's request. Neither was deleted, both are
  still functionally live:
  - `re2_vr_aim_alignment_probe.lua`: `auto_capture_on_aim` flipped from `true` to
    `false` — it was silently logging a burst of frames to `re2_framework_log.txt`
    every single time the player aimed, in every normal play session, not just while
    actively diagnosing the still-unresolved "gun points left after spine
    straightening" issue (see `re2_vr_torso_twist_status` memory). Kept, not removed,
    since that issue is still open and this is the tool that diagnoses it. UI collapsed
    behind an `imgui.tree_node`.
  - `re2_vr_cosmetic_dock.lua`: the per-weapon/per-character grip-offset sliders
    (`grip_back_from_muzzle_m`/`right`/`up`/pitch/yaw/roll) were NOT disabled or
    removed — confirmed still load-bearing: `re2_vr_recoil.lua`'s RG+LG support-hand
    latch (`patch_support_hand_ik_target`) reads the anchor position/rotation these
    sliders feed (`__vr_grip_anchor_world_pos`/`_rot`) every frame RG is released but
    the latch still holds LG, i.e. exactly the "LG keeps the hand on the gun after RG
    lets go" behavior. Only the UI panel was collapsed behind an `imgui.tree_node` (was
    always-visible before) so it doesn't clutter the default screen; nothing about the
    underlying anchor computation changed.

- **2026-08-14_disable_force_new_item_look** -- `re2_vr_inventory_auto_complete.lua`,
  pre-edit copy taken right before disabling `force_new_item_look`. Player reported a
  SECOND herb-combine freeze (same symptom: heart-monitor HUD still animating, all
  input unresponsive) with the master auto-complete toggle already off (defaulted off
  earlier this session) -- meaning the grant/merge logic (`precombinationItemSub`,
  `exchangeGetItem`, etc.) was never exercised, narrowing the cause to something that
  runs unconditionally. Found it: `install_open_mode_rewrite_hook`'s PRE-hook on
  `NewInventoryDetailBehavior.open` is installed every frame regardless of
  `state.enabled`, and unconditionally rewrites the `mode` argument to `3` ("new item
  card") on every single open -- including merge results, which aren't genuinely new
  items. Corroborating precedent found in this same live codebase:
  `re2_vr_run_state_probe.lua`'s own header documents a prior CONFIRMED full game hang
  from forcing a *different* field (`IsFinish`) on this exact `NewInventoryDetailBehavior`
  class -- i.e. forcing state/flow-control values on this specific native object already
  has a known history of hanging this game. Not proven as THE cause (no smoking gun in
  `re2_framework_log.txt` -- the whole log for this session was only ~5 seconds of
  boot-time hook-install chatter, nothing logged between boot and the freeze either
  time), but it's the only unconditional mod behavior touching the screen that froze, so
  `force_new_item_look` is now OFF by default too, UI updated to flag it as the prime
  suspect. **Next test:** reproduce the herb-combine with this off (now the default) --
  if the freeze doesn't recur, that confirms this hook as the cause; if it still happens
  with every toggle in this file off, the cause is elsewhere entirely (would need to
  audit for other unconditionally-installed hooks touching inventory).

- **2026-08-14_grant_step_concurrency_guard** -- `re2_vr_inventory_auto_complete.lua`,
  pre-edit copy taken right before this fix. Player re-enabled both toggles to test and
  gave a precise step-by-step reproduction: picking up 4 allowlisted items back-to-back
  produced ALTERNATING behavior (some auto-completed after only a manual NIC-close,
  others required full manual confirm+place), then combining 2 herbs froze the game
  (heart-monitor HUD still animating, all buttons unresponsive) -- same symptom as
  the two previous freezes.
  - **Alternating auto/manual explained:** the existing `if state.phase ~= "idle" then
    ... return end` gate in the `getInitializeCursorPosition` hook was already correct
    (skip arming a new pickup if the previous one's automation is still mid-sequence)
    but logged nothing, so a fast pickup sequence looked like unexplained inconsistent
    behavior. Now logged.
  - **Real bug found and fixed:** `do_grant_step` -- the function that actually calls
    `exchangeGetItem`/`precombinationItemSub` -- was the ONE step in the whole
    grant/close/finish chain that never called `context_still_ours()`, even though
    `do_detail_close_step` and `do_finish_chain_step` right after it both do.
    `get_sub_behaviors()` always fetches the CURRENT live singleton UI objects, not a
    snapshot from arm-time -- if the player moves fast enough that a different screen
    (next pickup, or a merge confirmation) is open by the time this fires (0.5s+ after
    arming), it would blindly act on that new screen using `state.slot_index` captured
    for the OLD item. This is a concrete, real mismatch that fits the reported freeze
    precisely: 4 fast pickups armed/re-armed the sequence repeatedly, then combining
    herbs opened a new screen while a stale grant was still pending, and the stale
    grant fired against the live merge screen with the wrong slot index. Fixed by
    moving `context_still_ours()` above `do_grant_step` and adding the same guard the
    other two steps already have. Both toggles (`enabled`, `force_new_item_look`)
    remain OFF by default -- this fix is unverified until re-tested live.

- **2026-08-14_nic_confirmed_freeze_cause** -- `re2_vr_inventory_auto_complete.lua`,
  pre-edit copy. Player isolated NIC alone (APU fully off) against the actual failure
  scenario (combining two herbs) and it froze again, same symptom. Since APU's entire
  grant/close/finish chain is provably inert with `state.enabled` false, this
  conclusively isolates the freeze cause to NIC's unconditional
  `NewInventoryDetailBehavior.open` mode-3 rewrite -- NOT the `do_grant_step`
  concurrency bug fixed in the previous snapshot (that fix is still believed correct
  and worth keeping, just not the actual cause of these freezes). Matches the
  `IsFinish`-hang precedent documented in `re2_vr_run_state_probe.lua`. Comments and UI
  updated from SUSPECTED to CONFIRMED; `force_new_item_look` stays off, marked
  do-not-enable-for-normal-play. See [[re2_vr_item_pickup_skip_status]] memory for the
  full thread.

- **2026-08-14_v1.3.1_release** -- full `reframework\autorun\`/`reframework\data\`
  snapshot at release time. Player's explicit decision: focus on getting APU
  (auto-pickup) safe and trusted before returning to NIC; NIC stays parked as a
  known-broken opt-in. Packaged as **v1.3.1**, not v1.4.0 -- the v1.4.0 lineage was
  never actually uploaded to Nexus (see [[re2_vr_mod_v1_4_0_release]], superseded by
  this release) and shipped its headline features enabled/risky; v1.3.1 branches
  conservatively off the last-known-good v1.3.0 numbering with all three new/risky
  features (APU, NIC, the RG+LG support-hand latch) OFF by default and clearly labeled
  EXPERIMENTAL in both the UI and the ReadMe.txt changelog. `merge_call_combination_mode`
  (the internal "ISOLATION TEST" toggle) also flipped to `false` by default per the
  player's explicit "everything off" request -- previously defaulted `true`.
  Zip: `ARCADE_CONTROLS_for_RE2_VR_v1.3.1.zip` (`Desktop\Nexus mods\`), 47 file entries,
  built file-by-file per [[re2_vr_fluffy_zip_dir_entry_bug]], verified zero phantom
  directory entries. Note: player then hand-edited `ReadMe.txt` in the staging folder
  themselves after this packaging -- their wording is authoritative going forward, don't
  regenerate/overwrite it from this session's draft if the zip gets rebuilt later.
  Excluded from the shipped zip (kept in live dev `reframework\autorun\` untouched, not
  deleted): `VRLight.lua` (separate third-party mod, per established convention), and
  three dev-only one-shot/read-only diagnostic probes with no player-facing UI or
  ongoing value (`re2_vr_firstpersonmod_probe.lua`, `re2_vr_run_precede_bits_probe.lua`,
  `re2_vr_run_state_probe.lua`) -- same precaution pattern as the two files pulled
  before v1.4.0's build. `re2_vr_aim_alignment_probe.lua` WAS included (kept
  deliberately, collapsed behind a tree_node, still relevant to the unresolved
  spine/aim-alignment issue). `reframework\plugins\REAudio.dll` included (present in
  v1.3.0's staging and live, but missing from v1.4.0's staging -- likely an oversight in
  that never-shipped build, restored here). Static assets (screenshot,
  `re2_fw_config.txt`, `_interaction_profiles_oculus_touch_controller.json`)
  byte-identical between v1.3.0 and v1.4.0 staging, carried forward unchanged. Not yet
  uploaded to Nexus -- player's plan after upload: move on to RG+LG grip feel work, then
  circle back to auto-pickup once it's proven trustworthy.

- **2026-08-14_pickup_bg_investigation_probe_created** -- new file
  `re2_vr_pickup_bg_investigation_probe.lua` (autorun, not yet in any shipped zip).
  Player changed plans after the v1.3.1 packaging: instead of continuing on APU/NIC/RG+LG
  right away, investigate the player's parked idea from
  [[re2_vr_pickup_reuse_itembox_camera_idea]] -- item-box withdrawal never shows the
  disruptive black-screen/blur that regular world-item pickup does, so see if pickup can
  reuse whatever item box already does for its background, instead of trying to fix
  pickup's own blur/zoom camera directly (already a confirmed reflection dead end, see
  [[re2_vr_inventory_bg_tint_status]]). Found two genuinely relevant old probes already
  sitting in `history\desktop_archive_pre_2026-08-07\re2 files\`
  (`re2_vr_itembox_probe.lua`, `re2_vr_itemexamine_probe.lua`) from a 2026-08-07-era
  investigation into a DIFFERENT problem (flashlight/menu-blocking detection gaps) --
  reused their proven `on_pre_gui_draw_element` + `go:read_byte(0x10)` active-element-
  tracking technique verbatim rather than reinventing it. New probe logs: GUIMaster's
  `Ref*UI` fields (confirms `RefInventoryUI` vs `RefItemBoxUI` are genuinely separate
  GameObjects, a real lead found via code read of `re2_vr_holster.lua`'s
  `BLOCKING_GUI_NAMES` list before any live test), context transitions (ITEM_BOX vs
  PICKUP_OR_INVENTORY vs NONE, via the already-proven `isBusyItemBox`/`getItemBoxEnable`/
  `get_IsOpenInventory` getters), a camera/blur field snapshot on each context entry
  (`NewInventoryBehavior`'s `CameraFov`/`DetailCameraFov`/`DetailBlurScale`/
  `DetailBlurMipLevel`, the same fields `re2_vr_inventory_auto_complete.lua`'s parked
  `suppress_blur` experiment already reads/writes), and a read-only observer on
  `NewInventoryDetailBehavior.open` (separate hook instance from the NIC feature's own,
  to confirm whether item box calls this native method at all). Pure read-only, no
  gameplay effect. **Not yet tested live** -- player's next step: open the item box once,
  then pick up a regular world item once, then the log gets read/compared. Syntax-checked
  clean.

- **2026-08-14_pickup_bg_probe_first_result** -- `re2_vr_pickup_bg_investigation_probe.lua`
  run live for the first time. Clean, unambiguous result: `NewInventoryDetailBehavior.open`
  fired exactly ONCE in the whole test, for the regular world pickup -- it never fired at
  all during the item-box interaction. Confirms item box genuinely never engages the
  zoom/blur "detail" screen at all, staying on the grid/slot view (`GuiSlot`/`GuiBack`)
  the entire time -- not a suppressed/hidden version of the same screen, a fully separate
  code path. `GUIMaster.RefItemBoxUI` confirmed as a real, separate field from
  `RefInventoryUI` (91 `Ref*UI`-pattern fields dumped total). GUI element list for the
  ITEM_BOX context: `GUI_ItemBox`, `GuiCaption`, `GuiSlot`, `GuiBack`, `GUI_GeneralGuide`,
  `GUI_MouseCursor` -- test window was short (~4s item box, ~3s pickup) so this isn't
  exhaustive, but the `NewInventoryDetailBehavior.open` finding alone is conclusive on its
  own terms (a hook either fired or it didn't, no ambiguity there).

- **2026-08-14_decouple_suppress_blur_from_apu** -- `re2_vr_inventory_auto_complete.lua`.
  Acted on the probe result above: the file already had an existing, never-properly-tested
  `suppress_blur` toggle that zeroes `DetailBlurScale`/`DetailBlurMipLevel` and matches
  `DetailCameraFov` to normal FOV on `NewInventoryBehavior` -- exactly the fields tied to
  the zoom/blur screen item box was just confirmed to never open. Problem: it only ever
  triggered as a side effect buried inside APU's own arm sequence
  (`if state.enabled then ... if state.suppress_blur then suppress_detail_blur() end`),
  making it impossible to test in isolation from APU's own risk. **Decoupled it
  completely:** trigger moved to `install_open_mode_rewrite_hook`'s PRE-hook (already
  installed unconditionally every frame regardless of APU/NIC, same hook the NIC feature
  uses on the args side -- this only touches the blur/FOV fields, never `open()`'s own
  arguments); restore moved to a new independent `GUIMaster.get_IsOpenInventory()`
  true-to-false transition check in the main `on_frame` loop (same signal the new probe
  already validated live), tracked via its own `last_inventory_open` local, not APU's
  `state.phase`. Now genuinely independent of both APU and NIC -- can be tested completely
  on its own. UI reorganized: this checkbox (labeled `[BG]`) moved to the top of the panel
  with its own explanation, ahead of APU's warning block. Still defaults OFF (untouched
  default), still fully untested against the actual black-screen symptom -- next step is
  the player enabling ONLY this checkbox and picking up a regular item. Syntax-checked
  clean.

- **2026-08-14_suppress_blur_confirmed_dead_end** -- `re2_vr_inventory_auto_complete.lua`.
  Player tested the decoupled `[BG]` toggle alone (APU/NIC both off): "still black and
  unchanged." Checked the log before concluding anything -- confirmed the mechanism
  worked exactly as designed, not a silent failure: checkbox toggle logged, hook fired on
  the next pickup, `"Suppressed detail blur/zoom (was scale=20.0 mip=3.0 detailFov=60.0,
  normalFov=40.0)"` with real captured original values, `"Restored original blur/zoom
  values"` logged correctly on close via the new independent
  `GUIMaster.get_IsOpenInventory()` detection, a second pickup repeated the same pattern
  correctly. **This is a real negative result, not a bug in the decoupling work**:
  `DetailBlurScale`/`DetailBlurMipLevel`/`DetailCameraFov` genuinely do not control the
  VR black screen. Matches the exact same dead-end shape as
  [[re2_vr_inventory_bg_tint_status]]'s `BgBlur`/`ColorScale` findings from a week earlier
  (different fields, same conclusion: numeric write succeeds and reads back correctly,
  zero visual effect) -- strengthens the case that whatever actually renders this is
  shader/render-level, not reachable through REFramework's reflection layer regardless of
  which specific field cluster gets targeted. Comments and UI updated to CONFIRMED DEAD
  END, toggle left in place (harmless, not deleted) but no longer expected to fix
  anything. See [[re2_vr_pickup_reuse_itembox_camera_idea]] for where this leaves the
  investigation -- the only remaining path per this session's `NewInventoryDetailBehavior.
  open` finding (item box never calls it at all) is intercepting/redirecting that call
  itself for regular pickups, a materially bigger, riskier change than adjusting camera
  parameters, and closer to touching pickup mechanics than the player asked for this
  round -- flagged back to the player rather than attempted unprompted. Syntax-checked
  clean.

- **2026-08-14_pickup_camera_investigation_probe_created** -- new file
  `re2_vr_pickup_camera_investigation_probe.lua` (autorun, read-only, not shipped).
  Player's explicit go-ahead: "if you got more ideas, risky or not, let's try them... we
  always have earlier mod versions saved... no risk, just lost time." Both prior
  black-screen angles only ever probed a small, already-guessed set of numeric fields
  (DetailBlurScale/DetailCameraFov, BgBlur/ColorScale) -- this does a broad,
  keyword-filtered (camera/view/capture/scene/render/target/detail) FULL dump of every
  field+method across the whole type hierarchy of `NewInventoryBehavior` and
  `NewInventoryDetailBehavior` on first pickup, plus (separately, via a second
  `on_pre_gui_draw_element` hook reusing the SAME proven "GuiBack" discovery method
  [[re2_vr_inventory_bg_tint_status]] already validated, not a guessed GameObject walk)
  the same for `NewInventoryBackBehavior`'s `BgPanel`/`CapturePanel`/`MainPanel`/`BgBlur`
  sub-objects -- METHODS this time, which neither prior investigation ever looked at
  (both only ever tried writing properties). Goal: find the actual camera-switch/
  capture-trigger mechanism, since the numeric knobs on whatever camera is already
  active are conclusively not it. One-shot dumps (not every frame), pure observation, no
  writes. Also confirmed via existing log output that `re2_vr_firstpersonmod_probe.lua`
  (already in the mod, unused) already ruled out enumerating `firstpersonmod` itself --
  it's a non-reflectable Lua-side proxy (`pairs()` fails) -- so that angle wasn't
  re-attempted. Syntax-checked clean. **Not yet run live** -- next step: pick up one
  regular world item, then read the log for both dump blocks.

- **2026-08-14_pickup_camera_probe_first_result** -- probe run live, real leads found
  neither prior investigation ever touched: `NewInventoryDetailBehavior` has a `MainCamera`
  field (`via.GameObject` -- a real camera object reference, not just a FOV number) plus
  `searchMainCamera`/`getInventoryCameraMatrix`/`updateCameraParam` methods.
  `NewInventoryBehavior` has real trigger methods -- `openDetailDisp`/`closeDetailDisp`/
  `activatePostEffectCapture`/`changePostEffectDetail`/`deactivatePostEffectDetail`/
  `setItemCamera` -- plausibly what actually turns the capture/blur effect on, as opposed
  to the blur/FOV fields (confirmed inert on their own). Also `NewInventoryBehavior.
  CaptureTexture` (`via.render.RenderTargetTextureResourceHolder`) and
  `NewInventoryBackBehavior.RenderTex` (`via.gui.Texture`) -- two SEPARATE render-target
  objects, never inspected before (`RenderTex` for the grid/back view,
  `CaptureTexture` for the detail/zoom view).

- **2026-08-14_pickup_camera_probe2_created** -- new file
  `re2_vr_pickup_camera_investigation_probe2.lua` (autorun, read-only, not shipped).
  Follow-up probe targeting the specific new leads above: (a) hooks the 7 trigger
  methods (`openDetailDisp`/`closeDetailDisp`/`closeDetailOnly`/
  `activatePostEffectCapture`/`changePostEffectDetail`/`deactivatePostEffectDetail`/
  `setItemCamera`/`searchMainCamera`) as pure PRE+POST observers to log call
  order/timing during a real pickup, no writes; (b) dumps `MainCamera`'s GameObject
  name + Transform position + its `via.Camera` component's full type hierarchy, and
  compares against the REAL HMD position via `vrmod:get_position(0)` (same proven
  technique `re2_vr_ik_extention.lua`/`re2_vr_haptics.lua`/`re8_vr.lua` already use) to
  see whether it's a sane VR-aware camera or something degenerate; (c) dumps
  `CaptureTexture`'s own type hierarchy, unfiltered this time (small specific object).
  Syntax-checked clean. **Not yet run live** -- next step: pick up one regular world
  item, then read the log (prefix `[pickup_cam_probe2]`).

- **2026-08-14_pickup_camera_probe2_result** -- probe2 run live (after a false start
  where the player picked up an item before resetting scripts, so the new file hadn't
  loaded yet -- confirmed from the log via boot-sequence timestamps, not guessed).
  `activatePostEffectCapture` fired once on open. `setItemCamera` fired ~11 times in 4
  seconds (~every frame) -- a live per-frame camera driver, not one-shot setup.
  `MainCamera` GameObject name: `"Main Camera"` (legitimate, not a placeholder). Its
  `via.Camera` component confirmed real with standard methods (FOV/clip planes/
  ViewMatrix/ProjectionMatrix/CameraType/ProjectionType/DebugCamera/etc.).
  `CaptureTexture`'s type hierarchy (`via.render.RenderTargetTextureResourceHolder ->
  TextureResourceHolder -> ResourceHolder`) exposes almost nothing reflectable beyond
  `get_ResourcePath` -- dead end for direct inspection via this object's own methods.
  **Flaw caught in the probe's own comparison**: MainCamera's Transform position
  `(36.879, 1.578, -7.519)` was compared against `vrmod:get_position(0)`
  `(0.144, -0.194, 0.182)` -- but the latter is TRACKING-space, not world-space, the
  exact coordinate-space mismatch this project already hit and fixed once before (see
  [[re2_vr_real_weapon_grip_attempt]] memory). Not meaningful evidence of anything
  broken -- corrected in the next probe rather than left as a false lead.

- **2026-08-14_pickup_camera_probe3_created** -- new file
  `re2_vr_pickup_camera_investigation_probe3.lua` (autorun, read-only, not shipped).
  Fixes the coordinate-space comparison (player's real world position via
  `re2.get_localplayer()`'s Transform, matching MainCamera's own coordinate space,
  instead of tracking-space HMD position) and actually READS the `via.Camera`
  properties probe2 only enumerated by name: `FOV`/`NearClipPlane`/`FarClipPlane`/
  `AspectRatio`/`VerticalEnable`/`CameraType`/`ProjectionType`/`DebugCamera`/
  `LookAtDistance`/`LookAtPosition`. Deliberately does NOT guess at a "real gameplay
  camera" comparison API -- no proven accessor for that exists in this codebase, and
  this project has a specific documented lesson against guessing unverified native
  method names blind (the `force_aim_grip_probe` dead end). Syntax-checked clean. **Not
  yet run live** -- next step: pick up one regular item (after confirming scripts are
  actually reset this time), then read the log for `[pickup_cam_probe3]`.

- **2026-08-14_pickup_camera_probe3_result** -- probe3 run live, correct comparison this
  time. `MainCamera` world position `(37.775, 1.577, -14.176)` sits essentially right on
  top of the player's own world position `(37.774, 0.000, -14.162)` -- ~1.577 Y offset
  reads exactly like a normal eye-height offset. `via.Camera` readout: FOV=84.8,
  NearClip=0.01, FarClip=3000.0, AspectRatio=1.1876, VerticalEnable=true, CameraType=0,
  ProjectionType=0, DebugCamera=false, LookAtDistance=8.725. Nothing here reads as
  broken/debug/degenerate -- this is very likely the SAME "Main Camera" used for
  ordinary gameplay rendering (which works fine in VR), not a separate broken examine
  camera. Conclusion: the camera object's own properties are conclusively not the
  differentiator either -- third confirmed dead end for "adjust a reflectable property
  and fix the background" (after BgBlur/ColorScale, then DetailBlurScale/
  DetailCameraFov, now the camera itself). Whatever `activatePostEffectCapture`
  actually does internally is very likely below what Lua reflection can reach.

- **2026-08-14_v1.3.1_uploaded_to_nexus** -- player confirmed the v1.3.1 zip is now
  live on Nexus. Player's plan changed: rather than moving to RG+LG grip-feel work
  next (as previously stated), chose to keep going on the pickup black-screen
  investigation first -- "we have all the time in the world to trial and error stuff"
  now that the mod itself is considered upload-ready as-is.

- **2026-08-14_skip_post_effect_capture_experiment** -- `re2_vr_inventory_auto_complete.lua`.
  First actual BEHAVIOR-changing experiment in this investigation (rounds 1-3 were pure
  read-only diagnostics). New toggle `state.skip_post_effect_capture` (`[BG2]`, default
  OFF): hooks `NewInventoryBehavior.activatePostEffectCapture` and returns
  `sdk.PreHookResult.SKIP_ORIGINAL` when on, so that ONE native call never runs at all.
  Deliberately more surgical than the alternative considered (skipping
  `NewInventoryDetailBehavior.open()` entirely, which the player originally wanted to
  avoid since it would mean touching pickup MECHANICS, not just background) --
  `openDetailDisp`, `open()` itself, the manual confirm/grid flow, `setItemCamera`'s
  per-frame camera drive, and close/`deactivatePostEffectDetail` are all left completely
  untouched either way. Confirmed `sdk.PreHookResult.SKIP_ORIGINAL` is the correct,
  already-proven API name (used extensively elsewhere in this mod -- `re2_vr_recoil.lua`,
  `re2_vr_reload.lua`, `re8_vr.lua`, etc. -- not guessed). Genuinely untested: unknown
  whether skipping this actually stops the black screen, or produces some OTHER visual
  side effect (the 3D item model itself might rely on whatever this effect also sets up).
  UI warns about this explicitly. Syntax-checked clean.

- **2026-08-14_skip_post_effect_capture_result** -- player tested `[BG2]` alone: still
  black, but item model rendered fine otherwise. Verified from the log before trusting
  it (not a mechanism failure): `"activatePostEffectCapture SKIPPED
  (skip_post_effect_capture on)"` fired correctly on both pickups in the test. Fourth
  confirmed dead end. Useful narrowing though: since the item model itself renders
  correctly, the item's own camera/render path is fine in VR -- the failure is isolated
  specifically to the captured/blurred BACKGROUND behind it, pointing at the
  `via.gui.Capture` mechanism itself (`BgPanel`/`CapturePanel`/`MainPanel`, found in
  round 1's dump but never actually read, only enumerated by name).

- **2026-08-14_pickup_capture_probe4_created** -- new file
  `re2_vr_pickup_capture_investigation_probe4.lua` (autorun, read-only, not shipped).
  Reads (does not write) the `via.gui.Capture` component's live state on `BgPanel`/
  `CapturePanel`/`MainPanel`: `CaptureEnable`, `CaptureTextureId`,
  `RenderTargetFormat`, `CaptureAllFrame`, `CaptureAction`, `CaptureRequest`,
  `CaptureStartPosition`, `CaptureSize`, `RenderTargetResource`, `CaptureTexture`.
  Reuses the same proven "GuiBack" GUI-element discovery method as probe4's
  predecessors, not a guessed GameObject walk. Goal: is capture even enabled, does it
  have a valid render target/size, before deciding whether a `set_CaptureEnable(false)`
  write experiment is worth trying -- same observe-before-write discipline as the rest
  of this investigation. Syntax-checked clean.

- **2026-08-14_fix_probe2_get_frame_count_error** -- `re2_vr_pickup_camera_investigation_probe2.lua`.
  Player hit a real script error, correctly flagged rather than ignored: `re.
  get_frame_count()` was called unguarded in probe2's method-call observer hook, and it
  crashed EVERY single time a hooked method fired (repeatedly, including
  `setItemCamera` which fires every frame the detail screen is open). Root cause: this
  codebase has an established guarded pattern for this exact API elsewhere
  (`re2_vr_haptics.lua`, `re2_vr_ik_extention.lua`, `re2_vr_reload_ext_2.lua`/`_4.lua`
  all do `if re.get_frame_count then ... end` first) -- this hook skipped that guard,
  the exact kind of blind-API mistake this investigation's own probe3 comment
  explicitly warned against repeating. Fixed by dropping the frame number from the log
  line entirely (not essential to the diagnostic) rather than reintroducing the same
  risk with a guard. Syntax-checked clean.

- **2026-08-14_pickup_capture_probe4_result_and_probe5_created** -- probe4's dump
  showed `CaptureEnable=false`/`CaptureTextureId=0` across `BgPanel`/`CapturePanel`/
  `MainPanel` -- but the dump fired on the very FIRST sighting of the `GuiBack` GUI
  element ever, which is almost certainly too early (likely scene-load time, not
  actual pickup time) -- not trusted as real evidence either way. Probe4 removed from
  live `reframework\autorun\` (already archived, superseded, not deleted history).
  New file `re2_vr_pickup_capture_investigation_probe5.lua` (autorun, read-only, not
  shipped) fixes the timing: caches the panel references once via the same proven
  `GuiBack` discovery, then defers the actual dump to two correctly-timed moments --
  immediately on `NewInventoryDetailBehavior.open()` firing (the real black-screen
  trigger point, same timing round 2/3 already validated), and again ~30 frames later,
  to see whether `CaptureEnable`/`CaptureTextureId` actually change once the screen is
  genuinely open. Syntax-checked clean.

- **2026-08-14_pickup_capture_probe5_result** -- probe5 ran with correct timing (fix
  confirmed working -- no new `get_frame_count` errors after it loaded), but BOTH
  scheduled dumps (at `open()`, and ~30 frames later) came back "unavailable" -- the
  `"GuiBack"` element was never observed via `on_pre_gui_draw_element` at all during
  this session, despite round 1's probe finding it successfully in an earlier test.
  Real anomaly, not a bug in probe5's logic -- rather than guess why (draw-order
  timing, a different element name for this specific pickup context, etc.), moved to a
  broader sweep instead of patching the same assumption again.

- **2026-08-14_pickup_capture_probe6_created** -- new file
  `re2_vr_pickup_capture_investigation_probe6.lua` (autorun, read-only, not shipped).
  Drops the "GuiBack will appear" assumption entirely -- logs EVERY uniquely-named
  active GUI element seen via `on_pre_gui_draw_element` during a 120-frame window
  armed the instant `open()` fires (~1.3-2s, self-terminating, not indefinite). Same
  "observe everything, don't assume" technique the original `BgPanel`/`CapturePanel`
  discovery and the 2026-08-07 itembox/examine probes both used successfully -- going
  back to ground truth after two consecutive rounds built on an assumption that didn't
  hold up this time. Syntax-checked clean.

- **2026-08-14_pickup_capture_probe6_result_and_extension** -- probe6's sweep ran
  clean: `open()` fired, then 6 elements seen in order --
  `GuiCaption`/`GuiBack`/`WhiteFade`/`BlackFade`/`GuiSearch`/`GUI_GeneralGuide` --
  `GuiBack` appearing just ~2ms (about 1 frame) after `open()`. So round 5's earlier
  "unavailable" result was apparently just bad luck on that one specific test, not a
  real problem with the caching technique. Extended `probe6` in place (rather than
  writing a 7th separate file) to also cache + dump the `via.gui.Capture` state on
  `BgPanel`/`CapturePanel`/`MainPanel` off this now-proven `GuiBack` sighting -- both
  immediately and ~30 frames later, same two-point timing round 5 intended.
  `re2_vr_pickup_capture_investigation_probe5.lua` removed from live (fully superseded,
  already archived, not deleted history). Syntax-checked clean.

- **2026-08-14_pickup_bg_investigation_PARKED** -- probe6's final result confirmed
  `CaptureEnable=false` across `BgPanel`/`CapturePanel`/`MainPanel`, both immediately
  and ~30 frames later (consistent, not a timing fluke) -- these panels belong to
  `NewInventoryBackBehavior`, shared with the manual inventory grid, and being
  confirmed inactive redirects/closes that thread rather than confirming it as the
  cause. Player's explicit decision: park the whole investigation here. Six rounds of
  real, verified elimination, never guessed: `BgBlur`/`ColorScale`, `DetailBlurScale`/
  `DetailCameraFov`, `MainCamera` (legitimate, matches player position),
  `activatePostEffectCapture` (skippable with zero effect, item still renders fine),
  and now the shared Capture panels (confirmed inactive for this screen). The one
  object never successfully read, `NewInventoryBehavior.CaptureTexture`, exposes
  nothing useful via reflection (no width/height/valid check). Conclusion: very likely
  shader/native-rendering level, outside what Lua reflection can reach -- matches
  [[re2_vr_inventory_bg_tint_status]]'s conclusion from a week earlier, now
  quadruple-confirmed from independent angles. Full closing summary written into
  [[re2_vr_pickup_reuse_itembox_camera_idea]] memory. All 5 diagnostic probes + the
  `[BG]`/`[BG2]` toggles remain in live `reframework\autorun\`, inert and off by
  default, kept in case this is ever revisited rather than removed. Player's next idea,
  raised in the same message: investigate not pausing the game during inventory/pickup
  screens at all -- a different angle (gameplay-time freeze, not the render/black
  screen itself), being looked into next.

- **2026-08-14_inventory_pause_investigation_probe_created** -- new file
  `re2_vr_inventory_pause_investigation_probe.lua` (autorun, read-only, not shipped),
  new memory `re2_vr_inventory_no_pause_idea` created (separate topic from the
  parked black-screen investigation, though raised in the same message). Genuinely
  fresh territory -- nothing in this mod has investigated pause/time-scale behavior
  before. Most likely mechanism (untested hypothesis): `via.SceneManager`'s TimeScale
  dropping to 0 while `GUIMaster.get_IsOpenInventory()` is true -- reuses the proven
  singleton-fetch pattern already in `re2_vr_melee.lua`
  (`sdk.get_native_singleton`/`sdk.call_native_func`), not reinvented. Dumps
  `via.SceneManager`'s real methods/fields (time/scale/pause/speed keywords) as ground
  truth, plus a best-effort read of a few plausible getter names cross-checked against
  that real list rather than trusted blind. Logs on every
  `GUIMaster.get_IsOpenInventory()` transition. Syntax-checked clean.

- **2026-08-14_pause_probe_first_result_and_widened** -- probe run live: `via.
  SceneManager` came back with ZERO matching methods or fields at all for
  time/scale/pause/speed -- CONFIRMED wrong, not just unconfirmed. Widened the same
  probe (rather than a new file) to also check `via.Application`, RE Engine's more
  standard global time/speed control class used across many REFramework mods for
  exactly this purpose, using the same proven singleton-fetch pattern. Also added
  "clock" to the keyword list. Syntax-checked clean.

- **2026-08-14_pause_probe_globalspeed_found** -- widened dump ran live: `via.
  Application` has `get_GlobalSpeed`/`set_GlobalSpeed` (also `get_DeltaTime`,
  `get_MaxDeltaTime`, `get_UpTimeSecond`, others -- `GlobalSpeed` is the standout
  candidate for a real global speed multiplier). `via.SceneManager` still confirmed
  empty. The transition log still read `nil=nil` for open/close since the
  candidate-getter list didn't include `GlobalSpeed` by name yet -- fixed, moved to
  first in the list (real, confirmed name now, not a guess). Syntax-checked clean.
  **Not yet re-tested with the real name plugged in.**

- **2026-08-14_globalspeed_ruled_out_and_updatebehavior_probe_created** -- retest
  confirmed `Application.get_GlobalSpeed=1.0` on both inventory open AND close, never
  drops -- ruled out as the pause mechanism. Player confirmed directly (extensive play
  experience, not a guess) that the game genuinely pauses -- enemies stop moving. So
  the pause is real, just not a global clock scalar -- most likely per-system checks.
  New file `re2_vr_inventory_updatebehavior_investigation_probe.lua` (autorun,
  read-only, not shipped) checks whether the engine's own `"UpdateBehavior"`
  frame-pipeline stage (same `re.on_pre_application_entry` hook point already used in
  `re2_vr_recoil.lua`/`re2_vr_holster.lua`) still fires at all while inventory is open
  -- distinguishes "per-object pause, no single lever, likely impractical to patch
  comprehensively" from "centralized native-engine skip, likely still unreachable from
  Lua either way" before spending more time on either path. Syntax-checked clean.

- **2026-08-14_inventory_pause_PARKED** -- probe run live: `UpdateBehavior` fired
  ~1,675 times in ~9.5 seconds (~175/sec) with the inventory open near zombies -- the
  pipeline never stops, runs continuously the whole time. Confirms the pause is NOT
  centralized -- no single flag/clock, each system (zombie AI, possibly others)
  individually checks something like `GUIMaster.get_IsOpenInventory()` and skips its
  own logic every frame. Player accepted this as parking the investigation: removing
  the pause would mean finding and patching every individual system that does this,
  unknown count/coverage, much bigger/riskier than anything else this session, and a
  genuine gameplay/difficulty change rather than a technical fix. All 3 probes from
  this thread remain in live `reframework\autorun\`, inert, kept for reference.

- **2026-08-14_pickup_fade_investigation_probe_created** -- new file
  `re2_vr_pickup_fade_investigation_probe.lua` (autorun, read-only, not shipped), new
  memory `re2_vr_pickup_fade_idea` created. Player's next idea after parking both prior
  threads: fade the black screen in/out instead of an instant cut. Real lead already in
  hand (not a fresh guess): both round-1 and round-6 probes from the black-screen
  investigation independently logged `"BlackFade"`/`"WhiteFade"` as active GUI
  elements during the exact pickup sequence, never followed up since those probes were
  chasing the render/capture mechanism specifically. Likely native fade-transition
  objects reused from elsewhere (loading screens etc.) -- opacity/color control on a
  GUI panel is a standard, well-supported operation, unlike the native camera/capture
  internals that dead-ended repeatedly in the parked investigation. New probe dumps
  `BlackFade`/`WhiteFade`'s FULL type hierarchy unfiltered by keyword (both the
  GameObject and the raw `element` from the draw callback), since the actual
  alpha/color control's naming is unknown. Syntax-checked clean. **Not yet run live.**

- **2026-08-15_laser_dot_multistage_probe** -- resumed the paused laser/red-dot sight
  drift investigation ([[re2_vr_laser_sight_drift_status]]). Extended the existing
  `re2_vr_laser_dot_probe.lua` (not a new file) with the "next reasoned-but-untried
  step" noted at the pause point: `LaserSightTipPosition` plus the mod's own
  known-accurate aim correlation data now logged at 5 pipeline stages within the SAME
  frame -- PRE/POST `LateUpdateBehavior`, PRE/POST `UpdateJointExpression`, PRE
  `PrepareRendering` -- the identical multi-stage technique `re2_vr_aim_alignment_probe.lua`
  used to pin down spine-correction timing. Burst/frame-gating refactored to a
  `should_log()` flag decided once per frame so N frames of burst means N frames with
  all 5 stages logged, not N log lines split arbitrarily. Existing setter and
  `Stamp.set_Color` hooks left installed unchanged (both confirmed dead twice over,
  harmless to leave running) -- UI text updated to mark them as confirmed-dead rather
  than open questions. Syntax-checked clean. **Untested in VR** -- goal is finding
  WHICH of the 5 stages the tip value's discontinuous garbage-to-tracking jump lands
  between.

- **2026-08-15_laser_dot_flatscreen_ground_truth** -- player tested the multi-stage
  probe flat-screen with spine correction ON (Pre timing, the default) and directly
  confirmed the drift IS visible on flat-screen too -- overturns the old investigation's
  assumption that this was VR-only, and means it no longer needs a headset session to
  diagnose. Also found the actual capture's `crosshair_pos`/`shoot_pos`/`shoot_dir`
  fields were `nil` throughout: `re2_vr_crosshair.lua`'s muzzle/crosshair correlation
  data is gated behind `vrmod:is_hmd_active()` at every call site, so it never
  populated regardless of what was actually broken. Rather than touch the shipped
  crosshair script, `re2_vr_laser_dot_probe.lua` now resolves its own VR-independent
  ground truth -- copied `re2_vr_crosshair.lua`'s `update_muzzle_data()` joint-
  resolution logic verbatim (that logic itself was never VR-dependent, only its call
  site was) to get a real muzzle position + forward direction, then computes the
  actual angular deviation in degrees between the muzzle's true aim direction and
  where `tip` points -- a real number matching how this bug has always been described
  ("30-50 degrees off"), logged per-stage as `dev_deg=`. Also confirmed via the log
  timestamp that the live game session hadn't reloaded scripts since the prior
  snapshot's edit (old single-line format, no `stage=` field) -- flagged to the player
  that Reset Scripts (or relaunch) is needed before the new multi-stage/dev_deg output
  will actually appear. Syntax-checked clean. **Not yet re-tested with the reloaded
  script.**

- **2026-08-15_laser_dot_camera_ground_truth** -- player Reset Scripts and re-ran the
  capture (flat-screen, spine correction ON, Pre timing, ~5s aim). Full 90-frame/
  5-stage burst (450 log lines) analyzed: `dev_deg` (tip vs. the muzzle joint's own
  forward direction) never exceeded 0.31 degrees the entire capture -- `tip` tracks the
  muzzle joint essentially perfectly, so `LaserSightTipPosition` itself is NOT
  internally broken relative to where the weapon mesh is actually pointing. This
  reframes the whole investigation: the visible "points left" symptom is very likely
  NOT a laser-dot-specific rendering bug at all -- it's the MUZZLE JOINT ITSELF (i.e.
  the weapon mesh's actual in-hand pose, driven by arm IK) being misoriented, with the
  dot just faithfully rendering wherever that already-wrong joint points. This would
  also explain why the original 17-mechanism investigation never found a laser-
  specific culprit -- there may not be one. Added a second ground-truth comparison to
  test this directly: `dev_deg_vs_cam`, the angle between the muzzle joint's forward
  direction and the camera's actual look direction (camera forward isn't part of the
  arm-IK chain spine correction disturbs, so it's a real independent reference). If
  `dev_deg_vs_cam` comes back large while `dev_deg` (tip vs. muzzle) stays near zero,
  that confirms the bug is upstream in arm-IK/weapon-mesh pose -- the same class of
  problem `re2_vr_posture_spine_straighten_override.lua`'s manual aim-compensation
  sliders and the original 2026-08-05 Pre/Post hook-timing fix already target, not a
  new laser subsystem to chase. Syntax-checked clean. **Not yet re-tested with
  dev_deg_vs_cam.**

- **2026-08-15_laser_dot_wrist_ground_truth** -- player re-ran the capture; found
  `dev_deg_vs_cam` came back EXACTLY 0.00 across all 450 log lines, too perfect for a
  real independent measurement. Root cause: `get_muzzle_ground_truth()` has a
  camera-forward FALLBACK for "camera type" weapons (`_FireBulletType == 0`) -- this
  weapon apparently used that path, meaning `muzzle_fwd` WAS camera forward by
  construction, making the comparison circular/uninformative, not a real zero-
  deviation finding. Fixed by returning a third value, `src`, on every call so log
  lines now record which path resolved (`joint(fire_type=N)` vs
  `camera_fallback(fire_type=N)`) instead of silently assuming. Also added a second,
  unambiguous ground truth: `get_wrist_ground_truth()` reads `r_arm_wrist` directly
  (the actual joint the weapon mesh is physically skinned to/attached from, and the
  same joint `re2_vr_posture_spine_straighten_override.lua`'s aim-compensation
  sliders already manipulate for this exact symptom) -- nothing camera-locks it, so
  `dev_deg_wrist_vs_cam` (wrist forward vs. camera forward) is a real test of whether
  the visible mesh itself is misaimed, independent of any fire-calculation
  abstraction. **Mid-edit, player directly confirmed the reframe visually without
  even needing the new metric**: "weapon mesh is definitely twisted and the red dot
  is pointing where the weapon is pointing" -- i.e. the mesh itself is twisted, and
  the dot faithfully follows it. This settles the "is it a laser bug or a mesh-pose
  bug" question by direct observation; the new wrist-vs-camera metric is now for
  quantifying/pinpointing the fix, not for settling whether the reframe is correct.
  Syntax-checked clean. **Not yet re-tested with the new metric.**

- **2026-08-15_aim_align_probe_ik_hook_fix** -- with the reframe confirmed (weapon
  mesh itself is twisted, not a laser-dot bug), pivoted to the purpose-built
  `re2_vr_aim_alignment_probe.lua` (auto-capture, previously off by default) instead
  of continuing to extend the laser probe. Player ran a capture (spine correction ON,
  Pre timing, ~5s aim): spine0_y correction confirmed applying correctly (raw
  ~-0.3256 at PRE LateUpdateBehavior -> corrected ~-0.0001 by POST, held through
  PrepareRendering/UpdateJointExpression), but **zero `IkArmFit.updateIk` log lines
  appeared despite the hook being confirmed installed** -- the native method never
  fired during the whole capture. Root cause: `install_ik_hook()` only called
  `get_method("updateIk")`, silently grabbing a single overload; two other scripts in
  this mod (`re2_vr_ik_extention.lua`, `re2_vr_recoil.lua`) both successfully hook
  this same method by iterating ALL methods named `updateIk` via `get_methods()` and
  hooking every one (both log "(2)" on install -- 2 overloads), which is how they
  avoid this exact trap. Fixed `re2_vr_aim_alignment_probe.lua` to match that proven
  approach (iterate all overloads, `get_method` single-overload fallback only if that
  finds zero). Syntax-checked clean. **Not yet re-tested with the fixed hook.**

- **2026-08-15_removed_from_live_autorun** -- player asked to remove two files from
  live `reframework\autorun\` to keep it clean, since neither is currently being
  actively worked: `re2_vr_suppress_sight_attachment.lua` (the laser-drift
  investigation's suppression fallback, no longer the right fix now that the bug is
  understood to be arm-IK/weapon-mesh pose, not laser-specific -- see
  [[re2_vr_laser_sight_drift_status]]) and `re2_vr_ladder_camera_probe.lua` (still
  PAUSED, not abandoned -- see [[re2_vr_ladder_camera_status]]). Both copied here
  before deletion; restore from this snapshot back into `reframework\autorun\` if
  either investigation resumes -- neither is present in the live folder anymore.

- **2026-08-15_hand_head_coupling_probe_created** -- player tested in real VR: with
  Aim Compensation fully OFF (ruling that feature out), the weapon/pointer still
  visibly swings when just turning the HEAD, controller held still. This is a much
  bigger finding than the torso-twist thread -- it's a BASE VR hand-tracking coupling,
  not specific to today's spine-correction or aim-compensation work. Suspect
  identified via code review (not yet confirmed): `re2_vr_ik_extention.lua`'s
  `get_fp_style_hand_world_pos()` (~line 636) takes the controller's real-world
  offset from the HMD (both from `vrmod:get_position()`, which -- based on how the
  raw `get_vr_controller_world_pos()` result is used AS-IS elsewhere in the same file
  as a valid absolute hand position -- appear to already be true world-space
  coordinates) and then RE-ROTATES that offset by the camera's CURRENT/live yaw
  before adding it back to the camera position. If the inputs are already
  world-space, this re-rotation is redundant and wrong -- it would bake live head yaw
  into the hand target a second time, visibly swinging the computed hand position as
  the player turns their head even with the controller held still, exactly matching
  the report. New file `re2_vr_hand_head_coupling_probe.lua` (autorun, read-only, not
  shipped) mirrors that function's exact math step by step (offset, yaw-only
  camera rotation, final hand_pos) with every intermediate value logged, so this can
  be confirmed/denied with real numbers rather than more code-reading. This function
  is heavily load-bearing (published globals used for hand tracking throughout the
  mod), so a live-verified diagnosis is required before any patch is attempted --
  deliberately not touching `re2_vr_ik_extention.lua` yet. Syntax-checked clean.
  **Untested -- next step: player holds the right controller still, turns head
  left/right, checks whether `offset` stays ~constant while `hand_pos` still swings.**

- **2026-08-15_hand_head_coupling_confirmed_standing_origin_check** -- player ran the
  test (right controller held still, ~70s of turning head left/right, yaw swept
  roughly -52 to +57 degrees). Full capture analyzed (12,356 frame-pairs): filtered to
  6,192 pairs where the controller moved <0.5mm frame-to-frame (genuinely still) but
  yaw was changing -- **`hand_pos` still moved in those frames**, averaging ~0.012
  units of movement per degree of yaw change, backing out to an implied offset
  magnitude (~0.68) consistent with the larger `offset` lengths actually observed
  (up to 0.78). This is the expected signature of re-rotating a roughly-fixed vector
  by live head yaw -- CONFIRMED with real numbers, not just code-reading. Correction
  to the original suspect writeup: `ctrl_pos`/`hmd_pos` are NOT already world-space
  (small numbers like 0.25/-0.29/-0.47, clearly a local tracking-space frame -- real
  world coords in this session were ~-12/1.5/-18) -- so the rotation step is likely
  necessary in principle, just probably using the wrong (live, not fixed) yaw source.
  Cross-referenced [[re2_vr_ladder_camera_status]], which independently theorized
  (unconfirmed there too) that `vrmod:get_standing_origin()`'s `w` component is a
  fixed play-space calibration yaw -- added read-only logging of it to
  `re2_vr_hand_head_coupling_probe.lua` to check whether IT stays constant while
  cam_yaw changes (if so, it's the right thing to substitute for the live yaw in
  `get_fp_style_hand_world_pos`). Syntax-checked clean. **Untested -- next capture
  should show whether standing_origin.w holds steady through head turns.**

- **2026-08-15_standing_origin_ruled_out_cached_yaw_experiment** -- player re-ran the
  test (right controller still, ~70s head turning, yaw swept -44.5 to +61.17 degrees).
  `standing_origin` came back EXACTLY identical across all 3,619 samples (one unique
  value: `(0.0420, 0.1268, -0.1808, w=1.0)`) -- confirmed genuinely fixed regardless of
  head yaw, but the value's SHAPE (small x/y/z, w exactly 1.0) looks like a standard
  homogeneous-coordinate position marker rather than a yaw angle -- likely tells us
  WHERE the play-space origin is, not WHICH WAY it's rotated. Ruled out as a usable
  yaw source (or at least not directly, without more work). Pivoted to a simpler,
  self-contained fix: cache the camera's yaw ONCE instead of re-reading it live every
  frame, sidestepping the need to find a "true" native calibration API at all.
  Implemented as an EXPERIMENTAL, default-OFF toggle directly in
  `re2_vr_ik_extention.lua` (`CFG.fp_hand_use_cached_yaw`, new `cached_fp_look_rot`
  local) -- `get_fp_style_hand_world_pos()` branches on the flag: cached-once vs.
  live-every-frame, all other logic unchanged. Enabled via
  `reframework/data/re2_vr/re2_vr_ik_extention.json` (this file has no ImGui panel of
  its own) for live testing. **Given how load-bearing this function is** (published
  globals used for hand tracking throughout the whole mod), created a targeted
  RESTORE_POINT first --
  `RESTORE_POINTS\2026-08-15_before_fp_hand_cached_yaw_experiment\` -- covering just
  the 2 touched files (not a full folder snapshot; see its README for why NOT to
  `/MIR` it). Syntax-checked clean both for the live file and the reconstructed
  restore-point copy. **Untested -- next step: player tests general hand tracking AND
  the original weapon-twist symptom with this flag enabled, watching for regressions
  as well as whether it fixes the head-yaw swing.**

- **2026-08-15_laser_dot_10s_capture_spine_state** -- player tested the wrist-vs-cam
  A/B (spine off then on, aim-triggered 90-frame bursts). Data came back too noisy to
  interpret: `dev_deg_wrist_vs_cam` sat at an oddly large 60-115 degree baseline with
  no clean on/off split -- traced to `wrist_fwd`'s baseline value pointing almost
  straight up (~0.07, 1.0, -0.01), meaning `r_arm_wrist`'s AxisZ convention is very
  likely the forearm's twist/roll axis, NOT "which way the gun points" the way the
  MUZZLE joint's AxisZ is (confirmed/validated) -- an unverified assumption that
  turned out wrong, so that specific metric isn't trustworthy. `dev_deg_vs_cam`
  (muzzle vs. camera, the validated metric) was usable this time since this weapon
  resolved through a real joint (`fire_type=3`, not the camera fallback) but couldn't
  be cleanly split into on/off phases either, since (a) the burst-triggered capture is
  too short (~1.5s) for a deliberate toggle-and-turn-head test and (b) the log had no
  record of when spine correction was actually toggled. Two fixes, both requested by
  the player: (1) added a time-based (`os.clock()`, not frame-count) "Start 10s
  continuous capture NOW" button to `re2_vr_laser_dot_probe.lua`, replacing reliance
  on the short aim-triggered burst for this kind of test; (2)
  `re2_vr_posture_spine_straighten_override.lua` now publishes
  `__vr_spine_correction_enabled` as a global every frame (same pattern
  `re2_vr_holster.lua` already uses for `__vr_is_cinematic_blocking`), and the probe
  logs it as `spine_on=` on every line -- so the on/off boundary is read directly from
  the log, no timing/narration needed. Both files syntax-checked clean. **Untested --
  next step: player presses the new button once, then freely aims/turns head while
  toggling spine correction mid-window, for a clean single-capture A/B using
  `dev_deg_vs_cam` (not the wrist metric, which remains unreliable until its axis
  convention is separately verified).**

- **2026-08-15_laser_dot_camfwd_raw_logged** -- player ran the 10s-capture A/B (spine
  off then on, ~40s off / ~10s on). Result: `dev_deg_vs_cam` showed LARGE swings in
  BOTH phases (off: range 97.3 deg avg 18.6; on: range 50.3 deg avg 21.1) -- no clean
  split, and if anything OFF showed a wider range than ON, opposite the expected
  direction. Root cause: `dev_deg_vs_cam` (gun direction vs. camera direction,
  compared as a snapshot) is fundamentally the wrong metric for this test -- in a
  correctly working system, gun direction and camera direction are SUPPOSED to be
  independent (the whole point of 6DOF hand tracking), so a large absolute deviation
  is normal/expected whenever the player looks somewhere different from where they're
  aiming, regardless of any bug. This is the same category of methodological mistake
  avoided in the earlier, successful hand/head coupling test -- that test worked
  because it correlated FRAME-TO-FRAME CHANGE against camera yaw change (with the
  controller held still), not a snapshot comparison. Fixed by adding `cam_fwd` as a
  raw logged vector (previously only the derived angle was logged) to
  `re2_vr_laser_dot_probe.lua`, enabling the same delta-correlation analysis to be
  applied here. Syntax-checked clean. **Untested -- next capture: hold the weapon
  reasonably steady (not deliberately moving the arm) while turning head, same as the
  successful hand/head coupling methodology, so frame-to-frame muzzle_fwd change can
  be correlated against frame-to-frame cam_fwd change, separately for spine on vs
  off.**

- **2026-08-15_laser_dot_delta_correlation_inconclusive_then_major_correction** --
  player ran the delta-correlation test. Same-frame correlation between muzzle_fwd
  delta and cam_fwd delta came back weak/inconclusive in both phases (r=0.075 off,
  r=-0.055 on -- if anything backwards from expected), too noisy at the per-frame
  level to read. **Major mid-session correction from the player:** the weapon MESH
  itself never visibly moves at all in VR -- only the DOT does; the mesh visibly
  pointing left was a FLAT-SCREEN-only observation. This means the whole session's
  `muzzle_fwd`-based analysis up to this point was actually characterizing a SEPARATE
  flat-screen-only bug (real, and still valid on its own terms -- see
  `re2_vr_torso_twist_status` pass 8 for that finding, ~2.2x yaw-amplitude
  amplification under spine correction), not the VR dot symptom. Player also gave a
  sharp clue: "the dot is where the gun would be pointing if i was playing flat
  screen" -- suggesting `LaserSightTipPosition` may still be driven by a native
  camera-relative convergence calculation never redirected to VR-correct aim.
  Restored `muzzle_pos` to the log line (needed to turn `tip` into a direction) and
  added `dev_deg_tip_vs_cam`, the metric actually relevant to the dot.

- **2026-08-15_spine_timing_logged_confirmed_10x_coupling** -- redo capture using
  `dev_deg_tip_vs_cam`, analyzed via the amplitude-ratio technique (tip direction's
  own yaw/pitch swing vs. camera's own swing during each phase -- the technique
  validated earlier this session for the flat-screen finding). **Clean, dramatic
  confirmation:** spine OFF: tip barely moves at all (yaw ratio ~0.03, pitch ratio
  ~0.04 -- essentially locked regardless of head movement, exactly matching "rock
  stable"). Spine ON: tip swings roughly 10x more (yaw ratio ~0.39, pitch ratio
  ~0.53). This rules out "the dot is always camera-relative by design" (would show
  equally high coupling in both phases) -- the coupling is specifically triggered by
  spine correction being active. Player chose to test hook timing next (Post/Prepare,
  already built into the panel, zero new code) over a "skip redundant writes"
  experiment. Added `__vr_spine_correction_timing` global (same pattern as
  `__vr_spine_correction_enabled`) so `spine_timing=` is now logged automatically --
  no need to track which capture used which timing manually. Both files
  syntax-checked clean. **Untested -- next step: player runs 10s captures at Post and
  Prepare timing (spine correction on) to see if the coupling amount changes with
  hook timing.**

- **2026-08-15_hook_timing_visually_no_improvement** -- player tested Post and Prepare
  live and reported "same thing as far as i can tell by eye" -- the dot STILL visibly
  moves with HMD movement under both timings, despite the amplitude-ratio numbers
  showing a ~10x improvement (matching the spine-off baseline). This is a real,
  important discrepancy, not dismissed: it means `LaserSightTipPosition` (`tip`, the
  field measured all session) is very likely NOT what actually drives the rendered
  dot's position -- consistent with the ORIGINAL 17-mechanism investigation's own
  standing conclusion that `tip` is probably a "downstream readout," not the true
  render source (its setter never fires despite the value changing every frame).
  Today's clean data on `tip` was real, but was apparently measuring a side-channel,
  not the actual cause. Player explicitly chose to KEEP DIGGING for the real
  mechanism rather than fall back to full sight-suppression (the practical fallback
  built earlier this session, archived, still available).

  New diagnostic, genuinely new ground: `dump_full_hierarchy()` added to
  `re2_vr_laser_dot_probe.lua` -- recursively walks the WHOLE weapon and player
  transform tree (all descendants, not just one level), logging every GameObject's
  name and every component's type name at every depth. Real gap identified: the
  original investigation's mechanism 2 ("separate child GameObject -- zero children
  on both") only ever checked DIRECT children, never grandchildren -- if the dot/beam
  VFX lives on a nested child (e.g. an attachment-socket prefab's own child decal
  object), that check would have missed it. Also motivated by the player's own
  earlier observation: the JMB Hp3's laser BEAM stays accurate while the DOT at its
  end doesn't -- meaning they're two separate rendering mechanisms, and finding the
  beam's (working) renderer in the tree could reveal a structurally-adjacent sibling
  responsible for the (broken) dot. Uses the exact `get_Child`/`get_Next`
  linked-list traversal already proven in `re2_vr_holster.lua`'s
  `get_transform_children`/`find_flashlight_on_transform`, not a guessed API.
  Depth-capped (8) and node-count-capped (400) so it can't run away. Read-only,
  one-shot (button-triggered, not per-frame). 37/200 top-level locals in this file,
  plenty of headroom. Syntax-checked clean. **Not yet run live -- next step: aim with
  a sight/laser weapon equipped, press "Dump FULL weapon+player transform tree", then
  read the log for any GameObject/component name suggestive of a laser/dot/decal/
  sprite/billboard renderer not previously found.**

- **2026-08-15_laser_dot_hierarchy_auto_dump_on_aim** -- player raised a valid
  concern before testing the new hierarchy dump: clicking the overlay button while
  physically holding RG in VR means taking a hand off the controller, which could
  disturb the very aim state being measured -- same lesson already documented in this
  mod's `re2_vr_aim_alignment_probe.lua` header. Added auto-trigger: a new checkbox
  ("Auto-dump on next aim start") armed BEFORE aiming, fires `dump_full_hierarchy()`
  itself the instant `SurvivorCondition.IsHold` flips true (same rising-edge pattern
  already used for `auto_capture_on_aim`), then un-checks itself automatically so it
  doesn't spam the log on every subsequent re-aim. No button press needed mid-aim.
  Syntax-checked clean. **Untested -- next step: check the box, let go of the
  overlay, aim normally with a sight/laser weapon equipped -- the dump fires itself.**

- **2026-08-15_laser_sight_controller_dump_added** -- player ran the hierarchy dump.
  Structural bug found and fixed first: `list:call("get_elements")` doesn't work
  (looks up a real reflected method by that name, which doesn't exist, fails
  silently) -- fixed to `list:get_elements()` (direct method syntax, a REFramework
  Lua-binding sugar method, matching `utility/GameObject.lua`'s own proven usage).
  Redo dump came back with real structure: `wp0200` -> `LaserSight` (components incl.
  **`app.ropeway.LaserSightController`**, a genuinely NEW lead never found by either
  investigation session) -> children `Light` -> `effect_LaserSight` (has
  `via.effect.EffectPlayer`, a real VFX/particle player -- plausibly the actual dot
  renderer) and `Line` (plain `via.render.Mesh`, consistent with being the confirmed-
  accurate beam). New diagnostic `dump_laser_sight_controller()` added: finds the
  `LaserSight` child GameObject, gets its live `LaserSightController` instance, dumps
  ALL fields (with live values) and ALL methods across its full type hierarchy,
  unfiltered by keyword. Wired into the same auto-dump-on-aim checkbox as the
  hierarchy dump (both fire together, safely, no button press while holding RG) plus
  its own manual button. Syntax-checked clean, 40/200 top-level locals. **Untested --
  next step: check "Auto-dump BOTH", aim with a sight/laser weapon, read the log for
  `LaserSightController dump:` for any field/method suggestive of the dot's actual
  position/direction source.**

- **2026-08-15_laser_sight_controller_setposition_hook** -- dump result: real,
  promising structure found on `app.ropeway.LaserSightController` --
  `setPosition` method (very likely what positions the dot every frame, especially
  given a `lateUpdate` method is also present), `<PointerEffect>k__BackingField` +
  `get_PointerEffect`/`set_PointerEffect` (very plausibly the dot itself, a
  dedicated field distinct from the already-ruled-out `LaserSightTipPosition` side-
  channel), and `SightEmitJointName = vfx_muzzle3` (the sight's own true emission
  joint -- different from `vfx_muzzle1`/`vfx_muzzle2`, the only names
  `get_muzzle_ground_truth()` ever checked -- a plausible explanation for some of
  today's confusing/contradictory earlier numbers). Also confirms
  `WeaponPartsBits = 4` (bit index 2) IS the correct sight bit for wp0200/JMB Hp3,
  previously flagged as unverified for this weapon.

  Hooked `setPosition`, gated to the same burst/10s-capture window as everything
  else to avoid spam. Read-only: reads `PointerEffect`/`Light`/`Line`'s actual
  world-space Transform position via normal SDK calls on the captured controller
  instance (`ctrl:call("get_PointerEffect")` etc.) both before and after the call,
  NOT raw argument decoding -- same discipline as the earlier `Stamp.set_Color`
  hook (safer than guessing at parsing a value-type `via.vec3` argument out of raw
  hook args). Syntax-checked clean, 42/200 top-level locals. **Untested -- next
  step: use "Start 10s continuous capture NOW" while aiming with the sight/laser
  weapon (ensures the burst-gated hook logging window is active), then read the log
  for `LaserSightController.setPosition CALLED/RETURNED` lines -- does it fire at
  all, and if so, does `PointerEffect`'s position change between before/after in a
  way that correlates with camera direction or spine correction state?**

- **2026-08-15_laser_dot_vfx_muzzle3_and_parent_chains** -- player ran the 10s
  capture (spine off, ~36s window, confirmed genuinely active via normal `stage=`
  logging throughout). `LaserSightController.setPosition` hook confirmed installed
  but ZERO calls logged -- a third confirmed-dead hook (after the WeaponArm setter
  and `Stamp.set_Color`). Reframed conclusion: `setPosition` is very likely a
  ONE-TIME setup call (attach to a joint), not a per-frame recompute -- if so, the
  dot's real position is just ordinary native skeletal parenting, with no
  Lua-hookable per-frame logic involved at all. Two direct follow-ups added to
  `re2_vr_laser_dot_probe.lua`, no more guessing:
  1. `dump_laser_sight_controller()` now also walks `PointerEffect`/`Light`/`Line`'s
     actual Transform parent chain (up to 8 levels, via `get_Parent()`), to see
     exactly what each part is really attached to instead of assuming.
  2. New `get_vfx_muzzle3_ground_truth()` reads the sight's own TRUE emission joint
     (`SightEmitJointName = vfx_muzzle3`, found in the controller dump -- never
     checked before, different from `vfx_muzzle1`/`vfx_muzzle2`) directly by name off
     the weapon transform, logged every stage as `vfx3_fwd=`/`dev_deg_vfx3_vs_cam=`
     so the same amplitude-ratio technique validated earlier this session can be
     applied to it specifically.
  Syntax-checked clean, 43/200 top-level locals. **Untested -- next step: re-run
  dump_laser_sight_controller (auto-dump-on-aim checkbox) to see the parent chains,
  AND re-run the spine on/off 10s-capture A/B to get vfx3_fwd amplitude ratios --
  compare against the muzzle_fwd/wrist_fwd ratios already measured.**

- **2026-08-15_laser_dot_parent_chain_robust_fix** -- two results from the player's
  test. (1) `vfx_muzzle3` amplitude ratio analyzed: OFF yaw/pitch ratio ~0.10/0.07,
  ON ~0.06/0.07 -- essentially IDENTICAL between phases, no dramatic coupling like
  `tip` showed. Real negative result: argues AGAINST "the dot just follows
  vfx_muzzle3 via native parenting" as the sole explanation, since that joint itself
  doesn't show the head-coupling amplification the dot visibly does. (2) The new
  parent-chain dump came back "no transform found" for every getter -- traced to
  `dump_parent_chain` assuming a fixed obj->GameObject->Transform shape that doesn't
  match what these getters actually return (e.g. `PointerEffect` may be a
  `via.effect.EffectPlayer` component directly, not wrapped in a GameObject). Fixed
  to log the RAW RETURNED TYPE first (real info regardless), then try 3 plausible
  shapes in turn (component-with-GameObject, GameObject-with-Transform,
  already-a-Transform) instead of assuming just one. Syntax-checked clean. **Untested
  -- next step: player re-runs just the LaserSightController dump (Reset Scripts,
  auto-dump checkbox, aim) to see the ACTUAL parent chain / returned types this
  time.**

- **2026-08-15_created_effect_container_dump** -- player re-ran the dump with the
  fix. Clean, conclusive result: `get_Light`/`get_Line` both confirmed to return
  real `via.GameObject`s with ORDINARY skeletal parent chains --
  `Light <- LaserSight <- wp0200 <- pl0000` and `Line <- LaserSight <- wp0200 <-
  pl0000` -- exactly the normal weapon-skeleton hierarchy, nothing unusual. Since
  the gun mesh itself is part of this same `wp0200` chain and stays stable, this
  means Light/Line -- and thus the beam and the sight housing -- would stay stable
  too by the same logic. **`get_PointerEffect` returned `via.effect.script.
  CreatedEffectContainer`** -- NOT a GameObject/Transform at all, confirming
  PointerEffect is a wrapper for a dynamically-created VFX effect instance,
  positioned by the effect system's own separate logic, not the transform
  hierarchy Light/Line use. This is the clean structural confirmation the
  investigation needed: the dot (PointerEffect) and the stable parts (Light/Line/
  gun mesh) are definitively different mechanisms.

  New diagnostic `dump_created_effect_container()` added: full field+method dump of
  `CreatedEffectContainer`'s type hierarchy, unfiltered, same pattern as the
  LaserSightController dump. Wired into the same auto-dump-on-aim checkbox (now
  fires all three dumps together) plus its own manual button. Syntax-checked clean,
  44/200 top-level locals. **Untested -- next step: player re-runs the auto-dump
  (now fires all 3), read the log for `CreatedEffectContainer (PointerEffect)
  dump:` -- look for any field/method that could be the effect's actual world
  position/direction source.**

- **2026-08-15_pointer_effect_position_polling** -- `CreatedEffectContainer` dump
  came back with real, promising accessors: `get_effectPositions()` (a direct
  method returning the effect's own live position data), `PositionHolders` (a
  field), `getPositionForEPV`, `get_maxEffectPositionNum`. Rather than hook another
  write event (three previous hooks -- WeaponArm setter, `Stamp.set_Color`,
  `LaserSightController.setPosition` -- all confirmed dead), added
  `get_pointer_effect_world_pos()` to `re2_vr_laser_dot_probe.lua`: POLLS
  `get_effectPositions()` every logged frame (same pattern already used for `tip`),
  sidestepping the need to catch a rare/one-time write entirely. Handles unknown
  return shape defensively (tries `get_elements()` list-sugar first, falls back to
  treating the result as a single vec3-like value). Wired into `log_stage` as
  `pe_pos=` (raw world position) and `dev_deg_pe_vs_cam=` (direction from muzzle vs.
  camera, same technique as `tip`/`vfx3`). Syntax-checked clean, 45/200 top-level
  locals. **Untested -- next step: player re-runs the spine on/off 10s-capture A/B
  (same as before) and this time analyze `pe_pos`'s own amplitude ratio vs. camera,
  the most direct candidate for the dot's actual position source yet.**

- **2026-08-15_effect_positions_shape_probe** -- player ran the A/B capture:
  `pe_pos` came back `nil` for all 7,195 samples across both spine on/off phases --
  neither of the two guessed return shapes for `get_effectPositions()` matched.
  Rather than guess a third shape blind, added `dump_effect_positions_probe()`: a
  proper one-shot diagnostic that logs whether the call itself returns nil, the
  live type name of whatever it does return, whether `get_elements()`/
  `get_Length()`/`get_Count()` succeed, a raw `tostring()` fallback, and also tries
  `getPositionForEPV(0)` directly (a plausible single-item accessor seen in the
  same class dump). Wired into the same auto-dump-on-aim checkbox (now fires all 4
  dumps) plus its own manual button. Syntax-checked clean, 46/200 top-level locals.
  **Untested -- next step: player re-runs the auto-dump-on-aim (all 4 now), read
  the log for `effectPositions probe:` to see the real shape and pick the correct
  accessor for the next iteration of `get_pointer_effect_world_pos()`.**

- **2026-08-15_laser_dot_investigation_paused_roomscale_clue** -- fixed the
  enumerator consumption (`positions live type` was
  `<get_effectPositions>d__12`, a compiler-generated C# iterator state machine --
  `MoveNext()`/`get_Current()` is the correct pattern, not `get_elements()`/
  `get_Length()`/`get_Count()`, which never applied). Re-ran the full spine on/off
  10s-capture A/B with the fix: `pe_pos` was `nil` for all 14,375 samples across the
  entire window, both phases -- a real, consistent negative, not a bug this time.
  Four leads now confirmed dead on `LaserSightController`/`CreatedEffectContainer`:
  the WeaponArm setter, `setPosition`, `get_effectPositions`, and (separately)
  `Light`/`Line` confirmed to be ordinary stable skeletal parenting, not the dot.
  One field remains unchecked: `PositionHolders`.

  Player chose to pause here and resume tomorrow, but gave a critical new
  qualitative clue first (see [[re2_vr_laser_sight_drift_status]] for the full
  quote): the "off" feeling specifically requires BOTH RG held (aiming) AND spine
  correction on -- described as feeling "roomscale'y," like head movement is
  coupled to PRESENCE itself, not just a misplaced UI/VFX element, and "like it
  overwrites something that has been fine-tuned to feel right in VR." This may
  reframe next session's priority from "find the dot's exact render source" to
  "what does RG-hold do to the camera/view when spine correction is active" --
  worth checking camera POSITION (not just aim direction) against spine on/off +
  RG-held state before continuing the `CreatedEffectContainer` field hunt.

  All diagnostic tooling from today's session remains live in
  `reframework\autorun\` (`re2_vr_laser_dot_probe.lua`,
  `re2_vr_hand_head_coupling_probe.lua`, `re2_vr_posture_spine_straighten_override.lua`'s
  new globals), all syntax-checked and snapshotted throughout. Nothing needs
  reverting to resume -- pick up either `PositionHolders` or the camera-position
  idea above.

- **2026-08-15_effect_positions_enumerator_fix** -- probe result was decisive:
  `positions live type: via.effect.script.CreatedEffectContainer.<get_effectPositions>d__12`
  -- the unmistakable signature of a compiler-generated C# ITERATOR STATE MACHINE
  (a `yield return` method), not a list/array at all. Explains every prior failure
  cleanly: `get_elements()`/`get_Length()`/`get_Count()` genuinely don't apply to a
  raw enumerator. Fixed `get_pointer_effect_world_pos()` to use the standard C#
  `IEnumerator` consumption pattern instead: call `MoveNext()`, then read
  `get_Current()` if it returned true. Also extended `dump_effect_positions_probe()`
  to verify this pattern explicitly, walking up to 16 entries (not just the first,
  since `get_maxEffectPositionNum` implied multiple slots) and printing each
  `Current` value plus a vec3-shape check. Syntax-checked clean, 46/200 top-level
  locals. **Untested -- next step: player re-runs the auto-dump-on-aim once to
  verify the enumerator walk produces real position data, then re-runs the spine
  on/off 10s-capture A/B to get real `pe_pos` amplitude data for the first time.**
- 2026-08-16_camera_position_probe -- new diagnostic: re2_vr_camera_position_probe.lua, compares rendered camera pose (sdk.get_primary_camera) vs raw vrmod HMD pose (vrmod:get_position/get_rotation(0)) every frame during a 10s capture, to test whether the banked torso-twist residual sway (footstep-synced, all joints ruled out) is camera-computation vs real head movement
- 2026-08-17_motion_rack_pump_relative_hands_v1 -- NEW FEATURE (v2.0.0 headline, UNTESTED in VR): motion-driven slide rack + pump action layered on top of the confirmed-working LG+LT trigger cycles. New shared M.gesture_motion_ratio in re2_vr_reload_ext_2.lua: dot(P_left - P_right, pull_dir) vs grab-time baseline, so left-hand-back, right-hand-forward, or both all rack/pump identically (weapon translation cancels out of the subtraction). Pull direction comes from the bind-span sample (parked_z -> back_z world vector = "back" by construction) with live joint-axis reads sign-locked to it -- kills the original RE2VRMODRELOADED motion pump's front-to-back inversion class of bug by design. Raw controllers only (get_controller_game_world_pos, now takes "left"/"right"), never __vr_lh_world, which is fed the DOCKED joint pos during racking (feedback loop). Drives the existing state machines via max(LT travel, motion ratio): commit latches when motion physically reaches full travel; completion via the untouched, already-fixed cycle finish (the original's "racking animation did not finish" bug can't recur -- completion logic is the trigger path's). ext_4 cosmetic pump arms needs_pump only at FULL pull, so aim-hold hand drift can never block firing. UI: master toggles + pull-scale sliders in Manual Reload panel (keys read nil-tolerant: merge_cfg replaces slide_dock/manual_pump wholesale, so absent-in-JSON = enabled default). LT path unchanged and coexists. Files: re2_vr_reload.lua (UI), ext_2 (core+rack), ext_4 (pump).
- 2026-08-17_motion_rack_pump_relative_hands_v1 (UPDATE, session end) -- 3 live tests: drive ARMS with healthy parent-frame axis but s==0.0000 EXACTLY (hands read as identical points) through two different sources in turn: (1) ext_1 export hardcoded "left" ignoring its hand arg -- fixed; (2) widened VRControllerManager list read returns identical/zero positions for both entries -- reordered so vrmod:get_controllers()+get_position per hand is primary, list behind zero-guard, deps last -- UNTESTED. Also fixed 1733-exception get_GameObject error storm (0.5s backoff in get_camera_data), rack motion_pull_scale default 2.0 (Matilda span only 2.5cm per live log), HANDS IDENTICAL self-diagnosing guard + [motion_gesture] log lines + in-panel mo_status readout. Resume: one Matilda grab, read [motion_gesture] tail.
- 2026-08-17_motion_rack_deps_hand_arg_fix_source_xray -- THE MISSING HALF OF FIX 1 FOUND BY CODE AUDIT (untested in VR): re2_vr_reload.lua line ~1675 -- the deps wrapper that hands get_vr_controller_world_pos to ext_2 took NO parameters and called reload_mag.get_vr_controller_world_pos() with NO argument, so ext_1's session-end "pass the hand through" export fix was unreachable from ext_2 the entire time: every "right" read through the deps fallback still returned the LEFT controller. This explains why the 2nd live test still showed s==0.0000 after fix 1. Wrapper now forwards the hand arg. Also added a source X-RAY to M.gesture_motion_ratio (ext_2): every 2s while the gesture polls, one [motion_gesture] DUMP line logs ALL candidate providers side by side -- vm[i]=vrmod:get_controllers()+get_position per entry, sg[i]=via.VRControllerManager singleton controllers_list, dp[L/R]=deps export -- plus the chosen lp/rp, per-hand source tags (get_controller_game_world_pos now returns "vrmod_raw>gw" style tags carrying the raw provider through the camera transform), and dlen=|L-R|. ARMED and per-tick lines also log L=/R= source tags and dlen. Next single live test convicts the lying provider no matter which it is. Files: re2_vr_reload.lua, re2_vr_reload_ext_2.lua; both luac -p clean.
- 2026-08-18_motion_confirmed_working_phantom_pull_fix_slide_snap -- MOTION RACK/PUMP CONFIRMED WORKING IN VR (player: "it works!") after the hand-arg wrapper fix; log shows both hands vrmod_raw>gw, dlen varying naturally 0.28-0.58m, ratio sweeping 0->1.00 through real pump cycles. Two behavior fixes on top: (1) ext_4 PHANTOM PULL fire-block -- after complete_pump_cycle the cosmetic gesture auto-reactivates (grip still held) with a rest-posture motion baseline, and ordinary hand drift then reads as a full pull (live log: s drifted +14cm to ratio 1.00 within 1.3s of a completed cycle), arming needs_pump and BLOCKING FIRE + yanking the forend/hand visuals (the player's "hand came off the handle and i could not fire"). New gesture.mo_hold_off: set at completion, cleared by fresh grip PRESS EDGE (last_grip false) or arm_pump_gesture (real shot), gates the motion call only -- LT path untouched. (2) ext_2 Matilda slide now COMPLETES ON FULL PULL: motion drives the pull phase only (not rack.pull_done gate on the max()); at motion-committed pull limit the visual hand detaches immediately (same early-detach as LT release) and travel decays at spring speed to completion -- no push-forward return stroke needed (player had to pull down AND push up before). Pump keeps its physical pull+push cycle on purpose (it is a pump-action). Both luac -p clean, UNTESTED in VR.
- 2026-08-18_hold_slide_release_on_LG_pump_dock_persists -- feel refinements after 2nd live session (player: matilda works + drift-block works). (1) ext_2 Matilda: hold-then-release replaces same-day snap-at-full-pull -- motion holds the slide pinned at full pull while LG is held (max() ungated again, immediate-detach block removed); releasing LG finishes the cycle via should_finish_rack_on_release -> complete_rack_cycle in the grip-release branch, checked AFTER the 0.1s debounce but BEFORE the in-range anti-tremor hold (hard cap is 3.0s and the hand is by definition in range while holding the slide -- that hold protects mid-pull grabs from sensor noise, not a latched pull from its own release). Early release before latch still aborts. (2) ext_4 W870: support dock condition widened needs_pump -> (needs_pump or active) so the hand stays attached to the forend the whole time LG is held ("still lets go after pump handle goes back up") -- after completion the cosmetic gesture is auto-active, and with no pull the existing FP-passthrough branch hands the visual to the native support snap; ik_extention passthrough consumers verified safe (dock-IK write gate only matters while a blend is active). Both luac -p clean, UNTESTED in VR.
- 2026-08-18_lg_release_detach_edge_and_motion_real_pumps_only -- 3rd live session feedback. (1) ext_2 Matilda: hand was riding the slide home after LG release (complete_rack_cycle detached it only at cycle end). Same cure the LT path already had (detach at release EDGE): snap_hand_dock_off now fires the instant grip reads released (pull_done, ahead of the debounce -- zero latency), and instead of calling complete_rack_cycle directly the release FALLS THROUGH with grip off -- the motion drive is now grip-gated (`grip and`), so travel decays at spring speed to the standard completion branch = the LT path's animated return, handless. Early release before latch still aborts via the in-range/hard-cap path. (2) ext_4 W870: PHANTOM PULL SMOKING GUN in live log 2026-08-18 00:34 -- ratio pinned 0.75-1.00 for six straight seconds (pull_m ~0.06-0.10 jitter, dlen ~0.38 static) while the player just held the gun: a drifted baseline held needs_pump armed -> fire blocked, dock yanking the arm pose ("right elbow springs forward", "left hand comes off", "cannot fire"). Fix: motion drives GAME-REQUIRED pumps only (needs_pump or pump_is_real -- set by on_weapon_fired even when the gesture was already active from a cosmetic grip); free racking stays LT-only. Escape hatch: manual_pump.motion_cosmetic_pump=true opts cosmetic motion pumping back in. mo_hold_off kept as post-completion guard. Both luac -p clean, UNTESTED in VR.
- 2026-08-18_always_pumpable_back_phantom_defanged_fp_window_unblock -- night build for tomorrow's test, player's explicit direction: bring back always-able-to-motion-pump ("really really don't wanna give that up"), keep the re-squeeze-LG mechanism they confirmed working. ext_4, 3 changes: (1) reverted the real-pumps-only motion gate (and dropped the motion_cosmetic_pump escape hatch) -- motion pumping always available again, mo_hold_off kept. (2) PHANTOM DEFANGED instead of prevented: a MOTION-only cosmetic full pull no longer arms needs_pump (arming now requires gesture.pump_committed, i.e. a deliberate LT press) -- a drifted-baseline phantom can at worst animate the forend; it can never block firing, and the pull-arm IK dock (needs_pump-gated) never engages to yank the arm. (3) REAL "loses the grip" ROOT CAUSE FOUND: Pump.update_globals set __vr_block_empty_pump_reload_motion for the whole 2.5s post-shot suppress window (pump_window_sec); ik_extention's sync_fp_left_hand_block then BLOCKS FirstPerson left-hand IK whenever needs_pump is false inside that window -- i.e. the instant a fast motion pump completes, the hand floats off the forend for the window's remainder (slow LT pumps mostly consumed the window, hence never noticed). Now gated `and not gesture.active` -- never block the FP hand while the player is actually holding the forend; non-gripping behavior unchanged. Spine-correction link to the weird elbow: player's hypothesis, NOT ruled out -- free A/B tomorrow: toggle the spine straighten off in the REFramework UI, reproduce the pump, compare elbows. luac -p clean, UNTESTED in VR.
