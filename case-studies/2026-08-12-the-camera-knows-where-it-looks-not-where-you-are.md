# The camera knows where it's looking, not where you physically are

**Status:** Fixed in two separate places, both live-confirmed, once the pattern was
recognized the second time.

## The symptom

A proximity-triggered VR interaction (a hand snapping onto an object when the real
hand gets close enough) worked correctly as long as the player faced roughly the same
direction they'd been facing when the feature was last tuned. The moment they
physically turned around in their room — no artificial/stick turning, just their own
body rotating in real tracked space — the trigger point drifted, ending up noticeably
behind where it should have been.

A second, superficially unrelated bug had the same signature: a different
proximity zone (this one anchored to the headset rather than a real hand) was
restricted to a single safe offset axis, because an earlier investigation had already
found that any *sideways* offset "drifted off the player's actual facing during
physical room-scale turning" — while working fine for in-game stick/snap turns.

## The shared root cause

Both features computed a real-world comparison point using the same category of
helper: read the render camera's current `WorldMatrix`, extract its position and
forward/right/up axes from that matrix, then use those axes to project an offset (or
reconstruct a hand position) into world space.

That's a completely reasonable thing to do — except the render camera's world matrix
is *not* a faithful proxy for the player's real physical orientation. It reflects
wherever the in-game view is currently pointing, which can be influenced by camera
smoothing, recentering behavior, or simply not being perfectly 1:1 with raw headset
orientation depending on how the VR integration layer composes it. It happens to line
up well when the player is facing the same way they were during calibration — hence
tuning/testing "working" the first time — and silently diverges the moment that
assumption breaks, which room-scale turning does immediately and completely.

The tell, in hindsight: a helper function's own doc comment on the second instance
already said, almost in passing, that it "includes artificial locomotion; not raw
play-space tracking." That sentence was true and specific, and described exactly the
failure mode — it just hadn't been connected to the earlier bug yet.

## The fix, once recognized

Both fixes were the same shape: stop deriving a "where is the player really" answer
from the camera, and use the actual tracked controller/HMD position instead.

- For the hand-position case, the code already had a second, correct source
  available — a raw tracked-position read, published as a shared global by other
  scripts and already used elsewhere in the same codebase — it just wasn't being
  tried *first*. The fix was as small as swapping which function got called first vs.
  used as a fallback.
- For the headset-anchored zone, there was no direct substitute (there's no single
  body joint for "near your head"), but the deeper insight generalized: a *real
  skeletal joint* also tracks true body orientation and doesn't have this problem, the
  same as a raw tracked position doesn't. Re-anchoring the zone to a nearby joint
  (reusing one already in use for a different, unrelated zone) fixed it and, as a
  bonus, unblocked a placement that specifically required a sideways offset — the
  exact direction the original camera-based approach couldn't support at all.

## General lessons

- **A render camera's world transform is not raw physical tracking**, even in VR,
  even though it's tempting to treat "where the camera is looking" as equivalent to
  "where the player physically is." If a helper's own naming or comments hint at this
  ("game-world," "includes locomotion," anything camera-relative), treat that as a
  concrete warning, not incidental phrasing.
- **A bug that only reproduces under real physical movement, and not under
  artificial/analog-stick movement, is a strong, specific signature** for exactly
  this class of problem — the two locomotion paths differ precisely in whether they
  update this deceptive camera-relative reference. Test physical turning explicitly,
  not just the in-game equivalent, before trusting a spatial calculation.
- **Any real tracked source — a controller position, an HMD pose, a skeletal joint —
  is a better ground truth than a derived camera transform** for anything that needs
  to reflect the player's actual body, even if the camera-relative version is more
  convenient to compute or already available.
- **Once a pattern is found once, actively look for it again elsewhere in the same
  codebase** rather than assuming it was a one-off. The second instance here had
  already been partially worked around (restricted to one "safe" axis) without the
  underlying cause being named — recognizing the shared root cause turned a
  workaround into an actual fix, and unblocked a feature request the workaround had
  been silently blocking.
