# Subtract the offset, not the motion: ending a two-week fight with a gait animation

**Status: resolved, confirmed live in VR.** The character's torso-twist
correction now runs at full strength while standing, walking, running and
turning, with no rigid trunk, no camera sway, and no red-dot drift — by
changing *what* the correction removes rather than tuning *when* it applies.

## The trap: every knob we had adjusted the wrong tradeoff

The underlying fix (covered in the earlier torso-twist and laser-drift case
studies) force-writes the spine joints' local rotation every frame to remove
a character-specific twist. That creates a fundamental fight: the gait
animation wants the spine to keep moving, the override wants it still.
Every mitigation we built over two weeks was a different point on the same
bad tradeoff curve:

- **Constant-strength freeze** → visible shake and gun bounce while moving
  (the arm IK reads the spine as input and fights the still-moving hips).
- **Speed/turn fade** (correction off while moving) → no shake, but the
  posture reverts while moving, and every on/off transition visibly swings
  the weapon's red dot.
- **Freezing more of the chain** (spine_1/2, then hips, root, COG, even
  legs as a diagnostic) → reduced the residual footstep-synced sway but
  made the body feel rigid. The player's verdict was the design insight:
  *"a rigid body is weird to play with — I'd rather have the twist."*

Meanwhile a residual footstep-synced camera sway survived **every** joint
rotation freeze from root to spine_2. We also disabled the engine's native
IK solvers live (leg IK, arm IK, the game's IK orchestrator — found by
string-mining the game binary with a static analysis tool, then toggled via
reflection) and the sway survived those too. Whole families of suspects,
all real negatives.

## The reframe

All of those observations point at one conclusion: the problem was never
*which* joints we froze or *when* — it was that freezing is the wrong
operation. The visible defect is a **sustained offset** (the character
holds their torso rotated); the thing we kept destroying is the
**high-frequency motion** (gait sway, breathing, turn lean) that the body
needs to look alive and that the IK chain needs to stay consistent with the
hips.

Signal-processing framing: we wanted to remove the DC component and keep
the AC. Implementation:

1. Keep a slowly-adapting average (exponential moving average, ~0.4s time
   constant) of each spine joint's *animated* local rotation — that average
   IS the sustained twist, by construction.
2. Straighten the average (the same blend-toward-identity already proven),
   producing a correction offset that changes only slowly.
3. Each frame, write: corrected-baseline ∘ inverse(baseline) ∘ live-animated
   rotation. The animation's deviation from its own baseline passes through
   at full amplitude; only the baseline is replaced.

Standing still, this is identical to the old freeze. Moving, the gait rides
through untouched — so the anti-shake fade became unnecessary and was
bypassed entirely, which as a free side effect also eliminated the
straight↔twisted transitions that used to swing the red dot on every stop
and start.

## Two details that made it actually work

**Mid-aim stability.** The player immediately asked the right question: if
the baseline keeps adapting, won't the dot drift during pose transitions?
Answer: freeze the baseline while the aim button is held. The correction
offset becomes a literal constant exactly when a sight picture exists;
adaptation resumes when no dot is on screen. A UX concern answered with a
gate, not a tuning pass.

**Idempotency under multi-call hooks.** The correction is re-applied before
every native arm-IK call — six times per frame (see the earlier case study
on the mid-frame clobber). The freeze formula was naturally idempotent;
the new formula is not: applied to its own output it would compound the
correction. On a repeat call the joint may hold either our previous write
(native didn't clobber it yet) or a fresh animated value (it did). The
guard: remember both the last written and the last raw quaternion; if the
current read matches the last written (quaternion dot ≈ 1), treat the
remembered raw value as the animation source instead. Handles both cases
without caring which one occurs when.

## Lessons

1. **When a per-frame override fights an animation, ask whether you can
   subtract an offset instead of clamping a signal.** Freeze/fade tradeoffs
   that resist multiple rounds of tuning are a hint the operation itself is
   wrong, not the parameters.
2. **Rotation-freeze elimination is structurally blind to positional
   effects, and both are blind to design-level wrongness.** We eliminated
   every joint and every native solver honestly — the sway was the fight
   itself, which no single component "owned."
3. **Player experience feedback can be the diagnosis.** "I'd rather have
   the twist" wasn't a preference to accommodate; it was the statement that
   the fix was removing the wrong thing.
4. **Any write you re-apply inside a multi-call native hook must be
   idempotent** — or made effectively idempotent with a stale-read guard.
   Check what your formula does to its own output before shipping it into
   a hook that fires six times a frame.
