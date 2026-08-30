# A mod manager that silently drops mods, and the cache file that explains why

Fluffy Mod Manager (RE Engine games). An add-on refused to appear in the mod list.
No error, no warning, nothing in the log — it simply was not there. Three fix attempts
in, the actual cause turned out to be something no amount of reading the packaging
conventions would have revealed.

Writing this down mostly as a **debugging-method** lesson: I guessed twice from
structure before going to look at the tool's own state, and both guesses were wrong.

## The symptom

A mod zip containing a parent mod and two add-ons (declared with `addonfor=<parent
name>` in `modinfo.ini`). The parent listed. One add-on listed. The other never did.

## Two wrong answers, and why they were seductive

**Guess 1: standalone add-on zips don't work.** I had shipped the add-ons as separate
zips. The original author shipped his as sibling top-level folders inside one archive
alongside the parent. Repacking to match his layout felt obviously right — it was
*his* proven structure — and it did fix nothing.

**Guess 2: malformed `modinfo.ini`.** Comparing bytes against the author's originals
turned up two genuine defects: mine used bare LF where every one of his used CRLF, and
my `name=` did not match the mod's folder name and contained a `/` (illegal in a
Windows path — the manager builds folders from the mod name). Both worth fixing. Still
did not fix the missing add-on.

Both guesses shared a flaw: they reasoned about what *should* matter from conventions
and file structure, instead of asking the tool what it had actually parsed.

## Where the answer was

Fluffy keeps per-game state next to the mods, and the interesting file is a binary
cache of parsed mod metadata:

```
<fluffy>/Games/<GAME>/ModinfoCache.bin      <- every mod it successfully parsed
<fluffy>/Games/<GAME>/installed.ini         <- [Section] per installed mod
<fluffy>/Games/<GAME>/ModPackagesCache.bin  <- per-archive file listings
<fluffy>/Data/Log.txt                       <- always empty, ignore it
```

`ModinfoCache.bin` is binary but the strings are plain ASCII, so a regex for printable
runs of 4+ characters dumps it readable. Entries appear in a fixed order:

```
display-name, name, screenshot, author, description, version, addonfor, source-zip, category
```

**If a mod is missing from that dump, the manager never accepted it** — which
immediately separates "not parsed" from "parsed but not displayed", and that is the
distinction the three guesses had all been blind to.

The dump showed the parent and one add-on from our archive, and no entry for the
other. It also showed why: an entry with the *identical* `name=` already existed,
parsed earlier from a different archive still sitting in the mods folder — the
original author's zip, which had not been removed.

## The actual rule

**Fluffy deduplicates mods by `name=`.** A mod whose name collides with one already
cached from another archive is silently skipped. No error surfaces anywhere.

Renaming the add-on to something unique fixed it instantly. It also explained the one
detail that had looked like noise: the *other* add-on worked only because guess 2 had
incidentally renamed it, giving it a unique name by accident.

## Rules worth carrying

For writing `modinfo.ini`:

- CRLF line endings.
- `name=` must exactly match the containing folder's name.
- Plain ASCII, and no `/ \ : * ? " < > |` — the name becomes a path.
- The name must be **unique across every archive in the mods folder**, including old
  versions and other people's mods the user still has installed.
- Add-ons (`addonfor=`) belong in the same archive as their parent, as sibling
  top-level folders, and the value must match the parent's `name=` byte-for-byte.

For debugging any tool that "just doesn't show" something:

Find where it caches what it parsed, and read that first. A tool's own state
distinguishes *never ingested* from *ingested and filtered*, and those have completely
different fixes. I spent two rounds proposing fixes for the second problem while
actually having the first. The generalisable move is: **stop reasoning about the input
format and go read the tool's output about the input.**
