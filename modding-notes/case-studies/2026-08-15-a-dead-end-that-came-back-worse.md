# A closed dead end recurs, gets worse, and finally gets a live-hooking pass

**Status:** Reopened, two more angles eliminated with real evidence, then
paused again by deliberate choice — not because the leads ran out, but
because the practical workaround (removing the broken feature and
substituting a known-good one) was judged good enough to stop on for now.

This is a direct follow-up to the companion case study
(`2026-08-06-laser-sight-drift-investigation.md`), which closed the same
bug as a 17-mechanism dead end. Read that one first; this picks up from
its ending.

## Why a closed dead end reopened

The bug's root cause was the torso-twist correction feature — closed dead,
*and* removed from the shipping mod the same day, for an unrelated reason
(it broke cutscene animations). With the cause gone, the symptom couldn't
recur. Weeks later, the torso-twist feature was rebuilt from scratch for
a different goal (a player wanted it working while running, not just
standing still) and shipped again, disabled by default. The moment it was
re-enabled for testing, the drift came back — and this time worse: it now
tracked head pitch as well as the original body-strength coupling, because
the new build's aim-compensation logic interacted with it in a way the old
one hadn't.

**Lesson:** closing an investigation because its root cause was removed is
not the same as fixing the underlying bug. If the cause is a *feature*,
not a *removed piece of code*, treat "closed, cause no longer present" as
conditional, not permanent — write that condition down explicitly so a
future rebuild of the same feature knows to re-check.

## Two wrist-offset attempts, both genuinely tested, both zero effect

Before touching the original 17-mechanism investigation again, two new
ideas were tried at the *symptom* layer instead of the *cause* layer: a
small manual rotation nudge on the arm bone nearest the gun, meant to
visually cancel the drift by hand.

- **Attempt 1, local space:** applied the nudge relative to the bone's own
  parent-local axes. Fixed left-right alignment at one head angle, but the
  error came back the moment the player looked up or down.
- **Attempt 2, world/body space:** re-derived the same nudge relative to
  the character's root orientation instead (via quaternion conjugation),
  specifically to stop being sensitive to head pitch. **Zero change** —
  the head-pitch-dependent drift was exactly as present as before.

The second attempt's negative result is the informative one: two
structurally different reference frames for the same manual offset, and
neither touched the head-pitch component at all. That's strong evidence
the offset lever was never going to reach this part of the bug — arm/wrist
pose isn't upstream of whatever computes the pitch-dependent piece.

**Lesson:** if a fix attempt changes *how* you apply an offset (different
reference frame) and the result doesn't change at all, that's more
informative than a fix that partially works — it tells you the whole
category of lever (arm/bone pose) isn't the mechanism, not just that this
particular frame was wrong.

## First real live-hooking pass on this bug

The original investigation's stated stopping point was "the next serious
avenue is live method hooking, not another reflection dump" — flagged, but
never attempted, because it was a materially bigger investment than
anything tried up to that point. This round finally did it, on the one
field the original investigation had found real correlation on but
concluded was "probably a downstream readout, not the value the renderer
consumes."

**Confirmed, for the first time, why that write never worked:** the
field's own generated setter method was hooked directly. It never fired —
not once, across two independent live captures — despite the field's
value visibly changing every single frame. Something writes that backing
field directly, bypassing its own property setter entirely. The original
investigation had tried writing both the raw field and the proper setter
and gotten "no visible effect" from both; this explains *why* both failed
identically: nothing in the live game ever calls that setter, so hooking
or writing it was never going to intercept anything.

**A second candidate, ruled out with equal cleanliness:** a decal-painting
engine type had turned up as an architectural comparison in the original
investigation ("a projected dot landing on a wall is similar to a decal")
but was never actually checked for existence. This round confirmed it
exists, confirmed it has exactly the kind of color-control API that theory
would predict, hooked its color-setter — and it never fired either, during
a live aim-burst window. A second promising-looking system, cleanly
eliminated by hooking instead of guessing.

**A genuinely new data point, not previously observed:** correlating the
broken field frame-by-frame against a known-accurate aim reference (a
raycast-based value from an unrelated feature in the same codebase)
revealed a two-phase pattern: for roughly a quarter-second right as aiming
starts, the field sits in a completely different coordinate range —
consistent with stale or uninitialized data — then snaps to a range that
roughly tracks the real aim, offset by an amount large enough to fully
explain how far off the visible symptom looks. Interesting shape, but
still didn't reveal a controllable lever — knowing precisely *how* a value
is wrong isn't the same as finding what writes it.

**Lesson:** "we found a field that correlates but doing nothing when
written" is not the end of the story if you never actually watched the
live call graph. Two rounds of hooking here — one on a getter/setter pair,
one on a completely different system — each produced a clean, confirmed
negative in a way that pure reflection reading never could. A negative
from a hook (confirmed: this method never runs during the symptom) is a
stronger claim than a negative from a value read (confirmed: writing this
had no visible effect) — the first rules out a code path, the second only
rules out one specific intervention on it.

## Also ruled out: redirecting instead of hiding

A tempting alternative to removing the broken visual entirely was floated:
instead of suppressing it, redirect it somewhere harmless (behind the
player, out of view), keeping the attachment's other gameplay behavior
intact. This turned out to already be ruled out by evidence gathered in
the *original* investigation, re-read with this specific question in mind
— the one field ever found to correlate with the bug had already been
confirmed to have zero rendering effect when written (see above), and an
earlier round of that investigation had confirmed the visible element
survives having every one of its associated mesh materials individually
hidden. Between those two facts: there is no reachable lever that controls
*where* the broken visual appears, only (per the original investigation's
still-standing finding) one that controls whether the whole attachment is
considered equipped at all.

**Lesson:** before spending a new round of live testing on a variant idea
("what if we redirect it instead of removing it"), check whether the
evidence already gathered answers the variant too. A "reposition" idea and
a "remove" idea sound different, but if the only known-working lever is
binary, that already answers both.

## Where it landed, again

Same practical conclusion as the original investigation reached, arrived
at faster this time because the underlying mechanism was already partly
mapped: suppress the broken attachment via the existing safe override
channel (documented in the original write-up), and let an existing
correct system — a raycast-based aim indicator built for an unrelated
purpose — fill the gap while the broken one is off. New this round: gating
that substitute so it only activates for weapons that actually need it (an
attachment equipped, and only while actively aiming), so it doesn't affect
weapons that were never broken in the first place. Known tradeoff, same as
last time: this also removes the attachment's real gameplay behavior along
with its visual, not just its cosmetic bug — a deliberate, informed choice
this time, not a default fallen into.

## Process lessons, independent of the eventual answer

- **"Closed, cause removed" is not "fixed."** If the underlying feature
  gets rebuilt later, write down explicitly that the closed bug is
  conditional on the feature staying off, so a future rebuild knows to
  recheck rather than assume it's still closed.
- **A negative result from hooking a method is stronger evidence than a
  negative result from writing a value.** One confirms a code path never
  runs during the symptom; the other only confirms one specific
  intervention had no effect. If you have the tooling to hook, prefer it
  over another round of read/write on the same field.
- **Two structurally different fix attempts producing the identical zero
  result is informative, not just twice-as-disappointing.** It rules out
  a whole category of lever (here: arm/bone pose, in either reference
  frame), which is worth more than either attempt alone.
- **Before testing a variant of an old idea, check whether old evidence
  already answers it.** A "reposition instead of remove" idea can be
  fully answered by evidence gathered while testing "why doesn't writing
  this field do anything" months earlier, if you go back and re-read it
  with the new question in mind.
