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
