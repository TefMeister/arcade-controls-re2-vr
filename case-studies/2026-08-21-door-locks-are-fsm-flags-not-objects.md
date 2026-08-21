# Door locks are FSM flags, not objects (and a field named for the job was empty)

**Date:** 2026-08-21 · **Game:** RE2 Remake (RE Engine, REFramework Lua)
**Feature context:** "open doors with your hands" in VR — push gesture fires the
game's own door-open path. Side quest: the slide-bolt doors you unlock from one side.

## What happened

Hunting the slide-bolt mechanism, a field dump on the door
(`app.ropeway.gimmick.action.GimmickDoorBase`) turned up a field literally named
`_LockMechanism`. Obvious jackpot — dump it. It resolved to a
`List<app.ropeway.gimmick.action.GimmickDoorLockMechanism>`... with `mSize = 0`.
Empty. On a door that was demonstrably locked.

The real lock lived somewhere much less object-shaped. Capturing a live unlock
(player on the bolt side, interact) showed the whole thing is **FSM state + a
flag**, not a lock component:

```
InteractManager.requestTriggerLock   lock_name = "Key [ButtonUnlockB] > FSM: KeyUnlockStartB"
GimmickDoorBase.startCamera          <- the little lock-opening cutscene
startChoreographSequence(side=1, ...)
onUnlock                             <- _ChoreoKey = "Unlock"
  _SetFlagUnlock : FsmActionSetParam { KeyName = "Unlock", Enable = true }
<startUnlockSequence>b__223_0        <- compiler-generated lambda, sequence end
requestOpenByLever(1) -> setOpenSpeed(0.01) -> onOpened   <- then a NORMAL open
```

The "lock" is an FSM `Key` node (`ButtonUnlockB`) on the door's own
`MotionFsm2`, and unlocking sets a named flag via `FsmActionSetParam`. The
locked-side rejection is the same shape: `requestOpenByLever` fires first, and
the FSM vetoes it into `execCantOpen` (which plays the handle-rattle animation).
The `GimmickDoorLockMechanism` class exists in the type system but this door
never populates it.

## Lessons

1. **A field named exactly what you're hunting can still be a decoy.** Dump the
   *value*, not just the type. `_LockMechanism` was real, typed correctly, and
   unused — the five minutes spent printing `mSize` saved a session of building
   against a dead API.
2. **Capture a live success before theorizing from statics.** The unlock
   sequence was un-guessable from the class dump: the lock state, the cutscene
   camera, and the flag-set all hang off FSM plumbing (`Key [...]` nodes,
   `FsmActionSetParam`) that no amount of method-name reading would have tied
   together. One real unlock with arg-capturing hooks told the whole story.
3. **Locked vs unlocked is observable without any lock object.** Locked door:
   `requestOpenByLever → execCantOpen`. Unlocked door: `requestOpenByLever →
   setOpenSpeed → onOpened`. A feature that force-opens doors can use the
   `execCantOpen` path as its "don't touch locked doors" guard and never needs
   to read lock state at all.
4. **Compiler-generated lambda names are grep gold.** `<startUnlockSequence>b__223_0`
   in the hook log immediately named the orchestrating method
   (`startUnlockSequence`) — the entry point if the hand-unlock idea is ever
   resumed.
5. **Sometimes the answer is "the game already does it well."** The unlock
   cutscene reads fine in VR, so the hand-operated bolt was parked on player
   verdict, not technical failure — with the entry point documented for later.

## Where the main feature stands

**Bench test passed the same evening:** `door:call("execForceOpen", side)` alone
fully opens a closed unlocked door from Lua — no other calls needed, verified on
two doors at under ~1.3 m. `SideType` is an **absolute door-local swing
direction** — 1 swings the door one way, 0 the other, regardless of where the
player stands (the player's final clarification after two rounds of
player-relative "push/pull" readings that were artifacts of testing from a
single side). A push feature must therefore map the player's side of the door
plane to the away-swinging value itself.

Two testing lessons from the bench itself:

6. **A "failed" test at the wrong distance looks like a partial API.** The first
   bench report was "it only nudges, like a zombie, door stays closed" — which
   sent us building a call-combo matrix (add `setOpenSpeed`, add `onOpened`...).
   The real cause: the player stood too far away. Same call, closer in, swings
   the door fully. Before theorizing that an API needs more calls, re-run the
   minimal call under the exact conditions the live capture showed (~1 m).
7. **Direction conventions take three tries — plan for it.** The side-0/side-1
   meaning was reported as push/pull one way, corrected to the opposite, and
   finally resolved as *neither*: an absolute door-local swing direction that
   only looked player-relative because early tests all stood on one side. Test
   directional APIs from both reference frames before naming the convention —
   and ship a config flip toggle regardless, it costs nothing.

8. **The "fallback" verb was a trap.** `requestOpenByLever` + `setOpenSpeed`
   (the exact pair the game itself fires on a normal interact) called from Lua
   opens the door a crack and then wedges it — no further open call works on
   that door. Outside its interact context, the lever path starts a
   choreography it can never finish, and the door FSM stays mid-sequence.
   `execForceOpen` (with its force/one-shot semantics) is the only safe
   external verb. Replaying a captured call sequence is not automatically
   safe just because the game runs it — context the game sets up around the
   calls (interact lock, player jack animation) can be a hard dependency.

The feature script is now built (wrist-velocity push gesture → `execForceOpen`,
side chosen from the door's facing axis with a flip toggle, per-door cooldown,
no hooks at all, and deliberately NO lever fallback). Awaiting its first
in-headset test.
