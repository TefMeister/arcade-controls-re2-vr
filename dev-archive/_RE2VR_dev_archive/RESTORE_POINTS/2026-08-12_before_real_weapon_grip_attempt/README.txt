RESTORE POINT — 2026-08-12, before attempting the "real two-handed weapon grip"
feature (weapon aim actually blended toward the real left-hand position, not
just a cosmetic hand placement).

WHAT THIS IS
------------
A full, known-good copy of everything in `reframework\autorun\` and
`reframework\data\re2_vr\` taken immediately before starting a risky,
multi-file experiment. At this point:
- Cosmetic left-hand dock (re2_vr_cosmetic_dock.lua) is LG-gated, rotation-locked,
  per-character tunable, roomscale-drift-fixed. Confirmed working live in VR
  (2026-08-11/12 session).
- Special weapon holster (re2_vr_holster.lua) is re-anchored to the shoulder
  joint, NOT yet re-Calibrated/tested in VR.
- Everything else matches the state described in this session's memory files
  as of this timestamp.

WHY IT EXISTS
-------------
The player explicitly asked for a clean, no-effort-required rollback path
before this attempt, given it touches already-working, delicate code
(re2_vr_recoil.lua's IK/TargetMatrix patching, re2_vr_suppress_supporthold.lua's
LG/RG disambiguation, re2_vr_reload_ext_4.lua's pump gesture) — the explicit
instruction was: if it goes wrong, don't carefully thread a manual undo,
just wholesale restore from here.

HOW TO RESTORE
---------------
1. Copy every file from this folder's `reframework\autorun\` back over the
   live `<game_root>\reframework\autorun\`, overwriting whatever's there.
2. Copy every file from this folder's `reframework\data\re2_vr\` back over
   the live `<game_root>\reframework\data\re2_vr\`, overwriting whatever's
   there.
3. In-game: REFramework menu -> ScriptRunner -> "Reset scripts" (or relaunch
   the game) to make sure nothing from the failed attempt is still loaded
   in memory.

PowerShell one-liner (run from the game root):
    robocopy "_RE2VR_dev_archive\RESTORE_POINTS\2026-08-12_before_real_weapon_grip_attempt\reframework\autorun" "reframework\autorun" /MIR
    robocopy "_RE2VR_dev_archive\RESTORE_POINTS\2026-08-12_before_real_weapon_grip_attempt\reframework\data\re2_vr" "reframework\data\re2_vr" /MIR

Note: /MIR mirrors exactly, meaning it will DELETE any file in the live
folder that isn't in this restore point too (i.e. any new file created
during the failed attempt gets removed, not just overwritten) — this is
intentional, matching "delete everything we created from this point forward."

WHAT HAPPENS TO THE FAILED ATTEMPT'S CODE/FINDINGS
----------------------------------------------------
Per the player's instruction: if this doesn't work out, useful findings
(what was tried, why it failed, any real technical discoveries) get written
up and copied into `_RE2VR_dev_archive\history\` or a new dev-archive
snapshot before the restore happens — so the attempt isn't wasted even if
the feature itself doesn't ship. This restore point folder itself is never
modified after creation; it stays exactly as a rollback target.
