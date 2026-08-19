# 2026-08-19: inventory/pickup black-void ROOT CAUSE found + bypass built (UNTESTED)

Root cause of the VR inventory/pickup "black void" background, found by reading
REFramework's own source (src/mods/VR.cpp, on_pre_gui_draw_element):

    // the weird buggy overlay in the inventory
    case "GuiBack"_fnv:
        if (gi.is_re2() || gi.is_re3()) {
            return false;   // draw cancelled entirely

REFramework's VR mod deliberately culls the whole GuiBack GameObject (the
NewInventoryBackBehavior backdrop: BgPanel/CapturePanel/BgBlur) BY NAME HASH
whenever the VR runtime is active. This retroactively explains every dead end in
the two prior investigations (re2_vr_inventory_bg_tint_status,
re2_vr_pickup_reuse_itembox_camera_idea): all those field writes landed
correctly on an element that was never drawn at all.

Hook-order facts (verified in source): Mods.cpp registers VR before
ScriptRunner, and Hooks.cpp skips the draw if ANY mod returns false -> Lua
cannot out-vote the suppression; per-draw rename sandwich impossible. But VR
re-reads the name fresh every draw call -> persistent rename while the screen
is open bypasses the filter and routes GuiBack through the generic
screen->worldspace GUI path (World + Overlay + Detonemap).

New script: re2_vr_inventory_bg_unhide.lua -- renames GuiBack -> "GuiBackU" on
first sighting (own pre-gui-draw hook fires even for suppressed elements),
auto-restores 1s after last sighting / on disable / on HMD off / on script
reset. Runtime-verifies via.GameObject.set_Name exists in TDB before use.

Expected first result: praydog's "weird buggy overlay", not a clean backdrop.
Anything visible beats the void; once drawn, the previously-inert blur/tint
fields become real tuning levers.

UNTESTED -- syntax-checked only (luac -p clean).
