# Laser/red-dot sight beam drifting off aim, in VR only

**Status:** Unresolved as a direct fix. Found the specific field that
drives the bug, confirmed it can't be influenced by writing to it
directly, and pivoted to a suppress-and-substitute strategy instead of
continuing to chase the native calculation. Documented in full because
the elimination process — including the parts that led nowhere — is the
actual value here, not just the eventual answer.

## The symptom

With the torso-twist fix (see the companion case study) applied and
confirmed working — weapon model, arms, and bullet trajectory all
visually correct — a weapon-upgrade attachment (a red dot sight, on a
revolver) still projects its dot well off from where the gun is actually
aimed: eyeballed at roughly 30-50° off, landing on a wall to one side.
No visible beam line, just the dot itself in the wrong place. Everything
*else* about the pose — mesh, arms, actual bullet impact — was already
independently confirmed correct.

## Establishing the shape of the bug before guessing mechanisms

Two cheap live tests before writing any probing code:

1. **Does it track the torso fix at all?** Toggling the fix's correction
   strength from 0 to 1 and watching the dot: it moved. Ruled out
   "completely unrelated," confirmed it's coupled to whatever the fix
   changes, just not correctly.
2. **How big is the error, precisely?** Not "off" — specifically
   30-50°, comparable in size to the *original* twist bug (25-55°). That
   pushed the working theory toward "reading something still
   substantially uncorrected," not a fine residual gap.

## Round one: exhausting the 3D-object theories

Six distinct, falsifiable theories, each tested and eliminated using the
game's own reflection API (see the companion technique note) rather than
guessing from documentation that doesn't exist for this engine:

- **A dedicated joint on the weapon mesh.** Dumped every joint name on
  the weapon's skeleton (12 joints, both with the sight active and not)
  — none named anything like "laser"/"sight"/"dot".
- **A separate child GameObject.** Walked the actual Transform child
  tree of both the weapon and the player GameObjects. Zero children on
  both — a useful data point on its own: this engine's attachment props
  generally aren't simple Transform children of what they're visually
  attached to.
- **A same-frame IK timing gap.** The working theory from the original
  twist fix was "one system reads a value before another finishes
  correcting it." Directly measured: sampled the muzzle joint's world-
  forward vector at two points in the same frame (early, at the fix's
  own hook; late, at the same point the bullet-trajectory code reads
  it). Result: 0.00° — the muzzle joint is fully stable within the
  frame, so this specific mechanism, plausible as it was, doesn't apply
  here.
- **A named component directly on the weapon/player GameObject.**
  Dumped every component class on both (~90 on the player alone) —
  nothing with "laser"/"sight" in the name.
- **The arm-corrector component from the original twist investigation.**
  A plausible-but-ruled-out suspect for the *original* bug, worth a
  fresh test against *this* different symptom. Only one of its several
  fields turned out to even be the right data type to test meaningfully
  (a UI mistake caught by checking field types before trusting a "no
  effect" result) — that field came back null during normal aiming,
  consistent with the component being for wall-clipping prevention, not
  general aim-pose correction.
- **A 2D/UI element, not a 3D object.** The game's VR aim-reticle fix
  already repositions one specific UI element (`GUI_Reticle`) every
  frame via a draw-element hook. Registered an independent listener on
  the same hook and logged every distinct element name seen with the
  dot active — only `GUI_Reticle` and ammo-count UI showed up, no
  separate laser element. Since `GUI_Reticle` is already correctly
  positioned by existing code, this ruled out "it's an unhandled UI
  element" too.

## Round two: the VFX system, and a red herring

A component called `ObjectEffectManager` (present on both the weapon
and player) is this engine's native visual-effects manager — exactly
the kind of system that would play a sight's dot effect, and untested so
far. Drilling into it:

- Its live "currently active effects" list and a "range-tracked effects"
  dictionary (a better semantic fit for a continuously-updating effect)
  both came back **empty**, even with the dot visibly on screen.
- A live comparison across *every* joint on the weapon mesh against the
  known-correct muzzle joint turned up one real outlier: an unlabeled
  numbered joint sitting ~60° off from muzzle (everything else sat at a
  near-zero or a rock-steady ~90°, the latter reading as an axis-
  convention artifact rather than a real error). That 60° figure was
  close enough to the eyeballed 30-50° that it looked like a strong
  candidate.
- It wasn't. The joint's offset changed when the aim-down-sights input
  was pressed (activating the sight) but **did not change** with the
  torso-fix slider — and the real dot demonstrably does move with that
  slider (confirmed by watching the dot alone, isolated from the
  visibly-moving body, to rule out an optical illusion). A joint that
  reacts to *pose state* but not to the *specific correction* known to
  move the real bug isn't the source; it's a coincidentally-similar
  number. Two other joints on the character's own arm skeleton
  (dedicated weapon-attachment sockets, found by dumping the full 190-
  joint player skeleton) showed the same "reacts to pose, not to the
  fix" pattern and were ruled out the same way.

**Lesson inside this round:** an angle landing "close enough" to the
target magnitude is not confirmation. The slider-coupling test is the
one that actually discriminates real candidates from coincidences, and
it's worth re-running on *every* new candidate rather than trusting a
plausible-looking number once.

## Round three: found the field, couldn't act on it

A component's *full* field list had never actually been dumped — only
two specific fields had been accessed by name, early in the
investigation, for an unrelated purpose. Dumping every field on it
turned up `LaserSightTipPosition`: a small-magnitude 3D vector, named
unambiguously, that updates continuously and — confirmed directly —
**moves when the torso-fix slider changes**, matching the real dot's
behavior exactly. First real correlation found all night.

Then the letdown: writing to it did nothing.

- Wrote directly to the field: no visible effect on the dot.
- Suspected the write was being skipped by whatever renders the beam
  because a raw field write bypasses a C# property's *setter method* if
  one exists (a real, general reflection gotcha — the getter/setter
  pair can do more than just store a value). Called the actual setter
  method instead of poking the field: still no visible effect.

Conclusion: this field is very likely a **downstream readout**, not the
authoritative value the renderer consumes — probably computed for
separate gameplay logic (a sibling field literally named
`IsSightToEnemy` suggests target-detection use) from the same broken
upstream data, rather than being upstream of the visual itself. It
tracks the bug perfectly without being a lever we can pull.

## A costly aside: don't force a field tied to real game state

One more theory: force the "which parts are equipped" flag to zero,
hoping the dot's spawn logic gates on it. Applied every frame, this
caused the game to visibly, rapidly re-trigger a real equip/unequip
cycle — the field is wired to an actual state-change event, and native
logic kept resetting it, fighting the override every frame. No crash,
but a real, live disruption caused by a diagnostic script, not a
hypothetical risk.

**Lesson:** before force-writing a field every frame, check whether it
looks like a passive value or a state-change trigger (an adjacent
`OnChange*` event field, in this case, was the tell, visible in the
same field dump — worth reading names in the dump for exactly this
signal before wiring up a per-frame override, not just for what to
target).

## Where it stands / the pivot

Rather than continuing to chase the native formula, the practical plan
going forward: suppress the native dot (once a safe way to do that is
found — force-zeroing the equip-parts flag is not it) and substitute the
mod's own already-correct aim-reticle system in its place specifically
when this attachment is equipped, instead of fixing the broken
calculation directly. Not yet implemented as of this writing.

## Process lessons, independent of the eventual answer

- **Get a magnitude before guessing a mechanism.** A vague "it's wrong"
  supports dozens of theories; a concrete number close to a previously-
  understood bug's magnitude narrows the search immediately.
- **A "close enough" number is not confirmation.** Re-run the
  discriminating test (here: does it move with the specific fix, not
  just with pose/aim in general) on every new candidate, even a
  promising-looking one, before treating a match as real.
- **A component ruled out for one symptom isn't ruled out for a
  different symptom**, especially investigated before the second bug was
  even known to exist — retest specifically.
- **Check that a "no effect" test was actually valid.** A checkbox that
  silently no-ops on a type mismatch reports "no effect" indistinguishably
  from a genuine negative result.
- **A raw field write and a property's setter method are not the same
  operation.** If forcing a field does nothing, try the actual setter
  before concluding the field is inert — the getter/setter pair can carry
  logic a direct field write skips entirely.
- **Read field *names* in a dump for risk signals, not just for what to
  target.** An adjacent `OnChange*`/event-shaped field name is a hint
  that a field is a state-change trigger, not a passive value — worth
  noticing before wiring up a per-frame override, which cost a real (if
  minor) live disruption this session.
- **When a live UI-based test comes back ambiguous, ask for a screenshot
  rather than a transcription.** A status panel with several similarly-
  worded lines is easy to misdescribe; a screenshot removes an entire
  class of back-and-forth.
- **When direct fix attempts are exhausted, "suppress and substitute" is
  a legitimate strategy**, not a consolation prize — especially when a
  known-correct alternative system already exists in the codebase for a
  closely related purpose (here: the VR aim-reticle fix).
