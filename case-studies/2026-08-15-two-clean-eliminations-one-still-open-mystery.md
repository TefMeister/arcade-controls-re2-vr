# It was never the mod's bug — closing out a background that won't stop going black

**Status:** CLOSED, with an actual root-cause answer, just not a fixable one. Four
fix attempts across two sessions all failed, but the last one failed in the single
most informative way possible — it wasn't even a fix attempt, it was a free test of
whether the symptom exists in the *unmodified* game at all. It does. This flips the
whole investigation from "this mod broke something" to "this specific native UI
screen doesn't render correctly in VR at all," which is a real, complete answer,
just not one any amount of further modding effort can act on.

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

## Attempt four: not a fix, a free test — does the unmodified game have this bug too?

One question was still open after attempt three: the screen that opens for a pickup
takes an internal mode value that changes its exact behavior (a "brand new item"
presentation versus a "you already have this" one), and a *different*, completely
native, never-modded interaction — manually selecting an item you already own from
your inventory to view its description — uses that same underlying method with the
other mode value. Nothing in this mod has ever touched that specific interaction.

Rather than write code to force pickups into that other mode — which carried a real,
specific risk given a past feature in this same codebase had already caused a hard
freeze by forcing this exact argument into a state that didn't match what the
engine internally expected — the actual question got tested directly, for free: go
into the inventory manually, look at an owned item's description, see what happens.

**Also black.** Immediately conclusive, and far more informative than another
elimination would have been: the value of that mode argument doesn't matter,
because the symptom isn't tied to pickups, to any mode, or to anything this mod's
code has ever touched. A totally unmodified, native interaction has the identical
bug.

**Lesson:** when a hypothesis is really "does behavior A differ from behavior B,"
check whether B already exists somewhere in the unmodified program before writing
code to manufacture it artificially. Here, B (mode=2's rendering) was one manual
button press away in the existing game, fully untouched by any mod code — testing
it directly cost nothing and carried zero risk, versus writing new code with a
known, structurally-similar precedent for causing a hard freeze, to answer a
question the game itself could already answer for free.

## Where this leaves the investigation

All three code-based toggles were left in the shipped mod as inert, harmless
switches — off by default, clearly labeled as confirmed dead ends (or worse) rather
than deleted, on the theory that a documented negative result is worth more sitting
next to the code than erased from it. None should be re-tested blind; all are now
conclusively resolved, not merely untried.

But the real finding is the fourth attempt: this was never this mod's bug to begin
with. The native detail/examine screen doesn't render correctly in VR through this
VR injection layer, full stop, independent of pickups, independent of which mode
it's opened with, independent of anything reachable through Lua reflection or
method hooking. Ten total eliminations across two sessions all pointed the same
direction — shader/native-rendering level, below what this mod's tooling can reach
— but it was the one test that touched zero mod code at all that turned "probably
unreachable" into "confirmed to already exist in the unmodified game." **Closed by
the player's own call, and the correct one:** accept this as a genuine engine/VR
limitation, not something to keep chasing.

## General lesson

A confirmed-successful write (or skip) with zero — or negative — observed effect,
repeated across multiple independently-plausible targets, is real signal: each one
narrows what *isn't* the cause. But the single most decisive piece of evidence in
this whole investigation wasn't a fix attempt at all — it was checking whether the
unmodified game already exhibits the same symptom somewhere untouched by any of
this code. That question is worth asking *before* committing to a risky code-based
test, not just after several code-based tests fail: if the "healthy" comparison
point turns out to have the same bug, no amount of code will ever close the gap,
because there isn't one to close.
