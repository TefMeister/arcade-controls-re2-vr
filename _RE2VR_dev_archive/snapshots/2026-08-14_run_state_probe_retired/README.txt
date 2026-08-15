re2_vr_run_state_probe.lua -- RETIRED 2026-08-14, removed from live autorun

Context: game crashed (access violation, c0000005) during a live testing
session. The crash's own call stack pointed at igWindowRectRelToAbs
(Dear ImGui window-rect code, via DINPUT8.dll) -- NOT at any Lua script
logic, and NOT at re2_vr_inventory_auto_complete.lua (the script being
actively tested that session). This file does not fix or explain that
crash and should not be assumed to.

Reason for retirement: right up until the crash, the framework log showed
this script logging "NATIVE CALL set_JogMode(...)" at roughly 120+ calls/
second, continuously, for a sustained period. The script's own hooks are
strictly observe-only (sdk.PreHookResult.CALL_ORIGINAL, post-hook returns
retval unchanged) -- it never blocks or alters the native call, so it is
not a plausible direct cause of a game-state corruption. But the run-toggle
investigation this probe was built for was already resolved and confirmed
working (see re2_vr_run_toggle_status memory) long before this session --
it had no remaining diagnostic purpose, and logging at that frequency for
an extended period is pure unnecessary overhead. Retired on that basis,
independent of the crash investigation.

If the crash recurs after this removal, this file is conclusively not the
cause and the investigation should look elsewhere (ImGui/REFramework
internals, or the sheer number of other simultaneously-active autorun
scripts/UI panels this session accumulated).
