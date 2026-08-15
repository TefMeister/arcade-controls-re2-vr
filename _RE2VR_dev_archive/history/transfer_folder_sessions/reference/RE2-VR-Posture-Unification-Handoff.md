# RE2 VR — Unifying Character Hold Poses (Handoff Notes)

**Context for whoever reads this (including a fresh Claude Code session):** this documents an investigation done on a different PC than the user's main VR/modding rig. Tool installs mentioned below (REtool, 7-Zip, Fluffy Mod Manager) live on that other machine, not necessarily this one — treat file paths as reference, not fact, on a new machine. Re-verify anything with `Test-Path` / a fresh `Grep` before acting on it.

## The actual goal

The user has an ongoing RE2 VR mod project: **"ARCADE CONTROLS for RE2 VR"** (v1.2.0), a fork of Andyalpa's "RE2VRMODRELOADED" on Nexus Mods. `modinfo.ini` for that mod credits authors as **"Andyalpa, TefMeister, Claude code"** — meaning the user (TefMeister) and a *previous* Claude Code session have been actively co-developing this mod for weeks. That mod's own `ReadMe.txt` has a real changelog (v1.0.1 → v1.1.0 → v1.2.0) documenting past work. If you land in a session with access to that mod's files, read `ReadMe.txt` and `modinfo.ini` first — they're the authoritative record of prior work, since conversational memory doesn't carry across machines/sessions.

**The specific problem driving this investigation:** in VR, looking down at your own body, **Claire's and Jill's torso visibly twists (~40°, angled right)** depending on which weapon is equipped — as if the animation assumes the gun is held low-and-right. This breaks embodiment because the twist is baked into the animation and doesn't track the player's real headset/controller orientation. **Leon's hold animations don't have this problem** (or are much more consistent). The user wants Claire, Ada, and eventually Jill/Carlos (from RE3) to use **Leon's hold-pose animations** instead of their own, to eliminate the twist.

Important: this is a base-skeleton-animation problem (torso/spine orientation baked into `.motlist` files), **not** an IK/hand-offset problem. We initially considered the mod's `reframework/data/re2_vr/re2_vr_holster.json` and `re2_vr_ik_extention.json` (which have per-character hand-reach-to-holster tuning — only Leon's profile is actually hand-tuned there, everyone else shares generic placeholder values), but the user clarified the actual issue is torso rotation during weapon holds, which those configs don't control. So the right layer to fix is the animation files themselves, not IK config.

## Technical findings (RE2, RT/Steam release)

- Game uses RE Engine. Character animation data lives inside `re_chunk_000.pak` (+ patch paks) at paths like:
  `natives/stm/sectionroot/animation/player/pl{XX}/list/{weapon-category}/{filename}.motlist.524`
- Character codes confirmed: **`pl00` = Leon**, **`pl10` = Claire**. `pl20` is very likely Ada (has a full weapon motion-bank set like Leon/Claire, same as the others). `pl30` = an NPC "survivor" model, identity unconfirmed.
- Weapon-category folders (same taxonomy repeated per character): `cmn` (common/base movement — probably most important for general posture), `etc`, `face`, `fce`, `gnl`, `hdg` (**handgun/pistol class**), `mag` (**magnum/revolver class — separate from hdg!**), `mle` (melee), `rkl`, `smg`, `stage`, `stg` (shotgun), `sup`.
- **Important gotcha we hit:** `hdg` and `mag` are separate animation categories. A revolver (magnum-class) does NOT use the `hdg` files — it has its own `mag` folder (`base_mag_hold.motlist.524`, `base_mag_finger.motlist.524`, no `base_mag_move` — movement likely falls back to `cmn`). If testing a swap, make sure you're testing the correct weapon-class folder for whatever gun is actually equipped.
- Leon (`pl00`) alone has **158 total `.motlist` files** across all weapon categories. Full unification across Leon/Claire/Ada is several hundred files; RE3's Jill/Carlos would additionally need real cross-game retargeting (different game, though likely similar rig standard — see below).
- Confirmed the existing **"Jill's Animation To Claire"** mod already in the user's game folder works by directly overwriting Claire's (`pl10`) `.motlist` files with Jill-retargeted content — i.e., a straight file replacement at the same relative path, filename unchanged. Only touches `pl10/list/hdg/base_hdg_hold.motlist.524` and `..._move.motlist.524` (2 files, handgun only). Whoever built it did the actual cross-game retargeting work upstream (Blender, presumably) — the archive only ships the final compiled `.motlist` output.

## What we tried, and what actually works for delivery

RE2 does **not** dynamically load arbitrary new patch pak numbers you drop in (confirmed via a modding guide: *"the engine doesn't support any easy method for loading modified files"* — Fluffy Mod Manager is described as *"the only way of installing file mods for RE2."*). Things that did NOT work:
- ❌ Loose `natives\...` folder at game root relying on REFramework's LooseFileLoader — untested to completion because REFramework crashed/got removed mid-session (see below) before we could confirm.
- ❌ Manually packaging a new `re_chunk_000.pak.patch_008.pak` via REtool and dropping it in — the base game doesn't scan for unregistered patch numbers, so this silently did nothing.

**What should work:** Fluffy Mod Manager (FluffyQuack's tool, same author as REtool) — this is the standard/intended tool, confirmed by the fact both existing mods (Jill's Animation, Arcade Controls) ship a `modinfo.ini` in exactly FMM's expected format. Setup requires one manual step (FMM's config UI is a custom-rendered menu, not scriptable): add RE2 as a **custom game** via *Options → Define Game Info*:
  - Game name: `Resident Evil 2`
  - Mod directory: `RE2`
  - Executable name: `re2.exe`
  - Steam ID: `883710`
  - Steam directory: `RESIDENT EVIL 2  BIOHAZARD RE2` (note: two spaces between "2" and "BIOHAZARD" in the actual folder name)

Once configured, mods go in `<FluffyModManager install dir>\games\RE2\mods\<modname>\` (folder containing `natives\...` and `modinfo.ini`), and get installed via FMM's own UI (which handles backups automatically).

A staged test mod was prepared (not yet confirmed working) at `games\RE2\mods\LeonPoseToClaire-TEST\`: copies Leon's `base_hdg_hold`, `base_hdg_move`, `base_mag_hold`, `base_mag_finger` onto Claire's (`pl10`) equivalent paths, to test whether same-game raw swaps (no retargeting) are enough — since Leon/Claire/Ada all share identical file taxonomy, it's plausible they share a compatible enough rig that a direct copy just works, without needing Blender retargeting (unlike the Jill/RE3 case, which is cross-game and definitely needs real retargeting).

## REFramework situation (important — currently NOT installed on the machine this was tested on)

The user had installed a **DLSS-specific build of REFramework** (via "MrSurviv0r's hub," which the Arcade Controls mod's own readme actually recommends as an install source) — it crashed the game. The user then manually removed REFramework entirely in response, which also took out `dinput8.dll`, `openxr_loader.dll`, `nvngx_dlss.dll`, `PDPerfPlugin.dll`, `REVR-Universal-Runtime-Switcher.exe`, and a `Backup\` folder (all likely bundled together as part of that same install package). **No VR, no autorun scripts work until REFramework is reinstalled.** User said they'll handle this "at home" — not urgent for this handoff, but necessary before any in-headset testing can resume. When reinstalling: prefer the official standard build over a DLSS-specific repack, or at least be aware that's the variant that crashed last time.

## Update (2026-08-04, home PC): raw same-path swap CONFIRMED NOT SUFFICIENT

Steps 1-3 below were completed on the home PC (REFramework was already installed
here; Fluffy Mod Manager was already configured for RE2R). This section
supersedes the "suggested next steps" that follow — read this first.

**Scope was also expanded per the player's request** before testing: instead of
just Claire's `hdg`+`mag`, the test mod (`LeonPoseUnify-RE2`, built into
`C:\fluffy mm\Games\RE2R\Mods\LeonPoseUnify-RE2\`) unified, for Claire (`pl10`),
Ada (`pl20`), **and** a previously-undocumented Ghost Survivors character
(`pl64` — has `cmn`+`hdg` only, no `mag`; identity not yet confirmed in-game):
- All `cmn_move*` variants (normal/`stcombat`/`stlight`/`stwater`/`sttension`) ← Leon's own files
- `cmn_move_cncaution*`/`cmn_move_cndanger*` (injured-state pose) ← Leon's **normal** move file, to collapse the injured pose to identical-to-normal
- All `hdg_hold*`/`base_hdg_hold` (pistol) ← Leon's own files, direct filename match
- All `mag_hold*` (revolver/magnum) ← Leon's **`hdg_hold`** files (cross-category, so every handgun type shares one pose), matched by numeric suffix

`pl30`/`pl50`/`pl75` were confirmed to lack `cmn`/`hdg`/`mag` data entirely (minor/face-only rigs) — out of scope regardless. RE3 was **not** attempted — it isn't installed on the home PC.

**Result: zero visible change in-game (flat-screen test), across every category touched — not even the walk gait/stride differed.**

Root-caused via direct verification (not guesswork) before concluding:
1. Hash-compared the live loose-override file at
   `<game>\natives\stm\sectionroot\animation\player\pl10\list\cmn\cmn_move.motlist.524`
   against both vanilla Claire's and Leon's extracted originals — **confirmed
   byte-identical to Leon's file**, correctly differing from vanilla Claire.
   File placement/content was correct.
2. Re-extracted that exact same path directly from the *live, FMM-modified*
   `re_chunk_000.pak` via REtool — **0 files extracted / entry not found**,
   while a control extraction of an untouched file (Leon's own `cmn_move`)
   succeeded normally. **Confirmed FMM's pak invalidation genuinely worked**
   for this path — the original packed entry really is gone.
3. Confirmed the general "invalidate + loose override" mechanism itself isn't
   broken system-wide: other already-installed FMM mods using the same
   `installtype=invalidate` method on non-texture data (e.g. **Peaceful Mr. X**,
   which swaps `.bhvt` behavior-tree files) are player-confirmed working fine,
   launched the same way (via FMM's own launch button, not Steam directly).

So both preconditions for the override to apply were independently verified
correct, yet nothing changed. **Conclusion: compiled `.motlist` files are
skeleton-specific binary data, not freely interchangeable between different
characters' file paths even within the same game and same category
taxonomy.** Community sources (residentevilmodding.boards.net threads on the
Motlist Tool / editing original animations) reference a "motbank" validation
step and "wrong body type" mismatches for swapped-in motlists — consistent
with the engine silently rejecting/ignoring skeleton-incompatible animation
data rather than crashing or producing a garbled pose, which matches exactly
what was observed. This means even the original "same-game raw swap" bet
this section used to describe as plausible (last paragraph, now superseded)
was wrong — Leon/Claire/Ada sharing identical folder taxonomy only means
their animation *categories* match, not that the compiled binary data is
skeleton-portable.

**Real fix requires actual animation retargeting** — the same class of work
already known to be needed for the RE3 Jill/Carlos case, just also true for
same-game Leon→Claire/Ada now too. Tools: RevilMax (3ds Max plugin) or RE
Mesh Editor (NSACloud's Blender addon, Blender 4.3.2+) — likely the same
workflow whoever built the existing "Jill's Animation To Claire" mod used
(their shipped mod is almost certainly *not* a raw file copy either, despite
living at an unchanged same-path filename — the compiled output was very
likely custom-retargeted upstream, exactly like the RE3 case). A background
research pass on this toolchain (requirements, licensing, realistic
skill/time investment for someone without prior 3D animation experience) was
started 2026-08-04 — check for its findings before starting any retargeting
work from scratch.

The `LeonPoseUnify-RE2` FMM mod package was uninstalled (clean — no leftover
`installed.ini` entry or loose override files) and deleted on 2026-08-04
now that the finding above is fully written up; don't expect it to still be
on disk if you go looking for it. Rebuilding it would just repeat the steps
in this doc (trimmed hash-list extraction from `re_chunk_000.pak` via
REtool, then the `cmn_move`/`hdg_hold`/`mag_hold` mapping described above)
if anyone ever needs to re-verify this finding.

## Update 2 (2026-08-04/05, home PC): live REFramework probing session — new lead found, then ruled out

**Context shift:** the player's real priority is narrower than "unify everyone's poses" —
**eliminating Claire's torso twist is what matters most**; the injured-state-pose-change
fix is a nice-to-have, and full RE2+RE3 unification is explicitly lower priority. This
also produced a new hypothesis worth testing on any future character too: *"the game
still thinks the body posture is the default two-handed low-and-right hold, even in VR
where hands are free — can we trick it into thinking a different weapon (e.g. shotgun)
is held, to get a different default posture, while the actual equipped/functional
weapon stays whatever it really is?"* Not yet tested — see "Not yet tried" below.

Since Update 1 established that raw `.motlist` swapping doesn't work (skeleton-specific
binary data), this session pivoted to the hypothesis that the twist might instead be a
**runtime/procedural correction** layered on top of the base animation — the kind of
thing this project has successfully found and manipulated before (e.g. `ForceEquipType`
struct mutation for the sub-weapon-suppression feature). Two new diagnostic/experiment
scripts were built:

- `reframework/autorun/re2_vr_posture_twist_probe.lua` — ImGui panel, "Dump Posture
  Snapshot" button. On first click each session, dumps every component attached to the
  local player (via `GameObject.get_components`), flags/dumps fields for any whose type
  name matches posture/IK/twist/correct/offset/aim/spine/etc. keywords, dumps
  `Equipment` and `MainWeapon` (Arm) fields unconditionally, and logs world+local
  orientation for `pelvis`/`spine_0`/`spine_1`/`spine_2`/`neck`/`head` joints via
  `tf:call("getJointByName", name)`. Has a "Reset" button to allow a fresh full
  component dump (the full list only dumps once per script-load otherwise).
- `reframework/autorun/re2_vr_arm_correct_override.lua` — ImGui checkbox, "Enable
  override (Claire only)". While checked, every `LateUpdateBehavior` tick it forces
  `app.ropeway.survivor.SurvivorBuriedArmCorrector`'s
  `<RightArmCorrectRotation>k__BackingField` to `Quaternion.identity()` on the local
  player, if-and-only-if `player:call("get_Name") == "pl1000"`.

### Key fact discovered: Claire's live GameObject name is `pl1000`, not `pl0100`

`utility/RE2Character.lua`'s `RE2_PL_MAP` assumes Claire is `pl0100` (and its
`normalize_profile_name` fallback logic checks for a `"pl01"` prefix) — this is wrong
for the live/runtime `player:call("get_Name")` value, which is **`pl1000`**. Leon's is
confirmed correct at `pl0000`. This caused `RE2Character.get_active_profile_key()` to
silently fall through to its `PROFILE_LEON` default for Claire the whole session (every
snapshot's `profile=` field misleadingly said "leon" regardless of who was actually being
tested) — harmless for this investigation since raw `Name` was logged too and used for
identification instead, but this is a real latent bug in a shared utility used by
holster/reload code elsewhere in the mod. Not fixed yet; separate task from this
investigation.

### Component inventory (both Leon and Claire — identical set, 91 components)

Captured directly from the probe's full-dump output so it doesn't need to be
re-generated (`re2_framework_log.txt` gets cleared/rotated on next game launch):

```
via.Transform
via.motion.DummySkeleton
via.motion.Motion
via.motion.ActorMotion
via.motion.MotionFsm2
via.physics.RequestSetCollider
via.motion.IkLeg
app.ropeway.IkArmFit
app.ropeway.IkController
app.ropeway.CharacterHandler
app.ropeway.JackDominator
app.ropeway.RestrictClient
app.ropeway.StayAreaController
app.ropeway.PressController
app.ropeway.dynamics.cloth.ClothControl
app.ropeway.survivor.SurvivorRestrictionCollector
app.ropeway.timeline.SurvivorActorController
app.ropeway.survivor.SurvivorCostumeChanger
app.ropeway.survivor.SurvivorMotionSpeedController
app.ropeway.survivor.jack.SurvivorJackActionController
app.ropeway.WwiseContainerApp
app.ropeway.WwiseAttitudeSender
app.ropeway.WwiseClipTagSender
app.ropeway.WwiseTagEventOnStopTrigger
app.ropeway.WwiseTagEventAutoTriggerEnabler
app.ropeway.WwiseTagSenderByEvent
via.wwise.WwiseVelocityTriggerList
via.wwise.WwiseJointAngleTriggerList
app.ropeway.WwiseTagAutoTriggerEnabler_v2
app.ropeway.WwiseTagPrefabGenerator_v2
app.ropeway.WwiseTagOnStopTrigger_v2
app.ropeway.WwiseTagFootEffectController_v2
app.ropeway.WwiseTagTrigger_v2
app.ropeway.WwiseTagToName_v2
via.wwise.WwiseSetGameParameterList
app.ropeway.WwiseTagWeaponTrigger_v2
app.ropeway.message.MessageSpeakerRegister
app.ropeway.effect.script.PlRainEffect
app.ropeway.motion.MotionEventHandler
app.ropeway.GroundFixer
app.ropeway.TerrainAnalyzer
app.ropeway.WaterSurfaceChecker
app.ropeway.survivor.SurvivorWallHitChecker
app.ropeway.survivor.motion.SurvivorTargetBankController
via.physics.CharacterController
app.ropeway.survivor.SurvivorCharacterController
app.ropeway.PenetratePreventer
via.dynamics.Ragdoll
via.physics.SensorTarget
app.ropeway.MotionCameraContainer
app.Collision.HitController
app.ropeway.HitPointController
app.ropeway.survivor.Inventory
app.ropeway.survivor.Equipment
app.ropeway.DynamicMotionBankController
app.ropeway.survivor.SurvivorIKLeftArmController
app.ropeway.survivor.SurvivorDynamicMotionController
app.ropeway.survivor.player.PlayerCondition
app.ropeway.survivor.player.PlayerController
app.ropeway.survivor.player.PlayerUserVariablesUpdater
app.ropeway.survivor.player.PlayerActionOrderer
app.ropeway.camera.PlayerCameraPositionSetting
app.ropeway.PlayerNoticePointSelector
app.ropeway.PlayerFootEffectController
app.ropeway.survivor.player.PlayerLookAt
app.ropeway.survivor.SurvivorBuriedArmCorrector
app.ropeway.survivor.player.PlayerForbidAimController
app.ropeway.VibrationController
app.ropeway.motion.MotionFsmTagCollector
app.ropeway.WwiseComponentEnabler
via.effect.script.ObjectEffectManager
app.ropeway.effect.script.EPVExpertDamageEffect
app.ropeway.PlBurnController
app.ropeway.effect.script.StampComponentCollector
app.ropeway.effect.script.PlEffectRecordClearController
app.ropeway.WwiseTagSetState_v2
app.ropeway.WwiseGlobalUserVariablesTriggerList
app.ropeway.util.script.SkeletonObserver
hikako.PlayerHapticVibrationParameterController   (false-positive keyword match — "hikako" contains "ik")
hikako.PlayerAdaptiveTriggerController            (same false-positive; DualSense adaptive-trigger stuff, unrelated)
via.wwise.WwisePackageList
via.wwise.WwiseBankList
via.wwise.WwiseGameParameterList
via.wwise.WwiseSwitchByNameList
via.wwise.WwiseMaterialSwitchList
via.wwise.WwiseSwitchList
via.wwise.WwiseGetGameParameterList
via.effect.script.EPVStandard
app.ropeway.effect.script.EPVExpertStandWave
via.effect.script.EPVExpertFootLanding
app.ropeway.ObjectStopControl
```

Keyword-matched components whose fields were actually dumped (see full field dumps in
git history of this doc / original session log if needed — summarized below):
- `via.motion.IkLeg` — no non-static fields printed
- `app.ropeway.IkArmFit` — `Setupped=true`, `UpdateTiming=5`, `BlendRateField=1.0` (same both characters)
- `app.ropeway.IkController` — large field set (leg/wrist/arm IK config: damping rates,
  foot-lock options, look-at target, `_SpineKind=0`, `_WristKind=0`, `LegKind=0`,
  `ExpressionId=3`). **`_SpineKind` was `0` on both Leon and Claire — not a
  differentiator**, but this is the component most likely to actually own spine
  posture and wasn't fully explored (only the fields REFramework reflection listed as
  non-static were dumped — there may be methods/other logic not visible as fields).
- `app.ropeway.survivor.SurvivorIKLeftArmController` — `IKEnable=true` (only field, same both)
- `app.ropeway.survivor.SurvivorBuriedArmCorrector` — **the main finding, see below**
- `app.ropeway.survivor.player.PlayerForbidAimController` — `CheckStartOffset`,
  `CheckStartPos`, `CheckDirection` — this is an aim-obstruction raycast check (forbids
  aiming through walls/geometry), not a posture pose; ruled out by inspection, not tested live.

### Main finding: `SurvivorBuriedArmCorrector.RightArmCorrectRotation` — real difference, but ruled out as sole cause

Confirmed reproducible across repeated snapshots, both characters holding their own
starting handgun (Leon: `WeaponType=1`/`EquipParts=6`; Claire: `WeaponType=9`/`EquipParts=2`
— per player confirmation these are each character's starting pistol, so this is a valid
same-category comparison despite the different specific weapon IDs):

- **Leon:** `RightArmCorrectRotation = (0.0000, 0.1305, 0.0000, 0.9914)` — a *pure
  Y-axis-only* rotation (x and z exactly zero), ~15° magnitude.
- **Claire:** `RightArmCorrectRotation = (-0.0227, 0.1722, -0.1285, 0.9764)` — a
  *multi-axis* rotation (real x, y, and z components), ~25° magnitude.

This is a genuine, repeatable, per-character structural difference in a component
literally named "arm corrector," so it looked like a strong lead.

**Live override test:** `re2_vr_arm_correct_override.lua` was enabled while playing as
Claire, forcing this field to `Quaternion.identity()` (no correction at all) every
frame. Confirmed via the probe's readback that the value genuinely landed at
`(0,0,0,1)` and *stayed there* — including checked ~34 seconds after the override
checkbox was switched back off, proving this field is **not recomputed by the game every
frame** (it's set once, likely at some trigger like weapon-equip, then left alone —
useful mechanistic fact for any future work on this component). Re-verified again at a
later timestamp, same persisted-identity result.

**Result: the player reported zero visible difference with the correction fully
disabled.** This was a real, confirmed-active test (not a "did it even apply" ambiguity
like the earlier motlist-swap test) — so this is solid negative evidence.
**`SurvivorBuriedArmCorrector` is very likely NOT the (sole) cause of the torso twist,**
or at most a very minor contributor whose removal isn't visually significant.

### Not yet tried / open threads for next session

1. **The "spoof weapon category" idea** (player's hypothesis, not yet tested): equip a
   shotgun/SMG as Claire and observe whether the same torso twist happens with those
   too, or only with handguns (`hdg`/`mag`). If handgun-only, investigate whether
   `Equipment`'s `ForceEquipType`/`ForceEquipParts` struct-mutation technique (already
   proven working elsewhere in this project for the sub-weapon-suppression feature —
   see main `re2_vr_mod_project_status.md`) could force the animation/posture system to
   use a different weapon category's pose while leaving the actually-equipped/functional
   weapon (ammo, fire logic, reticle) untouched. Not yet known whether such a
   posture-only override point even exists separately from the full equip type — this
   needs more probing (start with `MotionFsm2`/`ActorMotion`/`via.motion.Motion`,
   completely unexplored so far, and `DynamicMotionBankController` — name suggests it
   picks which motion bank/category plays, very promising and untouched this session).
2. **Continuous/live logging over a real play sequence** (proposed at the very end of
   this session, not yet built): a version of the posture probe that logs
   spine_0/1/2 local rotation once a second (or on a timer) rather than only on a manual
   button click, so it can be left running while doing normal gameplay (drawing weapon,
   aiming, moving, taking damage) to see whether those values are ever dynamic/live, or
   are purely a function of which baked animation clip is currently playing. This would
   settle "baked vs. procedural" more rigorously than single-snapshot comparisons.
3. `app.ropeway.IkController`'s other fields (arm damping rate/time, `ExpressionId`)
   weren't tested for a live effect on the twist — only inspected as static values, which
   matched between characters except where noted. Only `_SpineKind` was confirmed
   identical; the rest of this component's fields also matched in the one Leon/Claire
   snapshot pair actually diffed side-by-side, but a full field-by-field diff wasn't done
   carefully — worth double-checking, and this remains the single most name-relevant
   untouched component ("Ik**Controller**" with a "**Spine**Kind" field).
4. If none of the above pan out: the animation-retargeting route from Update 1
   (RevilMax + alphazolam's Motlist Tool, 3ds Max) remains the fallback, now with the
   3D-tool skill/licensing research already done (see the research-agent report
   summarized in this conversation's history, or re-run that research if starting fresh
   without that context).

### Files added this session
- `reframework/autorun/re2_vr_posture_twist_probe.lua` (diagnostic, safe to leave in place)
- `reframework/autorun/re2_vr_arm_correct_override.lua` (diagnostic/experimental
  override, currently gated to Claire only and defaults to OFF on load — safe to leave
  in place, does nothing unless the checkbox is manually enabled)

## Suggested next steps (original, now superseded by the update above — kept for history)

1. On the home PC, reinstall REFramework (VR is needed anyway, and it's required to properly test animation swaps in-headset rather than on a flat monitor).
2. Get Fluffy Mod Manager's RE2 custom-game entry configured (one-time manual step, see above).
3. Install/test the Leon→Claire `hdg`+`mag` swap (recreate similarly to `LeonPoseToClaire-TEST` above, or redo it fresh) and judge in-headset whether the torso-twist problem goes away.
4. If it looks right: scale the same swap to `cmn` (base movement — likely the most impactful for general posture) and the remaining weapon categories, for Claire and then Ada (`pl20`).
5. If broken/needs retargeting: the RE3 Jill/Carlos case will need this regardless — look into RE Mesh Editor (NSACloud's Blender addon, needs Blender 4.3.2+) for actual bone/animation retargeting, following the same technique whoever built the existing "Jill's Animation To Claire" mod used.
