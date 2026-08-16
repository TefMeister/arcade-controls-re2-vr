RESTORE POINT — 2026-08-15, before the "cached FP-hand yaw" experiment in
re2_vr_ik_extention.lua.

WHAT THIS IS
------------
NOT a full autorun/data snapshot like other restore points in this folder —
this one only covers the TWO files actually touched by this experiment:
- reframework\autorun\re2_vr_ik_extention.lua
- reframework\data\re2_vr\re2_vr_ik_extention.json

Do NOT robocopy /MIR this folder over the live reframework\autorun\ or
reframework\data\re2_vr\ — those live folders contain many other files this
restore point doesn't have copies of, and /MIR would delete them. Restore
just these two files individually (see below).

WHY IT EXISTS
-------------
re2_vr_ik_extention.lua's get_fp_style_hand_world_pos() is heavily load-
bearing — its output is published as globals used for hand tracking
throughout the whole mod, not just weapon aiming. Confirmed live (see
re2_vr_hand_head_yaw_coupling_status.md memory) that it re-rotates the
controller's tracking-space offset by the camera's LIVE yaw every frame,
which visibly swings the computed hand position when the player just turns
their head, controller held still. Testing a fix (caching the yaw once
instead of re-reading it live) directly in this file, gated behind a new
`fp_hand_use_cached_yaw` config flag (default false in the code, set to
true in the live JSON for this test) — given how central this function is,
a clean rollback path was created before enabling the experiment, per this
project's standing convention for risky changes.

WHAT CHANGED (exact diff, both reversible by restoring these 2 files)
-----------------------------------------------------------------------
1. re2_vr_ik_extention.lua: added `fp_hand_use_cached_yaw = false` to the
   CFG table, added a `cached_fp_look_rot` local, and changed
   get_fp_style_hand_world_pos()'s look_rot computation to branch on that
   flag (cached-once vs. live-every-frame). All other logic unchanged.
2. re2_vr_ik_extention.json: added `"fp_hand_use_cached_yaw": true` to
   actually enable the experiment for live testing (the code default is
   false — this JSON edit is what turns it on).

HOW TO RESTORE (just these 2 files, not a folder mirror)
------------------------------------------------------------
1. Copy this folder's reframework\autorun\re2_vr_ik_extention.lua over the
   live reframework\autorun\re2_vr_ik_extention.lua.
2. Copy this folder's reframework\data\re2_vr\re2_vr_ik_extention.json over
   the live reframework\data\re2_vr\re2_vr_ik_extention.json.
3. In-game: REFramework menu -> ScriptRunner -> "Reset scripts" (or relaunch).

PowerShell one-liner (run from the game root):
    Copy-Item "_RE2VR_dev_archive\RESTORE_POINTS\2026-08-15_before_fp_hand_cached_yaw_experiment\reframework\autorun\re2_vr_ik_extention.lua" "reframework\autorun\re2_vr_ik_extention.lua" -Force
    Copy-Item "_RE2VR_dev_archive\RESTORE_POINTS\2026-08-15_before_fp_hand_cached_yaw_experiment\reframework\data\re2_vr\re2_vr_ik_extention.json" "reframework\data\re2_vr\re2_vr_ik_extention.json" -Force

EASIER ALTERNATIVE
-------------------
Since this is a single config flag, you can also just skip restoring files
entirely and instead flip `"fp_hand_use_cached_yaw"` back to `false` in the
live reframework\data\re2_vr\re2_vr_ik_extention.json, then Reset Scripts.
That alone reverts to the original live-yaw behavior without touching the
.lua file at all (the .lua file's change is inert when the flag is false).
