import Cocoa
import Darwin
import ApplicationServices

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

// MARK: - Window herder (Accessibility)
//
// Uses the Accessibility API to keep real windows off the "powered-off" displays. When a
// display is blacked out, every window whose center sits on a darkened screen is minimized;
// while a blackout is active an enforcement tick pulls any window that later drifts onto a
// darkened screen back onto the primary active screen. Requires Accessibility permission
// (System Settings → Privacy & Security → Accessibility). All geometry here is CoreGraphics
// global (top-left origin) — the space AX positions and CGDisplayBounds share, so there is
// no NSScreen Y-flip to reconcile.

final class WindowHerder {
    private let ownPID = getpid()

    /// Original frame of each window we've displaced (minimized, moved, or tiled), captured
    /// the FIRST time we touch it, so we can put it back on full restore. Matched with CFEqual
    /// — the list is small (tens of windows), so a linear scan is fine and avoids relying on
    /// AXUIElement's CFHash being identity-stable.
    private struct WindowRecord {
        let element: AXUIElement
        let homeFrame: CGRect
    }
    private var records: [WindowRecord] = []

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompt once at startup. Returns the current trust state. The key is the documented
    /// value of kAXTrustedCheckOptionPrompt, spelled out to dodge SDK CFString bridging churn.
    @discardableResult
    func requestPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: display geometry (CG global, top-left origin)

    private func activeDisplayList() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids
    }

    private func displayContaining(_ p: CGPoint) -> CGDirectDisplayID? {
        activeDisplayList().first { CGDisplayBounds($0).contains(p) }
    }

    private func center(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    private func screenID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Height of the display anchored at the AppKit global origin — the pivot for flipping
    /// AppKit (bottom-left) rects into the CoreGraphics (top-left) space AX uses.
    private func primaryHeight() -> CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height)
            ?? NSScreen.main?.frame.height ?? 0
    }

    /// A display's usable area (menu bar and Dock excluded) in CG top-left coordinates, taken
    /// from NSScreen.visibleFrame and Y-flipped. This is the one spot AppKit geometry enters.
    private func visibleAreaCG(of displayID: CGDirectDisplayID) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { screenID($0) == displayID }) else { return nil }
        let v = screen.visibleFrame
        return CGRect(x: v.origin.x, y: primaryHeight() - v.origin.y - v.height, width: v.width, height: v.height)
    }

    // MARK: AX helpers

    private func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
        return (value as? Bool) ?? false
    }

    private func setMinimized(_ window: AXUIElement, _ minimized: Bool) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                     minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private func recordIfNeeded(_ element: AXUIElement, homeFrame: CGRect) {
        guard !records.contains(where: { CFEqual($0.element, element) }) else { return }
        records.append(WindowRecord(element: element, homeFrame: homeFrame))
    }

    private func move(_ window: AXUIElement, to origin: CGPoint) {
        var o = origin
        guard let axValue = AXValueCreate(.cgPoint, &o) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axValue)
    }

    private func setSize(_ window: AXUIElement, _ size: CGSize) {
        var s = size
        guard let axValue = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue)
    }

    /// Position, then size, then position again: some apps clamp size, which can shove the
    /// origin; re-setting the origin re-anchors the top-left after any clamp.
    private func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        move(window, to: rect.origin)
        setSize(window, rect.size)
        move(window, to: rect.origin)
    }

    private func forEachManagedWindow(_ body: (AXUIElement, CGRect) -> Void) {
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            for window in windows(of: app.processIdentifier) {
                if let f = frame(of: window) { body(window, f) }
            }
        }
    }

    // MARK: operations

    /// Minimize every window whose center sits on a display that is NOT in the active set.
    /// Snapshots each window's original spot before minimizing so it can be restored later.
    func minimizeWindowsOffActive(_ activeIDs: Set<CGDirectDisplayID>) {
        guard isTrusted else { return }
        forEachManagedWindow { window, frame in
            guard let id = displayContaining(center(of: frame)), !activeIDs.contains(id) else { return }
            if !isMinimized(window) {
                recordIfNeeded(window, homeFrame: frame)
                setMinimized(window, true)
            }
        }
    }

    /// Auto-size the windows on each active display into a master + stack layout: the largest
    /// window fills the left ~60%, the rest stack in a column on the right. Runs only while a
    /// blackout is engaged (there is a darkened display), so exiting fully restores originals
    /// instead. Each window's pre-tile frame is snapshotted so full restore can undo it.
    func tileActiveDisplays(_ activeIDs: Set<CGDirectDisplayID>) {
        guard isTrusted else { return }
        var byDisplay: [CGDirectDisplayID: [(AXUIElement, CGRect)]] = [:]
        forEachManagedWindow { window, frame in
            guard !isMinimized(window),
                  let id = displayContaining(center(of: frame)), activeIDs.contains(id) else { return }
            byDisplay[id, default: []].append((window, frame))
        }
        for (id, windows) in byDisplay {
            guard let area = visibleAreaCG(of: id) else { continue }
            tileMasterStack(windows, in: area.insetBy(dx: 8, dy: 8))
        }
    }

    private func tileMasterStack(_ windows: [(AXUIElement, CGRect)], in area: CGRect) {
        guard !windows.isEmpty else { return }
        windows.forEach { recordIfNeeded($0.0, homeFrame: $0.1) }
        let gap: CGFloat = 8
        // Master = the currently largest window (usually your main work window).
        let ordered = windows.sorted { $0.1.width * $0.1.height > $1.1.width * $1.1.height }
        guard ordered.count > 1 else { setFrame(ordered[0].0, area); return }

        let masterWidth = (area.width - gap) * 0.6
        setFrame(ordered[0].0, CGRect(x: area.minX, y: area.minY, width: masterWidth, height: area.height))

        // Stack the remaining windows top-to-bottom on the right, ordered by current height.
        let stack = ordered.dropFirst().sorted { $0.1.minY < $1.1.minY }
        let stackX = area.minX + masterWidth + gap
        let stackW = area.maxX - stackX
        let cellH = (area.height - gap * CGFloat(stack.count - 1)) / CGFloat(stack.count)
        for (i, win) in stack.enumerated() {
            let y = area.minY + CGFloat(i) * (cellH + gap)
            setFrame(win.0, CGRect(x: stackX, y: y, width: stackW, height: cellH))
        }
    }

    /// Bring windows back for displays that just turned on.
    /// - `finalRestore` (everything on / quitting): apply every snapshot — un-minimize and
    ///   move each window back to its original frame — then forget them.
    /// - partial (some displays still dark): only un-minimize recorded windows whose home just
    ///   turned on so tiling can re-place them; snapshots are KEPT for the eventual full undo.
    func restoreWindows(nowActive activeIDs: Set<CGDirectDisplayID>, finalRestore: Bool) {
        guard isTrusted else { return }
        if finalRestore {
            for record in records {
                setMinimized(record.element, false)   // no-op if it wasn't minimized
                setFrame(record.element, record.homeFrame)
            }
            records.removeAll()
        } else {
            for record in records {
                guard let homeID = displayContaining(center(of: record.homeFrame)),
                      activeIDs.contains(homeID) else { continue }
                setMinimized(record.element, false)
            }
        }
    }

    /// Enforcement tick: any un-minimized window that has landed on an off display is pulled
    /// back onto the primary active display. Skipped while a mouse button is down so we never
    /// fight an in-progress drag.
    func pullStraysBack(activeIDs: Set<CGDirectDisplayID>, to primaryID: CGDirectDisplayID) {
        guard isTrusted, NSEvent.pressedMouseButtons == 0 else { return }
        let active = CGDisplayBounds(primaryID)
        forEachManagedWindow { window, frame in
            guard !isMinimized(window),
                  let id = displayContaining(center(of: frame)),
                  !activeIDs.contains(id) else { return }
            recordIfNeeded(window, homeFrame: frame)
            // Inset from the active display's top-left, clamped so the window stays on-screen.
            let inset: CGFloat = 40
            let x = max(active.minX, min(active.minX + inset, active.maxX - frame.width))
            let y = max(active.minY, min(active.minY + inset, active.maxY - frame.height))
            move(window, to: CGPoint(x: x, y: y))
        }
    }
}

// MARK: - Blackout controller
//
// Keeps a SET of displays "on" and covers every other display with an opaque black window at
// screen-saver level (above the menu bar and Dock). The active set grows center-outward:
// pressing N keeps the N highest-priority displays on, priority order middle → right → left.

final class BlackoutController {
    private var overlays: [NSWindow] = []
    // Displays kept "on", stored by ID (not NSScreen reference) so the set survives
    // screen-parameter changes, which hand back fresh NSScreen objects.
    private var activeDisplayIDs: Set<CGDirectDisplayID> = []
    private let herder = WindowHerder()
    private var enforcementTimer: Timer?

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func sortedScreens() -> [NSScreen] {
        NSScreen.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
    }

    /// Displays in the order they should be kept on: middle first, then expanding outward
    /// preferring the right neighbor before the left (so for 3 screens: middle, right, left).
    private func displayPriorityOrder() -> [NSScreen] {
        let screens = sortedScreens()
        guard !screens.isEmpty else { return [] }
        let mid = screens.count / 2
        var order: [NSScreen] = [screens[mid]]
        var lo = mid - 1, hi = mid + 1
        while lo >= 0 || hi < screens.count {
            if hi < screens.count { order.append(screens[hi]); hi += 1 }
            if lo >= 0 { order.append(screens[lo]); lo -= 1 }
        }
        return order
    }

    @discardableResult
    func requestAccessibility() -> Bool { herder.requestPermission() }

    // MARK: key handling

    /// Digit N keeps the N highest-priority displays on. `0` (and N ≥ display count) means
    /// all-on. Anything with at least one darkened display arms window herding + enforcement.
    func handleKey(_ key: Character) {
        switch key {
        case "0":
            allOn()
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            setActiveCount(key.wholeNumberValue ?? NSScreen.screens.count)
        default:
            break
        }
    }

    private func setActiveCount(_ n: Int) {
        let kept = Set(displayPriorityOrder().prefix(max(0, n)).map { displayID(of: $0) })
        activeDisplayIDs = kept
        rebuild()
        let allOn = activeDisplayIDs.count >= NSScreen.screens.count || activeDisplayIDs.isEmpty
        // Restore first. A full restore (nothing darkened) puts every window back where it
        // started; a partial one just un-minimizes windows whose display turned on so tiling
        // can re-place them.
        herder.restoreWindows(nowActive: activeDisplayIDs, finalRestore: allOn)
        if allOn {
            stopEnforcement() // nothing darkened → nothing to guard, no tiling
        } else {
            herder.minimizeWindowsOffActive(activeDisplayIDs)
            herder.tileActiveDisplays(activeDisplayIDs)
            startEnforcement()
        }
    }

    /// Turn every display back on, restore every displaced window, and stand down. Used by
    /// `0` and by quit (`q`/Esc) so leaving the tool always hands your windows back.
    func allOn() {
        setActiveCount(NSScreen.screens.count)
    }

    // MARK: overlays

    private func clearOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }

    /// Recompute overlays for the current screen set. Safe to call on screen changes.
    func rebuild() {
        clearOverlays()
        guard !activeDisplayIDs.isEmpty else { return }
        // Drop unplugged displays; if none of the active displays remain, fall back to all-on
        // rather than blacking out every surviving screen.
        let present = activeDisplayIDs.filter { id in
            NSScreen.screens.contains { displayID(of: $0) == id }
        }
        guard !present.isEmpty else { activeDisplayIDs = []; return }
        activeDisplayIDs = present
        for screen in NSScreen.screens where !activeDisplayIDs.contains(displayID(of: screen)) {
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

    // MARK: enforcement

    /// Highest-priority display that is currently on — where strays get pulled back to.
    private func primaryActiveID() -> CGDirectDisplayID? {
        for screen in displayPriorityOrder() {
            let id = displayID(of: screen)
            if activeDisplayIDs.contains(id) { return id }
        }
        return nil
    }

    private func startEnforcement() {
        stopEnforcement()
        enforcementTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self,
                  !self.activeDisplayIDs.isEmpty,
                  let primary = self.primaryActiveID() else { return }
            self.herder.pullStraysBack(activeIDs: self.activeDisplayIDs, to: primary)
        }
    }

    private func stopEnforcement() {
        enforcementTimer?.invalidate()
        enforcementTimer = nil
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
        if !blackout.requestAccessibility() {
            let warning = """
            ⚠️  Accessibility permission not granted. The black overlays still work, but windows
               won't be minimized or confined until you enable it:
               System Settings → Privacy & Security → Accessibility → enable this tool
               (or your terminal app), then re-run.
            """
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }
        startInputThread()
    }

    @objc func screensChanged() {
        blackout.rebuild()
    }

    private func printBanner() {
        let banner = """
        display-blackout — simulate powering monitors off to cut distraction & eye strain.
          Number = how many monitors stay on, expanding from the center:
          1 = middle only    2 = middle + right    3 = all on
          0 = all on    q / Esc = quit
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
                    self.blackout.allOn()
                    terminalRestore()
                    NSApp.terminate(nil)
                }
                return
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
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
