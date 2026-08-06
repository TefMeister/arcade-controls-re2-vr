# Exploring a native game object model blind, through REFramework/Lua

Modding a closed-source game engine through
[REFramework](https://github.com/praydog/REFramework)'s Lua bindings
means there's no header file, no autocomplete, and no official API
reference for any given game's own classes (`app.ropeway.*`,
`app.CollisionManager.*`, whatever the target game's namespace is). The
engine (`via.*`) is documented by the community to a degree; the game's
own code is not. Most of the actual work is reflection: asking a live
object what it has on it, rather than reading a spec.

This is general enough to apply to any REFramework-based VR/gameplay mod,
not just one specific bug.

## The three shapes a "where does X live" question takes

Given some visible effect (a beam, a pose, a sound) and no idea what
native object produces it, there are three structurally different places
to look, and they require different reflection calls:

1. **A named joint on a skeleton.**
   ```lua
   local joints = some_transform:call("get_Joints"):get_elements()
   for _, joint in ipairs(joints) do
       log.info(joint:call("get_Name"))
   end
   ```
   Skeletal joints are welded to a specific mesh's rig. A weapon prop's
   own attachment points (muzzle flash sockets, etc.) show up here. A
   character's bones show up here. This does **not** show separately
   parented GameObjects or components — it's specifically the animation
   skeleton.

2. **A child GameObject in the Transform hierarchy.**
   ```lua
   local count = some_transform:call("get_ChildCount")
   for i = 0, count - 1 do
       local child_transform = some_transform:call("get_Child", i)
       local child_go = child_transform:call("get_GameObject")
       log.info(child_go:call("get_Name"))
   end
   ```
   Useful for VFX props that are spawned as their own object and parented
   under something. Worth knowing going in: not every attachment in this
   engine works this way — plenty of native systems attach visual props
   via joint-based or manager-based parenting that never shows up as a
   Transform child at all. A clean "zero children" result doesn't prove
   nothing is attached; it only proves nothing is attached *this way*.

3. **A component attached directly to a GameObject** (not a child, not
   a joint — a behavior/class instance living on the object itself).
   ```lua
   local components = some_gameobject:call("get_Components"):get_elements()
   for i, component in ipairs(components) do
       local td = component:get_type_definition()
       log.info(td:get_full_name())
   end
   ```
   This is the one it's easiest to forget to check, because it's neither
   "in the skeleton" nor "in the scene tree" — it's metadata on an object
   you may have already been holding a reference to the whole time.
   Component lists on gameplay objects (a weapon, a player character) are
   often long — expect 20-100 entries, mixing rendering, physics, audio
   middleware, and gameplay logic components together. Skim for class
   names that plausibly relate to the effect, but don't assume the
   obviously-named one is the only relevant one; the real driver is
   sometimes a generically-named class (an "effect manager" or "IK
   controller") rather than anything with the effect's name in it.

## Drilling into an object's own fields

Once you've got *a* native object instance, its non-static fields are
enumerable without knowing the class ahead of time:

```lua
local td = obj:get_type_definition()
for _, field in ipairs(td:get_fields()) do
    if not field:is_static() then
        log.info(field:get_name() .. "  (" .. field:get_type():get_full_name() .. ")")
    end
end
```

Two traps here, both encountered in practice:

- **A field's listed type matters before you act on it.** A UI that
  offers "force this field to identity" for every field it finds, without
  filtering by type, will silently no-op on anything that isn't actually
  a quaternion/rotation type — wrapped in a `pcall` (as it should be, so
  one bad field doesn't crash the whole probe), a type-mismatched write
  just fails quietly. A batch of "no effect" results from a test like
  this needs a second look at which fields were even the right type to
  begin with, or you'll wrongly rule out the one field that mattered.
- **A field can be legitimately `nil` under some game states and
  populated under others.** A per-frame correction/IK-arm-target field
  might only exist while the character is actually in a specific pose
  context (e.g. arm colliding with geometry). Getting `nil` when you
  dump it doesn't mean the field doesn't matter — it might mean you
  tested it in the wrong game state. Worth re-testing under the specific
  condition (weapon drawn, aiming, moving, etc.) the effect actually
  requires, not just "player exists."

## Hook timing: "did I apply the fix" vs. "did I apply it before the
## thing that reads this value"

Overwriting a value once per frame (a bone rotation, a field) is only
half the fix if something else reads that same value later in the same
frame to compute something downstream (an IK solve, a derived aim
direction). Two different callback points that both fire "before
rendering" can still fire in the wrong order relative to each other.

Concretely useful when debugging this: sample the same value at two
different hook points in the same frame and directly compare them.

```lua
-- early hook
re.on_pre_application_entry("SomeNativeMethod", function()
    early_value = read_the_thing()
end)

-- late hook, same frame
re.on_application_entry("SomeLaterNativeMethod", function()
    local late_value = read_the_thing()
    -- compare early_value vs late_value directly
end)
```

If the two disagree, something between those two points changed the
value — that's your ordering bug, and now it's measured, not guessed at.
If they agree and a downstream effect is still wrong, the bug isn't a
same-frame ordering issue on *this* value — stop looking at timing and
go back to "is this even the right value" instead. (Don't skip straight
to reordering hooks on a hunch; measure first, since a wrong theory
confirmed by a "fix" that happens not to make things visibly worse is
easy to mistake for a real fix.)

## Logging conventions worth keeping from the start

- Every diagnostic script logs under one consistent bracketed tag
  (`[my_script_name]`), so a log file with tens of thousands of lines
  from every loaded script can still be grepped down to just the
  relevant ones.
- Wrap reflection calls in `pcall`. Native calls into an engine that
  wasn't designed for this kind of introspection fail in ways that
  aren't always predictable (wrong argument count, wrong overload,
  object doesn't support the method) — better a caught, logged failure
  than a script that dies silently on line one with the only symptom
  being "the expected log line is missing."
- If a script exposes a live status readout in its UI, remember that
  readout only reflects the *last* thing that ran — if a panel has
  several buttons and several status lines, a report of "it says X" is
  ambiguous about which status line is even being read. When a live
  UI-based test comes back confusing over text description, a
  screenshot resolves it faster than another round of description.
