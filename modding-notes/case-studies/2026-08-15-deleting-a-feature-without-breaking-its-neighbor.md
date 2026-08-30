# Deleting a feature without breaking the unrelated one hiding in the same hook

**Status:** RESOLVED — a short one, but a real trap worth naming on its own.

## The setup

A toggle that forced a UI screen into a specific display mode was confirmed
game-breaking weeks earlier (froze the game on a specific case) and shipped off
by default ever since, with the underlying bug it was meant to work around fixed
by other means in the meantime. With the toggle no longer serving any purpose,
the instruction was simple: remove it completely, not just leave it off.

## The trap

The toggle's logic lived inside a hook on a native UI method — a single
pre-hook function, installed once, that ran on every relevant screen-open event.
Deleting the *feature* looked, at first glance, like it should mean deleting
that hook entirely: it existed to implement this one toggle, so removing the
toggle should mean removing the hook too.

It didn't. The same hook had picked up a second, completely unrelated job days
later, in a separate piece of work: it was also the one reliable place in the
codebase that fires unconditionally on every relevant screen-open, which made it
the natural trigger point for a *different* experimental feature (a background
blur suppression toggle) that had nothing to do with the first one. That second
feature's own code comment said as much directly — it had been deliberately
moved to piggyback on this exact hook specifically because the hook already
fired at the right moment for free.

Deleting the whole hook to remove the first feature would have silently broken
the second one, with no error, no crash — the second feature would have simply
stopped triggering, the same "quiet regression with no signal" shape as several
other bugs already logged in this project.

## The fix

Read the hook's body fully before deleting anything, not just the part
implementing the feature being removed. Found the second, unrelated job in the
same function, cut only the lines belonging to the feature actually being
retired, and left the rest — including the guard state field and the function
itself — untouched.

**Lesson:** when a piece of shared infrastructure (a hook, a listener, a
"runs on every X" callback) was installed for reason A, check whether anything
*else* in the codebase later started depending on it for reason B before
deleting it wholesale just because reason A is gone. The safest signal that this
has happened is a comment near the shared infrastructure explicitly describing
why it was chosen — that's usually there specifically because someone already
had to justify piggybacking on existing infrastructure instead of building
something new, and it's exactly the note that gets missed by anyone scanning
only for the code being removed.
