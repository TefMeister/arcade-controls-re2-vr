# Replacing a tracked-hand pump gesture with a discrete trigger press

**Status:** Fixed and shipped — later became the template for two more
weapons' reload gestures (see the companion slide-rack teleport case study).

## The symptom

One of the manual-pump shotguns modeled the pump-action reload as a real
hand gesture: grip the pump handle with the off-hand controller, then
physically pull it back and push it forward, with the game measuring the
tracked distance your hand actually moved. It felt great when it worked.
In the middle of an actual encounter it didn't work reliably enough —
missed pulls left the gun unchambered at the worst possible moment.

This wasn't a bug in the usual sense. The gesture-tracking code was doing
exactly what it was built to do: watch hand position, compare it against a
distance threshold, decide whether a pull happened. The problem was the
input itself — controller tracking jitter, players not pulling quite far
or fast enough, and the code's own logic for locking onto a pull direction
from a noisy first sample. All of that is inherent to *any* continuous,
tracked-distance gesture in VR. No amount of threshold-tuning was going to
make it reliable enough for something that gates whether your gun fires.

## The reframing

The fix wasn't "tune the gesture better" — it was noticing that the
gesture had two very different parts glued together, only one of which
was actually the reliability problem:

- **Hand placement and shell insertion** — reach for the forend, dock your
  hand there, load shells. This part relied on continuous tracking too,
  but it worked fine; nobody complained about it.
- **The pump stroke itself** — the pull-back/push-forward motion that
  chambers a round. This was the unreliable part, and it's also the part
  that has an obvious discrete equivalent: a button already under that
  hand.

So the fix left hand-docking and shell insertion completely alone and
replaced only the stroke: hold the off-hand grip to dock to the handle
(unchanged), then press and hold the trigger to represent "pulled back,"
release to represent "returned and cycled." A continuous, error-prone
measurement became a binary controller state — the least reliable part of
the interaction became the most reliable part, without touching the parts
that were already working.

## What this bought, and what it cost

Reliability, straightforwardly — a digital button state can't have the
"didn't pull far enough" or "wrong axis locked in" failure modes a
tracked-distance measurement can.

The cost was gesture fidelity: because the trigger is a binary hold, the
pump joint's visual position has no genuine "partial pull" state to
represent, and without any added easing it would snap directly between
parked and pulled rather than gliding. That trade was made deliberately —
reliability was the actual ask, not motion fidelity — but it's the kind of
decision worth writing down explicitly, since "the animation snaps" reads
like an oversight if you don't know it was a conscious choice with a
`os.clock()`-based glide identified as the follow-up if it read as too
abrupt in testing.

## What was left untouched, and why that mattered later

The rewrite only replaced the function that decided *when* a pull started
and ended. It deliberately reused, unchanged:

- the bind-pose blending math that actually animates the joint,
- the shell-insert/dock logic,
- the off-hand support IK docking logic,
- the completion function that handles chambering, sound, and haptics.

The new trigger-driven code just drives the same two state fields
(something like "how far pulled" and "pull committed") that this
downstream logic already read. That decision — swap the *input source*,
keep the *state shape* identical — is what made this pattern portable.
When the same tracked-pull reliability problem showed up later on a
different weapon's slide-rack step, the fix was a near-line-for-line port
of this same trigger-driven approach, because the downstream animation and
completion code didn't need to change at all, only the code deciding when
a pull started and ended. (See the companion case study on the bugs that
port introduced — the port itself was easy; getting the *visual hand
position* to update correctly across multiple competing per-frame writers
was not.)

## General lesson

When a VR gesture is unreliable, it's worth asking whether the whole
gesture actually needs to be continuous, or whether only *part* of it
does. Splitting "the part that needs real tracked motion for immersion"
from "the part that's really just a binary state dressed up as a
gesture" can let you replace only the unreliable half with a discrete
input, while reusing all the animation and game-logic plumbing built for
the original tracked version. The reuse isn't incidental — designing the
replacement to write into the *same* state fields the existing downstream
code already consumes is what makes it a clean swap instead of a parallel
implementation.
