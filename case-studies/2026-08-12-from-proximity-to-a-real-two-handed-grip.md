# From a proximity dock to a real two-handed grip — three bugs in, still going

**Status:** IN PROGRESS, paused mid-investigation by the developer's own choice
("rule out everything before giving up," not a dead end). Two real bugs found and
fixed from live log data during this session; a third, more serious one is open.
Written up now rather than waiting for a conclusion, because the debugging process
itself — real data over speculation, twice — is the reusable part.

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
