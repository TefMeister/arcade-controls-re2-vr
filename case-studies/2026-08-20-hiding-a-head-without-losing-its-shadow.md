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

**What works:** don't bet on any single load signal. This corner took three builds in
one day, and each failure taught something a reader should have up front:

### Failure A: a "busy" flag that never goes back down

The first build gated all per-frame work on `SaveDataManager.get_IsLoadBusy` OR
`MainFlowManager.get_IsInLoadGameData` OR `get_IsLoadGame` being true. At least one of
the MainFlowManager pair is a *mode* flag, not a *transient* flag — once a save has
been loaded it stays true for the rest of the session. The gate that was supposed to
pause the script during loads became a permanent off-switch: one save load and the
script never hid anything again, and a script reset couldn't fix it because the flag
was still latched. "Is a load happening" and "did this session come from a load" both
look like `IsLoadSomething` in RE Engine's naming.

### Failure B: the "safe" getter never fires at all

The second build gated and edge-detected on `SaveDataManager.get_IsLoadBusy` alone.
Across five consecutive in-game save loads it never went true once — whatever it
reports busy for, it is not this path. So the load detector silently ceased to exist,
and only a player-object address comparison caught the rebuilds (which, per the trap
above, misses same-slot reuse).

### Failure C: the rescan that fires early finds a torso with a flashlight

When a rebuild *was* detected, the immediate rescan walked a player whose meshes had
not streamed in yet: it found only attachments (FlashLight, Transceiver), no
Face/Hair. The list was now non-empty, so the "rescan when empty" logic considered the
job done, and the head meshes that appeared a beat later were never hidden. The
existence of a player object does not mean the player's hierarchy is complete.

### The combination that ships

- **Never gate on unverified getters.** Poll all three, and treat *any transition of
  any of them* as a load boundary that forces a rescan — rising or falling doesn't
  matter, a spare rescan is cheap, and logging each transition means the log
  eventually documents each getter's real semantics for free.
- **Validate scan results semantically.** A scan without a Face/Hair mesh is flagged
  provisional and retried every 2 seconds until the real head shows up.
- **Periodic revalidation as the backstop.** Re-walk from the live player every 10
  seconds even when everything looks healthy. This is the only thing that catches the
  same-slot reuse case, because the orphaned components accept writes and read back
  the written values — no per-component validity check can see the problem. Restore,
  rewalk, and re-apply all land inside one frame callback, so the periodic pass never
  flickers on screen.

### Bonus trap: substring matching bites back

The wide name-match that catches `eyelash`/`lash` meshes also caught **FlashLight**
("F-lash-Light") and quietly hid the flashlight's body mesh for several builds. If you
match mesh names by substring, keep an exclusion list that wins over the match list —
and audit your scan log's "will hide" tags against what you actually intended.

### How the wedge was diagnosed from the log alone

The log showed `load finished -- forcing mesh rescan` exactly once (one all-false
frame during the handover), and then the periodic distance-trace lines kept flowing
while the `rescan (gen N)` line that should have followed never appeared. The distance
trace runs *before* the load gate in the frame handler; the rescan runs *after* it;
the only early return between them is the gate itself. Which log lines kept appearing
versus which stopped bisected the frame handler to a single statement — worth
arranging your per-frame logging so that ordering carries information on purpose.

## Diagnostic lesson

The first instrumented build produced **zero** log lines across a whole play session,
because the distance function returned early on failure without logging why. A
diagnostic that can fail silently teaches you nothing and costs a full test cycle.
Always log the failure branch, rate-limited, with which lookup failed.
