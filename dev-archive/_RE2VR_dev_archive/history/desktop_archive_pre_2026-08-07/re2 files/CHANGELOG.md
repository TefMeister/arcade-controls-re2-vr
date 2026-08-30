# RE2 VR Mod — Changes

Files from `reframework/autorun/`, everything touched during this round of
work — including two that ended up reverted/diagnostic-only, included here
for completeness rather than omitted. All changes are additive/opt-in —
existing weapons and behavior not mentioned below are untouched.

## re2_vr_reload_ext_2.lua — Matilda trigger-driven slide-rack, fully fixed

Converted the Matilda's post-reload slide-rack step from hand-tracked
pull-back to trigger-driven (grip the slide, hold LT to pull, release to
finish), opt-in per weapon via `CFG.weapons[wp].trigger_slide_rack = true`
(see re2_vr_reload.lua). Three root causes were found and fixed, all in
`update_slide_rack_trigger()` / `weapon_uses_trigger_rack()` / the hook
wiring — none of the fixes are Matilda-specific, so any weapon opted in via
the flag inherits all of them:

1. **Dual-hook publish race.** The trigger-rack tick runs from both
   `UpdateMotion` and `LateUpdateBehavior` pre-hooks (for higher-frequency
   easing than a single post-entry tick allows). Both calls were publishing
   the hand-follow visual, but only the `LateUpdateBehavior`-timed call
   reliably read a fresh world matrix for the slide joint — the
   `UpdateMotion`-timed call read a stale one, so alternating between them
   every frame looked like the hand teleporting. Fix: added a
   `publish_visual` param, only publish from the `LateUpdateBehavior` call;
   both still advance `trig_travel`/`local_z` every call for the easing.

2. **`M.apply_slide_park()` fighting the trigger write.** This function
   (called every frame via `M.sync_rack_motion()` from 3 more hook sites)
   was never gated with `weapon_uses_trigger_rack()`, unlike its sibling
   functions. It independently computes the slide's `local_z` from
   hand-tracked pull data, and once `pull_done` is true, from the *live
   controller/HMD position* relative to a captured peak
   (`get_push_delta_from_peak`). So for a trigger-rack weapon, real hand
   movement was still driving the slide, racing the trigger-driven writes.
   Fix: `if rack.active and weapon_uses_trigger_rack(wp) then return end`
   right after its `get_slide_joint()` guard — preserves its pre-grab
   "park slide open" display logic, stops it from touching the joint once
   an active trigger-rack cycle is underway.

3. **`trig_committed`/`trig_travel`/`trigger_prev` never reset between
   cycles.** The only two reset points for these fields live inside
   `update_slide_rack_trigger` itself — one is dead code (blocked by the
   wrapper's own `rack.active` gate), the other only fires on an aborted
   grab, never a normal completion. So after the *first* successful
   trigger-rack reload in a session, `trig_committed` stays `true`
   forever — the next grab's very first tick would auto-commit to a full
   pull with zero regard for LT's actual state, playing the whole
   pull-and-release animation on its own. Fix: explicit reset of all three
   fields added to `try_start_rack_gesture`, alongside the resets already
   there for `pull_done`/`pull_max`/`pull_now`.

Confirmed working live by the player across many repeated cycles.

## re2_vr_reload.lua — Magnum opted into trigger-rack; hook wiring for fix #1

- `CFG.weapons.wp3000` (Lightning Hawk / Magnum) gained
  `trigger_slide_rack = true` — one-line mirror of the Matilda's existing
  entry, confirmed working live. No other Magnum-specific changes needed;
  the trigger-rack machinery is fully generic.
- `UpdateMotion`/`LateUpdateBehavior` pre-hook calls to
  `reload_slide.tick_trigger_rack(...)` updated to pass the new
  `publish_visual` boolean (`false`/`true` respectively) — see fix #1
  above.

## re2_vr_holster.lua — LT flashlight toggle + new "special" (4th) holster slot

**Flashlight toggle moved from X to left trigger (LT).** X shared its
physical button with the native menu/back action; `is_menu_blocking()`'s
hardcoded GUI element name/getter lists kept missing custom screens one at
a time (item box, save point/typewriter, a lion-medallion puzzle all hit
the same gap), each one letting X-close-menu also toggle the flashlight.
LT isn't the native menu button at all, so it sidesteps the whole bug
class. Suppressed while either grip (LG or RG) is held. Old X-button code
removed outright (not kept as a disabled fallback, per player preference —
reintroducing X would mean auditing every screen that uses it to exit, not
worth keeping half-built).

**New 4th weapon holster slot ("special"), reusing the old head-reach
flashlight zone.** The flashlight's old reach-gesture zone tracking (kept
running only to suppress accidental native sub-weapon-ready near the head,
after its toggle was replaced by LT) was repurposed into a full weapon
holster slot, drawn/stowed by reaching near the head with the right hand +
RG, identical mechanic to the existing hip (pistol) / shoulder (longarm) /
chest (magnum) holsters. Holds: Chemical Flamethrower (wp4200), Spark Shot
(wp4300), Anti-Tank Rocket (wp4600), Minigun (wp4700) — all four were
previously either miscategorized as "longarm" or fully excluded from
holstering (`EXCLUDED_IDS`). The old accidental-sub-weapon suppression
behavior was dropped per player request (no longer relevant now that
that's a real holster).

Touches: new `SPECIAL_IDS` category + `is_special_slot_weapon()`; renamed
all `head_flash_*` profile/CFG keys to `special_*`
(off_x/y/z, trigger/release_dist, cooldown, zone_haptic_enabled/continuous,
new `special_enabled` master toggle); added `last_special`/`_wp`/`_guid`
profile fields; explicit `"special"` branches added to every slot-dispatch
function that previously only handled pistol/longarm/chest
(`cache_weapon_to_holster_profile`, `reconcile_holster_slot_cache`,
`sync_profile_wp_key`, `resolve_profile_weapon_id`,
`equip_weapon_from_profile`, `validate_cached_weapons`,
`bootstrap_last_weapons`, `track_weapon`, profile-sanitize); new
`refresh_special_zone()` mirrors `refresh_holster_zone` but anchors on
`get_hmd_pose_local()` instead of a skeletal joint (no body joint for
"near your head"); wired into both `refresh_weapon_holster_zones_for_suppress()`
and the main RG-driven on_frame equip/stow block, same
`holster_zones`/`pick_closest_holster_zone`/`HOLSTER_ACTION.pending`
pipeline the other 3 slots already use. UI: new "Special Holster (head)"
block (calibrate/trigger-distance/haptics), flashlight UI simplified to a
plain enable toggle (no longer zone-based, so no calibration needed there).

**Zone position tuning:** default offset is `(0, 0.27, 0)` — straight up
from the HMD, no left/right or forward/back component. This was
deliberate, not arbitrary: any non-zero offset gets rotated by the HMD's
right/up/fwd axes (`holster_pos_with_offsets`), and those axes were found
to drift off the player's actual facing during **physical** (room-scale)
body turning — they track correctly for in-game stick/snap turns, but lag
or misalign on real rotation. A vertical-only offset sidesteps this
entirely (the up axis doesn't have the problem, and left/right/forward/
back offsets — which would — are zeroed out). If this axis-drift is ever
worth fixing properly for some other feature that can't just zero its
offset, start with `get_hmd_pose_local()`/`get_game_world_camera_pose()`'s
right/up/fwd computation — not investigated further here since the
workaround was sufficient.

**Also fixed:** `re2_vr_holster.lua` was sitting at 199/200 of Lua's
hard 200-local-per-chunk ceiling before any of this work (pre-existing,
not caused by these changes) — a script-load-time compile error waiting
to happen on the next unrelated addition. This refactor net *removed*
more dead code (the old flashlight zone's left-hand HMD-relative tracking
helpers, several now-obsolete suppression functions) than it added, so the
file is down to ~186/200 now with real headroom again.

All of the above confirmed working live by the player.

## re2_vr_suppress_supporthold.lua — included for completeness, net UNCHANGED

Included as-is even though the actual content is identical to before this
round of work started. A debounce fix was tried and then explicitly
reverted at the player's request, so there's nothing to actually diff —
worth knowing the attempt happened in case the underlying issue resurfaces:

Player reported the RG+LG sub-weapon-suppression logic (order-based
disambiguation between "two-handing" and "grenade throw", see the existing
comment block at the top of this file) occasionally misfired on a plain,
deliberate RG-then-LG press with no reload/grenade involved — the log
showed `LG already held=true` at the exact moment RG's rising edge was
checked, even though RG was genuinely pressed first. Root cause: the
order check only samples LG's boolean state at the single frame RG's
rising edge is detected — a fast two-handing grab can land both presses
within the same or an adjacent polled frame, making LG read as
"already held" with no way to tell it apart from a genuinely
pre-existing hold.

Fix tried: track LG's own rising-edge timestamp (`os.clock()`), and only
treat LG as "genuinely pre-existing" if it's been held ≥150ms already;
anything shorter (including 0) treated as "arrived together" → defaults
to suppress (two-handing case, the far more common combo). Player asked
for it removed after one round of testing ("remove the timer and we'll
see how it is") rather than confirming or denying whether it helped —
inconclusive, not confirmed broken. If this recurs, the debounce approach
above is the reasoned starting point; don't need to re-derive it from
scratch, just reintroduce the same `left_grip_rising_at`/
`LEFT_GRIP_SIMULTANEOUS_WINDOW` pattern.

## re2_vr_savepoint_probe.lua — diagnostic tool, not a feature

One-off diagnostic script, not part of the delivered feature set. Built to
find the real GUI element name for the typewriter/save-point screen (the
same class of bug `GUI_ItemBox` was for the item box — `is_menu_blocking()`
in `re2_vr_holster.lua` relies on a hardcoded list of guessed screen names/
getters, and this screen's real name was never in it). Made moot by the
flashlight toggle moving to LT (no longer depends on `is_menu_blocking()`
at all), so this was never actually run to completion — the underlying
`is_menu_blocking()` gap for the save point (and a lion-medallion puzzle
screen, also reported) is still open, since `is_menu_blocking()` is also
used by the reload and melee scripts. Safe to delete, or reuse as-is next
time that gap needs chasing — it just logs every active GUI element name
change plus a keyword-filtered dump of `GUIMaster`'s own methods, unfiltered
so it'll catch any screen, not just the save point.
