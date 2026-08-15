2026-08-13 -- Force-Aim Grip Probe (DEAD END)

Context: real-grip's custom position/rotation math in re2_vr_recoil.lua had produced
several bugs in a row (sign error, wrong reference point, gain, RH roll leak, visual
snap flicker). Investigated whether a more robust alternative existed: force the
native SurvivorCondition.IsHold flag ("is aiming") true while LG alone is held, so the
game's own existing two-handed-aim systems (re2_vr_ik_extention.lua etc., which also
read this flag) would produce the identical pose to genuine RG aiming, instead of
hand-rolled Lua math.

Result: clean negative. Logged ~80 samples of `cond:call("set_IsHold", true)` every
frame while LG-only was held. The call never threw (ok=true every time), but
`get_IsHold()` read back false immediately after, with zero exceptions. For
comparison, genuine RG-held correctly read IsHold=true (line 13393 in that session's
re2_framework_log.txt), confirming the READ side works fine -- only the WRITE never
took effect.

Two possible explanations, not distinguished by this test:
1. `set_IsHold` isn't a real method at all -- REFramework can silently no-op an
   unresolved method call rather than throw, so "didn't error" doesn't prove the
   method exists.
2. IsHold is computed live from raw RG input each time it's read, not backed by a
   simple field a setter could write to.

Either way: forcing this flag via a direct method call does not work. A next attempt
(not tried) could guess at a raw backing-field name for a lower-level `:set_field()`
write instead of a method call -- but this is speculative with no better odds, and the
player chose to go back to refining the custom recoil.lua math instead rather than
chase this further.

Real grip's custom system was fully re-enabled after this probe was retired. See
re2_vr_real_weapon_grip_attempt memory (assistant's memory system) for full history.
