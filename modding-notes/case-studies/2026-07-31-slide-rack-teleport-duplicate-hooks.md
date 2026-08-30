# Porting a working gesture pattern to a new weapon still teleported — three unrelated root causes

**Status:** Fixed and shipped, confirmed working. All three root causes
belong to the same *class* of bug, even though they lived in three
different functions.

## The setup

A pump-action shotgun's reload had already been converted from a
tracked-hand pull gesture to a trigger-driven one (hold trigger = pulled,
release = returned + cycle complete — see the companion case study). A
different weapon's final reload step — racking the slide after inserting
a new magazine — needed the same conversion: grip to grab the slide
(unchanged), trigger to drive the pull instead of tracked hand distance.

Porting the state-machine logic was close to line-for-line, since the
original pump conversion had deliberately been written to keep its
downstream animation/completion code separate from the input-decision
code (that separation is the whole point made in the companion case
study). The port worked immediately for chambering, sound, and reload
completion. The problem was purely visual: the *hand* — the thing the
player is actually watching, since it's meant to visually track the
controller pulling the slide back — teleported between two fixed
positions instead of gliding, even though the working shotgun version of
this same pattern glided fine.

## Three fix attempts that didn't work, and why they were still useful

Before finding the real causes, three plausible theories were tried and
ruled out:

1. **Higher-frequency ticking.** The working shotgun version ran its
   per-frame update from an earlier pair of hook points than the new
   port did; matching that timing seemed like the obvious fix. It changed
   nothing.
2. **Publishing the hand-follow target more often**, on the theory that
   the target position wasn't being republished fast enough to keep up
   with the (correctly eased) underlying value. No change.
3. **Calling the arm-IK bending function directly** inside the new
   per-frame update, on the theory that the *target* was fine but the
   *IK application* was still running at the old, slower cadence. No
   change.

None of these were bad guesses — each one targeted a real, plausible link
in the pipeline (tick rate → target publish → IK application). What made
them useful despite not working: each failure narrowed the search by
ruling out an entire stage of the pipeline, which is what made it obvious
the next step needed actual data instead of another theory.

## Root cause #1 — two hooks, one frame, one stale write

Debug logging on the underlying pull-distance value showed it climbing
smoothly and monotonically every single call — so the eased math itself
was never the problem, confirming the theory behind attempt 1 was chasing
the wrong layer entirely.

But that "every single call" was itself the clue: attempt 1's fix had
made the update function run from *two* different native hook points
per rendered frame, and the logged hand position alternated in lockstep
with which hook had triggered the call. Calls from one hook read back a
frozen position (the pre-pull pose, never advancing); calls from the
other read back the correctly progressing position. Two writers per
frame, racing — one publishing the real value, the other immediately
overwriting it with a stale one, every frame. That alternation *was* the
visible teleport.

The mechanism: the function that publishes the hand's visual position
reads a joint's cached world-space transform immediately after this same
code writes that joint's local position. The engine only recomputes the
cached world transform during its own native processing pass, which had
completed in time for one of the two hooks but not the other. Same
write, same frame, but only one of the two read points had a
post-recompute value available to read.

**Fix:** only publish the visual hand position from the hook that
reliably read the fresh transform; the other hook still advances the
underlying eased value (for update-rate smoothness) but stops touching
anything the player actually sees. Confirmed via the same debug logging,
now tagged by which hook produced which line — the two call sites
stopped disagreeing.

## Root cause #2 — a sibling function nobody remembered to gate

Fixing root cause #1 didn't fix the teleport. It changed the symptom: now
the pull *snapped* instead of gliding, and — new and stranger — while
holding the grip, trigger, and moving the physical controller all at
once, the slide could visibly be dragged back and forth by real hand
movement, which the trigger-driven version was never supposed to respond
to at all.

The original tracked-hand gesture and the new trigger-driven one weren't
the only code touching this joint. A third, older function — part of a
"park the slide open when nothing is grabbing it" display behavior — also
wrote to the same joint every frame, from three more hook sites. It had
sibling functions that already had an explicit guard skipping them when
the new trigger-driven mode was active; this one didn't, seemingly just
missed rather than deliberately left out. While a trigger-driven pull was
in progress, this ungated function was independently computing the
joint's position from live controller/hand tracking data and writing it
— racing against the two legitimate trigger-driven writes, every frame.

That explains all three symptoms at once: the snap (multiple writers
disagreeing within a frame), the hand-tracking-drives-the-slide behavior
(this function's own formula *is* hand-tracking-based), and a specific
one-frame jump that had shown up right at the pull-committed transition
in the earlier debug log — exactly the frame where this function's own
internal formula switches from one calculation branch to another.

**Fix:** add the same guard its siblings already had — skip this
function entirely while a trigger-driven cycle is active on this weapon.
It still does its original job (parking the slide open) for every case
that isn't this new one.

## Root cause #3 — state that only got reset by an unreachable code path

With #1 and #2 fixed, the mechanic worked — until testing across multiple
reload cycles in the same play session surfaced a third bug: on the
*second* trigger-rack reload (and every one after), grabbing the slide
would sometimes play out the entire pull-and-release animation
automatically in about a second, with the trigger never touched at all.

No debug logging was active for this one (it had already been stripped
out once root causes #1 and #2 were confirmed fixed), so this one was
found by reading the code rather than watching data. Three state fields
tracked the trigger-driven pull's progress and commit status. Two reset
points existed for them, both inside the same per-frame update function —
but one was unreachable dead code (gated behind a condition its own
caller had already filtered out before ever reaching it), and the other
only ran on an *aborted* grab, never a normal successful completion.
Nothing else in the codebase ever reset these fields. So after the first
successful cycle in a session, the "committed" flag was left permanently
true. On the next grab, a *different* field correctly reset to its
starting state, but the stale committed flag didn't — so the very first
frame of the new grab read "committed" as true and animated straight to
a full pull, with no regard for the trigger's actual state, before the
player had done anything.

This also explained why testing had missed it for so long: reloading the
scripts during development reset all state to its zeroed defaults,
masking the bug every time — it only appeared on a *second* reload within
one continuous play session without a script reload in between.

**Fix:** add the missing reset for all three fields to the function that
starts a fresh grab, alongside the resets already present for the other
state this gesture tracks.

## The pattern across all three

Every root cause here is a version of the same underlying problem: a
piece of state (a joint's position, or flags describing gesture progress)
had more than one writer, and at least one of those writers didn't know
about — or wasn't updated for — the new trigger-driven mode:

- Two hook call sites racing to write the same visual output in the same
  frame.
- A pre-existing function racing to write the same joint from a different
  data source, because a guard its siblings already had never got added
  to it.
- State that only had a reset path for one of the two ways a gesture
  cycle can end, so the other ending silently left it stale for next
  time.

None of these would show up from reading the new code in isolation — each
one only exists at the *boundary* between the new code and something
older it now has to coexist with. The practical lesson: when porting a
working pattern to reuse existing lower-level plumbing (the animation
blending, the "park it when idle" display logic, shared state fields),
audit every other place that plumbing gets written to or reset, not just
the places that read it. A missing guard or a missing reset in a sibling
function is invisible until the exact runtime sequence exposes it, and
by design it won't be near the code you're actually changing.
