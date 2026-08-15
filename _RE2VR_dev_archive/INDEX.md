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
- `history\github_notes_repo\` — the full `reframework-ai-modding-notes` repo clone
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
