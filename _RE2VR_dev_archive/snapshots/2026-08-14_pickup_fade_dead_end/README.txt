Pickup black-screen fade-in/out idea -- DEAD END, 2026-08-14

Idea: instead of fixing what's black or removing the item-pickup pause,
fade smoothly in/out of it. Lead: BlackFade/WhiteFade GUI elements were
seen active during the pickup sequence by two earlier probes from the
original black-screen investigation.

Round 1 (re2_vr_pickup_fade_investigation_probe.lua): dumped BlackFade's
and WhiteFade's full type hierarchy. Both are via.gui.GUI components with
ZERO raw fields exposed -- no plain Alpha/Opacity field exists anywhere on
the GameObject or Element chain. Only methods: get/set_Segment,
get/set_PlaySpeed, get/set_Asset, plus a named-parameter system
(findParameterVariable / getParameterListCount).

Round 2 (re2_vr_pickup_fade_investigation_probe2.lua): getParameterListCount
returned 0 for both -- the parameter system is unused here. AssetPath for
both is the generic "systems/gui/ImagePlane_1920x1080". Unfiltered Segment
logging showed both objects "first sighted" ~30ms after script load (before
any player action was possible) and Segment cycling through a small set of
values {10,13,14,40,53,55} many times WITHIN single ~16ms frames --
conclusive that these are persistent, frequently-reused GUI nodes, not a
pickup-exclusive fade animation, and that raw Segment-change logging is
pure noise.

Round 3 (re2_vr_pickup_fade_investigation_probe3.lua): gated snapshots at
real transition points (GUIMaster context change NONE/ITEM_BOX/
PICKUP_OR_INVENTORY, plus a hook on NewInventoryDetailBehavior.open) using
a control (item box open/close, no black screen) vs test (regular pickup
open/close, has the black screen) comparison. Result: Segment values from
the SAME small set {13,14,53,55} appeared in BOTH the control and the test,
with no consistent split. Enabled=true and PlaySpeed=1.0 never changed in
either case. No correlation at all between these fields and whether the
black screen was actually showing.

Cross-check: the pre-existing re2_vr_pickup_bg_investigation_probe.lua (from
the ORIGINAL black-screen investigation, not part of this session's new
work, left live in autorun/) independently diffed every named GUI element's
first-sighting by context. Every element unique to PICKUP_OR_INVENTORY
(GuiCaption, GuiBack, GuiSlot, GuiSearch) also appeared in ITEM_BOX (which
has no black screen) -- no pickup-exclusive named element exists.
BlackFade/WhiteFade never toggled around either context change.

Conclusion: two independent techniques (fade-field probing and full
GUI-element diffing) agree -- there is no Lua-reachable, named lever
driving the pickup black screen. This reinforces (does not contradict) the
original 6-round black-screen investigation's parked conclusion
(re2_vr_pickup_reuse_itembox_camera_idea memory) that it's shader/
native-render-level, out of Lua's reach. Idea parked.
