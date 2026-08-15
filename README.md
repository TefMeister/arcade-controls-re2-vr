# ARCADE CONTROLS for RE2 VR — Development Archive

The full, unpolished development history behind [**ARCADE CONTROLS for RE2
VR**](https://www.nexusmods.com/residentevil22019/mods/2640), a
[REFramework](https://github.com/praydog/REFramework)/Lua VR mod for
*Resident Evil 2 Remake*, built through an ongoing pairing between a human
modder and an AI coding assistant (Claude Code).

This is **not** a curated release. It's the working archive: every
snapshot taken as files changed, dead-end probes, abandoned experiments,
restore points taken before risky changes, and cross-machine session
handoffs. If you want the clean, current mod, see the **[releases
repo](https://github.com/TefMeister/arcade-controls-re2-vr)** instead. If
you want written-up lessons from the investigations behind this mod, see
the **[modding notes
repo](https://github.com/TefMeister/reframework-ai-modding-notes)**.

This repo exists for two reasons: as a real backup (so nothing gets lost
across machines or time), and because the raw history — including the
false starts — might be useful to someone else modding with an AI
assistant, or just curious what that process actually looks like day to
day.

## What's in here

- **`reframework/`** — the live mod source as of the most recent sync:
  `autorun/` (Lua scripts) and `data/re2_vr/` (config).
- **`_RE2VR_dev_archive/snapshots/`** — one dated, labeled folder per
  change to a mod file, going back to 2026-08-11. Append-only — nothing in
  here is ever edited after the fact, so old snapshots stay exactly as
  they were when written.
- **`_RE2VR_dev_archive/RESTORE_POINTS/`** — full-state copies taken
  immediately before a risky, multi-file experiment, each with its own
  restore instructions.
- **`_RE2VR_dev_archive/history/`** — consolidated older material: every
  prior release zip, the original unorganized early-development dump, and
  cross-machine session handoff notes from when development was split
  between two computers.

## Credits

This mod would not exist in its current form without other people's work
and generosity:

- **Andyalpa** — the original base VR conversion this mod was built on
  top of and extended. Andyalpa has given explicit permission for that
  work to be used as a base for further modding.
- **Oziman** — creator of the "VR Hands" mesh mod, evaluated during
  development (including a real investigation into an RT-vs-Non-RT mesh
  format mismatch, written up in the notes repo) — not part of the final
  shipped mod, but a real, credited influence on the process. Oziman has
  also given explicit permission to build on/reference their work.
- **[hosamnasr](https://www.nexusmods.com/residentevil22019/mods/1984)**
  — creator of the "All Weapons" mod, used constantly throughout
  development to have every weapon available for testing whatever was
  being worked on at the time.
- **alphaZomega** — creator of
  [EMV-Engine](https://github.com/alphazolam/EMV-Engine) (MIT licensed).
  A specific technique from it (writing bone-pose overrides at the
  `PrepareRendering` hook, the latest point in the frame before render)
  was studied and reused in this mod's posture-correction code.
- **[praydog](https://github.com/praydog/REFramework)** — creator of
  REFramework itself, the modding framework this entire project runs on.

If you're one of the people above (or anyone else) and see something here
that should be credited differently, linked differently, or just isn't
sitting right with you — see the disclaimer below.

## Disclaimer

If you created something referenced, credited, or included anywhere in
this repository (or its companion repos) and want any part of it changed
or removed — a credit line, a link, a technique description, anything —
**we will comply, fully, without argument or requiring justification.**
Open an issue, or reach out however works for you. This applies whether
or not something here is technically permitted; if it's your work and you
want it handled differently, that's the end of the conversation.

## A note on how this was built

Every script here was written through a human/AI pairing session — the
human directing intent and doing all live in-headset testing (VR changes
can't be verified any other way), the AI proposing code, reading
REFramework's reflection API to explore an engine with no public source
or docs, and helping interpret test results. Nothing here is
AI-generated without a human in the loop deciding what to build and
confirming it actually works in-game.
