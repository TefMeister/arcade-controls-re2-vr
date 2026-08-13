# A fix that existed — just not anywhere the next session could find it

**Status:** RESOLVED. Not a technical bug story so much as a process one: a real,
working fix was built, then briefly became unrecoverable not because it was lost, but
because it existed in a place nobody thought to check. Worth writing up because the
failure mode (and its accidental recovery) generalizes well beyond this one project.

## The setup: two machines, one project, an informal handoff

This project is developed across two computers — one with the VR headset needed for
live testing, one without. A shared sync folder held dated session write-ups so an AI
assistant picking the project back up on either machine could see what the other
machine had done. The convention: whenever a session changed live mod files, drop a
copy plus notes into a new dated folder before ending the session.

A real, working bug fix — the last unsolved case in an inventory-pickup automation
feature — was found and confirmed live on the machine without the headset. The session
that found it did not export it into the shared folder before ending.

## The fix goes missing, and the wrong thing gets blamed at first

Picking the project back up later, the assistant found the shared folder's most recent
entry (from before the fix), correctly identified that entry as no longer matching what
the developer described, and — instead of assuming the fix simply hadn't happened —
spent real effort re-deriving it from scratch: reproducing the bug live, reading fresh
diagnostic data, forming a real hypothesis. That diagnostic effort wasn't wasted (it
independently found a genuine, previously undocumented correlation in the failure), but
it was still solving a problem that had already been solved once, because the *existing*
solution was unreachable from where the assistant was looking.

**Lesson:** when a memory or shared record says "still open" and the person says "no,
that's fixed" — don't quietly trust the record over the person, and don't quietly trust
the person over the record either. Ask which is stale, out loud, before spending real
effort. A five-second confirmation is cheaper than a full re-diagnosis, and the
direction of the mismatch matters: here the *person* was right and the *record* was
stale, but that's not knowable in advance.

## The actual recovery: checking one directory level higher

The fix wasn't lost. It existed in a *different* handoff artifact than the one the
assistant already knew about — a full mirror of the other machine's project folder,
plus a written summary document, sitting one directory level above the folder the
assistant had been specifically told to check in a much earlier session. That earlier
instruction had named a specific subfolder; the assistant kept checking that exact
subfolder, correctly, every time — without ever listing its parent directory to see if
anything else had shown up alongside it.

**Lesson:** a piece of prior guidance about *where to look* is itself just as capable of
going stale as a piece of guidance about *what's there*. Conventions drift — a
project's actual handoff mechanism had quietly evolved to something better than what a
past instruction described, and the fix was sitting in the new location the whole time.
When told to check a specific known place and it comes up empty or outdated, checking
one level up costs almost nothing and would have caught this immediately, instead of
concluding the fix was genuinely gone.

## What the recovered fix actually contained

Once found, the fix itself was substantial and worth its own note: the automation had
been using the wrong native API entirely for one specific case (merging a picked-up
item into an already-partially-filled inventory slot, as opposed to an empty one). The
API pair it was calling worked fine for empty slots but silently failed to fully commit
a merge — the item's count updated correctly, but the object representing it in the
game world never got cleaned up, leaving a "ghost" pickup behind. The real fix required
switching to a *different* pair of native calls specifically for the merge case, one of
which needed a freshly constructed, disposable copy of a data object rather than a
live reference — passing the live reference (an earlier attempt) caused the game to
treat it as scratch space and directly zero out real inventory data. This was found and
avoided through live testing, not documentation, since the corruption case was silent
until specifically checked for.

## A second, smaller bug found immediately after recovery

With the merge fix live, a related but previously undiscovered bug surfaced on the
very first fresh live test: with a completely full inventory, the automation would
silently evict whatever was in a specific fixed slot to make room for the new pickup,
instead of blocking the pickup or prompting the player — invisible data loss with no
error, no crash, nothing in the logs pointing at it directly.

The fix was a genuinely different native check — a method whose name directly asked
"is this slot actually available" — that existing code simply hadn't been checking.
Diagnostic logging added first (not a blind fix) confirmed the target slot really was
occupied at the exact moment the eviction happened; only then was the gate wired in to
abort automation and fall back to the game's own manual flow when the target slot
turns out not to be free.

That diagnostic logging itself had a bug worth naming on its own: the first version
used a common "condition and value or fallback" shorthand to build a log line, which
silently collapses to the fallback whenever the value being logged is itself `false` —
a language footgun that had already bitten this project once before in an unrelated
feature. The log said "unknown" on a call that had actually succeeded and returned a
perfectly good `false`. Caught by noticing the call reported success while the logged
value showed a placeholder, not by suspecting the language construct until the numbers
didn't add up.

**Lesson:** that shorthand (`condition and value or fallback`) is only safe when
`value` can never itself be a legitimate false-y result. The moment a boolean or a
number that can be zero is what's being conditionally returned or logged, use an
explicit if/else instead — the bug it produces is specifically the kind that looks like
correct code and passes a casual read.

## General lessons

- **A shared handoff mechanism is only as reliable as its most forgettable step.**
  "Export before ending the session" is a single point of failure if it's a manual
  habit rather than something the tooling enforces — a version-controlled repository
  with real commit history doesn't have this failure mode at all, since a forgotten
  step there is just an unpushed commit, not a vanished fix. Worth moving to that if
  the sync-folder convention keeps having this problem.
- **When a person's memory of "this was fixed" conflicts with a shared record saying
  otherwise, say so and ask, rather than picking a side silently and re-deriving
  everything from scratch** — even when the re-derivation produces real, useful
  findings along the way, it can still be solving an already-solved problem.
- **Instructions about *where to look* age exactly like instructions about *what's
  there*.** If a known location comes up empty or stale, check its parent directory
  before concluding the thing you're looking for doesn't exist anywhere.
- **`cond and a or b` silently breaks the instant `a` can be a real `false`.** Prefer
  an explicit `if/else` for anything logging or returning a value that could
  legitimately be false-y — this exact shape of bug has now hit the same project
  twice.
