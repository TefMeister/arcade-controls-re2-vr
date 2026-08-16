# Decoding an engine's animation-bank selector in three dumps

**Status: shipped, confirmed working.** Feature request: "play the unarmed
walk animations even while a weapon is equipped." Delivered same evening by
diffing live engine state between two conditions until the selection
mechanism fell out, then flipping the narrowest switch that mechanism
offered. No engine code was read; every fact below came from comparing two
reflection dumps.

## Why not the obvious approaches

Two known dead ends from earlier in this project ruled themselves out
immediately: swapping compiled animation files on disk (skeleton-specific
binary data, and a file-level hammer for a runtime problem), and spoofing
the equipped-weapon type (visibly swaps the weapon model too). The right
altitude had to be the live motion system.

## Pass 1: capture what actually plays, in both states

A probe logged, per frame while walking: each motion layer's dominant
animation name, weight, frame, bank id. Once walking armed, once unarmed.
The diff was strikingly clean:

- The locomotion layer plays the **same motion ids from the same bank id
  (1000)** in both states — only the resolved animation *name* differs
  (an unarmed-variant prefix vs. a weapon-variant prefix).
- The weapon grip lives on a completely different layer, fed by different
  bank ids (a "hold" bank and a "finger" bank).

So the game doesn't pick different animations — it changes *what bank 1000
resolves to*. (Incidentally, the player worried this capture was invalid
because they stood still for part of it. It was better for it: idle, walk,
and walk-end all appeared, all showing the same pattern.)

## Pass 2: dump the bank tables — and learn from an "empty" result

Dumping the component's *dynamic* bank slots found nine entries, all empty,
identical in both states — a null result that immediately redirected
attention to the *active* bank list. That list had 82 entries and was
**byte-for-byte identical armed vs. unarmed**: every candidate motlist
(weapon walk, common walk, all their caution/danger/wet variants) coexists
permanently, with several entries sharing bank id 1000. Selection among
same-id entries had to come from per-bank state we hadn't read — and the
component's method list conveniently included a `TargetBankType` property.

## Pass 3: sweep every getter, diff again

Rather than guessing which per-bank property mattered, the third dump
called **every parameterless getter on every bank object** in both states.
The diff decoded the whole mechanism:

- `Motion.TargetBankType`: **287 armed, 0 unarmed** — the selector.
- Each bank carries `BankType` + `BankTypeMaskBit`; a bank is eligible when
  `(TargetBankType & mask) == BankType`. The values line up perfectly:
  low byte = weapon category (handgun walk = 31; 287 = 0x11F), high bits =
  condition flags (light/water/combat/caution/danger each visible as a bit
  pattern across the variant banks).
- The common-walk fallback has BankType 0, mask 0 — always eligible, wins
  only when nothing more specific matches.
- Bonus fact from comparing this dump against pass 2's: the bank list is
  **rebuilt when the equipped weapon changes** (magnum banks appeared where
  handgun banks had been). Any fix must re-apply after equips.

## The fix: poison the specific, fall through to the general

The tempting fix — force `TargetBankType` to 0 — is wrong, and the decoded
mechanism says exactly why: the hold and finger banks obey the same rule,
so the hand would stop gripping the weapon. Instead, the shipped script
rewrites only the weapon-specific *movement* banks' `BankType`/mask to an
unsatisfiable combination. Bank 1000 resolution falls through to the
common-walk family, whose own condition-bit matching still works — so the
caution/danger/wet gait variants survive, just in their relaxed versions.
Grip and finger banks untouched. Originals remembered and restored on
disable; the poison re-applies on a short poll because of the
rebuild-on-equip behavior.

One honest unknown was declared before testing: the setters had never been
called (only getters were proven). The script was written to detect and
report a read-only failure loudly instead of failing silent. They turned
out writable, and the native selector re-reads them live.

## Lessons

1. **Diff live state between two conditions instead of reading engine
   code.** Three dumps decoded a bitmask eligibility system that would have
   taken far longer to find in a disassembler — and the diff *is* the
   proof, not a hypothesis.
2. **Design each dump from the previous one's result.** Layer capture →
   "same id, different resolution" → bank tables → "identical lists" →
   per-bank getter sweep. None of the three was speculative.
3. **Sweep getters generically when you don't know which property
   matters.** Hand-picking members had already produced one misleading
   dump (wrong property names read as empty); calling everything with zero
   parameters is cheap and complete.
4. **Fix at the narrowest layer the mechanism offers.** The global selector
   was one write away, but understanding the rule showed it would break the
   hands. Poisoning three specific banks got the feature with zero
   collateral.
5. **A null result is a result.** The empty dynamic-bank table eliminated a
   whole subsystem in one dump and pointed directly at the active list.
