# "Block this from happening" is not the same lever as "make this happen"

**Status:** Fixed and confirmed working live, after one wrong hook point in between.
Written up because the failure mode — reaching for the wrong native API because it's
the *closest* one, not the *right* one — is easy to repeat.

## The ask

A VR control scheme wants a stick-click toggle for sprinting: press once to start
running, and it should stop the instant the stick returns to neutral *or* the button
is pressed again. The underlying game already has a native "Run Type" option
(Toggle/Hold/Always), but neither Toggle nor Hold alone matches the desired behavior,
and Toggle turned out to have its own separate bug (a one-way latch — pressing the
toggle key again mid-movement did nothing, it only cleared on a full stop).

## Wrong lever #1: inhibiting an order nobody was requesting

The game's character-control component exposed a real, already-proven-safe API:
`setInhibitPetient(bool, order)`, used elsewhere in the same codebase to temporarily
block a specific movement state from occurring during scripted sequences (e.g.
suppressing a run state during a manual reload animation). It looked like the right
tool: un-inhibit the run order while the toggle should be "on", inhibit it otherwise.

It compiled, ran without error, and did precisely nothing. The character never started
running under either setting.

The reason only became clear once it was named correctly: **inhibiting an order only
blocks or permits something that *something else* has to independently request first.
It can't manufacture a request.** In keyboard/gamepad play, holding a physical "run"
input is what generates that request; nothing in the VR control path was feeding an
equivalent signal, so there was never a request for the inhibit toggle to gate. The API
was real, safely-used elsewhere, and completely irrelevant to this problem — it answers
"is X *allowed* right now," not "make X happen right now."

**Lesson:** two APIs that both touch the same underlying state (a movement mode, a
UI flag, a permission bit) are not interchangeable just because they're on the same
object. "Permit/block" and "request/set" are different capabilities. Confirm which one
you actually have before building on it — in this case, confirming would have meant
asking "does anything currently request this order at all?" before reaching for the
gate.

## Finding the real lever, without guessing at it

Rather than guess at a second API, a read-only observation hook was installed on the
character's own per-frame update path, logging every value change of anything
plausibly related to the movement mode. This surfaced a genuine `get_X`/`set_X`
property pair — a proper accessor, not a raw animation-state field — that flipped
`false → true` at the exact moment real running started, and back on stop, called by
native code every single frame regardless of player input.

This was deliberately *not* written to on sight. A different raw animation-state flag,
investigated earlier in the same project, had already produced a lesson worth
respecting: forcing it directly didn't error, didn't even change on readback, and
silently froze movement outright. A clean `get_/set_` accessor pair being called
routinely by native code every frame is a much safer signal that it's a real,
intended write surface — but "safer" isn't "proven," so it was worth confirming the
call pattern first (every frame, both directions, correlated with real behavior) before
ever calling it from the mod's own code.

## Wrong turn #2: assuming there's exactly one call site

The first attempt at using the real lever hooked the *outer* per-frame update method
that (as far as the reflection dump showed) contained the call to this property, and
forced the desired value in that method's post-hook — reasoning that writing after the
one place it's set would make the mod's value "win" for the frame.

Live testing immediately falsified the assumption: running still wouldn't start under
one native setting, and under the other, the character would resume running if the
input was pressed quickly enough even after the mod's own code said it should be off.
Both symptoms point to the same root cause — **the property was being set from more
than one place per frame, or at a point this specific hook didn't actually precede** —
so "write after this one method" wasn't reliably last, it was just *a* place it got
written.

**Lesson:** a reflection dump showing a method that calls the property you care about
doesn't mean it's the *only* caller, or the *last* one that frame. An update method
found by name/proximity is a hypothesis, not a confirmed choke point, until tested.

## The fix that actually held: intercept the setter itself

The reliable fix skipped the "which caller runs last" question entirely by hooking the
property's setter directly with a pre-hook, and overwriting the incoming argument
before the native setter body ever ran. Every call to it that frame — regardless of how
many times or from where — lands on the mod's own value instead of native's, because
the interception point is the single funnel every caller has to go through, not one
caller among possibly several.

This is the same category of technique as overriding a function's *return* value from
a post-hook (a pattern already used elsewhere in the same codebase for boolean-returning
checks) — just applied to an *argument* instead, in a pre-hook, before the original
call executes. Confirmed working live afterward, including under the native setting
that has its own separate quirky latch behavior — forcing the value directly sidesteps
that native mode's internal logic rather than needing to fight it.

## General lessons

- **"Permit/block" and "request/cause" are different capabilities on the same
  underlying state.** An API name suggesting control over something doesn't guarantee
  it controls the part you need.
- **A clean accessor pair (`get_X`/`set_X`) called routinely by native code every
  frame is a much better sign of a safe write surface than a raw animation-state
  field** — but confirm the call pattern via observation before writing, especially
  after a prior direct-write attempt on a *different* flag caused real breakage
  elsewhere in the same investigation.
- **Finding "a" caller of the thing you want to control is not the same as finding
  "the only" caller, or "the last" one.** If forcing a value after one specific call
  site doesn't hold, the fix isn't "try a different specific call site" — it's
  "intercept the single point every caller has to pass through," i.e. the setter
  itself, not any one of its callers.
- **Overriding an incoming argument in a pre-hook is the argument-side equivalent of
  overriding a return value in a post-hook.** If one pattern is already proven safe in
  a codebase, the other is usually available too and solves a different half of the
  same class of problem.
