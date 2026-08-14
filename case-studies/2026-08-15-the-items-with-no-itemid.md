# The items with no ItemId — when "same UI, same data shape" is a bad assumption

**Status:** RESOLVED. Both the identification bug and the merge-into-existing-stack
bug are fixed and confirmed live. Worth writing up because the failure mode — two
categories of the "same" game object secretly using different identity fields —
is a general trap in reflection-driven modding, not specific to this engine.

## The setup

An opt-in automation reads an incoming pickup's item type from a specific field
(`GetItemStock.DefaultItem.ItemId`) to check it against an allow-list before
auto-granting it, skipping the game's own manual confirm screen. This field had
been reliable across dozens of item types over a long investigation — herbs,
ammo, key items, gunpowder, all read their correct ID the instant the pickup
screen opened.

Three specific items never worked: a melee weapon and two grenade types. Every
attempt to add them to the allow-list failed silently — no crash, no error, they
just always fell through to "not on the list, staying manual," as if the game
considered them invisible to the check.

## First wrong theory, and the diagnostic that killed it

The first assumption was a timing problem — maybe these three items populated
their ID field later than everything else, on some different frame. A poller was
added that samples the ID field every frame for a couple of seconds after any
pickup and logs every change, independent of the real allow-list logic, so the
question "when does this become correct" could be answered directly instead of
guessed at.

The answer: for these three items, the field was never anything but `0`, from the
very first frame to the last. Every *other* item type read correctly at frame
zero. This wasn't a timing bug — the field genuinely never held their identity.

## The real finding: a second, parallel ID table

Extending the same poller to dump the object's other fields (not just the one
being checked) turned up a second field, `WeaponId`, sitting right next to the
one everyone had been reading — and it held the item's real numeric identity.
These three items are classified internally as weapon-shaped objects, sharing an
ID namespace with actual firearms, despite behaving like ordinary consumables
from the player's side (they show up in the same pickup screen, stack, and
combine like anything else).

The practical fix was a second lookup table keyed on this separate field, checked
as a fallback whenever the primary lookup came back empty — cheap, and it doesn't
disturb anything already working for every other item type.

**Lesson:** when a handful of items in an otherwise-uniform category behave
consistently *wrong* while everything else is consistently right, the fault is
more likely a structural difference in how those specific items are represented
internally than a bug in the shared logic. "It shows up in the same menu and
behaves the same way to the player" is not evidence two objects share a data
shape underneath — verify the field actually holds what you think it holds for
*each* category, don't assume it generalizes from the cases that already worked.

## A second bug, only visible once the first one was fixed

Fixing identification only solved picking up the *first* one of these items.
Picking up a second one, meant to merge into an existing stack, still silently
failed — the automation correctly recognized the item now, but never detected
that this particular pickup was a merge rather than a fresh grant, and grant-if-
empty logic doesn't apply cleanly to a slot that's already occupied.

Two plausible field-based theories were tried and cleanly ruled out, not just
abandoned on a hunch:
- A direct "what's in this slot" accessor existed on the relevant object and
  looked exactly like the right call — it executed without error and returned
  nothing at all, a dead end distinguishable from "wrong argument" only by the
  fact that no error was raised either.
- A second, closely-related field that already carried real data for the
  *identification* fix above was checked for an equivalent merge-side signal —
  it read a fixed sentinel value ("none") on every genuine merge tested, never
  the existing stack's real value.

Both are the kind of dead end worth recording precisely because they *looked*
like the obvious next thing to try, and only live testing distinguished "wrong
API" from "right API, doesn't apply here."

## Finding the real answer by watching the native calls instead of guessing fields

After two field-based guesses failed, the approach changed from "which field
holds the signal" to "what does the game itself actually call when a human does
this correctly, with the automation switched off entirely." Four candidate
native methods on the relevant object were hooked as pure observers — call the
original unconditionally, change nothing, just log that the call happened and
what arguments it received. A fully manual merge was then performed by hand.

Only one of the four ever fired. Every other item type's merge path — already
working, already relied on a *different* one of these four methods to prepare a
subtraction calculation first — never touches that preparation step for this
item class at all. That single trace explained every earlier dead end at once:
none of the field checks had been reading stale or wrong data, they'd been
checking fields that this code path simply never populates, because the game
doesn't need that data for this specific case.

The fix matched the observed call exactly — call only the one method the trace
showed, skip the preparation step entirely for this item class, rather than
reusing the general-purpose merge path built for everything else. Reusing the
general path instead of matching the observed trace would have called a
subtraction-oriented method in a context the game itself never uses it for, on
data it wasn't built to receive — a pattern that had already caused real,
silent data corruption once before in this same project when a live object
reference was handed to a method expecting a disposable scratch copy.

**Lesson:** when direct field inspection runs out of plausible candidates, a
pure, non-mutating observer hook on the actual native call sequence during a
known-good manual action answers "what does the game call, in what order, with
what data" directly — a strictly stronger signal than continuing to guess at
which field might carry the same information indirectly. And once you have that
trace, match it exactly rather than reusing a similar-looking path built for a
different case; "similar enough" native calls can have real side effects the UI
never reveals.

## The merge-*detection* problem was separate from the merge-*execution* problem, and needed its own fix

Even with the correct call identified for actually performing a merge, the
automation still needed to decide *whether* a given pickup was a merge in the
first place — and the field every other item type's merge-detection relied on
never carries a signal for this item class either, confirmed by the same
observer trace (it simply isn't part of the call sequence these items go
through).

The eventual signal used instead: the game's own cursor-placement logic already
picks a specific inventory slot as the target for any given pickup, before this
automation gets involved at all. If that slot is already occupied, the game
chose it anyway — which only makes sense if the native flow already decided this
was a compatible merge target, not a random collision. Treating "target slot
already occupied" as the merge signal itself, for this item class only, closed
the gap without needing a field that doesn't exist.

**Lesson:** when nothing in an object's own data answers a question directly,
check whether something *upstream* in the flow already implicitly answered it —
here, the game's own slot-selection had already done the classification the
automation was trying to re-derive from scratch.

## General lessons

- **Consistent behavior across a whole category, with a small consistent
  exception, points at a structural difference in that exception — not a bug in
  the shared code.** Confirm the assumed data shape per-category instead of
  extrapolating from the cases that already work.
- **A call that "succeeds with no error" and a call that "genuinely doesn't
  apply here" look identical from the outside.** Only live testing against a
  known-good manual baseline distinguishes them — don't treat a clean return
  value as confirmation the call was the right one.
- **When field-guessing stalls, hook the real call sequence instead of guessing
  another field.** A pure CALL_ORIGINAL-only observer hook that only logs is
  safe to leave running during a known-good manual reproduction, and answers
  "what actually happens" directly instead of indirectly.
- **Match an observed native call sequence exactly for a new item class, rather
  than reusing a path built for a different one, even if the two look
  superficially similar.** A method designed to do subtraction math on live data
  can silently corrupt state when handed something it wasn't built to receive —
  this project has now hit that exact failure mode more than once.
- **If a question has no direct answer in an object's own fields, check whether
  an earlier step in the same flow already implicitly answered it.**
