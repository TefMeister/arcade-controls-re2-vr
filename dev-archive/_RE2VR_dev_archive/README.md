# RE2 VR mod — dev archive

A permanent, append-only historical record of this mod's Lua/JSON files, living inside
the game folder itself so it survives independently of any single machine's Claude Code
session, the `D:\Claude transfer stuff RE2\` handoff folder, or the GitHub notes repo.

Purpose: keep every success, mistake, dead end, and "just exists" script from this
project's whole history in one place, so an old idea can always be revisited without
rebuilding tooling or reasoning from scratch — even ideas that were abandoned as
unsolvable at the time.

## The rule

**Never overwrite or delete anything in `snapshots\`.** Every time a mod file
(anything under `reframework\autorun\` or `reframework\data\re2_vr\`, live feature code
or a throwaway probe alike) is created or changed in any way, a copy of the result goes
into a **new** dated/labeled subfolder here:

```
snapshots\<YYYY-MM-DD>_<short-label>\reframework\autorun\...   (path preserved)
snapshots\<YYYY-MM-DD>_<short-label>\reframework\data\re2_vr\...
```

If a file needs to change again later, it does **not** get edited in place inside an
existing snapshot folder — a new dated/labeled snapshot folder is created instead, with
the updated copy in it. The old snapshot folder is left exactly as it was. This means a
single file's whole history is reconstructable by finding every snapshot folder that
contains it, oldest to newest.

Entries here are indexed in `INDEX.md` (newest last) so the full history can be skimmed
without opening every folder.

## `RESTORE_POINTS\` — full known-good rollback snapshots

Different purpose from `snapshots\` (which records incremental per-change history).
A restore point is a **complete** copy of `reframework\autorun\` and
`reframework\data\re2_vr\` taken right before a risky, multi-file experiment, meant
for a clean wholesale revert (not a careful manual undo) if the experiment goes
wrong. Each has its own `README.txt` with exact restore instructions. See that
folder's README before assuming any particular restore point is still the most
recent one.

## `history\` — consolidated from everywhere else, 2026-08-11

Pulled together at the player's request ("sentimental data... working with you on my
very first mod ever") so the whole project's story lives in one place, not scattered
across machines and drives. Point-in-time copies, not synced further:

- `history\releases\` — every packaged release zip, **v1.0.0 through v1.3.0** plus
  `GripSuppressionVR-v1.0.0.zip`, copied from `Desktop\Nexus mods\`. This is the actual
  shipped lineage from the very first version onward.
- `history\desktop_archive_pre_2026-08-07\` — full copy of `Desktop\everything Claude
  re2` (713 files: early session logs, `CHANGELOG.md`, early probe scripts, duplicate
  `- Copy` files, more release zips). The messy, unorganized record of the project's
  earliest days, kept as-is rather than cleaned up — see [[re2_desktop_archive_folder]].
- `history\github_notes_repo\` — full copy of the `arcade-controls-re2-vr-modding-notes` GitHub
  repo clone, **including its `.git` folder** (full commit history preserved, not just
  the current working tree) — the curated case-study write-ups of dead ends and fixes.
- `history\transfer_folder_sessions\` — every dated session folder from both
  `D:\Claude transfer stuff RE2\` and `D:\mega dl\Claude transfer\` (deduplicated —
  each session folder copied once), covering the home/work-PC handoff record from
  2026-08-09 through today.

These are snapshots taken 2026-08-11, not live syncs — the originals at
`Desktop\`, `D:\Claude transfer stuff RE2\`, `D:\mega dl\`, and
`C:\Users\TD3KX\re2-vr-modding-notes\` keep evolving independently. If this archive
needs a refresh later, re-copy rather than assume it's current.

## What this is not

- Not a substitute for `D:\Claude transfer stuff RE2\` (that's for home/work-PC
  handoff of *current* work) or the GitHub `refframework-ai-modding-notes` repo (that's
  curated write-ups for other AI assistants). This archive is raw, uncurated, and local
  to this machine only.
- Not a replacement for the live files in `reframework\autorun\`/`reframework\data\`
  themselves — those are what the game actually loads. This archive is a read-only
  historical mirror, never loaded by REFramework.
- The work-PC has its own copy of this same folder/convention (set up 2026-08-11,
  originally scoped to probe/diagnostic scripts only). This home-PC copy has the same
  name and structure but a broader scope (all mod files, not just probes) — the two
  don't currently sync with each other.
