# The view anchor and the fifth lever

**Date:** 2026-08-22 (home-PC headset session) · **Game:** RE2 Remake (RE Engine, REFramework VR + Lua)
**Continues:** [The jacked camera and four dead levers](2026-08-22-the-jacked-camera-and-four-dead-levers.md)

The previous case study ended with every script-side lever dead and a plan:
read REFramework's source to find what re-derives the yaw reference. This is
what the source said, and what happened when we acted on it. Status at the
time of writing: **fix ~85% working, iteration in progress** (view steers to
the interaction but was stopped first by a convention mismatch, then by a
game-side yaw clamp; a closed-loop servo + clamp widening is under live test).

## The mechanism, from FirstPerson.cpp (not VR.cpp)

The suspect file was wrong — everything lives in `src/mods/FirstPerson.cpp`
(praydog/REFramework, master):

1. **The view in first person** = `m_rotation_offset * raw_HMD`, where
   FirstPerson's `m_rotation_offset` continuously interpolates toward the
   **game camera controller's `worldRotation`** at
   `delta_time * m_interp_camera_speed * dist` — the ~1.5 s smoothing we kept
   measuring.
2. **That controller rotation is the world-yaw anchor**, and it's a feedback
   loop: FirstPerson writes its final camera quat back into
   `controller->worldRotation` every frame and re-reads it the next frame.
3. **`vr->recenter_view()` is called EVERY FRAME** while first-person is
   active (`FirstPerson.cpp:1689`, comment "only affects third
   person/cutscenes"). This is why `set_rotation_offset` writes and manual
   recenters were dead levers — VR's offset is clobbered per frame by design.
4. **A jack rotates the body, not the anchor.** Body-follow is
   head→body only; nothing ever drives the camera anchor from the body. When
   a jack (ladder, cupboard push) turns the body to the interaction point,
   the view keeps its pre-jack world direction — the felt offset is exactly
   "how far the jack turned your body," which is why a deliberate wrong-facing
   approach gave ~150° and a natural approach gave ~90–120°.
5. **Cutscene-exit pan, same loop:** the anchor holds the cutscene camera
   direction; the moment player control re-couples (first movement input),
   the anchor re-anchors — observed as snap-to-raw-HMD then a smooth ~1.5 s
   turn to the real direction.

Live confirmation: during a cupboard push, `cam − hmd` held rock-constant
(−91.5° one run, −151.7° with our writes active) while the body froze facing
the cupboard — view = frozen anchor + live HMD, exactly as the source
predicts.

## Jack detection beats motion names

A jack-edge logger (`JackDominator.get_Jacked`, transition-logged) captured:

- The cupboard push = one clean 9 s `jacked=true` window — **with zero layer-0
  motion-name change** (stayed `Gazing_Idle_F_Loop`). Motion-name detection,
  which the ladder guard uses, is *blind* to pushes.
- Door-open animations show as frequent short jack blips (~0.5–2 s), so a
  jack-gated fix must tolerate rapid engage/disengage.
- `get_Jacked` is the clean universal detector for the whole takeover class:
  ladders, pushes, grabs — one flag.

## The fifth lever (and its own two walls)

The four dead levers never touched the anchor itself. The camera controller
(`app.ropeway.camera.PlayerCameraController`) is game-side reflected state —
**writable from Lua**. Found via `CameraSystem`'s
`<CameraControllers>k__BackingField` list, entry whose GameObject is named
`PlayerCameraController` (mirrors FirstPerson's own discovery). Relevant
fields (from a live dump, don't guess):

- `<Yaw>k__BackingField` / `<Pitch>k__BackingField` (radians) — **the real
  anchor state**; `PrevYaw`/`PrevPitch` are prev-frame caches (writes stick
  but drive nothing — an hour lost to auto-picking `PrevYaw` first).
- `<CameraRotation>k__BackingField` (via.Quaternion; forward is 180°-flipped
  vs camera forward).
- `<SyncCameraRotation>k__BackingField` (`app.ropeway.DampingQuat`, has
  `_Target`) — game-side damped rotation state.
- `<YawMin>/<YawMax>k__BackingField` — **wall #2**: during the push gimmick
  the game clamps controller yaw (observed hard saturation at exactly
  −2.6471 rad across independent runs). A steering servo stalls against the
  clamp ~60° short of the body facing.

Conventions decoded from readbacks: controller yaw ≈ camera yaw − HMD yaw
(the anchor excludes the head); absolute writes in a guessed convention
settled ~85° off (wall #1). The working approach is a **closed-loop servo**:
measure the observed error (body yaw − camera yaw) each frame, rotate whatever
values the fields currently hold by a rate-limited step (~120°/s) in the
correcting direction, watchdog auto-flips the sign if the error grows.
Convention-proof by construction. Clamp widening (`YawMin/Max = ∓100`) is
the current iteration's addition.

## Lessons (added to the previous five)

6. **The re-deriver you can't beat may be a feedback loop you can join.**
   Writing the loop's *inputs* (camera transform, VR offset) failed because
   they're recomputed; writing the loop's *persistent state* (the controller
   yaw the loop re-reads every frame) moves the equilibrium.
7. **A write that sticks can still be a decoy** — `PrevYaw` round-tripped
   perfectly and did nothing. Only a measured effect on the rendered view
   counts (same lesson as dead lever #1, one level deeper).
8. **When an absolute write lands at a constant wrong offset, stop decoding
   conventions and close the loop** — a measured-error servo with a sign
   watchdog converges under any consistent unknown mapping.
9. **Exact repeated magic numbers are clamps.** A value that saturates at the
   same 7-decimal float across runs is a limit field, not dynamics — go find
   the Min/Max pair.
10. **In VR, "lock the camera" must mean lock the *world anchor*, never the
    head response.** Steering the anchor to the body while keeping HMD
    tracking live gives the felt "locked to the climb" without the comfort
    violation of a true lock.

## Status

Open, close to resolution. Servo + clamp widening deployed for live test.
Remaining knowns-unknowns: which of the three written fields is the
load-bearing one (candidates can be pruned once it converges), whether the
game restores its own yaw clamps after a jack, and porting the same steering
to ladder climbs (ladders likely clamp too) plus the cutscene-exit case.
The proven pieces regardless of outcome: the anchor mechanism, jack-flag
detection, the controller acquisition path, and the field map above.
