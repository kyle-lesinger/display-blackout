# display-blackout

A tiny macOS terminal tool for multi-monitor focus. Run it, then press a number to
keep **one** display normal and make every other display go **solid black — like it's
turned off**. Press a key to bring them all back. Single-file Swift/AppKit, no Xcode.

## Keys

| Key | Action |
| --- | ------ |
| `1` | Keep the **middle** display, black out the rest |
| `2` | Keep the **left** display, black out the rest |
| `3` | Keep the **right** display, black out the rest |
| `0` | All displays back on |
| `q` / `Esc` | Restore everything and quit |

Keypresses act instantly — no Enter needed. The tool stays open in a loop so you can
keep pressing keys. The darkened screens are a solid, **click-blocking** wall (clicks
land on the black overlay, not on the apps underneath), so nothing on the side monitors
can grab your attention or your cursor.

## How it works (and one honest limitation)

macOS has **no public API to power off a specific display's backlight.** Instead this
covers each non-active display with an opaque black window at screen-saver window level
(above the menu bar and the Dock). It's visually indistinguishable from a screen that's
off, and it's instant and fully reversible — the windows underneath are never touched.

Displays are ordered left-to-right by position, so `left / middle / right` map to your
physical monitors. Designed for a 3-monitor setup; it still runs with other counts, but
the left/middle/right labels are most meaningful at 3.

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

Then just type `focus` in any terminal, press `1`/`2`/`3` to collapse to one screen,
and `q` when you're done.
