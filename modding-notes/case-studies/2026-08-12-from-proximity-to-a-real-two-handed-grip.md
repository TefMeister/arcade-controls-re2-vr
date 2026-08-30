# From a proximity dock to a real two-handed grip — and back to something simpler

**Status:** CONCLUDED, but not with the fix this write-up originally expected. After
several more sessions chasing real-hand-position tracking (summarized in the new final
section below), the developer made the call that hand-tracking was never going to feel
solid in this particular game engine, and the feature was rebuilt on a completely
different mechanism — a button-state latch with zero position tracking at all. That
version mostly works; one bug (aim briefly pointing the wrong way under a specific
condition) is still open. Kept as one continuous write-up rather than a new file,
because the reasoning that led to abandoning the tracked-position approach is the real
payoff here, not just the bugs found along the way.

## Escalation, not a single ask

A cosmetic left-hand placement feature (visually snap the hand onto a two-handed
weapon's foregrip, purely for looks, never affecting the weapon itself) went through
three design iterations across one evening before the *real* underlying ask surfaced:

1. **Pure hand-proximity trigger** — snap on when the real hand gets close enough,
   release when it moves away. Live testing found this unreliable: inconsistent snap
   timing, apparent dependence on which way the player was facing, unreliable
   release, and a real leak where an unrelated held button could nudge the hand even
   without a deliberate grab. (Turned out to be partly a real bug — see the companion
   write-up on camera-relative vs. real tracked position — but even after that fix,
   trust in "distance alone" as a trigger was already gone.)
2. **A held-button gate instead of proximity** — same cosmetic hand placement, but
   only while a specific grip button was held, matching how this project's actual
   weapon-handling gestures (a pump-action reload, a slide-rack reload) had already
   been converted from tracked-distance to discrete button presses for the same
   reliability reason. This worked, but exposed the real complaint underneath: the
   hand *looked* like it was holding the gun, while the player's actual hand was
   somewhere else. Cosmetic-only placement, no matter how reliably triggered, doesn't
   solve "make it feel like I'm actually holding this."
3. **A real two-handed grip** — the weapon's actual in-game aim direction blended
   toward the real hand position while gripped, not just a hand placed on top of an
   unaffected gun. This is the one still being debugged.

## Finding out the mechanism was real, not another wall

An earlier, unrelated investigation in the same project had already hit a genuine
wall: writing to a value the game's native engine recomputed every single frame,
silently discarding the write. Before spending real effort on the "real grip" idea, it
was worth confirming whether the weapon's aim was the *same* kind of native-owned
value or something the mod could actually control.

It turned out the project's own recoil system already proved the answer: it patches
the same underlying aim-orientation value every frame, successfully and reliably —
because it does so as a **pre-hook on the native solver's input**, immediately before
the native code reads it, rather than writing to a result *after* something else has
already consumed and moved past it. Same category of value, different intervention
point, completely different reliability. This is the generalizable lesson from the
earlier wall: "this gets overwritten every frame" doesn't mean "unwritable" — it can
mean "you're writing after the read, not before it."

A second, unexpected finding while investigating: the project already had a *related
but opposite* mechanism — the support hand's visual position being patched to follow
the weapon during recoil kicks. That's the reverse relationship from "the weapon
follows the hand," and quite possibly part of why the hand already felt disconnected
from reality even before any of tonight's changes. Worth remembering: when adding a
new relationship between two things, check whether an existing system already
relates them the *other* way — it may need explicitly overriding, not just ignoring.

## Bug #1: a slider left at its own maximum

First live test of the real-grip trigger: it engaged on almost every button press,
regardless of where the hand actually was. Rather than guess at the geometry, logging
was added directly to the trigger decision (the computed anchor point, the real hand
position, the measured distance, the threshold) and a second short test was run.

The log made it immediate: the *threshold itself* had been persisted at its UI
slider's maximum value — 40cm, wide enough to cover almost any casual hand position
near the body — almost certainly nudged by accident while exploring the new control
panel earlier in the same session, not a code defect at all. The same test gave two
clean real data points (hand deliberately far away vs. hand actually reaching for the
grip point), which set the corrected threshold precisely rather than by further
guessing. The slider's own range was also tightened afterward, so a future accidental
drag can't reach anywhere near as permissive a value again.

**Lesson:** a "the trigger fires constantly" bug report is not automatically a logic
bug. A live-tunable value that got persisted somewhere unreasonable is at least as
likely, especially right after a UI panel was added or touched — check the actual
persisted config before re-deriving the trigger logic from scratch.

## Bug #2: the hook was wired to the wrong lifetime

With the threshold fixed, the feature engaged correctly — but the weapon never
visibly followed the hand at all. The aim-blend code was confirmed correctly written
and correctly reached... intermittently. Tracing the surrounding hook revealed why:
it lived inside a gate originally designed to patch aim *only while active recoil
was animating* — a transient, per-shot window of a few frames, going idle the rest
of the time. That gate made complete sense for the system's original purpose
(showing a recoil kick) and none at all for a *continuous* aim-following effect that
needs to run every single frame the grip is held, shot or no shot.

The fix was narrow — let the new continuous-effect condition bypass that one gate,
confirmed first that everything upstream of the gate was already unconditional (so
bypassing it wouldn't change anything else's frequency), rather than restructuring
the whole hook.

**Lesson:** reusing an existing, proven hook for a *new* purpose means checking not
just "does my code run inside this hook" but "does this hook's own gating logic match
my feature's required lifetime," which can be completely different from the
lifetime the hook was originally built for. Code can be perfectly correct and still
almost never execute.

## Bug #3 (open): a rotation that occasionally goes wrong

Third test, after both fixes: the weapon's visual rotation spun wildly — not on every
grip, but often enough to be unmistakably wrong. Paused here rather than shipping
another untested guess.

The leading suspect, reasoned out but not yet confirmed with data: the rotation
between "where the weapon currently points" and "where it should point toward the
hand" is computed as a cross product between two direction vectors. When two vectors
being crossed are nearly parallel — which happens naturally whenever the support hand
ends up roughly in line with the barrel, a very plausible occurrence during ordinary
grip movement — the cross product's *magnitude* correctly shrinks toward zero, but
its *direction* becomes dominated by floating-point noise before it gets small enough
to be caught by a naive "is this basically zero" guard. A large rotation angle
combined with a numerically unstable axis is a well-known way to get exactly this
symptom: a big, seemingly-random spin, intermittent because it depends on incidental
hand/weapon geometry rather than happening constantly.

Not yet confirmed — the plan is the same one that found the previous two bugs:
targeted logging around the suspect computation, gated to only fire when something
looks abnormal (an unusually large rotation angle, or a big jump between
consecutive frames), then read the real numbers from one short test rather than
patching blind.

## General lessons so far

- **When a "distance/proximity" trigger keeps causing reliability complaints, stop
  tuning it and ask whether the whole approach should be a discrete button/state
  check instead** — this project has now hit that exact wall twice for two different
  features, converted both the same way, and both got measurably more reliable.
- **"This value gets silently overwritten" is a claim about *where* you're writing,
  not proof the value is unwritable.** A pre-hook on the consumer's input can succeed
  where a post-write to a result reliably fails, even for the exact same underlying
  field.
- **Before building a new relationship between two systems, check for an existing
  relationship running the opposite direction.** It may need to be explicitly
  disabled for the new behavior's cases, not just coexist with it.
- **A "happens on this hook" bug is sometimes a "this hook's own lifetime doesn't
  match what I need" bug.** Check what gates the hook itself before assuming your own
  code inside it is where the problem lives.
- **Cross products (and anything computing a rotation axis between two vectors) are
  numerically unstable near parallel/anti-parallel inputs** — a magnitude-only "is
  this near zero" guard catches the extreme case but not the wider unstable
  neighborhood around it. Worth a wider guard or a fallback reference axis whenever
  this pattern shows up, not just at the exact singularity.
- **When a live test surfaces a report like "it's not supposed to do that, but not
  every time"** — intermittency is data, not just an annoyance. It usually points at
  a specific geometric or timing condition rather than a uniformly-broken mechanism,
  and it's worth reasoning about *when* the bad case would occur before writing a
  fix, the same way the first two bugs here were resolved from real logged numbers
  rather than guesses.

## Bug #3, resolved: the rotation between the wrong two numbers

The cross-product-instability theory above turned out to be wrong. Targeted logging
(comparing the raw pre-processed rotation input against the same value after the
mod's own recoil-offset math) proved the numbers were identical the whole time — the
math wasn't unstable, it was correctly computing a rotation toward the *wrong target
direction entirely*. The support hand sits just behind the muzzle by design (a few
centimeters, for a realistic foregrip), and the code was computing "which way should
the weapon point" as the vector from the muzzle to that support hand — a vector that's
almost always nearly antiparallel to the barrel's real forward direction, which is
exactly the geometry that makes a rotation axis numerically unstable. Fixing the sign
didn't fix it either — the real bug was normalizing a vector that short at all: at
that distance, ordinary hand-tracking jitter (sub-centimeter) dominates the resulting
direction once normalized. The actual fix was changing which two points defined the
direction — measuring from the *trigger hand's own grip point* through the support
hand, not from the muzzle tip, since that vector is always tens of centimeters long
regardless of weapon or grip tightness and stays stable under the same jitter that
broke the muzzle-relative version.

**Lesson:** "numerically unstable" is a real, correct diagnosis of *how* something goes
wrong, but it doesn't by itself tell you *why* the inputs end up in the unstable
region in the first place. Here, the instability was a symptom of a badly chosen
reference point, not a badly chosen formula — the formula was fine once fed a vector
that was never going to be short or near-parallel to begin with. When a numerically
unstable computation misbehaves, check whether its inputs are structurally close to
the instability region *by construction*, not just occasionally by bad luck.

## The pivot: giving up on real hand-position tracking entirely

Getting the rotation direction right didn't end the debugging — it started a longer
run of it. Once the aim genuinely followed the tracked hand, a new problem appeared:
the gun's position (not rotation) jittered wildly, several tens of centimeters per
frame, even though the real hand tracking data feeding it was rock steady. Isolating
this took several more rounds: ruling out the render-frame vs. logic-tick mismatch,
ruling out wrist-side identity swapping between frames (confirmed stable via direct
logging), and eventually finding the real cause — the *native engine's own* solver
target was moving that much, before the mod's code ever touched it. The mod was
forcing a large rotation correction onto the arm-IK solver every single frame at full
strength, and the solver's own position solve turned out to be entangled with that
forced rotation in a way that produced a runaway feedback loop. Lowering the
correction strength (accepting a small responsiveness cost) made the position
instability disappear completely — a clean, confirmed root cause.

That should have been the finish line. Instead, live testing kept surfacing the same
underlying complaint in different forms: the grip zone effectively tracked where the
player's head was pointed rather than where their hand actually was (the camera-
relative hand-position reconstruction described in the companion write-up, "The
camera knows where it looks, not where you are," bleeding into yet another consumer
of that same shared value); the hand never felt "really" attached to the gun the way
the game's own existing two-handed-aim animation already does; and the whole thing
still felt subtly wrong while moving, no matter how many individual bugs got fixed.

At that point the developer made a call that mattered more than any single bug fix:
**real-world hand-position tracking was never going to feel solid in this particular
game, because the game wasn't built for it — chasing it further was polishing a
fundamentally shaky foundation.** Rather than keep refining position-tracked math,
the feature was rebuilt from scratch on a completely different mechanism with **zero
position tracking of any kind**:

- The game already has a proven, existing "support hand follows the two-handed
  weapon" animation system, active whenever the normal two-handed-aim button is held.
  It's cosmetic-only (doesn't drive aim) and has never had any of the above problems,
  because it's driven by the game's own animation, not reconstructed hand tracking.
- Instead of trying to reproduce or improve on that system, the new design just
  **extends its *lifetime***: holding both the normal two-handed button and a second
  grip button together "catches" that already-correct pose in a latch. Releasing the
  first button no longer drops the hand — the latch keeps the existing system engaged
  until the second button is released too.
- No proximity checks, no frozen offsets, no reconstructed positions anywhere in the
  new mechanism — just two button states and one latch flag.

This fixed the "doesn't feel real" and "janky while moving" complaints outright,
confirmed by the same developer who'd been unable to get either right across every
tracked-position attempt. One bug from the transition period remains open (see below).

**Lesson, the real payoff of this whole investigation:** when a feature keeps
generating a *new* plausible-sounding bug every time the last one gets fixed, and each
individual fix is clean and well-reasoned, that pattern is itself a signal — not proof
of an unfixable feature, but a reason to step back and ask whether the *entire
approach* is fighting the platform rather than working with it, before sinking more
effort into the fifth root-cause investigation of the same symptom in different
clothes. Reusing an existing, already-correct system by extending *when* it applies
can beat rebuilding an equivalent system from lower-level primitives, especially when
the lower-level primitives (real-world tracked positions, here) are exactly the part
that's been unreliable throughout.

## One bug still open: a decision that quietly depends on where you're looking

The one surviving issue from the tracked-position era followed the new mechanism into
its rebuild, because it lives one layer deeper than either implementation: deciding
*which* of two symmetric data structures corresponds to the left vs. right hand, when
the game's own "which hand is this" flag is ambiguous, falls back to comparing
distances against the same camera-relative reconstructed hand positions described in
the companion camera write-up. Under the old tracked-position system this
disambiguation rarely mattered enough to notice. Under the new latch — which, for the
first time, can hold a hand in a genuinely fixed pose for many seconds while the
player looks around freely — looking far enough off to one side shifts the
reconstruction enough to flip which structure gets called "the right hand," briefly
handing the aim-driving code the support hand's own pose instead. Two targeted fixes
(preferring a cached, non-reconstructed reference position for one side of the
comparison; separately, replacing a different piece of hand-relative math with a
value derived straight from the weapon's own geometry) each addressed a real,
independently-reasoned problem, and neither fixed this particular symptom — a reminder
that a system built from several years' worth of small historical patches, each
individually justified, can still have an unresolved case none of them cover, and
that finding it may take instrumenting the disambiguation decision directly rather
than fixing what looks adjacent to it.
