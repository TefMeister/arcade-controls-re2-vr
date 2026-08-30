2026-08-13 -- Real Grip: position-only aim + visual snap + jitter/roll fixes

Snapshot taken right after re-enabling real grip (re2_vr_cosmetic_dock.json
enabled:true) following the force_aim_grip_probe dead end (see sibling snapshot
2026-08-13_force_aim_grip_probe_dead_end). This is the state about to be live-tested.

Changes bundled in this snapshot (re2_vr_recoil.lua / re2_vr_cosmetic_dock.lua),
building on the earlier same-day sign-flip and pivot-relative reference point fixes:

1. Position-only aim: blend_aim_toward_left_hand now also corrects ROLL (twist around
   the barrel axis), not just pitch/yaw -- previously RH's own tracked orientation
   still leaked through as roll, which a player reported as "I can also point the
   weapon with RH." Second corrective delta rotates ground-truth muzzle_up (newly
   published as __vr_muzzle_world_up) toward world-up projected perpendicular to
   desired_fwd. Guarded against the same ill-conditioned-axis instability that caused
   the original spin bug (skips the correction when the two vectors are nearly
   anti-parallel).

2. Soft visual hand-snap: patch_ik_target_matrix's left-arm branch, when real_grip is
   active, now blends the rendered left hand toward the grip anchor's pose
   (proximity-based, snap_radius_m = 0.22 hardcoded) instead of always showing the
   untouched native pose. AIM MATH is unaffected -- still reads the raw tracked hand
   position. Fixed a discrete-flicker bug (was falling through to a DIFFERENT pose
   source at low blend values, causing a "swap between two locations rapidly" symptom
   a player reported) by always writing the reconstructed pose, never falling through.

3. New published globals from re2_vr_cosmetic_dock.lua: __vr_muzzle_world_up (for the
   roll correction) and __vr_grip_anchor_world_pos/__vr_grip_anchor_world_rot
   (published every frame now, not just at the LG rising edge, for the visual snap).
   The grip_rot_pitch/yaw/roll sliders (previously found completely dead/unused after
   the old cosmetic hand-lock was deleted) are meaningful again as of this change.

Status: syntax-checked clean (luac -p), NOT YET LIVE-TESTED. Player is about to test
this. See re2_vr_real_weapon_grip_attempt memory (assistant's memory system) for full
blow-by-blow history of every bug found so far this session.
