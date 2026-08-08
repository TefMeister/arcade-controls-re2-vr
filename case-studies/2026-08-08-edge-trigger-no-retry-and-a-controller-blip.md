# A gesture that only ever got one chance to start, plus a residual jank that turned out to be the controller, not the code

**Status:** Main bug fixed and shipped, confirmed working. A milder residual
case was investigated two rounds deeper with live log data, traced to a
plausible hardware-level cause, and deliberately left alone once the player
called it acceptable jank — a legitimate stopping point, not an abandoned
investigation.

## The symptom

Grabbing a weapon's slide (grip button, proximity-gated) to rack it would
sometimes get the hand stuck replaying its "reaching toward the slide"
animation in a loop, never actually completing the grab. Player-reported
reproduction: pressing grip *before* their tracked hand had physically
arrived at the grab zone.

## Root cause #1, found by reading the code, not logging

The function that starts this gesture checked two things at once: the grip
button's *rising edge* (this frame pressed, last frame not) AND whether the
tracked hand was currently within range — both required in the exact same
frame. If the player squeezed grip a moment before their hand arrived, that
single check failed, and the gesture had no way to reconsider: the next
frame, grip was still held, so there was no new rising edge to re-trigger
the check, no matter how close the hand got afterward.

**How this was confirmed, not just theorized:** the codebase had a state
field (call it `armed`) that looked exactly like it should gate a retry —
set `true`/`false` in ten different places throughout the gesture's
lifecycle. Grepping for it turned up all ten *writes* and zero *reads*
anywhere else in the codebase. A field that's write-only, with no consumer,
is dead — and its deadness here was the proof that no retry path had ever
actually existed, despite the code's own shape suggesting one should.
Worth remembering as a technique on its own: when a bug's shape suggests
"there should be a retry/gate here," grep the suspected flag for read
sites, not just its existence. A flag that's only ever assigned is
decoration, not logic.

**Fix:** change the check from edge-triggered ("only the exact frame grip
went from up to down") to level-triggered while the gesture hasn't started
yet ("every frame grip is held and the gesture isn't already active"). The
function itself was already idempotent once active, so this was a safe,
minimal change — retry cheaply until the hand catches up, instead of a
single now-or-never check.

## A false negative that wasn't a code problem

The first live retest looked like the bug was still present. It wasn't —
the player had skipped the "Reset Scripts" step in the mod framework's
overlay, so the retest ran against the *old* pre-fix code without either of
us realizing it until a second, proper retest (after the reload) confirmed
the fix actually worked. Worth flagging in any live-testing workflow: a
"the fix didn't work" report is sometimes a stale-build report in disguise,
and it's worth checking the obvious reload step before re-opening the
investigation.

## The residual case: two more hypotheses, both killed by data

After the main fix landed, the player found a milder version of the same
visual "loop" right at the edge of the grab zone — reproducible, but only
with deliberate effort to find the exact spot. Two theories were tried, in
order, each one plausible enough to implement before being disproven by
live debug logging rather than by further code reading:

**Theory A — distance-threshold flicker.** The obvious guess: the hand
hovering right at the boundary of the "in range" distance check, flipping
true/false frame to frame, restarting the gesture repeatedly. Added
throttled per-frame logging of the distance value, the "in range" boolean,
and the gesture's active state. The log disproved it directly — for most
of the test window a completely unrelated precondition (no reload pending)
was false, meaning the whole gesture subsystem was inert; the "loop" the
player was describing wasn't coming from this code path at all in that
run.

**Theory B — grip loosening at full arm extension.** A second, more
targeted log was added at the exact site of a *different* function's own
grip-release check (a sibling system driving the actual pull motion, which
checks grip every frame independent of distance). The hypothesis: reaching
to full arm extension naturally loosens an analog grip's squeeze pressure,
occasionally dropping a real, physical hold below the controller's digital
press threshold for a frame. This one looked confirmed at first — the
targeted log fired exactly when the visual loop happened. Added a 50ms
debounce: don't treat a false grip read as a real release until it's stayed
false continuously for that long, on the theory it was absorbing a
single-frame blip.

**The debounce didn't fully fix it, and the log said why.** A retest — this
time with the player deliberately squeezing hard to rule out an accidental
loose grip — still produced abort events, and the logged distance value at
the moment of each abort was effectively zero: the hand was sitting right
*on* the grab point, not out at extended reach. That directly falsified
theory B's "loosens at full extension" mechanism. Worse for the debounce
specifically: the aborts kept firing past the 50ms grace window, meaning
the false grip read wasn't a single-frame blip at all — it was a
*sustained* false read, specifically tied to that exact hand/wrist pose,
not to reach distance or grip pressure in any simple sense.

## Where it actually bottomed out

Tracing the grip-read function down another layer showed it terminates in
the VR framework's own action-system call — a pre-digitized true/false
already resolved by the OpenXR runtime, not a raw analog value the mod has
access to. There's no hysteresis to add on top of a boolean that's already
lost the underlying signal. The most defensible remaining explanation:
something about that specific wrist angle (needed to get the hand
precisely onto the dock point) causes the player's actual controller
hardware to misreport the grip button for a sustained stretch — a
real-world ergonomics/sensor quirk at one exact pose, not a logic error in
the gesture state machine.

The player's own framing mattered here: normal gameplay never lands in
that exact spot without deliberately hunting for it, and the behavior in
regular play was called acceptable jank. That's a legitimate place to stop
— the fix that mattered (the edge-trigger/no-retry bug) was real, confirmed,
and shipped; the debounce is a genuine, verified hardening that still
absorbs shorter blips even though it didn't eliminate this specific
sustained-pose case. Chasing a single-pose hardware-reporting quirk further
would have meant guessing at controller firmware behavior with no way to
verify a fix — a different category of problem than the state-machine bug
this investigation started with.

## The pattern worth keeping

Three rounds, three different tools:
1. **Code reading + a dead-field grep** found and fixed the real, reported
   bug.
2. **Debug logging disproved two plausible-sounding hypotheses in a row**
   for the residual case — both looked reasonable enough to implement
   before being tested, and both were wrong in ways that would have been
   hard to rule out by reasoning alone (the first because the actual
   precondition was a different, unrelated system; the second because
   "abort happens near the boundary" turned out to correlate with hand
   *pose*, not hand *distance*, once the numbers were actually read).
3. **Tracing the call stack to its actual floor** turned "we can't get this
   input to behave" into a confirmed statement about *why* it can't be
   fixed from this layer, instead of leaving it as an open bug to keep
   revisiting.

None of these three would have been reached by skipping straight to "let's
just add a bigger debounce and hope" — each step used the previous one's
result (a proven-dead flag, a disproven distance theory, a disproven
pressure theory) to make the next guess sharper instead of wider.
