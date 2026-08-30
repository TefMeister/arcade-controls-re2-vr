# Laser/red-dot sight beam drifting off aim, in VR only

**Status:** FIXED, confirmed live in VR ("the dot is exactly where it has
to be"). The root cause turned out to be a native method firing six times
per frame while a related fix elsewhere in the project only wrote its
correction once — see "Round ten" for the actual mechanism and how it was
found. Sections through "Round seven" and "Where it actually landed" below
are the original three-session investigation, left as written since the
conclusions there still hold on their own terms — the dead ends really
were dead ends. "Round eight" and "Round nine" found real new structure on
an object that turned out not to be the cause, also left as written for
the same reason. Documented in full because the reasoning behind a dead
end — or, this time, a fix that took ten rounds and two case studies to
find — is the actual value here.

## The symptom

With the torso-twist fix (see the companion case study) applied and
confirmed working — weapon model, arms, and bullet trajectory all
visually correct — a weapon-upgrade attachment (a red dot sight, on a
revolver) still projects its dot well off from where the gun is actually
aimed: eyeballed at roughly 30-50° off, landing on a wall to one side.
No visible beam line, just the dot itself in the wrong place. Everything
*else* about the pose — mesh, arms, actual bullet impact — was already
independently confirmed correct.

## Establishing the shape of the bug before guessing mechanisms

Two cheap live tests before writing any probing code:

1. **Does it track the torso fix at all?** Toggling the fix's correction
   strength from 0 to 1 and watching the dot: it moved. Ruled out
   "completely unrelated," confirmed it's coupled to whatever the fix
   changes, just not correctly.
2. **How big is the error, precisely?** Not "off" — specifically
   30-50°, comparable in size to the *original* twist bug (25-55°). That
   pushed the working theory toward "reading something still
   substantially uncorrected," not a fine residual gap.

## Round one: exhausting the 3D-object theories

Six distinct, falsifiable theories, each tested and eliminated using the
game's own reflection API (see the companion technique note) rather than
guessing from documentation that doesn't exist for this engine:

- **A dedicated joint on the weapon mesh.** Dumped every joint name on
  the weapon's skeleton (12 joints, both with the sight active and not)
  — none named anything like "laser"/"sight"/"dot".
- **A separate child GameObject.** Walked the actual Transform child
  tree of both the weapon and the player GameObjects. Zero children on
  both — a useful data point on its own: this engine's attachment props
  generally aren't simple Transform children of what they're visually
  attached to.
- **A same-frame IK timing gap.** The working theory from the original
  twist fix was "one system reads a value before another finishes
  correcting it." Directly measured: sampled the muzzle joint's world-
  forward vector at two points in the same frame (early, at the fix's
  own hook; late, at the same point the bullet-trajectory code reads
  it). Result: 0.00° — the muzzle joint is fully stable within the
  frame, so this specific mechanism, plausible as it was, doesn't apply
  here.
- **A named component directly on the weapon/player GameObject.**
  Dumped every component class on both (~90 on the player alone) —
  nothing with "laser"/"sight" in the name.
- **The arm-corrector component from the original twist investigation.**
  A plausible-but-ruled-out suspect for the *original* bug, worth a
  fresh test against *this* different symptom. Only one of its several
  fields turned out to even be the right data type to test meaningfully
  (a UI mistake caught by checking field types before trusting a "no
  effect" result) — that field came back null during normal aiming,
  consistent with the component being for wall-clipping prevention, not
  general aim-pose correction.
- **A 2D/UI element, not a 3D object.** The game's VR aim-reticle fix
  already repositions one specific UI element (`GUI_Reticle`) every
  frame via a draw-element hook. Registered an independent listener on
  the same hook and logged every distinct element name seen with the
  dot active — only `GUI_Reticle` and ammo-count UI showed up, no
  separate laser element. Since `GUI_Reticle` is already correctly
  positioned by existing code, this ruled out "it's an unhandled UI
  element" too.

## Round two: the VFX system, and a red herring

A component called `ObjectEffectManager` (present on both the weapon
and player) is this engine's native visual-effects manager — exactly
the kind of system that would play a sight's dot effect, and untested so
far. Drilling into it:

- Its live "currently active effects" list and a "range-tracked effects"
  dictionary (a better semantic fit for a continuously-updating effect)
  both came back **empty**, even with the dot visibly on screen.
- A live comparison across *every* joint on the weapon mesh against the
  known-correct muzzle joint turned up one real outlier: an unlabeled
  numbered joint sitting ~60° off from muzzle (everything else sat at a
  near-zero or a rock-steady ~90°, the latter reading as an axis-
  convention artifact rather than a real error). That 60° figure was
  close enough to the eyeballed 30-50° that it looked like a strong
  candidate.
- It wasn't. The joint's offset changed when the aim-down-sights input
  was pressed (activating the sight) but **did not change** with the
  torso-fix slider — and the real dot demonstrably does move with that
  slider (confirmed by watching the dot alone, isolated from the
  visibly-moving body, to rule out an optical illusion). A joint that
  reacts to *pose state* but not to the *specific correction* known to
  move the real bug isn't the source; it's a coincidentally-similar
  number. Two other joints on the character's own arm skeleton
  (dedicated weapon-attachment sockets, found by dumping the full 190-
  joint player skeleton) showed the same "reacts to pose, not to the
  fix" pattern and were ruled out the same way.

**Lesson inside this round:** an angle landing "close enough" to the
target magnitude is not confirmation. The slider-coupling test is the
one that actually discriminates real candidates from coincidences, and
it's worth re-running on *every* new candidate rather than trusting a
plausible-looking number once.

## Round three: found the field, couldn't act on it

A component's *full* field list had never actually been dumped — only
two specific fields had been accessed by name, early in the
investigation, for an unrelated purpose. Dumping every field on it
turned up `LaserSightTipPosition`: a small-magnitude 3D vector, named
unambiguously, that updates continuously and — confirmed directly —
**moves when the torso-fix slider changes**, matching the real dot's
behavior exactly. First real correlation found all night.

Then the letdown: writing to it did nothing.

- Wrote directly to the field: no visible effect on the dot.
- Suspected the write was being skipped by whatever renders the beam
  because a raw field write bypasses a C# property's *setter method* if
  one exists (a real, general reflection gotcha — the getter/setter
  pair can do more than just store a value). Called the actual setter
  method instead of poking the field: still no visible effect.

Conclusion: this field is very likely a **downstream readout**, not the
authoritative value the renderer consumes — probably computed for
separate gameplay logic (a sibling field literally named
`IsSightToEnemy` suggests target-detection use) from the same broken
upstream data, rather than being upstream of the visual itself. It
tracks the bug perfectly without being a lever we can pull.

## A costly aside: don't force a field tied to real game state

One more theory: force the "which parts are equipped" flag to zero,
hoping the dot's spawn logic gates on it. Applied every frame, this
caused the game to visibly, rapidly re-trigger a real equip/unequip
cycle — the field is wired to an actual state-change event, and native
logic kept resetting it, fighting the override every frame. No crash,
but a real, live disruption caused by a diagnostic script, not a
hypothetical risk.

**Lesson:** before force-writing a field every frame, check whether it
looks like a passive value or a state-change trigger (an adjacent
`OnChange*` event field, in this case, was the tell, visible in the
same field dump — worth reading names in the dump for exactly this
signal before wiring up a per-frame override, not just for what to
target).

## Round four: the "suppress it instead" plan, and why it didn't ship

With the direct calculation unreachable, the next plan was pragmatic:
stop trying to fix the broken beam and instead hide it, substituting a
different system in the same codebase that already computes a correct VR
aim reference for an unrelated reason (a raycast-based reticle, built for
general aiming feedback, always active and already proven correct).

The obvious lever — the same "which parts are equipped" flag that had
already caused a live disruption once (see the costly aside above) — has
a *safer* sibling: a dedicated override channel elsewhere in this same
codebase, already proven safe under continuous per-frame forcing for an
unrelated feature (suppressing a different in-hand item under a specific
grip combination). Using that channel instead of the raw live-state
field, masking out just the sight's bit: **it worked.** Both the beam and
the attachment's visible housing model disappeared.

It also broke something else. The weapon's aiming quietly lost a real
gameplay behavior the sight is supposed to grant — a faster reticle
lock-on — not just its visuals. The override flag doesn't gate "is the
dot rendered," it gates "is this attachment considered equipped at all,"
and multiple systems read that same signal for multiple different
purposes. Hiding a visual bug by making the game briefly forget you have
the attachment on is not a fix; it's swapping a cosmetic bug for a
mechanical one, and the mechanical one is worse.

**Lesson:** a flag that controls visibility often isn't visibility-only.
Before shipping a suppression workaround built on an equip/attachment
flag, explicitly go looking for anything *else* that flag might gate —
don't assume "the model disappeared" means "nothing else changed."

## Round five: exhausting the VFX system properly, not just poking at it

The native effects-manager component had already had two of its fields
checked and come back empty (see round two). This round went back and
checked *everything else on it*, methodically, one field at a time:

- A list of "expert" per-attachment effect providers — actually
  enumerated by runtime type this time, not just checked for a plausible
  name. Every single entry, on both the weapon and the player, matched
  an already-known, already-identified non-laser effect (muzzle flash,
  impact effects, damage/blood effects, water splashes, footstep dust).
  No hidden entry.
- Several object-reference fields meant to point at whatever a visual
  effect is currently "following" — all either empty, or resolving right
  back to the weapon or player object itself, never to some separate prop
  nobody had found yet.
- The actual data-driven configuration behind the whole effect system —
  and this one had something the others didn't: the original developers
  had labeled every single entry with a plain-language comment. A
  complete, human-labeled inventory of every visual effect this weapon
  and this character are configured to produce. None of them were the
  sight.

That last one is worth dwelling on, because it's a different *kind* of
negative result than most of the ones before it. "The list was empty"
always leaves a sliver of doubt — maybe it's just not active right now.
"Here is the complete, developer-labeled list of everything that *can*
happen, and the thing you're looking for isn't on it" doesn't have that
gap. This is as close to a definitive negative as reflection against a
compiled binary gets.

**Lesson:** when a system has multiple related fields and only a couple
have ever been checked, go back and check the rest before moving to a
different theory entirely — a system can be 90% eliminated and still
be hiding the answer in the one untouched field. And a config-driven
system's *data*, once found, is often more conclusive than the *code*
around it, especially if someone left the data labeled.

## Round six: it's on the mesh — just not the part you'd think

With the whole effects system exhausted, the next theory came from a
fact established all the way back in round one: this attachment has no
separate object of its own at all — zero children, on either the weapon
or the player. If it's not a spawned effect and it's not a separate
object, the remaining possibility is that it's baked directly into the
weapon's own 3D model.

The weapon's mesh component turned out to expose a real, working API for
enabling and disabling individual materials by index — confirmed via
reflection on the actual method signature rather than guessed. Listing
the material names directly hit paydirt: three of the weapon's six
materials were explicitly, unambiguously named for the sight attachment.

Toggling each one individually, live, produced a clean and complete
picture — but not the one hoped for. One material was the sight's solid
housing body. Another was its lens glass. A third was a tinted material
only visible from inside the housing looking out. All three, individually
confirmed, controlled real and distinct parts of the attachment's
appearance. **None of them were the dot.** It stayed lit, stayed
misaimed, through every combination.

**Lesson:** a hypothesis can be *right about the mechanism* (this really
is baked into the mesh, not spawned) while being *wrong about the
specific target* (the housing and glass are mesh materials; the glowing
dot itself apparently is not, or isn't only that). Getting a strong hit
on part of a theory is not the same as confirming the whole theory —
worth being precise about exactly what got confirmed versus what's still
assumed.

## Round seven: asking the whole game, not just the one object

Every theory up to this point shared a structural assumption: search
*outward* from a known object (the weapon, the player) through whatever
is attached to or reachable from it. That approach cannot find something
that was never attached to either of those two objects in the first
place — a separate, independent system that happens to read the weapon's
data without being part of its object graph.

The tool used for every previous check doesn't only support "show me
what's on this object" — it also supports a plain name search across the
game's entire loaded type database, independent of any object instance.
Searching directly for the obvious candidate words came back empty
across the board, with one accidental, unrelated hit and a couple of
generic engine types nothing to do with weapons.

This is a different, and in some ways more final, kind of negative
result than any of the object-graph searches before it: it doesn't just
rule out one theory, it rules out an entire *category* of theory — "a
dedicated class for this exists somewhere and we just haven't found the
right object to look on." No such class exists under any name a
developer would plausibly have given it.

**Lesson:** when every negative result has come from the same *kind* of
search (here: walking outward from a known object), it's worth explicitly
trying a structurally different search axis — a name-based, object-
independent search, if the tooling supports one — before concluding a
whole category of explanation is exhausted. A dozen failed object-graph
searches don't rule out something that was never reachable from an
object graph to begin with; only a genuinely different search method
does that.

## Where it actually landed

Seventeen mechanisms in, every static/passive angle this tooling
supports — reading fields, enumerating lists, resolving references,
searching type names — has been tried and has come back negative, several
of them conclusively rather than ambiguously. What's left isn't another
field to check; it's a different *technique* entirely: hooking the
native code live and watching what it actually does at the exact moment
the effect appears, rather than inspecting whatever state is sitting
there afterward. That technique has precedent for working on a
differently-shaped problem in this same project (see the companion case
study on shell-ejection timing), but it's a materially bigger investment
than anything here — hooking before knowing what to hook, and tracing
live rather than reading a single snapshot.

Given how much ground was already covered with solid, verifiable
evidence at every step, the call was made to stop here rather than open
that much larger investment unprompted. This is written up as a closed
dead end, not a paused one — but a well-documented dead end is exactly
the kind of thing that should save the next person (or the next AI) from
re-walking the same seventeen steps if they ever pick this back up.

## Round eight: a wrong assumption hiding inside a "confirmed" reframe

A later session picked this back up after an unrelated fix (a torso/spine
straightening feature, elsewhere in the same mod) started visibly pointing
the weapon mesh the wrong way on a flat screen. Reasonable-looking
reasoning at the time: since the weapon mesh itself was now provably wrong
on flat-screen, maybe the *original* dot-drift bug from this case study was
never a laser-specific bug at all — maybe it was always this same mesh-pose
problem, just misdiagnosed back in round one through seven.

A full session was spent building this out: multi-stage same-frame capture
of the muzzle joint's own forward direction, comparing it against camera
direction across dozens of live tests, eventually finding a real, solid,
quantified result — the weapon mesh's own orientation swings roughly 2x
wider than the camera's own head-turn range specifically when the
spine-straightening fix is active. Genuinely useful data. Wrong target.

**The player corrected it with one sentence:** in VR, the weapon mesh
*never visibly moves at all* — it stays rock-solid. Only the dot moves.
The mesh-pointing-left symptom was a flat-screen-only thing, a *different*
bug living in a different part of the same mod, and every measurement that
session had been (validly) characterizing that other bug, not this one.

**Lesson:** a reframe that "explains everything so far" and produces real,
reproducible numbers is not the same as a *correct* reframe. The tell in
hindsight was that nobody had gone back to first principles and re-asked
"what does the player actually see, on the actual platform they use" before
building an entire measurement apparatus on the assumption. A whole
session's worth of clean data was real and worth keeping (it fully
resolved *that* other bug), but it took a plain factual correction from the
person actually wearing the headset to notice the two symptoms had been
silently merged into one investigation.

## Round nine: two new leads, four new dead ends, and a genuinely new object

With VR/flat-screen properly separated again, the session picked the
original technique back up: live method hooking, the thing round seven's
closing note called the one remaining serious avenue. Two useful
discoveries, quickly:

- The multi-stage capture technique from round eight (sampling a value at
  five points across the same frame) was reused here, applied to the
  original suspect field from round three (`LaserSightTipPosition`). A
  clean, dramatic, *reproducible* result: with the spine-straightening fix
  **off**, that field's own direction barely moves at all when the player
  turns their head — roughly 3-4% of the head's own range. With the fix
  **on**, it swings roughly ten times more. A real, large, specifically-
  triggered effect, isolated cleanly for the first time.
- Then the player checked it by eye, and the dot still visibly drifted
  under every hook-timing configuration tested — including ones where the
  measured field's coupling had numerically dropped back to the "off"
  baseline. **The field everybody had been trusting as a stand-in for "the
  dot's real position" was never that.** It's a real, live, measurable
  value that correlates with the bug, exactly as round three concluded
  back at the start of this whole investigation — a downstream readout,
  not the thing the renderer actually consumes. Nine months (in
  investigation-time) of trusting a correlated variable as if it were the
  actual mechanism, confirmed wrong the same way round three first
  suspected it, just with much better instrumentation this time.

**Lesson:** a value correlating strongly and reproducibly with a bug is
still not the same as being *caused by* the same thing the bug is caused
by. The only real test is the one nobody can automate: does the thing you
can actually see change. Build the instrumentation, trust the player's
eyes over the instrumentation's numbers when they disagree.

With that settled, the session went back to a structural gap from round
one: the original child-GameObject check only ever looked *one level deep*
at the weapon and player. A full recursive walk of the *entire* transform
tree — not filtered by name, not stopped at the first level — found real
structure round one's shallower check had missed entirely: a `LaserSight`
child object, itself holding a `Light` child (with its own further child,
an actual particle-effect object) and a separate `Line` child. The `Line`
object's own component was a plain mesh — consistent with it being the
beam, which has always tracked correctly. The particle-effect object under
`Light` was a real VFX player component — a much more plausible dot
candidate than anything found in the first three sessions.

Better still: the `LaserSight` object itself carried a dedicated,
purpose-built native class — a controller class that had never once shown
up in round seven's whole-game name search, despite that search
specifically trying the obvious words. (Worth noting for anyone repeating
a name-search technique: it isn't exhaustive against every possible naming
convention a developer might have used, only the ones a human tester
thought to try.)

That controller class turned out to hold real, promising-looking members —
an explicit "set position" method, a field plausibly named for the pointer/
dot itself, and (as a bonus, unrelated to the main thread) the sight's true
emission joint name, which turned out to be a *different* joint than the
one every earlier round's muzzle-direction measurements had been reading.
Four follow-up hooks and reads, in order:

1. Hooked the controller's "set position" method. Never fired once, across
   a real, confirmed-active ~36-second capture window. Third confirmed-dead
   write-hook in this investigation's history (after the original field
   setter in round three, and an engine-level decal-color hook tried in an
   earlier live-hooking pass not detailed here).
2. Read the sight's own true emission joint directly (rather than the
   joint every earlier round had been assuming was equivalent) and ran the
   same on/off amplitude comparison that worked so well in round eight.
   Flat, uncoupled, nearly identical between the fix on and off — ruling
   out "the dot just passively follows this joint" as the mechanism,
   since if it did, it should show the same coupling the visible dot does.
3. Walked the actual parent chain of the two ordinary child objects
   (`Light`/`Line`) — confirmed completely ordinary, static, weapon-
   skeleton parenting, nothing unusual. Consistent with those staying
   visually stable. But the pointer/dot field turned out **not** to be a
   GameObject at all — it returned a wrapper for a *dynamically-created*
   visual effect instance, a structurally different kind of object than
   the two static ones sitting right next to it in the same hierarchy.
4. That dynamic-effect wrapper exposed what looked like the perfect
   accessor — a method returning the effect's own live position data.
   Polling it every frame, live, across a full on/off capture: empty,
   every single sample, both conditions. Investigating *why* it was empty
   turned up a real, generalizable reflection gotcha: the method's return
   type's name matched the exact pattern a compiler generates for an
   iterator method (a `yield`-based method in C#) — not a list, not an
   array, a lazily-evaluated sequence object that has to be pulled from
   with the two-step "advance, then read" pattern real language iterators
   use, not indexed or measured for a count. Fixed the extraction to use
   that pattern correctly — and the sequence was still empty, every frame,
   confirmed genuinely (not a leftover shape-guessing bug this time).

Four real leads, four real dead ends, on an object that had never been
found before this session. Paused here, one field on the same class still
unchecked, at the player's choice to pick it back up later rather than
push through fatigue.

## A late clue that may reframe the whole investigation again

Right at the pause point, the player described something that hadn't come
up in any of the visual bug reports so far: the sense of being "in" the
VR space itself feels different specifically when aiming with the
spine-straightening fix active — described as feeling almost like
room-scale positional movement is coupling to head rotation, present only
while the aim trigger is actively held *and* the fix is on, gone the
instant either condition drops. Not "a UI element is in the wrong place" —
a description of altered presence/embodiment.

This hasn't been investigated yet, and it might be describing the exact
same underlying bug this whole case study has been chasing, just noticed
from a different angle (a rendering artifact can absolutely also read as
"something about how my view feels wrong" if it's subtle enough not to
consciously register as "that one dot is misplaced"). Or it might be a
second, separate symptom of the same root mechanical cause — one process
change (forcibly overwriting one bone's rotation every frame, elsewhere in
the same mod) rippling into more than one visible effect. Left here
un-investigated deliberately, because it's exactly the kind of clue that's
easy to lose between sessions if it isn't written down verbatim.

**Lesson:** a qualitative, first-person description from the person
actually in the headset can carry information no field dump can — "it
feels different" is real data, even before it's been turned into a
hypothesis. Write it down precisely, in the reporter's own words, before
trying to translate it into a technical theory; the translation can happen
later, but the original phrasing is easy to lose and often contains detail
("only when both conditions are true together," here) that a paraphrase
would flatten.

## Process lessons, independent of the eventual answer

- **Get a magnitude before guessing a mechanism.** A vague "it's wrong"
  supports dozens of theories; a concrete number close to a previously-
  understood bug's magnitude narrows the search immediately.
- **A "close enough" number is not confirmation.** Re-run the
  discriminating test (here: does it move with the specific fix, not
  just with pose/aim in general) on every new candidate, even a
  promising-looking one, before treating a match as real.
- **A component ruled out for one symptom isn't ruled out for a
  different symptom**, especially investigated before the second bug was
  even known to exist — retest specifically.
- **Check that a "no effect" test was actually valid.** A checkbox that
  silently no-ops on a type mismatch reports "no effect" indistinguishably
  from a genuine negative result.
- **A raw field write and a property's setter method are not the same
  operation.** If forcing a field does nothing, try the actual setter
  before concluding the field is inert — the getter/setter pair can carry
  logic a direct field write skips entirely.
- **Read field *names* in a dump for risk signals, not just for what to
  target.** An adjacent `OnChange*`/event-shaped field name is a hint
  that a field is a state-change trigger, not a passive value — worth
  noticing before wiring up a per-frame override, which cost a real (if
  minor) live disruption this session.
- **When a live UI-based test comes back ambiguous, ask for a screenshot
  rather than a transcription.** A status panel with several similarly-
  worded lines is easy to misdescribe; a screenshot removes an entire
  class of back-and-forth.
- **A workaround that "works" by hiding something can still be the wrong
  answer.** If the lever you found gates more than the one symptom you're
  chasing, confirm nothing else depends on it before calling it a fix —
  a visual bug traded for a gameplay regression is not progress.
- **A system being 90% checked is not the same as 100% checked.** Go
  back and finish checking every field on a component you've already
  partially explored before moving to an unrelated theory — the answer
  can be sitting in the one field nobody got around to.
- **Data left labeled by the original developers, once you find it, can
  be more conclusive than any amount of code-reading.** A complete,
  human-labeled inventory closes a question a merely-empty list can't.
- **A confirmed mechanism can still target the wrong specific thing.**
  Getting a strong, real hit on part of a hypothesis (materials that
  really were sight-related) doesn't confirm the whole hypothesis (that
  those materials control the dot specifically) — check the actual
  target, not just the category.
- **When every failed search shares the same structural assumption**
  (here: walking outward from a known object), try a genuinely different
  search axis — like a name search across the whole type database —
  before concluding a category of explanation is exhausted, not just one
  member of it.
- **A well-documented dead end is a legitimate deliverable**, not a
  failure to write up. Seventeen eliminated mechanisms with real evidence
  is worth more to the next investigator than a vague "we tried some
  stuff and gave up."
- **A reframe that "explains everything so far" still needs a sanity check
  against first-hand observation before you build a session's worth of
  tooling on top of it.** Clean, reproducible numbers are not the same as
  numbers measuring the right thing — the fastest sanity check is asking
  "what does the person actually using this actually see," not just
  whether the new theory is internally consistent with prior results.
- **A value correlating with a bug is not the same as being the bug's
  cause**, even when the correlation is clean, large, and reproducible
  across a real controlled test. The only test that actually discriminates
  is whether the *visible* symptom changes — trust that over an
  instrument's numbers when the two disagree.
- **A C# method whose return type name matches the compiler's iterator
  pattern (something like `<MethodName>d__N`) is a lazy sequence, not a
  list or array** — it won't respond to "get elements"/"get length"/"get
  count" style calls, because none of those apply to it. It has to be
  pulled from with the "advance, then read current" pattern real
  enumerators use. Worth checking a return type's actual name before
  assuming it's a collection just because the method name is plural.
- **A structural check that only looks one level deep isn't the same
  check as looking at the whole tree.** A "zero children" result from
  years earlier turned out to mean "zero *direct* children" — real
  structure was sitting two and three levels further down, on an object
  a shallower check was never going to see.
- **A qualitative, first-person description ("it feels different") is
  real data, not a vague complaint to be translated away immediately.**
  Write down the reporter's exact words, including the precise conditions
  they describe ("only when both X and Y are true"), before turning it
  into a technical hypothesis — the exact phrasing often carries detail a
  paraphrase would lose.

## Round ten: the fix was in a different investigation's untested tool

The breakthrough, when it came, didn't come from continuing round nine's
thread (`LaserSightController`, `CreatedEffectContainer`, the dynamic VFX
wrapper). It came from a completely separate case study — the companion
torso-twist investigation — and specifically from a diagnostic tool built
there weeks earlier that had never actually produced real data.

That tool hooked a native arm-IK method to watch what spine value it
solved against. It had been sitting there, "confirmed installed," logging
nothing, for a full prior session. The assumption at the time was that the
hook simply never fired for some structural reason worth investigating
later. The real cause was much smaller and much easier to miss: the
install code only called the single-overload lookup function
(`get_method(name)`), which silently resolves to just *one* of the
method's overloads. This exact class had at least two. Two other scripts
elsewhere in the same project successfully hooked the same method by
iterating *every* method matching that name (`get_methods()`, then
checking each one's name) — a pattern that had already been proven
correct in this codebase, just never applied here. One-line-shaped fix,
in the sense that it was small; finding it required specifically
distrusting "the hook is installed, therefore the target genuinely never
gets called" as a conclusion.

The first real capture with the hook actually working delivered the
answer immediately: the native method that solves arm/weapon pose fires
**six times in a single frame**, not once. The fix elsewhere in this same
project that corrects a twisted spine bone only ever wrote its correction
**once per frame**, at the top of it. Within one frame, the first two of
those six calls saw the corrected value; the remaining four saw the raw,
still-animating original. Positions derived from those two groups
differed by roughly half a unit — easily enough to explain a dot landing
30-50° off target, and enough to explain the parallel case study's own
"gun points left" symptom, since both were reading the same inconsistent
mid-frame state.

The actual fix: stop relying on a single per-frame write entirely. Hook
the same native method the diagnostic was watching, and re-apply the
correction immediately before *every* call, not just once at the top of
the frame. Confirmed live, by the person actually in the headset: the dot
sits exactly where it should.

Two things worth naming separately about why this took as long as it did:

1. **A hook that logs nothing can mean two very different things**: "this
   code path genuinely never runs" or "my hook installation silently
   failed to attach to the code path that runs." Only one of those is
   informative about the game; the other is informative about the hook
   code. Before trusting a zero-calls result as a real negative, confirm
   the hook count matches what a *working* hook on the same method
   elsewhere in the same codebase reports (here, "(2)" — the tell was
   sitting in plain sight in two other files the whole time).
2. **The right diagnostic can already exist in a sibling investigation.**
   This project treats every bug as its own thread with its own tooling,
   which is usually right — but the actual mechanism here (native
   multi-call-per-frame IK solving) was a property of a *shared* system
   two different visible symptoms both depended on. When two investigations
   keep circling the same suspect system (here: arm-IK reading a
   spine-correction script's output) without either fully explaining the
   other's symptom, it's worth checking whether an *existing, unfinished*
   diagnostic in the other thread — even one already written off as a dead
   end — was actually just broken in a small, fixable way.

## What this means for the rest of this case study

Round nine's `LaserSightController`/`CreatedEffectContainer` exploration
wasn't wrong to try — that object genuinely exists and genuinely renders
something — but it turned out not to be where the bug lived. The dot was
never miscalculating its own position relative to the gun; the *gun's own
in-hand pose* was being solved against a stale, uncorrected value for most
of a frame's IK work, and the dot (like everything else attached to the
weapon) just faithfully followed wherever that already-wrong pose put it.
All four dead ends on that object stand as correctly-executed, genuinely
uninformative tests of a real system that simply wasn't the cause —
exactly the kind of result worth keeping on record rather than erasing,
per the lesson list above.

**Status, finally: FIXED**, confirmed by direct observation in a real VR
session, not just by an instrument agreeing with itself. The late,
qualitative "room-scale presence" clue from round nine's pause point
turned out to describe a real but *separate*, smaller residual issue
(a subtle body sway, still being chased) — worth remembering that
resolving the headline symptom doesn't automatically mean every
qualitative report about the same feature was describing the same root
cause.
