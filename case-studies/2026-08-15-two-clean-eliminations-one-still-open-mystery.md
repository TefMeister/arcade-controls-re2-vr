# Three clean eliminations and one that made it worse — closing out a background that won't stop going black

**Status:** RE-PARKED. Three independent, plausible-looking fixes for a
background-rendering bug have now all been tested to completion — two cleanly ruled
out with zero effect, one that actually made the symptom worse. Combined with six
earlier rounds against a different set of properties in an earlier session, every
angle reachable through reflection and native-method hooking is now exhausted. Not
a failure of the investigation — a complete, confident answer about where the fix
does *not* live, which is exactly the kind of result this repo exists to record.

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

## Attempt three: skip the whole screen, not just one call inside it — and it got worse

A separate, working reference point existed the whole time: a different interaction
(taking an item out of storage, as opposed to picking one up from the world) shows
no black background at all, and separately-confirmed diagnostic hooking had already
shown *why* — that interaction never calls the screen-open method in the first
place. It uses a completely different, structurally separate display path.

The obvious next idea: make regular pickups skip that same call too, the same way
the working interaction already effectively does, hoping to fall into whatever
clean path the working case uses. Built carefully scoped — gated so it only ever
applies during an actual pickup, never during a player deliberately re-examining an
item they already own from their inventory menu, which uses the exact same
underlying method for an unrelated purpose.

Tested live, with the feature that normally drives these pickups both off and on to
rule out interference: **the entire screen went black, not just the background.**
Worse than the original symptom, where at least the item itself still rendered
correctly against the broken backdrop.

**Lesson:** "a working alternative doesn't call this method" does not imply "not
calling this method gets you the working alternative's behavior." The working case's
cleanliness almost certainly comes from something specific to its *own* separate
code path, not from the mere absence of one call in the broken path. Skipping a call
that the broken path's own downstream logic silently depends on to reach a
half-working state can produce a *more* broken state than leaving it in — skipping
is not neutral just because it avoids calling something suspect.

## Where this leaves the investigation

All three toggles were left in the shipped mod as inert, harmless switches — off by
default, clearly labeled as confirmed dead ends (or worse) rather than deleted, on
the theory that a documented negative result is worth more sitting next to the code
than erased from it. None should be re-tested blind; all three are now conclusively
resolved, not merely untried.

The real cause is still unknown, and this specific investigation is now closed
without a fix. Nine total eliminations across two sessions — six against one set of
properties, three against another, plus the render trigger call and the screen-open
call itself — point at the same conclusion from every angle tried: whatever actually
produces the black background sits at the shader or native rendering level, below
what reflection into managed objects, or hooking their methods, can reach or safely
influence. Progress from here needs a fundamentally different kind of tool — frame
capture/shader debugging, or native plugin work — not another reflection-based
guess.

## General lesson

A confirmed-successful write (or a confirmed-successful skip) with zero — or
negative — observed effect, repeated across multiple independently-plausible
targets, is real signal, not a string of unlucky guesses. Two clean zero-effect
results said "stop adjusting parameters on this object." A third result that made
things actively worse said something sharper: the difference between the working
and broken cases isn't a missing or extra call at all, it's two genuinely different
systems, and no amount of nudging calls in the broken one will produce the working
one's behavior. Recognizing when a whole *category* of intervention is exhausted —
not just one specific attempt within it — is what let this close cleanly instead of
generating a tenth variation on the same idea.
