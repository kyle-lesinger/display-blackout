# display-blackout

A tiny macOS terminal tool for multi-monitor focus. Run it, then press a number to keep
some of your displays on and make the rest go **solid black — like they're turned off**.
Windows on the "off" displays are **minimized out of the way**, and while a blackout is
active anything you drag onto an off display gets **pulled back**. Single-file
Swift/AppKit, no Xcode.

## Keys

The number is **how many monitors stay on**, expanding out from the center
(priority order: middle → right → left).

| Key | Monitors on | Blacked out |
| --- | ----------- | ----------- |
| `1` | middle only | left + right |
| `2` | middle + right | left |
| `3` | all three | none |
| `0` | all three (same as `3`) | none |
| `q` / `Esc` | restore everything and quit | — |

Keypresses act instantly — no Enter needed. The tool stays open in a loop so you can keep
pressing keys. The darkened screens are a solid, **click-blocking** wall, so nothing on
the "off" monitors can grab your attention.

## What "off" means here

When you turn some displays off:

1. **They go black.** An opaque black window at screen-saver level (above the menu bar and
   Dock) covers each — visually indistinguishable from a powered-off screen, and instantly
   reversible.
2. **Their windows leave.** Every window whose center sits on an off display is **minimized**.
   While the blackout is active, a guard ticks a couple of times a second and pulls any
   window that drifts onto an off display back to the primary (center) active screen. The
   guard pauses while your mouse button is down, so it never fights an in-progress drag.
3. **The active screen auto-tiles.** The windows left on each on-screen display are arranged
   into a **master + stack** layout — your largest window fills the left ~60%, the rest stack
   in a column on the right — so everything fits together instead of overlapping. Press the
   same number again to re-tile after you've opened or moved things.

### Putting it all back

Every window's original position is remembered the first time it's touched. When a monitor
comes back on it hands its windows back, and pressing `0`/`3` or quitting with **`q`/`Esc`**
restores **every** window to exactly where it started. (Note: a hard **Ctrl-C** can only
reset the terminal, not un-minimize windows — use `q`/`Esc` for a clean restore.)

## Requirements: Accessibility permission

Minimizing and moving *other apps'* windows is only possible through the macOS
**Accessibility API**, which is permission-gated. On first launch macOS prompts you; if you
defer it, the black overlays still work but **windows won't be minimized or confined** until
you grant it:

> System Settings → Privacy & Security → **Accessibility** → enable this tool
> (or your terminal app), then re-run.

Note: because the binary is ad-hoc signed, **rebuilding it can reset the grant** — if window
herding stops working after a rebuild, re-enable it in that same Accessibility list.

## How it works (and one honest limitation)

macOS has **no public API to power off a specific display's backlight**, and **no native
way to fence a window or the cursor to one display**. So "off" is an opaque overlay, and
"nothing can leave" is enforced by a polling loop that minimizes/snaps windows back — not a
hard hardware wall. In practice it behaves like the monitors are off, but it's cooperative
enforcement, not a lock. The cursor itself is left free to roam.

Displays are ordered left-to-right by position. Designed for a 3-monitor setup; it still
runs with other counts (the number always keeps that many, center-out).

## Build

```sh
./build.sh          # swiftc → ./display-blackout, then ad-hoc codesign
```

Requires the Swift toolchain (`swiftc`, bundled with the Xcode Command Line Tools).

## Run

```sh
./display-blackout
```

Suggested shell alias (add to `~/.zshrc`):

```sh
alias focus="/Users/<you>/github/kyle/display-blackout/display-blackout"
```

Then just type `focus` in any terminal, press `1`/`2`/`3` to choose how many monitors stay
on, and `q` when you're done.
