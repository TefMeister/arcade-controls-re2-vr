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

## How it actually resolved (same day, ~10 more live iterations)

The steering servo was the wrong frame. The day's second user clarification
changed the design: the player necessarily FACES the interaction to start it,
so the bug is not "view exposed at a stale offset" — it's the game rotating
its gimmick camera for the takeover and the VR view following. The fix family
that won is a **HOLD**: pin the controller anchor every frame (via post-hooks
on the controller's update methods — the only slot that beats the game's own
per-frame write) and hand back a consistent state at release.

The iteration ladder, each step falsified by a headset test:

- **Servo vs clamp:** the "YawMin clamp" theory died — the −2.6471 rad
  constant is the game's per-frame gimmick yaw write, not a limit. Widening
  YawMin/YawMax did nothing; write-slot timing (sdk.hook post-call on the
  controller updates) is what wins.
- **Loop gain:** hooks fire ~5×/frame (all controller instances share
  methods); unbudgeted 0.5-gain corrections = 250% loop gain = violent
  oscillation. Budgeted per-frame corrections fixed it — then became moot.
- **Glide-in/out REVERTED:** the natural captured anchor renders ~150° off
  under jack composition — the hold's endpoints live in *different
  composition regimes*, so any smooth anchor path visits the wrong direction
  in view space. Instant transitions are the honest minimum.
- **Head-yaw lock REVERTED:** during a jack the composed view is the anchor
  *directly* — raw HMD yaw is not added — so counter-rotating by head yaw
  produced inverted head-look. (The hold is naturally yaw-locked; pitch stays
  free through the untouched HMD pose path.)
- **Body-target, not view-target (user's design):** holding the approach
  view made results vary with RS-steering state. Targeting the BODY facing is
  deterministic (the game aligns the body to the interaction), and the
  top-of-ladder 180° turn-around comes for free via **body-follow** (rotate
  the held anchor by the body's live yaw delta — view turns only when the
  body visibly turns).
- **The hmd0 term falsified by a controlled experiment:** the user isolated
  variables in-headset — RS-only turns: climb view perfectly reproducible;
  physical chair turns: climb view tracks the room orientation. The formula's
  `− hmd0` compensation had been "verified" only at near-constant chair
  orientations (a constant masquerading as a variable). v9 drops it and adds
  a user-facing trim slider for whatever fixed residual remains.

**Milestone (v8, user-verified):** ladder exits are deterministic and correct
every time — top dismount faces away from the ladder, bottom dismount faces
it straight on; cupboard pushes hold steady with a small paired settle.

## Endgame (same day, evening): ground truth ends the guessing

v9's formula surgery regressed the exits — the deleted `−hmd0` term had been
*canceling* the release formula's `−hmd_now`. The way out was discovering
that **`vrmod:get_last_render_matrix()` is bound to Lua**: the actual
rendered view, measurable at last. Everything after that took minutes of
design instead of hours of inference:

- **v10:** measured-view servo — self-calibrate the matrix's yaw convention
  per jack (sampled against the camera while composition is still normal),
  then nudge the anchor until measured view == body facing. User-verified:
  the climbing view became chair-proof and always faces the ladder; the 180°
  top-mount turn flows through body-follow.
- **v11 (the WIN, staging `512fda3`):** measured-view release — hand back
  `measured view − current HMD yaw` (the verified normal-play equilibrium)
  so exits continue the held view seamlessly. User-verified end-to-end on
  ladders and cupboards, chair-independent.
- **v12:** learned anchor→view constant K places the anchor correctly from
  frame one (log-verified within ~15°). Which exposed the true source of the
  residual start artifact (teleport + jitter + ~1 s pan): it is
  **FirstPerson's own `m_rotation_offset` interpolation**, not the anchor.

**The upstream find:** in VR, FirstPerson *intends* to snap
(`m_interp_camera_speed >= 100.0f && bone_scale == 0.0f` →
`m_rotation_offset = wanted_mat`), but `bone_scale` only ever *lerps toward*
zero — an exact float equality that is never true — so VR always takes the
slow interp path. Likely an upstream bug in REFramework's FirstPerson.cpp.

## Status

**Resolved for gameplay.** The hold ships the correct behavior: view locks
to the interaction (ladder/cupboard/switch) every time, clean 180° on
top-mounts, seamless chair-proof exits. Remaining cosmetic: the ~1 s
FP-interp settle at jack start — beyond Lua's reach. Follow-ups:
(1) native patch forcing FP's snap branch while jacked, or better
(2) an upstream PR to praydog/REFramework (fix the `== 0.0f` check / snap
while `is_jacked()`), and (3) extend the hold to cutscene enter/exit
(camera-type transition trigger instead of the jack flag).

14. **Find the API that measures the thing you keep inferring.** Six hours of
    composition algebra ended in minutes once the actual rendered view was
    readable. Search the bindings for ground truth before modeling around
    its absence.
15. **When your correction converges instantly but the artifact persists,
    the artifact belongs to someone else's smoothing.** Log-verified
    placement within 15° + a 129° visible slew = the slew is downstream of
    your write, in code you don't own.

## Meta-lessons from the iteration ladder

11. **A constant can masquerade as a variable.** The `cam = held + hmd0`
    relation was "confirmed" twice — at chair orientations 3° apart. Vary
    the suspected input deliberately before believing a fitted term.
12. **The user is an instrument.** Rough in-headset estimates ("150-ish
    left, like a watch with no numbers") repeatedly matched the logged math
    within degrees — and the decisive experiment (RS-only vs physical-only
    turns) was designed and run by the player mid-session.
13. **Endpoints in different composition regimes cannot be glided between.**
    Smoothness in parameter space is not smoothness in view space.
