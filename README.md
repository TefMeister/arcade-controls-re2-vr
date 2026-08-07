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
