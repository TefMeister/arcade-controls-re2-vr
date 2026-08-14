# Two clean eliminations, one mystery still open — a background that won't stop going black

**Status:** OPEN, but narrowed. Two independent, plausible-looking fixes for a
background-rendering bug have now both been tested to completion and cleanly ruled
out — not abandoned on a hunch, but confirmed dead via live testing after each one
appeared to take effect exactly as intended. Writing this up now, mid-investigation,
because a negative result that narrows the search space is still real progress, and
the repo this comes from exists specifically to record that kind of result.

## The symptom

A detail/examine screen shown during item pickups renders its background as fully
black in VR, while the same screen looks correct (blurred, not black) on a flat
monitor. Pickup mechanics themselves — granting the item, closing the screen — are
unaffected; this is purely a rendering problem on one specific screen.

## Attempt one: the numeric knobs

The screen's underlying object exposes its own dedicated blur/zoom fields for this
exact shot — a blur scale, a mip level, a field of view distinct from the normal
gameplay camera's. The theory: force these to neutral values (no blur, matching FOV)
right as the screen opens, and restore them on close, so the transition into this
camera's rendering path is as close to a no-op as possible.

This was built, hooked into the actual screen-open event, and verified two
independent ways: live log readback confirmed the write took effect exactly as
requested (not a silent no-op), and this was tested across multiple real pickups.
Zero visual change to the black background in VR either time.

**Lesson:** confirming a write "took" is necessary but not sufficient — it tells you
your code executed, not that you changed the thing actually responsible for what
you're trying to fix. Two independently-confirmed-successful writes producing zero
visible effect is strong evidence the fields themselves aren't in the causal chain
at all, not evidence the fix needs to be applied more forcefully.

## Attempt two: the trigger method, not a numeric parameter

The numeric-fields theory being dead didn't mean the screen's background system was
fully understood — a *different* candidate turned up: a method (not a parameter)
that fires exactly once, right when the screen opens, clearly involved in setting up
whatever effect renders that background. Unlike the blur fields, this isn't
something you tune; it's a trigger you can only call or skip.

The fix candidate: skip that one call entirely (return early from a pre-hook on it,
never letting the original run) while leaving every other part of the pickup flow —
data, manual confirmation, closing, the per-frame camera drive the screen also
uses — completely untouched. Deliberately narrower than skipping the screen's whole
open sequence, specifically so a failure would be easy to attribute to this one call
and nothing else.

Tested live: no effect on the black background, and — the real open question this
one carried, since skipping a real setup call risked side effects the numeric-field
approach never could — no other visual side effect either. The 3D item model itself
still rendered normally.

**Lesson:** when you find a method that's clearly *involved* (fires at the right
moment, is obviously part of the same system), that's evidence it's part of the
mechanism, not evidence it's a controllable lever for the specific symptom you're
chasing. A system can have a real, single-purpose trigger call that's necessary for
correct rendering elsewhere while having nothing to do with the one visual bug in
front of you.

## Where this leaves the investigation

Both attempts were left in the shipped mod as inert, harmless toggles — off by
default, clearly labeled as confirmed dead ends rather than deleted, on the theory
that a documented negative result is worth more sitting next to the code than
erased from it. Neither should be re-tested blind; both are now conclusively ruled
out, not merely untried.

The real cause is still unknown. What both eliminations narrow it to: not a numeric
render parameter reachable through reflection on the screen's own object, and not
this particular render-setup trigger call. The remaining live hypothesis is that
whatever actually produces the black background sits at the shader or native
rendering level, below what reflection into managed objects can reach or influence
directly — which would mean the fix, if there ever is one, looks structurally
different from either attempt here.

## General lesson

A confirmed-successful write with zero observed effect, repeated across more than
one independently-plausible target, is real signal — it's not "the fix didn't work
yet," it's "this whole *category* of fix (numeric render parameters on this
object) is not where the bug lives." Recognizing that shift — from "try harder on
this lever" to "stop pulling this class of lever entirely" — is what let the second
attempt spend its effort on a structurally different kind of candidate (a trigger
method, not a parameter) instead of re-testing variations on the first idea.
