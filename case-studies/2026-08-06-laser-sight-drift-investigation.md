# Laser sight beam drifting ~30-50° off aim, in VR only

**Status:** Unresolved / in progress. Documented as-is because the
elimination process so far is useful even without a final answer yet.

## The symptom

With the torso-twist fix (see the companion case study) applied and
confirmed working — weapon model, arms, and bullet trajectory all
visually correct — the game's native laser sight attachment still
projects its dot roughly 30-50° off from where the gun is actually
aimed, consistently toward one side. No visible beam line, just the
red dot landing in the wrong place on a wall.

This matters as a case study specifically because everything *else*
about the original bug was already fixed. The interesting question isn't
"why is there a twist" (already solved) but "why does one specific
native visual effect still disagree with a pose that's otherwise been
confirmed correct by every other measure available (mesh, arms, actual
bullet impact)."

## Establishing the shape of the bug before guessing mechanisms

Two live tests, cheap to run, before writing any more probing code:

1. **Does it track the fix at all?** Toggling the torso-fix's correction
   strength from 0 to 1 live and watching the laser: it moved. This
   ruled out "completely unrelated to the fix" and confirmed the beam's
   direction is coupled to whatever the fix changes, just not correctly.
2. **How big is the error, precisely?** Not "off" — specifically
   30-50°, eyeballed against a wall. That number matters: it's
   comparable in size to the *original* twist bug (25-55°, per the
   torso-twist case study), not a small few-degree residual. That
   pushed the working theory away from "a fine correction gap" and
   toward "reading something still substantially uncorrected."

Getting a concrete magnitude and a yes/no on coupling *before* writing
more diagnostic code avoided several rounds of building an instrument
aimed at the wrong scale of problem.

## Ruling things out systematically

Each of these was a specific, falsifiable guess, tested and eliminated
in turn using the game's own reflection API (see the companion technique
note on this) rather than reasoning from documentation that doesn't
exist for this engine:

- **A dedicated joint on the weapon mesh.** Dumped every joint name on
  the equipped weapon's skeleton. Same 12 joints whether the laser was
  active or not, none named anything like "laser"/"sight"/"dot". Ruled
  out: nothing joint-based on the weapon itself is a separate laser
  emitter.
- **A separate child GameObject.** Skeletal joints aren't the only way a
  VFX prop can be parented in this engine — walked the actual
  GameObject/Transform child tree of both the weapon and the player.
  Zero children on both. Ruled out, and also a useful negative data
  point about how this engine's attachment props generally *aren't*
  simple Transform children of the object they're visually attached to.
- **A same-frame IK timing gap.** The working theory from the original
  twist fix was "one native system reads a value before another system
  finishes correcting it." Directly measurable: sample the muzzle
  joint's world-forward vector both at the fix's own early hook and at
  the same late point the bullet-trajectory code reads it, same frame,
  compare the angle. Result: 0.00°. The muzzle joint itself is fully
  stable across the frame — this specific timing-gap theory, however
  plausible from the previous investigation, does not apply here.
- **A named component directly on the object (not a child, not a
  joint).** Dumped every component class attached to both the weapon and
  player GameObjects directly. Long lists (meshes, physics colliders,
  audio triggers, IK controllers, etc.) — nothing with "laser" or
  "sight" in the class name either.
- **The same arm-corrector component from the original twist
  investigation.** It was already known to exist on the player and had
  history (see the companion case study) as a plausible-but-ruled-out
  suspect for the *original* bug. Worth a fresh, specific test against
  *this* bug, since "ruled out for symptom A" isn't the same claim as
  "ruled out for symptom B." Turned out only one of its several fields
  was even the right data type to test meaningfully (a UI mistake caught
  by checking types before trusting a "no effect" result), and that
  field came back as inactive/null during normal aiming — consistent
  with the component being for wall-clipping prevention, not general
  aim-pose correction. Also a dead end, but a narrower and more
  confidently-closed one than the first pass suggested.

## Where it stands

Still open: whether the beam reads the player's raw hand/wrist bone
(pre-IK-compensation) rather than the weapon's own muzzle joint (which
is confirmed correct). That's the next concrete, falsifiable thing to
test — not yet done as of this writing.

## Process lessons, independent of the eventual answer

- **Get a magnitude before guessing a mechanism.** "The laser is wrong"
  supports dozens of theories. "The laser is wrong by roughly the same
  amount as the original, already-understood bug" rules out most of
  them immediately and points at "still reading something substantially
  uncorrected" rather than "a fine leftover gap."
- **A component being ruled out for one symptom doesn't close it for a
  different symptom**, especially when the second investigation didn't
  exist yet at the time of the first test. Re-test specifically, don't
  assume the old verdict transfers.
- **Check that a "no effect" test was actually a valid test.** A
  checkbox that silently no-ops because of a type mismatch will report
  "no effect" indistinguishably from a real negative result. Verify the
  mechanism fired before trusting what it reports.
- **When a UI-based live test comes back ambiguous, ask for a
  screenshot rather than a transcription.** A live status panel with
  several similarly-worded lines is easy to misread over a description;
  a screenshot removes an entire class of back-and-forth.
- Some negative results only fully make sense in hindsight, once a
  different investigation reveals what a component is actually *for*
  (here: the arm-corrector's real purpose only became clear from its
  runtime null/inactive state, not from its name or its fields' type
  signatures alone).
