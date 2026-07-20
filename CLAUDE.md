# Project Guide

## Overview
Single-file macOS terminal utility (Swift / AppKit, no Xcode project). Multi-monitor
focus tool: run it in a terminal, press a digit to keep one display normal and cover
every other display with an opaque, click-blocking black window (visually "off").
Pressing keys acts instantly (terminal in raw mode); the tool loops until you quit.

Key map: `1` = middle display, `2` = left, `3` = right, `0` = all on, `q`/`Esc` = quit.

## Key files
- `DisplayBlackout.swift` — entire app: terminal raw-mode setup, `BlackoutController`
  (overlay windows), `AppController` (stdin read loop + screen-change handling).
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
  steals key focus.
- **Terminal must be restored.** `terminalRawMode()` clears only `ICANON` + `ECHO`
  (leaves `OPOST` so the banner still prints cleanly). It is restored via `q`/`Esc`,
  `atexit`, and `SIGINT`/`SIGTERM` handlers — otherwise Ctrl-C leaves the shell with no
  echo. The signal handlers are no-capture C function pointers touching only globals.
- **Track active display by ID, not NSScreen.** `didChangeScreenParametersNotification`
  hands back fresh `NSScreen` objects, so the active display is stored as a
  `CGDirectDisplayID` and overlays are rebuilt against the current screen set. If the
  active display is unplugged, it falls back to all-on instead of blacking everything.
- **Positional mapping.** Screens are sorted by `frame.origin.x`; `1` → `sorted[count/2]`
  (middle), `2` → first (left), `3` → last (right). Designed for 3 displays.
- **AppKit on main only.** The stdin read loop runs on a background `Thread`; every
  overlay mutation is dispatched to the main queue.

## Lineage
Structurally modeled on the sibling `url-launcher` app (NSApplication accessory +
per-screen borderless windows + `didChangeScreenParameters` rebuild), but driven by raw
terminal stdin instead of a Carbon global hotkey, and with no Apple Events / signing
requirements.
