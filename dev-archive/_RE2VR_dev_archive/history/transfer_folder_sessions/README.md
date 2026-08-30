# Claude Transfer Stuff — RE2 VR Mod

Shared handoff folder between the two PCs (home and work) this project gets worked on
from. **Read this first if you're a fresh Claude Code session landing here** — neither
side has access to the other machine's conversation history, so this folder plus each
machine's own memory system is the only continuity between them.

## The situation

- **Home PC:** `C:\Steam\steamapps\common\RESIDENT EVIL 2  BIOHAZARD RE2` — has the VR
  headset. This is where anything actually gets *tested* in VR.
- **Work PC:** a different machine — no VR headset, no headset time during work hours.
  Good for writing/porting code, research, reading game data, building diagnostics —
  anything that doesn't need a live in-headset test.
- Both machines also touch the related **RE3** VR mod project (a separate game install),
  which reuses a lot of the same techniques/utility code. This folder is RE2-focused;
  if RE3 handoff volume grows, it may get its own `Claude transfer stuff RE3` folder —
  for now RE3 material that's directly relevant sits in `reference/`.

## Protocol — do this at the end of every session

1. Make a dated folder under `sessions/`, named `YYYY-MM-DD_home` or `YYYY-MM-DD_work`
   (append `_2`, `_3` etc. if a second session happens same day same machine).
2. Copy every `reframework/...` file you created or modified this session into that
   folder, **preserving the relative path** (e.g.
   `sessions/2026-08-09_work/reframework/autorun/foo.lua`) — so the receiving machine
   can diff/copy it straight into its own `reframework/` folder without guessing paths.
3. Write a `SESSION_NOTES.md` in that same dated folder covering:
   - What you worked on and why (one line of goal per thread).
   - What's **confirmed working live**, vs. what's **blocked on VR** (the other machine
     needs to know exactly what to go test first), vs. what's just research/not started.
   - Any manual/non-code steps required before something can even be tested (e.g. a
     native game settings change).
   - Anything you deliberately shipped disabled-by-default and why, so the other side
     doesn't assume "present in the folder" means "active in-game."
4. If a fix reverses or changes the status of something documented in an *earlier*
   session's notes or in either machine's own memory system, say so explicitly —
   don't make the next reader diff files to notice.

## Protocol — do this at the start of a session

1. Check `sessions/` for any folder dated later than the last time *this* machine
   synced. Read its `SESSION_NOTES.md` first.
2. Diff its `reframework/` files against this machine's live `reframework/` folder
   before copying — don't blindly overwrite; check whether this machine has its own
   newer/different version of the same file.
3. Copy over what applies, update this machine's own memory system with the outcome,
   then get to work.

## `reference/`

Long-lived investigation docs that aren't tied to one dated session — background on
multi-day threads (e.g. the animation-retargeting investigation that predates the
current spine-override torso-twist fix). Check here for deep context on *why* something
is built the way it is, not for current status — current status lives in the dated
session folders (most recent wins) and in each machine's memory system.
