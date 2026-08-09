# A fix that kept reverting itself — because it was fixing the wrong character's data

**Status:** Root cause found and fixed. Written up because the symptom (a config edit
that appears to work, then silently reverts) looks like a caching or file-locking
problem, and chasing that theory would have wasted a lot of time before finding the
real, much simpler explanation.

## The symptom

A per-character position setting (which body-relative slot a piece of equipment is
drawn from, tuned per playable character in a JSON config with one block per character)
had drifted to a broken value for one specific character. The fix was simple and
verifiable: the correct value was already known, already present for every *other*
character in the same file, and matched the game's own compiled-in default. Editing the
JSON directly to restore it should have been a one-line fix.

It reverted. Twice. Re-editing the file, confirming the write landed on disk, then
checking again minutes later showed the exact same broken value back — not a *similar*
broken value from some new accidental recalibration, but **bit-for-bit identical** to
the original corruption.

## Why "bit-for-bit identical" was the tell

A genuinely new accidental miscalibration (the likely original cause — reaching for a
different, deliberately-relocated slot while a totally different feature's calibration
was actually active) would produce fresh sensor noise every time. Getting the *exact
same* floating-point value back, twice, from two different play sessions, is not
consistent with "something recalibrated it again." It's consistent with **something
holding a stale copy in memory that never actually got refreshed, repeatedly
re-saving that same stale copy over the fix** every time an unrelated save-triggering
event fired (in this case, ordinary gameplay like switching weapons, which happened to
also serialize this character's whole settings block as a side effect, whether or not
anything about it had actually changed).

## The actual root cause: a profile-lookup bug, unrelated to the setting itself

The real bug was in a completely different piece of code: the function responsible for
mapping "which character is currently being played" to "which settings block applies"
had a stale hardcoded name check for one specific character's live in-engine identifier
— the identifier had apparently changed at some point (possibly a game patch, possibly
always been wrong and never exercised until this investigation), and the lookup quietly
fell through to a *default* character instead of erroring. This had already been found
and written up as a known bug in an earlier investigation, with a ready fix sitting
unapplied.

Once traced, this fully explained the reverting fix: **every read and write for that
one character's settings had actually been hitting a different character's data block
the entire time.** The file edit that kept "not sticking" was never actually being
undone by anything reading it correctly — it was being correctly loaded, then
overwritten again by ordinary gameplay under the *other* character's identity, which
was still silently routing into the same block.

## Why the corruption happened in the first place

With the routing bug in mind, the original corruption made sense too: an in-game
calibration action performed while playing the character whose lookup was broken had
been silently attributed to a different character's saved data the entire time — a
completely unrelated feature that happened to be positioned physically close to where
the corrupted value ended up (both were legitimately meant to be low, one deliberately
so) most likely got calibrated by accident, and the resulting value landed in the wrong
character's block due to the same routing bug.

## General lessons

- **A config edit that appears to work and then silently reverts to the *exact same*
  bad value is a strong signal of a stale in-memory copy being re-saved, not of a new
  event re-corrupting it.** Floating-point/sensor-derived values essentially never
  repeat bit-for-bit by coincidence; bit-for-bit repetition across sessions points at
  something never actually being refreshed, not something happening again.
- **When a fix to data X doesn't hold, check whether something else is silently
  routing reads/writes for a *different* identity into the same storage as X.** The
  bug wasn't in the value, or in the save mechanism — it was in a lookup one layer
  removed from both, deciding which record to touch at all.
- **A previously-found-but-unapplied bug is still active.** This exact routing bug had
  already been diagnosed and fixed in code during an earlier, unrelated investigation
  — the fix just hadn't been deployed to the running install yet. It kept causing new,
  seemingly-unrelated symptoms until it was actually applied, not just documented.
- **If a save operation writes an entire record (not just the field that changed),
  editing the underlying file while the owning process is live is inherently racy** —
  any subsequent unrelated write from that process will re-serialize its current
  in-memory state over your edit, whether or not the specific field you touched was
  ever actually refreshed in memory. Don't trust a live file edit until you've forced
  the owning process to reload and re-verified, especially if anything about the
  reload path is itself in question (as it was here, via the routing bug).
