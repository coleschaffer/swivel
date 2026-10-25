import AppKit

/// A window Swivel tiles, as it is on screen right now.
struct TiledWindow {
    let id: WindowID
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    /// Current frame, in Accessibility coordinates.
    let frame: CGRect

    var title: String { element.string(kAXTitleAttribute) ?? "" }

    func setFrame(_ target: CGRect) {
        // Chrome and Electron apps animate or drop programmatic resizes while "enhanced user interface"
        // is on (they switch it on when an assistive app is around), so turn it off around the change.
        let app = AXUIElementCreateApplication(pid)
        let enhanced = app.bool("AXEnhancedUserInterface") == true
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        element.setFrame(target, growing: target.width > frame.width + 1 || target.height > frame.height + 1)
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanTrue) }
    }
}

struct Move {
    let window: TiledWindow
    let from: CGRect
    let to: CGRect
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                        _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { manager.accessibilityNotification(name) }
}

/// Keeps the windows on the widest screen tiled in a row, with the focused one in the center.
@MainActor
final class WindowManager: NSObject {
    let prefs: Preferences
    private(set) var row = Row()
    private(set) var floating = Set<WindowID>()
    private(set) var isRunning = false

    /// Tileable windows found by the last full scan. A plain focus change doesn't need a new scan.
    private var known: [WindowID: (element: AXUIElement, pid: pid_t, appName: String)] = [:]
    /// Whether each window we've met is a normal, resizable window. Checked once per window.
    private var tileable: [WindowID: Bool] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    /// What each window was last asked to become and what it actually became, so a window that
    /// can't shrink to fit its slot isn't resized again on every update.
    private var applied: [WindowID: (target: CGRect, result: CGRect)] = [:]
    private var lastSeen = Set<WindowID>()
    private var lastArea: CGRect?
    private var needsScan = true
    private var pending: DispatchWorkItem?
    private var pendingAt: DispatchTime?
    private var pollTimer: Timer?
    private var monitors: [Any] = []
    private var lastMouseUp = Date.distantPast
    /// The left-button press in progress.
    private var press: Press?
    /// A drag that has ended and hasn't been looked at yet.
    private var endedDrag: Press?
    /// A side window that has focus but stays on its side, because you dragged in it (a tab, some text)
    /// rather than clicked it. A plain click brings it over after all; focusing another window ends it.
    private var stayPut: WindowID?
    /// Side windows you've resized, which Swivel leaves as they are until you move them.
    private var pinned = Set<WindowID>()
    private var inMissionControl = false
    /// Set when Swivel focuses a window itself, so the stale focus reported mid-switch is ignored.
    private var expectedFocus: (id: WindowID, until: Date)?
    /// Where the latest layout put each window.
    private var layout: [WindowID: CGRect] = [:]
    /// A picture taken the moment a side window is pressed, so its transition can start as soon as the
    /// button comes up. `frames` records where the windows were, to check the picture still matches.
    private var earlyPicture: (task: Task<CGImage?, Never>, area: CGRect, frames: [WindowID: CGRect], taken: Date)?
    private var transitionGeneration = 0

    private let mover = WindowMover()
    private let capture = ScreenCapture()
    private let overlay = TransitionOverlay()
    private let highlight = Highlight()

    init(prefs: Preferences) {
        self.prefs = prefs
        super.init()
    }

    /// The screen Swivel tiles: the widest one.
    static var screen: NSScreen? { NSScreen.screens.max { $0.frame.width < $1.frame.width } }

    var smoothTransitionsAvailable: Bool { prefs.smoothTransitions && ScreenCapture.isAllowed }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)  // a hung app shouldn't freeze Swivel
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Notifications cover nearly everything; a cheap check each second catches the rest,
        // like a window closing in the background.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) { monitors.append(down) }
        if let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackDrag() }
        }) { monitors.append(drag) }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp], handler: { [weak self] event in
            let left = event.type == .leftMouseUp
            MainActor.assumeIsolated { self?.mouseUp(left: left) }
        }) { monitors.append(up) }
        if let screen = Self.screen {
            capture.prepare(for: screen)
            _ = Wallpaper.image(for: screen)  // load it now rather than during the first transition
        }
        scheduleUpdate(rescan: true)
    }

    func scheduleUpdate(after delay: TimeInterval = 0, rescan: Bool = false) {
        if rescan { needsScan = true }
        let at = DispatchTime.now() + delay
        if pending != nil, let pendingAt, pendingAt <= at { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.update() }
        }
        pending = work
        pendingAt = at
        DispatchQueue.main.asyncAfter(deadline: at, execute: work)
    }

    func accessibilityNotification(_ name: String) {
        let focusOnly = name == kAXFocusedWindowChangedNotification || name == kAXMainWindowChangedNotification
        scheduleUpdate(after: focusOnly ? 0 : 0.03, rescan: !focusOnly)
    }

    // MARK: Commands

    func setEnabled(_ enabled: Bool) {
        prefs.enabled = enabled
        overlay.cancel()
        row = Row()
        applied = [:]
        stayPut = nil
        pinned = []
        if enabled { scheduleUpdate(rescan: true) } else { highlight.hide() }
    }

    /// Forgets the current order and starts again from where the windows are now.
    func retile() {
        row = Row()
        applied = [:]
        stayPut = nil
        pinned = []
        scheduleUpdate(rescan: true)
    }

    func relayout() { scheduleUpdate() }

    /// The center's share of the width on the screen being tiled. Each screen size keeps its own.
    var centerFraction: CGFloat { prefs.centerFraction(on: Self.screen?.frame.size) }

    func setCenterWidth(_ fraction: CGFloat) {
        prefs.setCenterFraction(fraction, on: Self.screen?.frame.size)
        relayout()
    }

    func adjustCenterWidth(by delta: CGFloat) { setCenterWidth(centerFraction + delta) }

    private var layoutSettings: LayoutSettings { prefs.layout(on: Self.screen?.frame.size) }

    func toggleFloating(_ id: WindowID) {
        if floating.remove(id) == nil { floating.insert(id) }
        relayout()
    }

    func toggleExcluded(_ bundleID: String) {
        var excluded = prefs.excludedApps
        if excluded.remove(bundleID) == nil { excluded.insert(bundleID) }
        prefs.excludedApps = excluded
        scheduleUpdate(rescan: true)
    }

    /// Brings the next window on the right (+1) or left (-1) into the center and focuses it.
    func step(_ direction: Int) {
        guard isRunning, prefs.enabled, AXIsProcessTrusted(), let snapshot = reconcile() else { return }
        stayPut = nil
        let before = row.center
        row.rotate(by: direction)
        guard let id = row.center, let window = snapshot.windows[id] else { return }
        expectedFocus = (id, Date().addingTimeInterval(0.75))
        apply(snapshot, previousCenter: before, centered: nil, smooth: smoothTransitionsAvailable)
        focus(window)
    }

    func focusedWindow() -> (id: WindowID, title: String, app: NSRunningApplication)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = AXUIElementCreateApplication(app.processIdentifier).element(kAXFocusedWindowAttribute),
              let id = element.windowID else { return nil }
        return (id, element.string(kAXTitleAttribute) ?? "", app)
    }

    /// What Swivel would do right now, without moving anything.
    func preview() -> (area: CGRect, slots: [(slot: String, window: TiledWindow, target: CGRect)])? {
        guard let snapshot = reconcile() else { return nil }
        let targets = row.frames(in: snapshot.area, settings: layoutSettings)
        var order: [(String, WindowID)] = row.left.enumerated().reversed().map { ("left \($0.offset + 1)", $0.element) }
        if let center = row.center { order.append(("CENTER", center)) }
        order += row.right.enumerated().map { ("right \($0.offset + 1)", $0.element) }
        let slots = order.compactMap { (slot, id) -> (slot: String, window: TiledWindow, target: CGRect)? in
            guard let window = snapshot.windows[id], let target = targets[id] else { return nil }
            return (slot, window, target)
        }
        return (snapshot.area, slots)
    }

    // MARK: Updating

    private struct Snapshot {
        let windows: [WindowID: TiledWindow]
        let area: CGRect
        let focused: WindowID?
        /// Windows you've zoomed or made full screen. They keep their place in the row but aren't moved.
        let zoomed: Set<WindowID>
    }

    /// A left-button press: where it started, the window under it, where every window was, and whether
    /// it has turned into a drag.
    private struct Press {
        let location: CGPoint
        let window: WindowID?
        let frames: [WindowID: CGRect]
        var dragged = false
    }

    private func update() {
        pending = nil
        pendingAt = nil
        guard isRunning, prefs.enabled, AXIsProcessTrusted() else {
            highlight.hide()
            return
        }
        // Stay out of Mission Control's way entirely: moving windows or drawing over it hides the windows you
        // came to drag between desktops. What you did there (and what focus it left) is sorted out once it closes.
        if let screen = Self.screen, Self.missionControlIsOpen(on: screen.axFrame) {
            if !inMissionControl { Log.write("mission control: open, holding still") }
            inMissionControl = true
            highlight.hide()
            overlay.cancel()
            press = nil
            endedDrag = nil
            stayPut = nil
            needsScan = true
            scheduleUpdate(after: 0.25)
            return
        }
        if inMissionControl {
            inMissionControl = false
            Log.write("mission control: closed")
        }
        // Never move a window while a mouse button is down: it may be mid-click or mid-drag.
        if NSEvent.pressedMouseButtons != 0 {
            trackDrag()
            scheduleUpdate(after: 0.016)
            return
        }
        let smooth = smoothTransitionsAvailable
        if !smooth {
            // With no transition to catch it, give a double-click time to land its second click
            // before the window it's aimed at moves away.
            let sinceClick = Date().timeIntervalSince(lastMouseUp)
            if sinceClick < 0.15 {
                scheduleUpdate(after: 0.15 - sinceClick)
                return
            }
        }
        // A drag that just ended, even when its mouse-up hasn't come through yet.
        var drag = endedDrag
        if let current = press, current.dragged {
            drag = current
            press = nil
        }
        endedDrag = nil
        let centerBefore = row.center
        guard let snapshot = reconcile() else {
            highlight.hide()
            return
        }
        if let drag { sortOut(drag, snapshot, centerChanged: row.center != centerBefore) }
        apply(snapshot, previousCenter: centerBefore, centered: row.center != centerBefore ? snapshot.focused : nil, smooth: smooth)
    }

    /// Works out what you just did with the mouse. A side window you resized keeps its new size; resizing
    /// the center window sets the center width instead; a window you moved goes back to its place.
    private func sortOut(_ drag: Press, _ snapshot: Snapshot, centerChanged: Bool) {
        for (id, window) in snapshot.windows where row.contains(id) && !snapshot.zoomed.contains(id) {
            guard let before = drag.frames[id], !window.frame.isClose(to: before, tolerance: 8) else { continue }
            // Back where Swivel put it (perhaps a transition finishing): nothing you did. "Where Swivel put it" is
            // what the window actually became, for apps that can't take their slot's exact size.
            let placed = layout[id].map { slot in applied[id].flatMap { $0.target == slot ? $0.result : nil } ?? slot }
            if let placed, window.frame.isClose(to: placed, tolerance: 8) {
                pinned.remove(id)
                continue
            }
            let resized = abs(window.frame.width - before.width) > 8 || abs(window.frame.height - before.height) > 8
            if !resized {
                pinned.remove(id)
            } else if id != row.center {
                pinned.insert(id)
            } else if !centerChanged {
                let fraction = (window.frame.width / snapshot.area.width * 100).rounded() / 100
                prefs.setCenterFraction(fraction, on: Self.screen?.frame.size)
            }
        }
    }

    /// Re-reads the screen and folds what changed into the row: closed windows leave, new ones join,
    /// and the focused window moves to the center.
    private func reconcile() -> Snapshot? {
        guard let screen = Self.screen else { return nil }
        let area = screen.axVisibleFrame
        let onScreen = onScreenWindows(in: screen.axFrame)
        let seen = Set(onScreen.keys)
        if needsScan || seen != lastSeen || area != lastArea {
            scan(onScreen)
            needsScan = false
        }
        lastSeen = seen
        lastArea = area

        var windows: [WindowID: TiledWindow] = [:]
        for (id, info) in known where !floating.contains(id) {
            guard let current = onScreen[id] else { continue }
            windows[id] = TiledWindow(id: id, element: info.element, pid: info.pid, appName: info.appName, frame: current.frame)
        }
        applied = applied.filter { windows[$0.key] != nil }

        var focused = focusedWindow().flatMap { windows[$0.id] == nil ? nil : $0.id }
        if let expected = expectedFocus {
            if focused == expected.id || Date() > expected.until {
                expectedFocus = nil
            } else {
                focused = nil
            }
        }

        let gone = Set(row.all).subtracting(windows.keys)
        if !gone.isEmpty { row.remove(gone, successor: focused) }
        // Only windows already in the row count as zoomed: one that opens full size still gets tiled.
        let zoomed = Set(windows.values.filter { row.contains($0.id) && $0.frame.fills(area) }.map(\.id))
        if row.isEmpty {
            row = Row(arranging: windows.values.map { (id: $0.id, midX: $0.frame.midX) },
                      center: focused, screenMidX: area.midX)
        } else {
            let newcomers = windows.values
                .filter { !row.contains($0.id) && $0.id != focused }
                .sorted { $0.frame.midX < $1.frame.midX }
            for window in newcomers { row.insertAtEdge(window.id) }
            if let focused, !row.contains(focused) { row.insertAtCenter(focused) }
        }
        if let focused, focused != stayPut {
            stayPut = nil
            // A window you've resized stays where it is, even with focus.
            if !pinned.contains(focused) { row.focus(focused, style: prefs.style) }
        }
        return Snapshot(windows: windows, area: area, focused: focused, zoomed: zoomed)
    }

    private func apply(_ snapshot: Snapshot, previousCenter: WindowID?, centered: WindowID?, smooth: Bool) {
        // Only side windows stay pinned: one that ends up in the center (the old center closed, say) takes its slot.
        if let center = row.center { pinned.remove(center) }
        let targets = row.frames(in: snapshot.area, settings: layoutSettings)
        layout = targets
        var moves: [Move] = []
        for (id, target) in targets {
            guard let window = snapshot.windows[id], !snapshot.zoomed.contains(id), !pinned.contains(id),
                  !window.frame.isClose(to: target) else { continue }
            if let last = applied[id], last.target == target, window.frame.isClose(to: last.result) { continue }
            moves.append(Move(window: window, from: window.frame, to: target))
        }
        if prefs.pointerFollowsFocus, let id = centered, !snapshot.zoomed.contains(id),
           let window = snapshot.windows[id], let target = targets[id] {
            movePointer(from: window.frame, to: target)
        }
        let center = row.center
        // The glow marks the focused window: usually the center one, but a side window that has focus where
        // it is (you dragged in it, or resized it) keeps the glow there.
        let lit = stayPut ?? snapshot.focused.flatMap { pinned.contains($0) ? $0 : nil } ?? center
        let litFrame = lit.flatMap { id in
            snapshot.zoomed.contains(id) ? nil : pinned.contains(id) ? snapshot.windows[id]?.frame : targets[id]
        }
        let showHighlight: () -> Void = { [weak self] in
            self?.showHighlight(center: lit, frame: litFrame)
        }
        guard !moves.isEmpty else {
            showHighlight()
            return
        }
        if smooth, let screen = Self.screen {
            playTransition(moves, area: snapshot.area, screen: screen, from: previousCenter, to: center, beforeReveal: showHighlight)
        } else {
            earlyPicture = nil
            mover.move(moves) { [weak self] in self?.record($0) }
            showHighlight()
        }
    }

    private func playTransition(_ moves: [Move], area: CGRect, screen: NSScreen, from oldCenter: WindowID?, to center: WindowID?,
                                beforeReveal: @escaping () -> Void) {
        transitionGeneration += 1
        let generation = transitionGeneration
        let started = Date()
        let picture: Task<CGImage?, Never>
        var early = false
        if let taken = earlyPicture, taken.area == area, Date().timeIntervalSince(taken.taken) < 2,
           moves.allSatisfy({ taken.frames[$0.window.id]?.isClose(to: $0.from) ?? false }) {
            picture = taken.task
            early = true
        } else {
            let capture = self.capture
            picture = Task { await capture.capture(area, on: screen) }
        }
        earlyPicture = nil
        overlay.cancel()

        Task { [weak self] in
            let image = await picture.value
            guard let self, generation == self.transitionGeneration else { return }
            let waited = Date().timeIntervalSince(started) * 1000
            guard let image else {
                Log.write("transition: no picture, snapping instead")
                self.mover.move(moves) { [weak self] in self?.record($0) }
                beforeReveal()
                return
            }
            let flights = moves.map {
                Flight(id: $0.window.id, from: $0.from, to: $0.to, fromCenter: $0.window.id == oldCenter, toCenter: $0.window.id == center)
            }
            let scene = TransitionScene(flights: flights, picture: image, pictureArea: area, screenFrame: screen.axFrame,
                                        wallpaper: Wallpaper.image(for: screen), dim: self.prefs.dimLevel)
            let moveStarted = Date()
            var moved = 0.0
            let capture = self.capture
            self.overlay.play(scene, on: screen, duration: self.prefs.transitionDuration, moveWindows: { [weak self] done in
                self?.mover.move(moves) { [weak self] results in
                    self?.record(results)
                    moved = Date().timeIntervalSince(moveStarted) * 1000
                    done()
                }
            }, pictureLanding: { deliver in
                let asked = Date()
                Task {
                    let picture = await capture.capture(area, on: screen)
                    Log.write(String(format: "transition: %d windows, picture %.0fms%@, moved in %.0fms, landing picture %@ in %.0fms",
                                     flights.count, waited, early ? " (taken on press)" : "", moved,
                                     picture == nil ? "failed" : "taken", Date().timeIntervalSince(asked) * 1000))
                    deliver(picture)
                }
            }, beforeFinish: beforeReveal)
        }
    }

    private func record(_ results: [(id: WindowID, target: CGRect, result: CGRect)]) {
        for result in results { applied[result.id] = (result.target, result.result) }
    }

    private func showHighlight(center: WindowID?, frame: CGRect?) {
        guard prefs.enabled, let center, let frame, let screen = Self.screen, prefs.glow || prefs.dimLevel > 0 else {
            highlight.hide()
            return
        }
        highlight.show(around: frame, below: center, on: screen, glow: prefs.glow, dim: prefs.dimLevel, gap: prefs.gap)
    }

    private func mouseDown() {
        guard isRunning, prefs.enabled, let screen = Self.screen, let location = CGEvent(source: nil)?.location else { return }
        let frames = onScreenWindows(in: screen.axFrame).mapValues { $0.frame }
        let pressed = window(at: location)
        press = Press(location: location, window: pressed, frames: frames)
        // When a side window is pressed, take the picture right away: by the time the button comes up
        // and the window moves to the center, it's ready.
        guard smoothTransitionsAvailable, let area = lastArea, let pressed, row.contains(pressed),
              pressed != row.center, !pinned.contains(pressed) else { return }
        let capture = self.capture
        earlyPicture = (Task { await capture.capture(area, on: screen) }, area, frames, Date())
    }

    /// Notices when the press turns into a drag. A side window you drag in (a tab, some text, a file)
    /// stays where it is instead of coming to the center.
    private func trackDrag() {
        guard let current = press, !current.dragged, let location = CGEvent(source: nil)?.location,
              hypot(location.x - current.location.x, location.y - current.location.y) > 5 else { return }
        press?.dragged = true
        earlyPicture = nil
        if let id = current.window, row.contains(id), id != row.center { stayPut = id }
    }

    private func mouseUp(left: Bool) {
        lastMouseUp = Date()
        guard left, let finished = press else { return }
        press = nil
        if finished.dragged {
            // Whatever you just moved or resized gets sorted out now, not whenever something next happens.
            // Now rather than after a pause, so it joins any update the drag set off instead of interrupting its transition.
            endedDrag = finished
            scheduleUpdate()
        } else if let id = stayPut, finished.window == id {
            // A plain click on a window that stayed put brings it to the center after all.
            stayPut = nil
            scheduleUpdate()
        }
    }

    /// The frontmost of other apps' windows under `point`, counting the strip just outside each window's
    /// edge, where you grab it to resize it.
    private func window(at point: CGPoint) -> WindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.insetBy(dx: -5, dy: -5).contains(point)
            else { continue }
            return info[kCGWindowNumber as String] as? WindowID
        }
        return nil
    }

    /// Keeps the pointer over the window it was on when that window slides to the center.
    private func movePointer(from old: CGRect, to new: CGRect) {
        guard let location = CGEvent(source: nil)?.location, old.contains(location) else { return }
        let x = new.minX + (location.x - old.minX) / old.width * new.width
        let y = new.minY + (location.y - old.minY) / old.height * new.height
        _ = CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        _ = CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func focus(_ window: TiledWindow) {
        window.element.set(kAXMainAttribute, kCFBooleanTrue)
        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementCreateApplication(window.pid).set(kAXFrontmostAttribute, kCFBooleanTrue)
    }

    // MARK: Finding windows

    /// Other apps' windows on `screenFrame` in the current Space that are actually showing:
    /// not minimized, hidden, or full screen elsewhere.
    private func onScreenWindows(in screenFrame: CGRect) -> [WindowID: (pid: pid_t, frame: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [WindowID: (pid: pid_t, frame: CGRect)] = [:]
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? WindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 40, frame.height > 40,
                  screenFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
            else { continue }
            result[id] = (pid, frame)
        }
        return result
    }

    /// Whether Mission Control (or App Exposé, or Launchpad) is showing. There's no public notification for it,
    /// but while it's up the Dock covers the screen with a window of its own, above normal windows.
    private static func missionControlIsOpen(on screenFrame: CGRect) -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == dock, (info[kCGWindowLayer as String] as? Int ?? 0) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return frame.fills(screenFrame)
        }
    }

    /// Asks each app with windows on screen which of them are normal, resizable windows.
    private func scan(_ onScreen: [WindowID: (pid: pid_t, frame: CGRect)]) {
        known = [:]
        for pid in Set(onScreen.values.map { $0.pid }) {
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  !prefs.excludedApps.contains(app.bundleIdentifier ?? "") else { continue }
            let appElement = AXUIElementCreateApplication(pid)
            watch(pid, appElement)
            for element in appElement.elements(kAXWindowsAttribute) {
                guard let id = element.windowID, onScreen[id] != nil else { continue }
                if tileable[id] == nil {
                    tileable[id] = Self.isTileable(element)
                    if tileable[id] == true { watchWindow(element, pid: pid) }
                }
                guard tileable[id] == true, element.bool("AXFullScreen") != true else { continue }
                known[id] = (element, pid, app.localizedName ?? "?")
            }
        }
    }

    /// Normal, resizable windows only: no dialogs, panels, sheets, or fixed-size windows.
    private static func isTileable(_ window: AXUIElement) -> Bool {
        window.string(kAXRoleAttribute) == kAXWindowRole
            && window.string(kAXSubroleAttribute) == kAXStandardWindowSubrole
            && window.isSettable(kAXPositionAttribute)
            && window.isSettable(kAXSizeAttribute)
    }

    // MARK: Watching for changes

    private func watch(_ pid: pid_t, _ app: AXUIElement) {
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
                     kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            _ = AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func watchWindow(_ window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] {
            _ = AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
    }

    @objc private func appActivated() { scheduleUpdate() }

    @objc private func workspaceChanged(_ note: Notification) {
        if note.name == NSWorkspace.didTerminateApplicationNotification,
           let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           let observer = observers.removeValue(forKey: app.processIdentifier) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        scheduleUpdate(after: 0.03, rescan: true)
    }

    @objc private func screensChanged() {
        if let screen = Self.screen { capture.prepare(for: screen, force: true) }
        scheduleUpdate(after: 0.3, rescan: true)
    }

    private func poll() {
        guard prefs.enabled, let screen = Self.screen else { return }
        if Set(onScreenWindows(in: screen.axFrame).keys) != lastSeen { scheduleUpdate() }
    }
}

/// Moves windows off the main thread, one queue per app: a slow app only holds up its own windows,
/// and the transition keeps animating while apps catch up.
final class WindowMover: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [pid_t: DispatchQueue] = [:]

    private func queue(for pid: pid_t) -> DispatchQueue {
        lock.lock()
        defer { lock.unlock() }
        if let queue = queues[pid] { return queue }
        let queue = DispatchQueue(label: "swivel.move.\(pid)", qos: .userInteractive)
        queues[pid] = queue
        return queue
    }

    func move(_ moves: [Move], completion: @escaping @MainActor ([(id: WindowID, target: CGRect, result: CGRect)]) -> Void) {
        let group = DispatchGroup()
        let results = Results()
        for move in moves {
            group.enter()
            queue(for: move.window.pid).async {
                move.window.setFrame(move.to)
                results.append((move.window.id, move.to, move.window.element.frame ?? move.to))
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(results.all) }
        }
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(id: WindowID, target: CGRect, result: CGRect)] = []

        func append(_ item: (id: WindowID, target: CGRect, result: CGRect)) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }

        var all: [(id: WindowID, target: CGRect, result: CGRect)] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }
}
