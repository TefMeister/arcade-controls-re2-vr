# Smoothing a snap the Lua layer never actually controlled

**Status:** Abandoned as a dead end after several rounds of live testing, and fully
reverted. Written up because the failure mode is subtle and easy to walk into again:
every individual piece of logic was doing exactly what it was told, and still had no
effect on what the player saw.

## The ask

In a VR mod, bringing a controller-tracked hand near a two-handed weapon causes the
game's own hand-IK to instantly snap it into a "supporting" grip pose — no
interpolation, just a one-frame pop. A different feature in the same codebase (a
manual slide-rack grab) already had a smooth version of essentially the same motion,
built by blocking the engine's native hand IK and driving the arm with a custom
two-bone solver instead. The ask was to get that same smoothness on the general
support-grip snap.

## Wrong turn #1: smoothing the value that gets read back stale

The natural first move: find the position value the engine's IK system reads each
frame, and instead of letting it jump, write an eased version of it for a few frames
after the snap starts. This compiles, runs without error, and produces a
mathematically correct blend when logged — start position, end position, easing
curve, all verified by printing them frame by frame.

It had zero visible effect. The giveaway, once instrumented properly: logging the
*raw* value at the top of the frame (before the smoothed write) showed it barely
changing at all across the blend window, never reflecting what had been written the
frame before. **The engine was recomputing that field itself, every frame, from its
own internal state — not reading back whatever got written into it.** The value
looked like a mutable target the mod could steer; it was actually closer to a
read-only report of a decision made elsewhere. Nothing about the code was wrong; the
premise that this value was the thing controlling the visual result was wrong.

**Lesson:** before smoothing a value, confirm you can actually *change* the rendered
outcome by writing to it — not just confirm the write succeeds and the arithmetic is
correct. A write that silently gets overwritten before it's ever consumed looks
identical, from the inside, to a write that worked.

## Wrong turn #2: fixing real bugs that didn't touch the actual cause

Switching to the technique that was already proven to work elsewhere (block native
hand IK, drive the arm with a custom solver, feed it the eased position) did produce
visible smoothing in the best case — confirmed by the person testing it live. But it
also surfaced a cascade of new, real problems:

- **Rapid re-triggering at the trigger-condition boundary.** The "is this now docked"
  check flickered true/false many times in under a second whenever the underlying
  physical condition hovered near its threshold, and each flicker restarted the blend
  from a freshly-captured origin. Fixed with a debounce (ignore a drop below threshold
  unless it persists past a short window) — a real bug, confirmed via timestamped log
  bursts, genuinely fixed.
- **A stale global.** A distance-check function was reading a cached position that a
  *different*, only-sometimes-active feature wrote and never cleared back to a neutral
  value — so once that other feature had ever fired even once in the session, the
  distance check silently compared against a frozen position instead of live tracking,
  making the new feature look "stuck" no matter where the hand actually moved. Also a
  real bug, also genuinely fixed, by gating the stale read behind the same flag a
  *different* function already correctly used to gate its own read of the same global
  — the inconsistency between two readers of one value was the actual defect.

Both fixes were correct and are worth keeping in general. Neither one fixed the thing
the person actually wanted, because neither one was the reason the *unwanted* snap
(the one this whole feature was trying to prevent, not produce) kept happening.

**Lesson:** finding and fixing real, verifiable bugs along the way can feel like
progress and *is* progress — but it doesn't validate the surrounding hypothesis. It's
possible to be several genuine bug-fixes deep into a wrong theory.

## The actual finding: a condition can be 100% correct and still not matter

The last change was removing a fallback that let the engine's own internal "is
gripping" signal short-circuit past this mod's own trigger condition, so that only
the mod's explicit condition could cause the snap. Live logging afterward confirmed
this worked *exactly* as coded: the explicit condition was false in the tested
scenario, and stayed false throughout, with the underlying inputs to that condition
logged frame by frame to prove it.

The snap happened anyway.

That's the actual root cause, and it only became visible once the condition itself
was proven correct rather than assumed correct: **the condition never controlled
whether the engine snapped the hand. It only ever controlled whether *this mod* added
extra smoothing on top of whatever the engine was already going to do.** When the
condition was false, the code did nothing at all — and "doing nothing" meant passively
showing through whatever the engine's own independent, closed-source logic decided,
unaffected by any Lua-side condition whatsoever. Every fix up to that point had been
correctly answering "should we add smoothing here?" while the actual question — "can
we stop the engine's own snap from happening?" — had never been addressed, because the
two questions look identical from the outside until you can prove one of your own
conditions is doing exactly what you designed it to do and the visual result still
doesn't move.

## What the real fix would require

Not attempted, but scoped: the only way to prevent an unwanted engine-driven snap
(rather than smooth a wanted one) is to stop *ever* letting the engine's own hand-IK
run — block it unconditionally and drive the hand yourself at all times, following
real tracked input when idle and blending to a grip pose when appropriate — instead of
opportunistically overriding it only during the moments you want a different result.
That's a materially larger scope (you inherit responsibility for every case native
tracking used to handle for free, not just the one you were trying to fix) and was
explicitly left for a future attempt rather than started blind.

## General lessons

- **A value you can successfully write to is not necessarily a value that controls
  the outcome.** Confirm causality (does changing this actually change what renders?)
  separately from confirming the write itself succeeds.
- **Logging that proves your own condition is correct is more valuable than logging
  that proves your fix ran.** The turning point here was proving a Lua-side condition
  was false exactly when expected — and only *then* noticing that truth didn't matter,
  because the effect it was supposed to gate wasn't actually gated by it.
- **Real bugs found mid-investigation aren't evidence the investigation is on the
  right track.** Keep them, but don't let fixing them substitute for re-checking the
  core hypothesis.
- **"We can make X happen" and "we can stop X from happening on its own" are
  different capabilities**, especially when X is driven by code you don't own. Being
  able to add a smoothed override on top of a trigger you control says nothing about
  whether you can suppress a trigger you don't.
- **Knowing when to stop is itself a useful outcome.** This was reverted in full
  rather than left half-working, once the real scope of an actual fix became clear —
  documented here specifically so a future attempt starts from "block everything,
  always" instead of re-discovering that opportunistic overriding can't win against
  independent native logic.
