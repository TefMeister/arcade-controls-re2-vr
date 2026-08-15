# Three structurally different searches, three real negatives, one working theory

**Status:** Paused by choice after three independent, confirmed negative
results — not because any single test was inconclusive, but because all
three together started pointing at an explanation outside what this
tooling can reach at all.

## The symptom

Climbing a ladder in VR causes the camera to face whatever direction the
headset happened to be pointing at the moment of the last recenter,
instead of a consistent, expected forward direction — a jarring
re-orientation the player notices every time. Nothing in the existing
codebase touched ladders at all; this was entirely new territory, not a
regression.

## Search one: is it a component on the player?

The default first move for "what native thing controls this" in this
codebase is a name-based reflection scan: enumerate every component on the
player object, and every method on each, looking for anything
ladder/climb-named. Ninety-one real components, fully enumerated,
including their full method lists. **Zero matches.**

This is a clean negative, not an ambiguous one — the scan doesn't rely on
guessing a name in advance, it lists everything and filters after the
fact, so there's no "wrong guess" failure mode to worry about.

## Search two: does it reuse existing state this codebase already reads?

A different, cheaper theory: the codebase already has working logic for
detecting "the camera is currently doing something special" (originally
built for cutscene detection), reading four separate native signals. None
of them are ladder-specific by name, but if ladder-climbing happens to
set any of the *same* flags cutscenes do, that's a free, already-proven
detection lever with no new reflection needed.

First attempt at testing this got a **misleading result**: a single
manual button press to capture the state came back completely flat — no
signal at all. That looked like a second negative, but there was a real
reason to distrust it: the same codebase had already documented, in an
unrelated feature, that pressing an overlay button in VR requires taking a
hand off to interact with a menu, which can interrupt the very state being
measured (there, it was aiming; here, it's climbing). Rather than trust a
single instantaneous snapshot that might have been taken *after* the
climb was already interrupted by reaching for the button, the test was
converted to a five-second continuous capture: press once, then have time
to actually grab the ladder before the window starts logging.

**With that fixed, the result held up as a real negative.** Three hundred
consecutive frames, confirmed genuinely mid-climb the whole time, and the
camera-state signal stayed flat throughout — never touching either of the
two values already known from cutscene detection.

**Lesson:** a manual-trigger diagnostic and a time-sensitive state don't
mix well in VR — anything that requires reaching for a menu can interrupt
exactly the thing you're trying to observe. If a single-shot capture comes
back suspiciously empty for a state the user swears was active, suspect
the capture method itself before trusting the negative. A short continuous
burst, triggered once and then given time to let go of the trigger, is
worth the extra complexity for anything that's disrupted by menu
interaction.

## Search three: is there even a physical object nearby?

With both "on the player" and "reuses existing detected state" ruled out,
the remaining theory was that the mechanism lives on the ladder itself —
a separate scene object, not attached to the player at all. Rather than
guess the object's name (a low-odds bet with no way to verify a guess is
merely "not this name" versus "this approach doesn't work at all"), the
plan was to physically find whatever's nearby via a raycast, then inspect
whatever it hits.

First version — a single ray straight ahead from the camera, two meters —
got zero hits across an entire capture. In hindsight, an obvious problem:
the player looks around freely while climbing, so a ray tied to head
direction spends most of its time not pointed at the ladder at all.

Second version fixed that: three rays every frame instead of one — from
the character's body-forward direction (stable regardless of where the
head is looking), from the camera as a fallback, and straight down from
chest height (since climbing rungs are often below hand height) — with
the search range extended. **Still zero hits, on all three, for the
entire capture, confirmed genuinely mid-climb.**

That specific result — no contact in *any* direction, not just the one
that happened to be wrong — is a meaningfully different kind of negative
than "the ray missed." It's consistent with there being no solid,
raycastable collision geometry near the player during the climb at all,
which lines up with a common way games actually implement ladder climbing:
a scripted animation following a designer-placed path, where the
character's limbs never really touch physical rung geometry, rather than
a physics simulation of hands gripping rungs.

**Lesson:** when a search comes back empty, the *shape* of the emptiness
matters. One missed ray in one direction is weak evidence. Zero contact
across three independent directions and an extended range, while
confirmed active, is a real result — worth treating as evidence *for* a
specific alternative explanation (no physics collider present), not just
as "still haven't found it yet."

## Where it landed

Three independent, structurally different searches — object-graph
reflection on the player, reuse of an existing native detection system,
and direct physics probing of the surrounding space — each returned a
clean, confirmed negative. Together, they point toward the actual
mechanism sitting somewhere this tooling genuinely cannot reach from the
game side at all: most likely inside the VR runtime/camera layer's own
handling of scripted locomotion, not in any game-side object, component,
or physics geometry. Paused here deliberately, with the reasoning written
down, rather than continuing to guess at a fourth game-side mechanism with
no new evidence pointing anywhere in particular.

## Process lessons, independent of the eventual answer

- **A full enumeration beats a guess, every time reflection allows it.**
  Scanning every component and filtering by name afterward has no "wrong
  guess" failure mode; a targeted lookup by an assumed name does.
- **Distrust a suspiciously-empty result from any test that requires
  interrupting the state you're measuring.** If capturing the data
  involves an action that could plausibly end the condition you're
  observing (reaching for a menu, letting go of a controller), that's
  a real confound, not a hypothetical one — convert to a
  press-once-then-observe window instead of a single snapshot.
- **The shape of a negative result carries information.** One failed
  probe in one direction is weak; failure across multiple independent,
  structurally different directions/techniques is a real finding that can
  point toward *why* nothing was found, not just confirm the search needs
  to keep going.
- **Three confirmed negatives from three different search axes is a
  legitimate stopping point**, even without a positive answer — the same
  way a whole-type-database name search earlier in this project's history
  closed off an entire category of theory at once rather than just one
  member of it.
