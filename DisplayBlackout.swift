import Cocoa
import Darwin

// MARK: - Terminal raw mode
//
// We put the terminal into a lightweight "raw-ish" mode: ICANON and ECHO off so a
// single digit press acts instantly (no Enter, no echoed character). OPOST and the
// rest are left intact so our own printed banner still formats normally. The original
// settings are always restored — via `q`/Esc, atexit, and SIGINT/SIGTERM — so Ctrl-C
// can never leave the shell in a broken state.

var originalTermios = termios()
var rawModeEnabled = false

func terminalRawMode() {
    let fd = FileHandle.standardInput.fileDescriptor
    guard isatty(fd) != 0 else { return }
    tcgetattr(fd, &originalTermios)
    var raw = originalTermios
    raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON))
    tcsetattr(fd, TCSANOW, &raw)
    rawModeEnabled = true
}

func terminalRestore() {
    guard rawModeEnabled else { return }
    tcsetattr(FileHandle.standardInput.fileDescriptor, TCSANOW, &originalTermios)
    rawModeEnabled = false
}

func installSignalHandlers() {
    // No-capture C function pointers; they touch only globals.
    signal(SIGINT)  { _ in terminalRestore(); _exit(0) }
    signal(SIGTERM) { _ in terminalRestore(); _exit(0) }
}

// MARK: - Blackout controller
//
// Keeps one display normal and covers every other display with an opaque black window
// at screen-saver level (above the menu bar and Dock). There is no public API to power
// off a specific display's backlight; an opaque black overlay is the visual equivalent.

final class BlackoutController {
    private var overlays: [NSWindow] = []
    // The physical display kept "on". Stored by display ID (not NSScreen reference) so it
    // survives screen-parameter changes, which hand back fresh NSScreen objects.
    private var activeDisplayID: CGDirectDisplayID?

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func sortedScreens() -> [NSScreen] {
        NSScreen.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
    }

    /// 1 = middle, 2 = left, 3 = right. Positional, computed against the current layout.
    private func targetScreen(forKey key: Character) -> NSScreen? {
        let screens = sortedScreens()
        guard !screens.isEmpty else { return nil }
        switch key {
        case "1": return screens[screens.count / 2] // middle
        case "2": return screens.first              // left
        case "3": return screens.last               // right
        default:  return nil
        }
    }

    /// Handle a digit key on the main thread.
    func handleKey(_ key: Character) {
        switch key {
        case "1", "2", "3":
            guard let target = targetScreen(forKey: key) else { return }
            activeDisplayID = displayID(of: target)
            rebuild()
        case "0":
            restoreAll()
        default:
            break
        }
    }

    func restoreAll() {
        activeDisplayID = nil
        clearOverlays()
    }

    private func clearOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }

    /// Recompute overlays for the current screen set. Safe to call on screen changes.
    func rebuild() {
        clearOverlays()
        guard let activeID = activeDisplayID else { return }
        // If the active display was unplugged, fall back to all-on rather than blacking
        // out every remaining screen.
        guard NSScreen.screens.contains(where: { displayID(of: $0) == activeID }) else {
            activeDisplayID = nil
            return
        }
        for screen in NSScreen.screens where displayID(of: screen) != activeID {
            overlays.append(makeOverlay(for: screen))
        }
    }

    private func makeOverlay(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrame(screen.frame, display: true)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = .screenSaver                 // above menu bar + Dock
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = false           // block clicks: the wall is solid
        window.orderFrontRegardless()               // show without stealing key focus
        return window
    }
}

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate {
    let blackout = BlackoutController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        printBanner()
        startInputThread()
    }

    @objc func screensChanged() {
        blackout.rebuild()
    }

    private func printBanner() {
        let banner = """
        display-blackout — keep one screen, black out the rest.
          1 = middle    2 = left    3 = right
          0 = all displays back on    q / Esc = quit
        """
        FileHandle.standardError.write(Data((banner + "\n").utf8))
    }

    private func startInputThread() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func readLoop() {
        let fd = FileHandle.standardInput.fileDescriptor
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            switch byte {
            case UInt8(ascii: "q"), 27: // q or Esc
                DispatchQueue.main.async {
                    self.blackout.restoreAll()
                    terminalRestore()
                    NSApp.terminate(nil)
                }
                return
            case UInt8(ascii: "0"), UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "3"):
                let key = Character(UnicodeScalar(byte))
                DispatchQueue.main.async { self.blackout.handleKey(key) }
            default:
                break
            }
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar of its own
installSignalHandlers()
atexit { terminalRestore() }
terminalRawMode()

let controller = AppController()
app.delegate = controller
app.run()
