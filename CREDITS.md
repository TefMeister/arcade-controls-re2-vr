# Credits & Attribution

This project is a reverse-engineering and modding effort built on the public
research, tools, and creative work of many people who came before us. None of
this would be possible without them. We list every source, tool, and prior
work we have drawn on below — by name or handle, as accurately as we could
verify it — including those that helped only as inspiration.

If we have missed someone, the omission is a mistake, not a slight. Please see
the "Get credited, or ask us to stop" section at the bottom.

## The original game

Resident Evil 2 (2019 Remake) is the creative work of its developer and
publisher. We are only modding it; we did not make it, and all rights to the
game and its assets belong to their owners. No game files are included in any
repository in this project.

| Work | Creator(s) | Note |
|---|---|---|
| Resident Evil 2 (2019 Remake), original game and its engine | Capcom | Built on Capcom's proprietary RE Engine. |
| RE Engine (the base engine) | Capcom | Capcom's in-house engine, successor to MT Framework. |

## Tools, frameworks, and prior research this project builds on

| Source / Work | Creator(s) | Link |
|---|---|---|
| REFramework — the mod-loading / scripting / generic-6DOF-VR framework this entire mod runs on | praydog | https://github.com/praydog/REFramework |
| The REFramework Book (Lua scripting API documentation) | cursey and REFramework contributors | https://cursey.github.io/reframework-book/ |
| REFramework API / TDB / VM reference | praydog and contributors | https://refdocs.praydog.com/ |
| `RE8VR.cpp` / `FirstPerson.cpp` (reference implementations for per-pass render flags and RE2 first-person joint handling) | praydog | https://github.com/praydog/REFramework |
| RE2VRMODRELOADED — the base flat-to-VR conversion this mod builds on top of (not the base REFramework VR conversion itself) | Andyalpa | Used with Andyalpa's explicit permission. |
| EMV-Engine — a REFramework Lua toolkit; a hook-timing technique from its live bone-posing tool was studied and reused (as a technique, not copied code) for posture correction. MIT licensed. | alphaZomega (alphazolam) | https://github.com/alphazolam/EMV-Engine |
| EMV-Engine-SILVER — actively-maintained fork of EMV Engine | SilverEzredes | https://github.com/SilverEzredes/EMV-Engine-SILVER |
| "VR Hands" mesh mod — tried and evaluated during development (helped surface a real mesh-format bug fixed along the way); not part of the final shipped mod | Oziman | Used/tested with Oziman's direct, explicit permission. |
| "All Weapons" — used constantly during development to have every weapon on hand for testing | hosamnasr | https://www.nexusmods.com/residentevil22019/mods/1984 |
| x64dbg (debugger; used elsewhere in our projects) | mrexodia, Sigma, tr4ceflow, Dreg, Nukem, Herz3h, torusrxxx, and the x64dbg contributor community | https://github.com/x64dbg/x64dbg |
| Superpowers (skills framework used during development) | Jesse Vincent (GitHub: obra) and contributors at Prime Radiant | https://github.com/obra/superpowers |
| AI development assistance | Claude (Anthropic) | https://www.anthropic.com |

Project lead and author: **TefMeister**.

Where a handle or attribution above is uncertain, we have said so, or we have
linked the source so anyone can check it. If you can correct or confirm a
detail, please open a GitHub issue — we would much rather fix it than leave it
wrong.

## Get credited, or ask us to stop

**If you helped and are not credited:** if you contributed anything to this
work — code, research, tools, documentation, or even just an idea that inspired
a part of it — and you do not see yourself credited above, that is an oversight
on our part, not a judgement about your contribution. Please contact us by
opening a GitHub issue on this repository, and we will correct the credits as
soon as possible.

**If you want your work removed or not used:** if you are the owner or creator
of something referenced or used here, and you would rather your work not be
referenced in this project, or you want specific content removed, please tell
us by opening a GitHub issue. We will honour that request promptly — no
argument and no delay — and we will find another way to do the job that does
not rely on your material. This is your work; we are only grateful to have
learned from it.
