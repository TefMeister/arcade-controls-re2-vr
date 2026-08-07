# A holster zone drifted only during physical turns — the fix was to stop depending on the broken axis, not to fix it

**Status:** Shipped workaround, confirmed working. Root cause still
unknown — documented here as a case for when "make the bug irrelevant" is
a legitimate stopping point, not a cop-out.

## The symptom

A body-anchored interaction zone (used for a reach-to-equip gesture,
positioned relative to the headset) would sometimes end up on the wrong
side of the player, or behind them, specifically when the player turned
their body **physically** in their room. Turning in-game with a control
stick instead of physically moving never triggered it — same zone, same
underlying position formula, only one of the two ways to turn broke it.

## Why this one wasn't worth root-causing

The zone's position was computed as the headset's position plus a small
offset, with that offset rotated into the headset's own local
right/up/forward axes so it would stay "in front of you" as you turn.
Those derived axes were the suspect — they appeared to drift away from
the player's true facing specifically under physical rotation, while
staying correct under in-game stick rotation, which pointed at some
difference in how the two turn types update headset-relative axis data.

That's a real, chaseable bug. It wasn't chased, for a practical reason:
the offset this particular zone needed was small and the feature had a
trivial escape hatch available (see below), so spending investigation
time on the underlying tracking-axis question wasn't worth it *for this
feature*, even though the same root cause would likely resurface for a
different feature that couldn't take the same shortcut.

## The workaround

The offset was rotated by three axis vectors (right, up, forward), each
scaled by an offset component (x, y, z) before being added to the
headset position. The drift lived specifically in the right/forward axes
— the ones that change based on which way you're facing (yaw). The up
axis doesn't rotate with yaw; it points the same "up" regardless of which
direction you're facing, physically or otherwise.

The fix: set the offset's right/forward components to exactly zero, and
only use the up component (moving the zone straight up from the headset,
not out in front of it). With those components at zero, whatever the
drifting right/forward axes were doing got multiplied by zero and
canceled out completely, regardless of what was actually causing the
drift. The zone became immune to a bug whose cause was never identified,
by simply no longer depending on the axes that bug affected.

This wasn't free — it changed the zone's position (straight up from the
headset instead of out in front at an angle), and a later request to
raise the zone slightly (to avoid overlapping a neighboring zone) had to
be satisfied purely with more "up," since "up and slightly forward" would
have reintroduced the exact axes being avoided.

## Why this is worth writing down as a real technique, not just a shortcut

"We didn't find the root cause, we just avoided needing it" can sound
like leaving a bug in the code. The distinction that makes it a
legitimate engineering decision here: the fix doesn't hide a symptom
under conditions where the bug still fires — it removes the *dependency*
that made the bug able to affect this feature at all. There's no
remaining code path where this zone can drift, because the terms that
would carry the drift are structurally zero, not just currently zero.
That's different from, say, clamping a wrong value after the fact, which
would still be silently masking an active bug on every frame.

The trade-off is real and worth stating plainly: this only works because
the feature could tolerate losing the "in front of you" positioning and
settle for "above you" instead. A feature that actually needed the
forward-offset behavior would have had no equivalent escape hatch, and
would have needed the real root cause — likely in whatever computes
headset-relative right/forward/up axes and treats physical body rotation
differently from in-game stick rotation.

## General lesson

When a bug's effect is isolated to specific terms in a larger
calculation, and the feature can tolerate not using those terms, zeroing
them out can be a legitimate fix rather than a deferred one — as long as
the result is that the buggy path is structurally unreachable, not just
unlikely. It's worth being explicit in the code and in notes like this
one about *which* underlying bug is being sidestepped and *why* this
particular feature could afford to, so a future feature that hits the
same root cause doesn't assume it's already been fixed.
