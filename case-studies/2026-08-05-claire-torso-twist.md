# Claire/Ada's torso visibly twisting ~40° in VR

**Status:** Fixed and shipped (both as part of a larger mod, and as a
standalone fix for people who don't want the rest of it).

## The symptom

Playing as Claire (or Ada) in VR, looking down at your own body while
holding a weapon showed the torso twisted roughly 40° relative to how it
should sit. Leon's weapon-hold poses didn't have this problem — it was
specific to certain characters' animation sets. In flat-screen play
nobody would ever notice this, because you never see your own character's
torso from the inside; it only becomes obvious once you're embodying the
character in a headset and can look down.

Arm position, weapon position, and shooting were all unaffected — this
was purely a torso/spine visual issue.

## Dead end #1: swapping animation files

The first idea was the simplest one: if Leon's hold animation doesn't
have the twist, copy Leon's compiled animation file onto Claire's
character so she uses the same pose data.

This doesn't work, and it's worth knowing *why* it doesn't, because it's
not a file-path or packaging problem — it looks like it should work right
up until you test it. Compiled animation data in this engine is
skeleton-specific binary data. It's not a portable "rotation curve" format
that happens to be keyed by bone name; it's baked against the specific
skeleton it was authored for, even when both skeletons belong to
characters in the same game and the same animation category. File
placement and the mod-loader's cache invalidation were both independently
confirmed correct — the swap itself was the dead end, not the packaging
around it.

**Lesson:** if two characters share a game and an animation taxonomy,
that doesn't mean their compiled motion data is interchangeable. Don't
assume portability without a positive test; "same category, different
character" is enough to break it silently (no error, just a wrong or
default pose).

## Dead end #2: spoofing the weapon category

Second idea: force the equipment system to report a different weapon
type was equipped, on the theory that a different weapon category has a
default pose without the twist, and that pose might get borrowed.

This failed in an instructive way: spoofing to a weapon category that
should have had a clean pose didn't reproduce that pose's spine value at
all — *and* it visually swapped in the wrong weapon model, since the
same field that selects the pose also selects what's rendered. Two
failures for the price of one hack. Ruled out and not worth revisiting.

## Dead end #3: a per-character "arm corrector" component

The game has a component (visible via reflection) responsible for
correcting arm rotation in specific situations — the name suggests it's
for preventing the arm from clipping into geometry ("buried" arm
poses). Real per-character differences were found in this component's
data between Leon and Claire, which made it a plausible suspect.

Forcing its rotation output to identity had **zero visible effect** on
the model. This is the kind of negative result that's easy to
misinterpret — it doesn't just mean "not the cause," it also revealed
(much later, during a follow-up investigation into a different bug) that
this component appears to sit inactive/null during normal aiming and
only actually engages in the wall/geometry-clipping scenario its name
implies. Forcing an inactive value to a different inactive value
naturally produces no visible change, independent of whether it was ever
a good suspect. Worth keeping in mind: a "no effect" result only tells
you the thing is inert *right now*, under the specific conditions you
tested — not that it's structurally irrelevant.

## What actually worked

The fix that stuck: bypass animation selection entirely and correct the
pose one layer lower, after the animation system computes it but before
anything downstream reads it. Every frame, directly overwrite the
`spine_0` joint's local rotation, blending it toward identity by a
tunable "strength" value (0 = untouched, 1 = fully straight).

Two details made this work rather than just mostly work:

**Hook timing.** The character's arm/weapon inverse-kinematics solve
runs later in the same per-frame update pass and reads `spine_0`'s
rotation as an input to compute where the hand should end up. Applying
the spine correction with a **pre**-hook (before that IK solve runs) lets
the IK solve against the *already-corrected* spine, so the hand and
weapon end up visually consistent. Applying the identical correction with
a **post**-hook (after the IK solve has already run and committed to a
hand position based on the *old*, twisted spine) leaves the weapon
visibly pointing off to one side, even though the torso itself looks
fixed. Same correction, same magnitude, wrong side of one native system's
read of the data — visually broken in a different way than the original
bug. This is a general trap: "did I apply the fix" and "did I apply the
fix before the thing that reads this value" are different questions, and
getting the second one wrong can look like a completely unrelated new
bug rather than an ordering mistake.

**Speed-based fade.** A constant-strength correction looks perfect
standing still but fights the game's own walk/run animation sway, which
also moves the spine. The result was visible camera shake while moving,
worse at higher speed — confirmed to scale with correction strength by
toggling it live (full strength = visible shake, half strength = less
shake, off = no shake). The fix was to fade the effective correction
strength down as measured movement speed increases (down to a small
fraction by a normal walking pace, to zero by a run), using the same
smoothed speed estimate the movement code elsewhere already computed.
Both speed thresholds ended up exposed as live-tunable sliders rather
than hardcoded, since "how fast is a run" isn't something you can get
right on the first guess.

## Verification

Confirmed with both flat-screen testing and, separately, a real in-headset
VR pass — the two aren't equivalent for this kind of visual/embodiment
bug, and it was worth explicitly re-confirming in-headset rather than
assuming a flat-screen pass was sufficient.

## General lessons

- When a "no effect" result comes back for a component you suspected,
  hold onto *why* you suspected it — that reasoning might turn out to be
  right about the component just wrong about which bug it explains. (See
  the companion laser-sight case study, where this exact component came
  back into consideration for a different symptom.)
- Hook/callback ordering relative to native systems that consume the same
  data you're overwriting matters as much as the overwrite itself. If a
  fix "mostly" works but something downstream looks subtly wrong, check
  ordering before assuming the fix's logic is incomplete.
- A visual fix that looks right in one input state (standing still) needs
  testing across the states that actually occur in play (walking,
  running) before calling it done — animation-driven values rarely sit
  still.
