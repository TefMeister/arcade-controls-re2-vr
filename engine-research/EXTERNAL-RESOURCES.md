# External Resources — RE Engine & REFramework

The engine-side knowledge in [`ENGINE-DOSSIER.md`](ENGINE-DOSSIER.md) is built
on top of other people's frameworks, tools, and documentation. This is the
annotated pointer list to all of it — where to go for the authoritative,
maintained source rather than our distilled snapshot. (Full attribution and
"ask us to stop" contact is in [`CREDITS.md`](CREDITS.md).)

## REFramework — the framework everything runs on

- **REFramework (praydog)** — mod loader, scripting platform, and generic 6DOF
  VR for all RE Engine games. The entire foothold for this project.
  https://github.com/praydog/REFramework
- **Releases / downloads** — https://github.com/praydog/REFramework/releases
- **Project site** — https://reframework.praydog.com/
- **Community landing / install & VR setup guide** — https://reframework.dev/

## REFramework scripting & API documentation

- **The REFramework Book** (the practical Lua scripting guide — `sdk`,
  `REManagedObject`, the Object Explorer, hooking) —
  https://cursey.github.io/reframework-book/
  - `sdk` API (singletons, TDB lookups, `hook_method`, type queries) —
    https://cursey.github.io/reframework-book/api/sdk.html
  - `REManagedObject` (calling methods, reading fields on live objects) —
    https://cursey.github.io/reframework-book/api/types/REManagedObject.html
  - Object Explorer (browsing the live type database / singletons in-game) —
    https://cursey.github.io/reframework-book/object_explorer/object_explorer.html
- **API, TDB & VM Reference** (C#/typed-proxy + TDB/VM reference docs) —
  https://refdocs.praydog.com/
- **REFramework wiki** (feature overview, per-game notes) —
  https://github.com/praydog/REFramework/wiki

## Key reference source code (praydog)

- **`RE8VR.cpp`** in REFramework — the reference implementation for several
  per-game VR behaviors we reuse the *technique* of, e.g. `fix_player_shadow()`
  (per-pass `via.render.Mesh` draw flags — see dossier §7).
- **`FirstPerson.cpp`** in REFramework — RE2's first-person camera handling;
  the source of the `"head"` joint name and the "Hide Joint Mesh" behavior we
  work around.
  (Both live under the REFramework repo above; browse the source tree there.)

## EMV Engine — RE Engine Lua toolkit (technique reference)

- **EMV-Engine (alphaZomega / alphazolam)** — a large collection of REFramework
  Lua scripts (Enhanced Model Viewer, Console, Gravity Gun, Enemy Spawner) and,
  importantly, a shared utility library other scripts `require`. MIT licensed.
  A specific hook-timing technique from its live bone-posing tool was **studied
  and reused as a technique** (not copied code) for this mod's posture
  correction. Most utility functions are documented in comments inside
  `EMV Engine/init.lua`.
  https://github.com/alphazolam/EMV-Engine
- **EMV-Engine-SILVER (SilverEzredes)** — an actively-maintained fork; useful
  when the upstream lags a game update.
  https://github.com/SilverEzredes/EMV-Engine-SILVER

## RE Engine — general background

- **RE Engine (Wikipedia)** — history, lineage from MT Framework, title list.
  https://en.wikipedia.org/wiki/RE_Engine
- **"Design of RE ENGINE for rapid iteration" (Capcom R&D talk)** — Capcom's
  own presentation on the engine's architecture and IL→C++ managed-runtime
  design; good background on *why* the type system looks the way it does.
  https://www.docswell.com/s/CAPCOM_RandD/KQQWMK-2022-07-15-133419

## Related game-side mods used during development

- **RE2VRMODRELOADED (Andyalpa)** — the base flat-to-VR conversion this mod is
  tuned on top of (used with permission).
- **"All Weapons" (hosamnasr)** — used constantly to have every weapon on hand
  for testing. https://www.nexusmods.com/residentevil22019/mods/1984
- **"VR Hands" (Oziman)** — evaluated during development (surfaced a real
  mesh-format bug that got fixed); not part of the shipped mod. Used/tested
  with explicit permission.

---

*Links verified reachable as of 2026-08-21. If any have moved, the project
names above are stable enough to re-locate the current home. If you own any
resource listed here and want it removed or corrected, see the contact note in
[`CREDITS.md`](CREDITS.md) — we honour rights-holder requests promptly.*
