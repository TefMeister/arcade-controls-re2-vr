# Hiding the player's head in first person without losing its shadow — and bringing it back only when it should

RE2 (RE Engine, REFramework VR). Written for other AI assistants doing similar work:
every detector below is one we verified live, and the two dead ends cost real hours.

## The starting problem

REFramework's FirstPerson has a "Hide Joint Mesh" option, but it hides the head by
zeroing the head bone's matrix. Collapsed geometry disappears from *every* render
pass, so the head's shadow goes with it — the player casts a headless shadow.

**Fix:** `via.render.Mesh` has independent per-pass draw flags. Setting
`set_DrawDefault(false)` + `set_DrawShadowCast(true)` renders the shadow only. The
technique is in praydog's `RE8VR.cpp` `fix_player_shadow()`. There is also
`set_DrawRaytracing` on RT builds, which you probably want false so the head does not
appear in ray-traced reflections. Leave REFramework's own `HideJointMesh` off.

Two scan gaps worth knowing: `getComponent()` returns only the FIRST `via.render.Mesh`
on a GameObject (eyelashes/eyes are often extra mesh components on the same object, so
enumerate all components), and name matching needs to cover face, hair, head, eye,
lash, brow, matsuge, beard, mustache, hige, tooth, teeth, tongue.

## Then: the head must come back sometimes

A hidden head reads as a decapitated body whenever the view leaves first person —
zombie grabs, death cams, third-person cutscenes. But restoring it while the camera is
*on* the head puts hair and eyelashes in the lens. So you need to know, precisely,
when the camera is not first-person.

### Dead end 1: a damage flag

`SurvivorCondition.get_IsDamage` is true for **any** hit. An ordinary punch or claw
swipe that never leaves first person would pop the head on with the camera inside the
skull. Rejected before shipping.

### Dead end 2: camera-to-head distance

Intuitively appealing: measure the distance from the camera to the `head` joint
(`transform:getJointByName("head")` — "head" is the name REFramework's own
FirstPerson.cpp hashes for RE2) and reveal the head when it grows.

Live measurement killed it. First-person resting distance was **0.111 m**, and during
an actual zombie grab it stayed at **0.112 m**. The camera does not leave the head
during a grab at all. No threshold could ever have worked.

### What actually works

**1. `JackDominator.get_Jacked`** — RE Engine's term for being grabbed/held.

```lua
local jd_type = sdk.typeof(sdk.game_namespace("JackDominator"))
local jd = player:call("getComponent(System.Type)", jd_type)
local td = sdk.find_type_definition(sdk.game_namespace("JackDominator"))
local jacked = td:get_method("get_Jacked"):call(jd)
```

True **only** for grabs — ordinary melee hits never set it. REFramework's
`FirstPerson::is_jacked()` reads exactly this to suppress body rotation and roomscale.

**2. `firstpersonmod:will_be_used()`** — REFramework exposes this to Lua. Internally it
is `is_enabled() && is_first_person_allowed() && m_player_transform != nullptr`. Use it
as a hard guard: *never* restore the head while it is true.

This second one fixed a bug that looked mysterious: flipping a lever put eyelashes in
the lens, because the game reports that interaction as cinematic while it actually
plays in first person. Trusting the game's "is this a cutscene" signal alone is not
enough — ask FirstPerson whether it is currently driving the camera.

The payoff of measuring instead of theorising: during a grab, `jacked=true` and
`firstperson=false` simultaneously. FirstPerson steps aside, so the reveal is safe and
cannot put geometry in the lens, and the head hides again the instant the grab ends.

Note you *cannot* drive FirstPerson's `ShowInCutscenes` from Lua to force first person
per-situation — it is a C++ ModToggle, and the only Lua bindings are `is_enabled`,
`will_be_used`, and `on_pre_flashlight_apply_transform`. Enabling it globally makes
every cutscene first-person and wrecks them.

## The stale-reference trap (this is the real lesson)

Symptom: the head becomes visible again after some transition and only a script reset
fixes it. We hit two independent causes, and **both defeat the obvious checks**.

**Reading a flag back from the component you just wrote to proves nothing.** After the
game rebuilds the player, the orphaned mesh components are still live objects. They
accept `set_DrawDefault(false)`, report success, and read back `false` — while the head
you can actually see on screen belongs to different components entirely.

**Comparing the player object's address only catches some rebuilds.** Death → Continue
allocates the new player elsewhere, so the address changes and the check fires. Loading
a save *while alive* frees and reuses the same slot, so the address is byte-identical
and the check sails straight past it. This is why "it works when I die but not when I
load" is a coherent bug report and not user error.

**What works:** watch the load transition itself, and rebuild unconditionally when it
ends.

```lua
-- true while a save load is in progress
SaveDataManager.get_IsLoadBusy
MainFlowManager.get_IsInLoadGameData / get_IsLoadGame
```

Skip all work while busy, then drop the cached component list when it goes false. No
dependence on object identity.

## Diagnostic lesson

The first instrumented build produced **zero** log lines across a whole play session,
because the distance function returned early on failure without logging why. A
diagnostic that can fail silently teaches you nothing and costs a full test cycle.
Always log the failure branch, rate-limited, with which lookup failed.
