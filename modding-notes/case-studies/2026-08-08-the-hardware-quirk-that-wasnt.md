# Three unrelated bugs, one visual symptom, and a "hardware quirk" conclusion that turned out to be wrong

**Status:** Fixed and confirmed working, standing and walking. This investigation
also revisits and corrects an earlier write-up in this repo
([`2026-08-08-edge-trigger-no-retry-and-a-controller-blip.md`](2026-08-08-edge-trigger-no-retry-and-a-controller-blip.md))
that concluded a milder residual case of the same symptom was an unfixable
hardware sensor quirk. It wasn't. It was two more software bugs, both fixable,
both found by continuing to instrument instead of accepting "no raw analog
access" as a final answer.

## The symptom

Grabbing a weapon's slide (grip button, proximity-gated, drives a
trigger-controlled rack/pull gesture) would sometimes leave the hand stuck
replaying its reach animation in a rapid loop, never landing on the slide.
Worse at full arm extension, worse while walking, better when the off-hand
came in close enough to brace the reaching hand. A prior investigation
(linked above) had found and fixed one real bug (an edge-triggered grab-start
check with no retry) and then chased a *milder* residual version of the same
symptom down to the VR framework's own pre-digitized grip-button read — a
boolean with no raw analog value behind it — and stopped there, with the
player agreeing it was acceptable jank.

This session, the same symptom came back **not milder** — bad enough to
block grabbing entirely at times, and clearly correlated with arm extension
and with walking. That mismatch (an "accepted, hard-to-reproduce edge case"
suddenly reproducing constantly) was the first sign the old conclusion needed
re-examining rather than re-confirming.

## First pass: the grip-button theory, extended

Everything in the code so far pointed at the same grip-digitization
mechanism as before, just worse. Debug logging of every grab-state
transition (grip, in-range, active) showed the grip reading flickering false
for stretches of 100ms up to 1.5 seconds while the hand sat still, at a
consistent distance from the target — the same signature as the earlier
"sustained false read at one wrist pose" finding, just with longer, more
frequent dropouts.

Two mitigations followed from that read:
1. Widened the existing single-frame debounce from 50ms to 500ms.
2. Added a second layer: past the debounce, keep tolerating a false grip
   reading as long as a second, independent signal (hand still measured as
   in-range of the target) corroborates that the hand hasn't actually moved
   away — with a hard ceiling so a genuine release still eventually
   registers. The idea: a real release is almost always followed by the hand
   moving away; a sensor glitch isn't.

This measurably helped. It did not fix it. That's the tell that the grip
button wasn't the whole story — a working theory that explains *some* of the
symptom without ever fully suppressing it is a sign to go looking for a
second, independent cause rather than tuning the first fix's numbers further.

## Second pass: the position source was frozen

The next report — "still loops, worse walking, hard to land the hand at all
even standing still trying different spots" — didn't fit a pure button-read
theory. A button glitch flickers a fixed position on and off; it doesn't
make the target hard to *find*. That distinction motivated comparing the
*position* the code was using against an independent reference, not just the
grip boolean.

Added throttled logging comparing two things every ~150ms: the distance the
grab logic was actually using (sourced, several fallback layers down, from a
bone on the character's animated skeleton), against the distance computed
from the raw controller pose, properly transformed into world space by a
function this codebase already had for other purposes.

First attempt at this comparison produced nonsense — the "raw" distance came
back at several *meters* while the skeleton-based one read centimeters. Not
a finding, a bug in the diagnostic: the wrong helper function had been used,
one that returns an untransformed, playspace-local position, not a world
position. Worth noting as its own small lesson — a diagnostic probe is code
too, and a diagnostic that produces a wildly implausible number should be
treated as a probe bug first, a discovery second, until ruled out. Finding
and using the correctly-transformed sibling function fixed the comparison.

With a valid comparison running, the real finding showed up immediately: the
skeleton-sourced distance sat *completely frozen* — identical to several
decimal places — for nine straight seconds, while the raw controller-based
distance moved continuously and smoothly through more than half a meter of
real hand motion. The position feeding the grab logic wasn't glitching. It
had stopped updating entirely, at some point earlier in the session, and was
just replaying a stale snapshot regardless of where the hand actually was.

**Root cause, found by reading the source of the frozen value, not by more
logging:** a global variable holding the left hand's world position was
written by an entirely separate system — the hand-docking/IK code that runs
*while* a weapon is actively socketed into the hand — but was **never
cleared** once that docking ended. Four different functions across three
files read this global unconditionally as a fallback position candidate,
with no check for whether it was actually current. One of those functions
already had the correct pattern next to it in the same file (gated behind a
boolean flag that genuinely does track "is this docking system live right
now") — proof the fix wasn't a guess, it was copying an already-correct
sibling. All four call sites got the same gate. This exact bug and exact fix
had actually been *identified* in an earlier, unrelated investigation into a
different feature (a smooth-hand-docking attempt that was ultimately
abandoned for other reasons) — but that fix had been reverted along with the
rest of the abandoned feature, and never reapplied on its own merits. Lesson:
a real bug found and fixed inside a larger change that later gets fully
reverted doesn't stop being a real bug. Worth a standing note, not just a
line in that one investigation's write-up.

## Third pass: the "live" position source was still noisy

Fixing the freeze was a real improvement, confirmed live. But one more test
still showed the same rapid-loop symptom. Same comparison logging, rerun,
showed a new pattern: the skeleton-sourced distance was no longer frozen —
it tracked real movement now — but it was *spiky*, jumping to roughly 3x its
neighboring values for a single sample every few frames, while the raw
controller-based distance stayed smooth throughout. An animated bone driven
by the game's own IK solver, reached indirectly through several fallback
layers, isn't a 1:1 mirror of the physical controller; it can glitch on
individual frames in ways raw tracking data doesn't.

Fix: rather than replacing the skeleton-based reading (higher blast radius,
other systems may depend on its specific behavior), the raw, properly
world-transformed controller position was added as one more candidate in the
existing "take the minimum distance across several position sources" logic
already used to decide whether the hand counts as at the target. A single
bad frame from the noisy source can no longer block a grab when the smooth
source agrees the hand is actually there.

## Fourth pass: the state machine was fixed, but something else still flickered

One more report of the same visible symptom, even after all three fixes
above — but this time the actual grab state machine's own transition log
told a different story: over nearly a minute of testing, only a handful of
clean transitions, none rapid, one grab held stably for thirteen seconds
straight. The bug that was originally reported — hand stuck looping,
snapping back and forth repeatedly — was still visibly happening, but the
system responsible for *starting and holding* the grab was, by its own
instrumentation, no longer misbehaving at all.

That contradiction was the useful signal: if the thing you've been watching
says it's fine but the user says it's still broken, look for a second
consumer of the same underlying noisy value that isn't protected by the fix
you already applied. In this codebase, the actual grab state and the
*visual* hand-to-target blend were two separate systems, both reading the
same "is the hand in range" boolean, but the visual blend read it directly,
every frame, with a single hard distance threshold and zero debounce of its
own — while the grab state machine (by design, for this class of gesture)
deliberately ignores small excursions out of range once a grab is already
active. Ordinary boundary noise in the range check — which nothing upstream
had smoothed, because nothing needed to for the grab state itself — was
enough to flip the visual blend's target on and off repeatedly, easing the
hand toward the target and back, over and over, with the grab state
machine's own log showing nothing unusual because it genuinely wasn't
involved.

Fix: hysteresis on the range check itself — once already counted as "in
range," require the hand to move measurably farther away before counting as
out of range again, rather than using the same threshold in both directions.
A few centimeters of margin was enough. This is the standard fix for any
boolean derived from a noisy continuous signal that more than one downstream
system reacts to independently; the earlier fixes had made the *distance
signal itself* trustworthy, but hadn't added debounce to every place that
read the boolean derived from it.

## What the original "hardware quirk" conclusion got wrong

The earlier write-up's reasoning wasn't unreasonable given what it had
tested — it traced the grip-button read to a call with no raw analog access
and treated that as the floor. But it never independently checked the
*position* being used for the same gesture, and the actual dominant causes
turned out to be a stale-cache bug and a missing-hysteresis bug, both
ordinary software problems, not hardware. "This specific input has no raw
value to add hysteresis to" was true and also not the real bottleneck —
there was a whole separate position pipeline with real, fixable problems
sitting one layer over that the earlier investigation hadn't looked at,
because the symptom at the time was milder and the grip-read theory already
explained enough of it to feel sufficient.

## The pattern worth keeping

1. **A previously-accepted "unfixable hardware" conclusion is not a
   permanent one** — if the same symptom comes back worse, or under new
   conditions (here: walking) the old investigation never tested, that's
   grounds to reopen it, not re-apply the old workaround harder.
2. **When a fix helps but doesn't fully resolve a symptom, that's a
   second-cause signal**, not a sign to keep tuning the first fix's
   constants.
3. **Compare an independent reference signal, not just the one the buggy
   code is using.** The freeze and the spikes were both invisible from
   inside the skeleton-position code path alone; both only became obvious
   once a properly-transformed raw controller position was logged
   side-by-side with it.
4. **A diagnostic that produces an implausible number is a bug in the
   diagnostic first.** The multi-meter "raw distance" reading wasn't a
   finding about the game; it was a wrong helper function call, caught by
   noticing the number couldn't possibly be real before trusting it.
5. **A bug fixed inside a reverted feature is still a real bug.** The stale
   global's fix had already been written once, then thrown away with the
   rest of an unrelated abandoned feature, and stayed broken in production
   until this investigation reapplied it on its own.
6. **Fixing the source of a noisy signal doesn't fix every consumer of it.**
   The grab state machine and the visual blend both read the same range
   boolean; fixing the *distance calculation* feeding that boolean left the
   *visual* consumer still exposed, because it had its own independent,
   undebounced read with no hysteresis of its own.
