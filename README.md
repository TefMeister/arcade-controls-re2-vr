# ARCADE CONTROLS for RE2 VR

A REFramework VR mod for *Resident Evil 2 Remake* — custom weapon handling,
IK, and posture behavior layered on top of an existing flat-screen-to-VR
REFramework base, built and tuned through iterative live testing with an
AI pair-programmer (Claude Code) throughout.

**This repo holds release history only** — Nexus-confirmed shipped
versions, one per tag/folder, so anyone can grab a specific past release
without wading through the full development history. For that history —
snapshots, dead ends, probes, session-to-session notes — see
[`arcade-controls-re2-vr-dev-archive`](https://github.com/TefMeister/arcade-controls-re2-vr-dev-archive).
For write-ups of the actual investigation/debugging process behind
specific bugs and features, see
[`reframework-ai-modding-notes`](https://github.com/TefMeister/reframework-ai-modding-notes).

**Nexus Mods page:** https://www.nexusmods.com/residentevil22019/mods/2640

## Releases

All 12 versions actually published on Nexus, oldest to newest. Each is a
GitHub Release with the exact zip that went up on Nexus attached — see the
[Releases page](https://github.com/TefMeister/arcade-controls-re2-vr-mod/releases)
for downloads and per-version notes.

v1.0.0 · v1.0.1 · v1.1.0 · v1.2.0 · v1.2.1 · v1.2.2 · v1.2.3 · v1.2.4 ·
v1.3.0 · v1.3.1 · v1.3.2 · v1.4.0

(A never-uploaded v1.4.0 build and the standalone `GripSuppressionVR-v1.0.0`
side-release exist in the dev-archive repo's history but are deliberately
not listed here, since they were never actually published.)

## Credits

This mod would not exist without other people's work, tools, and direct
help. Listed here regardless of how large or small the contribution —
even a single technique, a tip, or something used purely for testing
counts.

- **[praydog](https://github.com/praydog)** — [REFramework](https://github.com/praydog/REFramework),
  the mod-loading/scripting framework this entire mod runs on.
- **Andyalpa** — creator of RE2VRMODRELOADED, the base VR conversion this
  mod builds on top of (not the base REFramework VR conversion itself).
  Used with Andyalpa's permission.
- **alphaZomega** — [EMV-Engine](https://github.com/alphazolam/EMV-Engine),
  a REFramework Lua toolkit. A specific hook-timing technique from its
  live bone-posing tool was studied and reused (as a technique, not
  copied code) for this mod's posture-correction feature. MIT licensed.
- **Oziman** — the "VR Hands" mesh mod. Tried and evaluated during
  development (and helped surface a real mesh-format bug fixed along the
  way); ultimately not part of the final shipped mod. Used/tested with
  Oziman's direct, explicit permission.
- **hosamnasr** — ["All Weapons"](https://www.nexusmods.com/residentevil22019/mods/1984),
  used constantly throughout development to have every weapon on hand for
  testing everything that got modded.

If you believe your work is used here and isn't credited, or credited
incorrectly, please open an issue — see the note below.

## Disclaimer

If any mod author, tool author, or contributor credited (or *not yet*
credited) here wants anything about how their work is referenced,
described, or included changed or removed — a credit line, a technique
description, a file, anything — just ask. It will be done fully and
without argument, no justification required on your end. Open an issue
on this repo, or reach out however's easiest for you.

## License

No license is currently declared for the mod's own original code — all
rights reserved by default until a license is chosen. Third-party work
referenced above remains the property of its original authors and is
used here only with their permission or as a credited reference/link,
never redistributed wholesale without that permission.
