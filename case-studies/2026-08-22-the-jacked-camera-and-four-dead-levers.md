# The jacked camera and four dead levers

**Date:** 2026-08-22 · **Game:** RE2 Remake (RE Engine, REFramework VR + Lua)
**Symptom:** while climbing a ladder in VR (and during heavy-object push
animations), the view consistently turns to the same "wrong" direction —
about 120° off the ladder for one tester — and the body snaps to it when the
climb ends.

## The hunt, compressed

A body-yaw guard (snapshot the game's body rotation post-behavior, restore it
at the render-side write points) fixed the *body* twisting on ladders. The
tester then clarified the felt symptom was the **view**: body climbed fine,
but the view sat 120° off, always the same amount, hands following the view.

Instrumenting the angle between rendered-camera forward and body forward
(`rel`) told the story in three acts:

1. `rel` sat rock-steady at ~153° during climbs — not noise, an anchor.
2. `vrmod:recenter_view()` dropped it to −21° instantly... and something
   smoothly drove it back to ~153° over ~1.5 s, every time.
3. Splitting the sources ended the mystery:

```
cone: rel=158.0  cam=-22.0  body=180.0  hmd=-22.0  jacked=true
```

`cam ≡ hmd` to a tenth of a degree, with `jacked=true` the whole climb.

## The mechanism

RE Engine calls scripted-animation takeovers ("being grabbed", ladder climbs,
heavy-object pushes) **jacked** (`JackDominator.get_Jacked`). REFramework's
FirstPerson mod (verified in its source) gates two things on jack: body
rotation (stops following the head) and roomscale — but it never touches the
camera. REFramework VR's camera is fundamentally the **raw decoupled HMD
pose**; in normal play the body chasing your head every frame *masks* that.
The moment a jack freezes the body, the mask drops, and your view is your
physical chair orientation versus your room calibration — a constant, which
is why it "always turns the same amount".

## Four levers, all tested live, all dead

1. **`vrmod:set_rotation_offset(q)`** — accepts writes, render path ignores
   them: ~120°/s of correction for 5 s moved the measured angle 0.0°.
2. **Camera transform `set_Rotation`** at the late write points
   (pre-LockScene + PrepareRendering — the points where *pose* writes win) —
   300+ writes per climb, zero effect. The VR view is composed in the VR
   mod's own hooks, not from the camera transform at any point Lua can reach.
3. **`vrmod:recenter_view()`** — genuinely works (instant), then an
   unidentified per-frame re-derivation restores the old yaw reference over
   ~1.5 s and re-wins after every snap.
4. **Writing the body** — works (that's the guard), but while jacked the
   camera doesn't read the body at all, so it can't steer the view.

## Lessons

1. **Split your error signal before fighting it.** One combined angle (`rel`)
   supported three wrong theories. Logging cam / body / hmd yaws separately,
   plus the jack flag, identified the mechanism in a single climb.
2. **`cam ≡ hmd` is a signature.** If the rendered view tracks the raw HMD
   exactly while some state is active, the body/camera coupling you rely on
   elsewhere is switched off — look for the state flag (here: jacked), not
   for a rotating object.
3. **A lever that accepts writes is not a lever that works.** Two APIs
   round-tripped fine and did nothing. Only a measured effect counts.
4. **"Last-word write points" are per-consumer.** PrepareRendering wins for
   skeletal poses because the renderer consumes them after it. The VR
   compositor consumes its own state — the same trick writes into a void.
5. **When every script-side lever is dead and the mechanism is in the
   injected framework itself, stop iterating in Lua.** Next stop is the
   framework's source (find what re-derives the yaw reference) and, if
   there's no exposed switch, a native-level patch.

## Status

Open. Root cause fully characterized; fix requires either an undiscovered
REFramework-side switch (reading VR.cpp next) or a native patch. The body-yaw
guard stays shipped — it genuinely fixes the body half of the symptom.

**Continued (same day):** the source read found the mechanism (in
FirstPerson.cpp, not VR.cpp) and a fifth lever that works — see
[The view anchor and the fifth lever](2026-08-22-the-view-anchor-and-the-fifth-lever.md).
