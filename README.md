# RE2 VR Modding Notes

Trial-and-error notes from modding *Resident Evil 2 Remake* for VR using
[REFramework](https://github.com/praydog/REFramework) and Lua, working
with an AI pair-programmer (Claude Code) throughout.

This is **not** a mod release, a tutorial, or a finished reference — it's
the messy middle: the dead ends, the wrong guesses, the "we thought X but
it turned out to be Y" moments, written down as they happened. The target
reader is anyone using an AI coding assistant to mod a game they don't
have source access to, working purely through reflection, live probing,
and reading logs. That process looks different from normal software
debugging, and there isn't much public writing about what it actually
looks like session to session.

**The primary reader this is written for is an AI coding assistant,
mid-investigation, on a completely different game.** If you're an AI
reading this because you're stuck on something that rhymes with an entry
below — a hook that fires more than once per frame, a visual value that
lags one frame behind the state driving it, a per-character difference
that looks like your bug but tests inert — the specific engine details
here (RE Engine, `via.*`, `app.ropeway.*`) won't transfer, but the
*shape* of the bug and the elimination method usually will. Reading one
relevant entry in full is meant to be cheaper than re-running the same
dead ends this repo already paid for.

## Index

One line per entry — enough to tell if it's worth reading in full before
spending the tokens on it.

- [`case-studies/2026-07-26-pump-trigger-reload-conversion.md`](case-studies/2026-07-26-pump-trigger-reload-conversion.md)
  — an unreliable continuous hand-tracked VR gesture replaced by a
  discrete button state, by splitting the gesture into its "needs real
  tracking" half and its "actually just a binary state" half, and reusing
  all downstream animation/completion code unchanged.
- [`case-studies/2026-07-31-slide-rack-teleport-duplicate-hooks.md`](case-studies/2026-07-31-slide-rack-teleport-duplicate-hooks.md)
  — a visual teleport bug with three unrelated root causes at once:
  duplicate per-frame hook call sites racing to write the same output,
  an older sibling function missing a guard the new code path needed, and
  state only reset on one of two possible cycle-end paths.
- [`case-studies/2026-07-31-canceling-a-drift-bug-instead-of-fixing-it.md`](case-studies/2026-07-31-canceling-a-drift-bug-instead-of-fixing-it.md)
  — when it's legitimate to zero out the specific terms an unsolved bug
  flows through, instead of finding the bug, and how that differs from
  just masking a symptom.
- [`case-studies/2026-08-05-claire-torso-twist.md`](case-studies/2026-08-05-claire-torso-twist.md)
  — three dead ends (animation-file swap, weapon-category spoof,
  forcing a suspect component to identity) before the fix: overwrite a
  skeleton joint's rotation directly, where hook *ordering* relative to
  a native IK solve reading the same joint mattered as much as the fix
  itself. Later pulled from the shipping mod anyway — technically correct
  fixes can still be net-negative once you count what else silently reads
  the value you're overwriting.
- [`case-studies/2026-08-06-laser-sight-drift-investigation.md`](case-studies/2026-08-06-laser-sight-drift-investigation.md)
  — closed as a documented dead end after 17 eliminated mechanisms: a
  workaround that "worked" but broke gameplay, a config system fully
  exhausted via developer-labeled data instead of just empty lists, a
  strong partial hit (right mechanism, wrong specific target), and a
  whole-type-database name search that ruled out an entire category of
  theory at once.
- [`case-studies/2026-08-07-three-position-systems-one-weapon.md`](case-studies/2026-08-07-three-position-systems-one-weapon.md)
  — tuning a VR grab point that silently did nothing, three times in a row,
  because the codebase had three lookalike position systems (extract /
  insert-detect / visual-landing) for one weapon and each wrong guess
  produced correct-looking math on a code path that just wasn't running.
- [`case-studies/2026-08-08-smoothing-a-snap-the-lua-never-controlled.md`](case-studies/2026-08-08-smoothing-a-snap-the-lua-never-controlled.md)
  — abandoned after proving, via logging, that a mod-side trigger condition was
  working exactly as designed while the visual snap it was meant to gate happened
  anyway — because the condition only ever controlled whether the mod added
  smoothing on top of engine behavior, never whether that engine behavior occurred
  at all. Two real bugs were found and fixed along the way without touching the
  actual cause, a pattern worth recognizing on its own.
- [`case-studies/2026-08-08-edge-trigger-no-retry-and-a-controller-blip.md`](case-studies/2026-08-08-edge-trigger-no-retry-and-a-controller-blip.md)
  — a grab gesture checked "just pressed" and "in range" in the same frame with
  no retry, found dead via a state flag that was written in ten places and read
  in zero; fixed, then two more plausible hypotheses for a milder residual case
  (distance-threshold flicker, grip loosening at full reach) were each killed
  by live log data before tracing the input down to a pre-digitized boolean the
  mod has no hysteresis access to — and stopping there once the player called
  the remainder acceptable jank.
- [`case-studies/2026-08-08-the-hardware-quirk-that-wasnt.md`](case-studies/2026-08-08-the-hardware-quirk-that-wasnt.md)
  — revisits the entry above: the "acceptable jank, no raw analog access" residual
  case came back worse, and turned out to be two more ordinary software bugs, not
  hardware — a position global that was never cleared after use and went stale for
  seconds at a time, then an animated-skeleton position that spiked on individual
  frames, then a *separate* visual system reading the same noisy range check with
  no debounce of its own even after the state machine driving the actual grab was
  provably fixed. A case for reopening an "unfixable hardware" conclusion when the
  symptom changes shape instead of re-applying the old workaround harder.
- [`case-studies/2026-08-09-inhibit-is-not-request.md`](case-studies/2026-08-09-inhibit-is-not-request.md)
  — a "block this from happening" API looked like the right lever for "make this
  happen" and did nothing; the real fix needed a genuine per-frame request flag found
  via observation first, then survived one more wrong turn (writing after one specific
  update method, which wasn't reliably the last writer) before landing on intercepting
  the setter itself — the argument-side twin of overriding a return value in a
  post-hook.
- [`case-studies/2026-08-09-a-fix-that-kept-reverting-itself.md`](case-studies/2026-08-09-a-fix-that-kept-reverting-itself.md)
  — a config fix that reverted to the *exact same* bit-for-bit value twice, which
  ruled out "recorrupted by a new event" and pointed at a stale in-memory copy being
  re-saved instead — traced to an unrelated, previously-diagnosed-but-never-deployed
  profile-lookup bug silently routing one character's reads/writes into another
  character's data the whole time.
- [`case-studies/2026-08-12-the-camera-knows-where-it-looks-not-where-you-are.md`](case-studies/2026-08-12-the-camera-knows-where-it-looks-not-where-you-are.md)
  — two unrelated-looking proximity bugs, same root cause: deriving a "where is the
  player really" answer from the render camera's world matrix instead of raw tracked
  position, which lines up fine facing one direction and silently drifts the moment
  the player physically turns in their room. Fixed in both places once the pattern
  was recognized the second time; a doc comment that had already named the exact
  problem ("includes artificial locomotion; not raw play-space tracking") just hadn't
  been connected to the first bug yet.
- [`case-studies/2026-08-12-from-proximity-to-a-real-two-handed-grip.md`](case-studies/2026-08-12-from-proximity-to-a-real-two-handed-grip.md)
  — CONCLUDED, but not the way it started. A cosmetic hand-placement feature escalates
  through three designs into a real physical two-handed grip that moves the weapon,
  fixes a genuinely unstable rotation (wrong reference point, not a bad formula), then
  keeps generating new plausible bugs from real-world hand-position tracking until the
  developer concludes the platform itself will never make tracked positions feel solid
  — and rebuilds the whole feature on a button-state latch with zero position tracking
  at all, reusing an existing proven animation system by extending *when* it applies
  instead of reconstructing it from primitives. One bug (a decision that quietly
  depends on where the player is looking) survives the rebuild, still open.
- [`case-studies/2026-08-14-a-fix-that-existed-somewhere-else.md`](case-studies/2026-08-14-a-fix-that-existed-somewhere-else.md)
  — a real, working fix goes missing between two machines not because it was deleted,
  but because it existed in a handoff location one directory level above the specific
  folder a much earlier instruction had named — a reminder that guidance about *where
  to look* goes stale exactly like guidance about *what's there*. Includes a second,
  independently found bug (a silent full-inventory data-eviction case) and a language
  footgun (`cond and a or b` silently breaking when the value can legitimately be
  `false`) that had already bitten the same project once before.
- [`case-studies/2026-08-15-the-items-with-no-itemid.md`](case-studies/2026-08-15-the-items-with-no-itemid.md)
  — three items that never matched an allow-list check because they don't carry
  their identity in the field every other item type uses at all, but a second,
  parallel ID field meant for a different object category entirely. Fixing
  identification surfaced a second bug one layer in: merging a new one into an
  existing stack silently failed too, because the field every other item's merge
  path reads is simply never populated for this category — found by hooking the
  real native calls as pure observers during a known-good manual merge, rather
  than continuing to guess at which field might carry the signal.
- [`case-studies/2026-08-15-two-clean-eliminations-one-still-open-mystery.md`](case-studies/2026-08-15-two-clean-eliminations-one-still-open-mystery.md)
  — CLOSED, root cause found but not fixable. Three code-based fix attempts for a
  VR-only black background all failed (two with zero effect, one that made it
  worse), then a fourth "attempt" that wasn't code at all settled it for free:
  manually triggering the exact same native screen a completely different,
  never-modded way (an existing button that examines an owned item) produces the
  identical black background. The bug was never pickup-specific or even
  mod-specific — it's this native UI screen failing to render correctly in VR at
  all, confirmed by testing whether the unmodified game already has the symptom
  before writing any more code to chase it.
- [`case-studies/2026-08-15-deleting-a-feature-without-breaking-its-neighbor.md`](case-studies/2026-08-15-deleting-a-feature-without-breaking-its-neighbor.md)
  — removing a retired, confirmed-game-breaking toggle looked like it meant
  deleting the native-method hook it lived in, until a full read of that hook's
  body turned up a second, unrelated feature that had later started piggybacking
  on the same hook purely because it already fired at the right moment for free.
  Deleting the whole hook would have silently broken that second feature with no
  error at all — caught by reading the hook fully before cutting anything, not by
  assuming "this hook = this one feature."
- [`case-studies/2026-08-15-a-dead-end-that-came-back-worse.md`](case-studies/2026-08-15-a-dead-end-that-came-back-worse.md)
  — a bug closed as a 17-mechanism dead end recurs when its root-cause feature is
  rebuilt from scratch weeks later, now worse (tracks head pitch too). Two manual
  offset attempts in different reference frames both produce zero effect (a stronger
  negative than either alone). First live-hooking pass on this bug: a property setter
  confirmed to never fire despite its backing field changing every frame, and a
  decal-rendering system confirmed to exist but never touched during the symptom —
  both cleanly eliminated by watching live calls instead of reading static state.
  Lands on the same practical workaround as the original, arrived at faster.
- [`case-studies/2026-08-15-three-independent-negatives-and-what-they-add-up-to.md`](case-studies/2026-08-15-three-independent-negatives-and-what-they-add-up-to.md)
  — three structurally different searches (player-component reflection, reusing an
  existing native detection system, physics raycasting the surrounding space) each
  return a clean, confirmed negative for a VR camera bug during ladder-climbing —
  including catching a misleading first result caused by a manual-trigger diagnostic
  interrupting the very state it was trying to measure. The *shape* of three
  independent negatives becomes the actual finding: evidence for a cause outside
  what any game-side reflection or physics probing can reach.
- [`techniques/reframework-reflection-toolkit.md`](techniques/reframework-reflection-toolkit.md)
  — general method for finding an unknown effect's source in a
  closed-source engine with no API docs: the three structurally
  different places it can live (skeleton joint, child GameObject,
  component) and the reflection call for each.

## Layout

- **`case-studies/`** — one file per investigation. Each one covers a
  specific bug or feature: what the symptom was, what was tried and ruled
  out (with the actual reasoning for why it was ruled out, not just
  "didn't work"), and what the fix ended up being (or the current state,
  if unresolved).
- **`techniques/`** — reusable methodology notes that aren't tied to one
  specific bug: how to explore an unfamiliar native object model through
  Lua reflection, hook-timing gotchas, logging conventions, that kind of
  thing.

## Why publish dead ends

A working fix with the failed attempts deleted looks obvious in
hindsight and teaches nothing about how to *find* a fix next time. The
value here is specifically in the ruled-out paths: what made them
plausible, what evidence actually killed them, and what that evidence
implied about where to look next.

## Context

The mod this comes out of adds VR support on top of an existing
flat-screen REFramework VR base, with custom weapon-handling, IK, and
posture behavior layered on. No mod source is included here — this repo
is written explanation only.
