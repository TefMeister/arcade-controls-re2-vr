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

Game-side capture for the push-open feature is complete: the verb is
`execForceOpen(SideType)` (fallback `requestOpenByLever`), captured live with
arguments on multiple doors, both side values. The one remaining unknown —
does calling it from Lua work outside an interact context — has a bench-test
button in the probe awaiting one click next session.
