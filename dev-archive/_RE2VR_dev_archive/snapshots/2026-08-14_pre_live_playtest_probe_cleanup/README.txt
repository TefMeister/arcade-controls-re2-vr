Pre-live-playtest probe cleanup -- 2026-08-14

Player's request: about to play a real, non-dev-testing VR session tonight
and wanted the mod's live autorun/ folder cleared of all investigation
"construction leftovers" first, plus a cleaner REFramework UI (each
script's panel behind its own collapsible tree_node).

All 10 files below were confirmed, one by one, to be read-only or
already-superseded diagnostic probes with no remaining ongoing purpose --
each already fully documented in this project's memory system as
PARKED/dead-ended/superseded investigations. Copied here verbatim, then
removed from live reframework\autorun\.

- re2_vr_firstpersonmod_probe.lua -- one-shot dump of the firstpersonmod
  plugin's API, findings already absorbed into shipped features.
- re2_vr_run_precede_bits_probe.lua -- one-shot diagnostic for the run-
  toggle fix, findings already absorbed into re2_vr_run_toggle_fix.lua
  (shipped, confirmed working).
- re2_vr_pickup_bg_investigation_probe.lua -- round 1 of the pickup black-
  screen investigation, PARKED (see re2_vr_pickup_reuse_itembox_camera_idea
  memory -- likely shader/native-render-level, out of Lua's reach).
- re2_vr_pickup_camera_investigation_probe.lua / probe2 / probe3 -- later
  rounds of the same black-screen investigation, same PARKED status.
- re2_vr_pickup_capture_investigation_probe6.lua -- round 6, same
  investigation, same PARKED status (this was the final round before the
  idea was parked).
- re2_vr_inventory_pause_investigation_probe.lua -- from the "remove the
  pickup pause" idea, PARKED (see re2_vr_inventory_no_pause_idea memory --
  pause confirmed decentralized, no single lever, would be a real
  gameplay-difficulty change).
- re2_vr_inventory_updatebehavior_investigation_probe.lua -- same
  investigation as above, same PARKED status.
- re2_vr_weapon_aim_probe.lua -- built same night to chase why firearms
  auto-granted via APU's bypass-all-items toggle equip but can't aim. Root
  cause never fully confirmed; instead the practical fix shipped was
  FORCE_MANUAL_WEAPON_IDS in re2_vr_inventory_auto_complete.lua, forcing
  every known firearm to stay manual outright regardless of the mechanism.
  If the underlying "why" is ever worth chasing again, this probe (RG
  rising-edge IsHold tracking + live EquipWeapon component field dump) is
  the starting point -- not deleted, just no longer needed for tonight's
  goal of a clean live-play session.

NOT touched by this cleanup, on purpose:
- re2_vr_aim_alignment_probe.lua -- explicit standing instruction from an
  earlier session ("disable and collapse, don't delete") -- still relevant
  to the unresolved spine/aim-alignment drift issue. Left in live autorun\,
  UI collapsed behind its own tree_node.
- VRLight.lua -- separate third-party mod, not this project's own file.
- re2_sharpness_removal.lua -- unexplained but already-inert file, left
  alone per the player's own explicit choice in an earlier audit.
- re4_vr_crosshair.lua / re8_vr.lua / re2_vr_crosshair.lua (re3 branch) --
  cross-game reference material, self-guarded on game name (no-op in RE2),
  deliberately kept for the planned future RE3 port.
- utility/RE4.lua, RE7.lua, RE8.lua, Statics.lua, GameObject.lua,
  ManagedObjectDict.lua -- library plumbing required by the above, not
  probes.
