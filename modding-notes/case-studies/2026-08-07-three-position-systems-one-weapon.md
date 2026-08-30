# Tuning a VR grab point that silently did nothing — three lookalike systems, only one of them live

**Status:** Fixed and confirmed working, after three separate wrong turns on the
same weapon. Written up mainly for the shape of the mistake, since it's an easy one
to repeat: a codebase can have several similarly-purposed config tables for what
looks like the same feature, and tuning the wrong one produces no error and no
crash — just silence.

## The ask

A revolver's VR reload had a bullet-insertion grab point (the world position your
hand needs to reach, while holding a round, to trigger loading it) sitting in the
wrong place — near the frame of the gun instead of near the cylinder. The fix should
have been simple: find the config value that controls that position, nudge it.

## Wrong turn #1: the joint that isn't used

The first candidate was a per-weapon config table mapping weapon IDs to a named
joint on the mesh — exactly the shape of thing that sounded right. This weapon's
entry for that table was missing entirely, silently falling back to a hardcoded
default joint that happened to be correct for two *other* weapons sharing the table
but had never been verified for this one. Setting it explicitly, first to a
plausible joint, then to a different one when that missed too — both live-tested,
both wrong.

Rather than keep guessing joint names, the next step was pulling real data: dump
every joint on the weapon's mesh with its actual local coordinates. That data
revealed something the name-guessing couldn't have: every candidate joint sat
almost exactly on the gun's own centerline. The original ask had a distinct
sideways component ("move it left"). No joint swap could ever produce that, because
none of them were offset to the side in the first place. That single fact ended the
guessing — the fix needed an *added offset*, not a different anchor point.

An offset was added, confirmed by a live test to move in the correct general
direction... and then, on the next test, felt like it had stopped doing anything at
all. Suspecting the offset math might not even be running, a debug log was added
directly at the point the value gets applied. It confirmed the arithmetic was
correct down to four decimal places — the number really was what it was supposed to
be. And still: no visible effect, and this player-facing feature has nothing to do
with the value that had just been meticulously debugged.

**The actual explanation, found only afterward:** this joint/offset system governs
*extracting a spent shell from the chamber* — a real, separate feature — not
*inserting a new one from the ammo pool*, which is what was actually being tested
the whole time. Correct math, wrong feature. No error, because there wasn't one;
the code was doing exactly what it was told, on a path that simply wasn't being
exercised by the interaction being tested.

## Wrong turn #2 (implicitly): trusting a distance-measuring function that never fired

Before finding the mismatch above, a second live debug log was added inside the
function that resolves *which* of several candidate world positions is "closest"
for a grab check — reasoning that if a second, untouched candidate happened to be
nearer to the hand than the one being tuned, it would silently win every time and
make the tuning invisible. That log never printed once, across several player test
attempts. A function that never fires is itself a diagnostic result: it meant the
whole code path containing it wasn't part of the live interaction at all, which is
what eventually forced a search for the *actual* function driving the observed
behavior — the one used for insertion — rather than continuing to instrument the
extraction path more precisely.

**Lesson:** when a debug log you *know* should fire during the exact action you're
testing never appears, stop trusting your model of which function is responsible.
That absence is a stronger signal than any amount of "the math looks right."

## Finding the real target

Searching the file for insertion-specific function names (rather than anything with
"grab" or "dock" in it, which had already led astray) turned up a distinct pair of
functions measuring distance against a completely different config value — one that
also had no entry for this weapon in the obvious place (the same file's hardcoded
defaults) but *did* have one in the persisted runtime config that overrides those
defaults at load time. That's a second, independent trap layered on the first: even
after finding the right conceptual system, the first edit to it also had no visible
effect, because it landed in the file that gets silently overridden by already-saved
state. The fix had to go into that saved state directly, not the source defaults.

With the real value identified, live tuning happened quickly and normally: several
rounds of "3cm this way, 5cm that way," including one deliberate large overshoot
specifically to double check the axis mapping was really responding and not
imagined, before converging on numbers that felt right.

## A second, related bug the fix uncovered

Once the grab point was correct, a new problem appeared: the bullet's *visual
insertion animation* — the little flight from hand to chamber — now ended at the
newly-tuned, ergonomically-correct grab spot instead of at the actual chamber hole,
because both had been driven by the exact same position value the whole time. The
weapon actually uses a separate rendering technique for chambered rounds (pre-placed
meshes at each chamber slot, shown or hidden rather than moved), and the animation
was never supposed to share its endpoint with the grab-detection point at all — it
should end at the chamber's own real position, which happens to already be computed
and cached elsewhere in the same file for an unrelated reason (the very first, wrong
system from turn #1). Once identified, the fix was to make the animation use that
already-correct cached position instead of the tunable grab point, for any weapon
using this per-chamber rendering style. That also incidentally caught a live bug:
the offset from turn #1's dead end was still being applied unconditionally to that
same cached position, quietly corrupting it, even though it no longer had any
purpose. It had been left in on the reasoning that an unused value is harmless — true
right up until a *different* fix starts reading the same field for a new purpose.

## General lessons

- **A feature that looks singular in the UI can be backed by more than one
  independent system in code**, each answering a different question that sounds
  similar from the outside ("where do you grab from" vs. "where do you insert to"
  vs. "where does it land visually"). Confirm which one you're actually looking at
  before trusting a name.
- **Correct math on the wrong function is indistinguishable from a typo, from the
  outside.** A debug log that prints exactly the values you expect only tells you
  the code you're looking at works — not that it's the code doing the thing you're
  observing.
- **A log statement that never fires is data.** Don't just add more logging around
  a function you assume is responsible; notice when a function you're certain
  should run during a specific action stays silent, and go looking for what
  actually ran instead.
- **A config value with no entry for the thing you're testing might be silently
  using a shared default that was only ever validated for something else.** Missing
  configuration doesn't error, it just quietly borrows a neighbor's answer.
- **The same override-precedence trap can bite twice on one weapon.** Confirming a
  key exists in the live/persisted config (not just the source defaults) needs
  checking every time a new key is touched, not just once per project.
- **"Unused, so harmless" doesn't survive a later fix that starts using the same
  field for something new.** Worth actually reverting dead values once confirmed
  dead, not just leaving them because they're not doing anything *yet*.
