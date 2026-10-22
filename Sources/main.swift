import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private lazy var manager = WindowManager(prefs: prefs)
    private var menu: StatusMenu?
    private var hotKeys: HotKeys?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened twice (say, at login and by hand)? Keep the one already running.
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }
        Log.trim()
        Log.write("launched \(Bundle.main.bundlePath)")
        menu = StatusMenu(manager: manager)
        registerHotKeys()
        if !prefs.loginItemConfigured {
            prefs.loginItemConfigured = true
            LoginItem.setEnabled(true)
        }
        // Asks macOS to show its Accessibility prompt the first time.
        if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            begin()
        } else {
            Log.write("waiting for Accessibility access")
            waitForPermission()
        }
    }

    private func begin() {
        manager.start()
        menu?.refreshIcon()
        // macOS only shows this prompt when it hasn't been answered, e.g. after an update resets it.
        if prefs.smoothTransitions, !ScreenCapture.isAllowed { CGRequestScreenCaptureAccess() }
        Log.write("running; screen recording \(ScreenCapture.isAllowed ? "allowed" : "not allowed"), login item \(LoginItem.isEnabled ? "on" : "off")")
    }

    private func waitForPermission() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.begin()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func registerHotKeys() {
        let keys = HotKeys()
        let hyper = controlKey | optionKey | cmdKey
        keys.register("⌃⌥⌘[", key: kVK_ANSI_LeftBracket, modifiers: hyper) { [unowned self] in manager.step(-1) }
        keys.register("⌃⌥⌘]", key: kVK_ANSI_RightBracket, modifiers: hyper) { [unowned self] in manager.step(1) }
        keys.register("⌃⌥⌘T", key: kVK_ANSI_T, modifiers: hyper) { [unowned self] in
            manager.setEnabled(!prefs.enabled)
            menu?.refreshIcon()
        }
        keys.register("⌃⌥⌘F", key: kVK_ANSI_F, modifiers: hyper) { [unowned self] in
            if let window = manager.focusedWindow() { manager.toggleFloating(window.id) }
        }
        keys.register("⌃⌥⌘=", key: kVK_ANSI_Equal, modifiers: hyper) { [unowned self] in manager.adjustCenterWidth(by: 0.05) }
        keys.register("⌃⌥⌘-", key: kVK_ANSI_Minus, modifiers: hyper) { [unowned self] in manager.adjustCenterWidth(by: -0.05) }
        menu?.unavailableShortcuts = keys.unavailable
        hotKeys = keys
    }
}

/// `Swivel --dry-run` prints what it would do with the windows on screen right now, without moving any.
@MainActor
func dryRun() -> Int32 {
    guard AXIsProcessTrusted() else {
        print("Not allowed to read windows: this process doesn't have Accessibility access.")
        return 1
    }
    let manager = WindowManager(prefs: Preferences())
    guard let screen = WindowManager.screen, let preview = manager.preview() else {
        print("No screen found.")
        return 1
    }
    func show(_ r: CGRect) -> String { "x \(Int(r.minX))…\(Int(r.maxX))  \(Int(r.width))×\(Int(r.height))" }
    print("Screen \(Int(screen.frame.width))×\(Int(screen.frame.height)), tiling area \(show(preview.area))")
    print("Focused: \(manager.focusedWindow().map { "\($0.app.localizedName ?? "?") – \($0.title)" } ?? "none")\n")
    for (slot, window, target) in preview.slots {
        let name = "\(window.appName) – \(window.title)".prefix(48)
        print("\(slot.padding(toLength: 8, withPad: " ", startingAt: 0)) \(name.padding(toLength: 48, withPad: " ", startingAt: 0))  now \(show(window.frame))  →  \(show(target))")
    }
    return 0
}

/// `Swivel --render-test <folder>` draws a made-up swap transition at a few points along the way into
/// PNGs, to check the animation's geometry without touching the real screen.
@MainActor
func renderTest(into folder: String) -> Int32 {
    let screen = CGRect(x: 0, y: 0, width: 5120, height: 1440)
    let area = CGRect(x: 0, y: 30, width: 5120, height: 1410)
    let row = Row(center: 1, left: [2], right: [3, 4])
    let frames = row.frames(in: area, settings: LayoutSettings(centerFraction: 0.35, gap: 12))
    let colors: [WindowID: (CGColor, String)] = [1: (CGColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1), "CENTER"),
                                                  2: (CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1), "LEFT"),
                                                  3: (CGColor(red: 0.95, green: 0.55, blue: 0.2, alpha: 1), "R1"),
                                                  4: (CGColor(red: 0.6, green: 0.3, blue: 0.85, alpha: 1), "R2")]
    // A stand-in for a screen picture: each window gets its color, a dark title bar, and a white block
    // in one top corner, so a flipped or misplaced picture is obvious.
    func picture(of frames: [WindowID: CGRect], markerOnRight: Bool) -> CGImage {
        drawImage(width: Int(area.width), height: Int(area.height)) { context in
            context.setFillColor(CGColor(gray: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: area.width, height: area.height))
            for (id, frame) in frames {
                let r = CGRect(x: frame.minX - area.minX, y: area.height - (frame.maxY - area.minY), width: frame.width, height: frame.height)
                context.setFillColor(colors[id]!.0)
                context.fill(r)
                context.setFillColor(CGColor(gray: 0.1, alpha: 1))
                context.fill(CGRect(x: r.minX, y: r.maxY - 40, width: r.width, height: 40))
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: markerOnRight ? r.maxX - 240 : r.minX + 20, y: r.maxY - 160, width: 220, height: 100))
            }
        }
    }
    let before = picture(of: frames, markerOnRight: false)
    var swapped = row
    swapped.focus(4, style: .swap)
    let after = swapped.frames(in: area, settings: LayoutSettings(centerFraction: 0.35, gap: 12))
    let flights = [Flight(id: 4, from: frames[4]!, to: after[4]!, fromCenter: false, toCenter: true),
                   Flight(id: 1, from: frames[1]!, to: after[1]!, fromCenter: true, toCenter: false)]
    let scene = TransitionScene(flights: flights, picture: before, pictureArea: area, screenFrame: screen,
                                wallpaper: nil, dim: 0.15, includeBackdrop: false)
    // Same layer setup as on screen: an unflipped host holding the real windows' picture and the scene.
    let host = CALayer()
    host.frame = CGRect(origin: .zero, size: screen.size)
    host.backgroundColor = CGColor(gray: 0.3, alpha: 1)
    let still = CALayer()
    still.frame = area.flipped(within: screen)
    still.contents = before
    host.addSublayer(still)
    scene.root.frame = host.bounds
    host.addSublayer(scene.root)

    func write(_ name: String) -> Bool {
        let image = drawImage(width: Int(screen.width / 4), height: Int(screen.height / 4)) { context in
            context.scaleBy(x: 0.25, y: 0.25)
            host.render(in: context)
        }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("transition-\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("wrote \(url.path)")
        return true
    }
    for t in [0.0, 0.5, 1.0] {
        scene.place(at: t)
        guard write("\(Int(t * 100))") else { return 1 }
    }
    // Landing: the pictures switch to the after-move picture (markers on the right). They should line up
    // exactly with where the real windows now are, shown underneath in the after layout.
    still.contents = picture(of: after, markerOnRight: true)
    scene.land(on: picture(of: after, markerOnRight: true), fade: 0.1)
    guard write("landed") else { return 1 }
    return 0
}

private func drawImage(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(context)
    return context.makeImage()!
}

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    if arguments.contains("--dry-run") {
        _ = NSApplication.shared
        exit(dryRun())
    }
    if let i = arguments.firstIndex(of: "--render-test"), i + 1 < arguments.count {
        _ = NSApplication.shared
        exit(renderTest(into: arguments[i + 1]))
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
