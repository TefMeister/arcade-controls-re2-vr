# RE2 Remake (RE Engine) — VR Engine Research

Engine-side reference for **ARCADE CONTROLS for RE2 VR**, a REFramework Lua mod
that layers custom VR weapon handling, two-handed grips, IK, and posture
behavior onto *Resident Evil 2 Remake* (2019).

Unlike our other VR projects, **the VR conversion here is not ours** — it is
provided by praydog's [REFramework](https://github.com/praydog/REFramework),
which already delivers stereo rendering, 6DOF, and motion controls for every
Capcom RE Engine game. This project's work lives entirely in the gameplay and
interaction layer *above* that. So this repository documents the **RE Engine
managed object model as seen through REFramework's Lua reflection API** — how to
find and drive the game's own weapons, player, IK, and motion systems blind,
with no headers and no source — rather than a from-scratch renderer/camera
reverse-engineering effort.

This repository holds:

- **[`ENGINE-DOSSIER.md`](ENGINE-DOSSIER.md)** — the distilled, current-truth
  reference for this game's engine as reached through REFramework: the type
  system (`via.*` / `app.ropeway.*` / the TDB), the reflection model for
  finding objects (joints vs. children vs. components), hook-timing pitfalls,
  the camera-is-not-player-pose VR trap, per-pass render flags, the motion-bank
  selector, and the dead ends that cost real hours.
- **[`EXTERNAL-RESOURCES.md`](EXTERNAL-RESOURCES.md)** — the annotated pointer
  list to REFramework, its API docs, the EMV Engine toolkit, and general RE
  Engine references.
- **[`PLAYBOOK.md`](PLAYBOOK.md)** — the reusable, engine-agnostic VR
  reverse-engineering method shared across all our projects. For *this*
  project, its Phases 1–6 (injection → renderer → camera → stereo → VR runtime)
  are already provided by REFramework; the value here is the later
  gameplay-integration work.

The blow-by-blow development history lives in the sibling repositories
(`-dev-archive` for the messy in-progress record, `reframework-ai-modding-notes`
for readable per-bug case studies). This repo is the consolidated engine
knowledge, not the diary.

## Status

Shipped and released on Nexus (see the `-mod` repo). Engine-side knowledge is
mature; this dossier consolidates it in one place.

## Scope, ethics, and legality

- This is a **non-commercial fan project**. It requires owning a legitimate copy
  of the game and **redistributes no original game assets** — the mod is Lua
  scripts we author. See [`.gitignore`](.gitignore).
- The mod runs entirely through REFramework's public scripting API — no native
  code, no memory patching, no injected DLL of our own.
- We **credit everyone** whose work or research this builds on, and we honour
  correction/removal requests from actual rights holders. See
  [`CREDITS.md`](CREDITS.md).

## Templates

New engine? Start its dossier from
[`templates/per-engine-research-template.md`](templates/per-engine-research-template.md).
