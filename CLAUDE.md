# Project Guide

## Overview
Single-file macOS terminal utility (Swift / AppKit, no Xcode project). Multi-monitor
focus tool that simulates powering monitors off to cut distraction and eye strain: run it
in a terminal, press a digit for how many displays stay on; the rest are covered with an
opaque, click-blocking black window (visually "off") AND their windows are minimized away.
Pressing keys acts instantly (terminal in raw mode); the tool loops until you quit.

Key map: the number = how many monitors stay on, expanding center-out (priority
middle → right → left). For 3 displays: `1` = middle only, `2` = middle + right, `3` = all
on, `0` = all on, `q`/`Esc` = restore + quit.

## Key files
- `DisplayBlackout.swift` — entire app: terminal raw-mode setup, `WindowHerder`
  (Accessibility-based minimize/move of other apps' windows), `BlackoutController`
  (overlay windows + active-display set + enforcement timer), `AppController` (stdin read
  loop + screen-change handling + Accessibility prompt).
- `build.sh` — `swiftc DisplayBlackout.swift -o display-blackout`, strips xattrs, ad-hoc
  codesigns. No `.app` bundle, no Info.plist — this tool needs no TCC entitlements.

## Build & run
- `./build.sh` produces `./display-blackout` in the repo root.
- Run with `./display-blackout`. Stop with `q`, `Esc`, or Ctrl-C.

## Design notes / gotchas
- **No backlight API.** macOS has no public way to power off a specific display. The
  effect is an opaque black `NSWindow` per darkened screen at `.screenSaver` level (above
  menu bar + Dock). `ignoresMouseEvents = false` is deliberate — it makes the darkened
  screens block clicks. Shown with `orderFrontRegardless()` so the accessory app never
  steals key focus. **Overlays are purely cosmetic** — they do NOT move windows or fence
  the cursor; that's what the Accessibility layer below is for.
- **Active set, not single display.** `BlackoutController.activeDisplayIDs` is a `Set`.
  Pressing N keeps the N highest-priority displays on via `displayPriorityOrder()` (middle
  first, then outward preferring right before left). Overlays cover every display NOT in
  the set; `0`/N≥count/quit → all on.
- **Window herding needs Accessibility.** `WindowHerder` uses the AX API
  (`AXUIElementCreateApplication` per regular running app → `kAXWindows` → position/size/
  minimized). Requires the user to grant Accessibility (prompted at launch via
  `AXIsProcessTrustedWithOptions`). Without it, overlays still work but no window moves.
  Because the binary is ad-hoc signed, rebuilds can reset the TCC grant.
- **Coordinate space.** All AX/herder geometry is CoreGraphics global (top-left origin) —
  the space `kAXPosition` and `CGDisplayBounds` share. Do NOT mix in `NSScreen.frame`
  (bottom-left origin) here; window→display lookup uses `CGDisplayBounds(id).contains(center)`.
  Overlays are the exception — they use `NSScreen.frame` because they're AppKit windows.
- **Enforcement + tiling on keypress.** `setActiveCount` runs (in order): `restoreWindows`,
  then if any display stays dark → `minimizeWindowsOffActive` + `tileActiveDisplays` +
  `startEnforcement`. `minimizeWindowsOffActive` minimizes windows on off displays;
  `tileActiveDisplays` arranges the windows on each on-display into master + stack (largest
  window fills left ~60%, rest stack right), reading `NSScreen.visibleFrame` flipped to CG
  coords via `visibleAreaCG`. Tiling runs ONLY while a blackout is engaged, so a full restore
  gives back the original layout rather than a tiled one. While blacked out, a 0.5 s `Timer`
  calls `pullStraysBack`, moving any un-minimized window that lands on an off display back to
  the primary active display; it bails while `NSEvent.pressedMouseButtons != 0` so it never
  fights an active drag.
- **Restore = remembered original frames.** `WindowRecord {element, homeFrame}` snapshots each
  window's frame the FIRST time we touch it (minimize / stray-move / tile), matched by
  `CFEqual` (linear scan; do NOT rely on AXUIElement CFHash). `restoreWindows(finalRestore:)`:
  when everything comes back on (`0`/`3`/`q`/Esc) it un-minimizes + `setFrame`s every record
  back to its original and clears the list; on a partial transition (some displays still dark)
  it only un-minimizes records whose home just turned on, so tiling can re-place them while
  keeping the snapshot for the eventual full undo. **Caveat:** Ctrl-C (SIGINT/SIGTERM) only
  restores the terminal — the signal handler can't run AX restore, so windows stay as-is. A
  1→2→1 re-blackout dance can drift a window's "original" to its tiled position; a clean
  1→quit preserves true originals.
- **Terminal must be restored.** `terminalRawMode()` clears only `ICANON` + `ECHO`
  (leaves `OPOST` so the banner still prints cleanly). It is restored via `q`/`Esc`,
  `atexit`, and `SIGINT`/`SIGTERM` handlers — otherwise Ctrl-C leaves the shell with no
  echo. The signal handlers are no-capture C function pointers touching only globals.
- **Track active display by ID, not NSScreen.** `didChangeScreenParametersNotification`
  hands back fresh `NSScreen` objects, so the active display is stored as a
  `CGDirectDisplayID` and overlays are rebuilt against the current screen set. If the
  active display is unplugged, it falls back to all-on instead of blacking everything.
- **Count-based mapping.** Screens are sorted by `frame.origin.x`. The pressed number is a
  *count* of displays to keep on, taken from `displayPriorityOrder()` (middle → right →
  left). For 3 displays: `1` = {middle}, `2` = {middle, right}, `3` = all. Designed for 3
  displays; still runs at other counts (keeps N, center-out).
- **AppKit on main only.** The stdin read loop runs on a background `Thread`; every
  overlay mutation is dispatched to the main queue.

## Lineage
Structurally modeled on the sibling `url-launcher` app (NSApplication accessory +
per-screen borderless windows + `didChangeScreenParameters` rebuild), but driven by raw
terminal stdin instead of a Carbon global hotkey, and with no Apple Events / signing
requirements.
