import AppKit

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], checked: Bool? = nil,
         enabled: Bool = true, handler: @escaping () -> Void = {}) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        if let checked { state = checked ? .on : .off }
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// The menu bar icon and its menu.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let manager: WindowManager
    private var prefs: Preferences { manager.prefs }
    var unavailableShortcuts: [String] = []

    init(manager: WindowManager) {
        self.manager = manager
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        refreshIcon()
    }

    func refreshIcon() {
        let symbol = !AXIsProcessTrusted() ? "exclamationmark.triangle"
            : prefs.enabled ? "rectangle.split.3x1.fill" : "rectangle.split.3x1"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Swivel")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshIcon()
        guard AXIsProcessTrusted() else {
            menu.addItem(ActionItem("Swivel needs Accessibility access to arrange windows", enabled: false))
            menu.addItem(ActionItem("Open Accessibility Settings…") {
                Self.openSettings("Privacy_Accessibility")
            })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Quit Swivel", key: "q") { NSApp.terminate(nil) })
            return
        }

        let hyper: NSEvent.ModifierFlags = [.control, .option, .command]
        menu.addItem(ActionItem("Tile Windows", key: "t", modifiers: hyper, checked: prefs.enabled) { [unowned self] in
            manager.setEnabled(!prefs.enabled)
            refreshIcon()
        })
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Focusing a side window"))
        menu.addItem(ActionItem("Swaps It With the Center", checked: prefs.style == .swap) { [unowned self] in
            prefs.style = .swap
        })
        menu.addItem(ActionItem("Rotates the Whole Row", checked: prefs.style == .carousel) { [unowned self] in
            prefs.style = .carousel
        })
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Look"))
        if prefs.smoothTransitions && !ScreenCapture.isAllowed {
            menu.addItem(ActionItem("Smooth Transitions: Allow Screen Recording…", checked: false) {
                CGRequestScreenCaptureAccess()
                Self.openSettings("Privacy_ScreenCapture")
            })
        } else {
            menu.addItem(ActionItem("Smooth Transitions", checked: prefs.smoothTransitions) { [unowned self] in
                prefs.smoothTransitions.toggle()
                if prefs.smoothTransitions && !ScreenCapture.isAllowed { CGRequestScreenCaptureAccess() }
            })
        }
        menu.addItem(submenu("Transition Speed", [("Snappy", 0.18), ("Smooth", 0.28), ("Relaxed", 0.38)],
                             current: prefs.transitionDuration) { [unowned self] in prefs.transitionDuration = $0 })
        menu.addItem(ActionItem("Glow Around the Focused Window", checked: prefs.glow) { [unowned self] in
            prefs.glow.toggle()
            manager.relayout()
        })
        menu.addItem(submenu("Dim Side Windows", [("Off", 0), ("Subtle", 0.15), ("Strong", 0.35)],
                             current: prefs.dimLevel) { [unowned self] in
            prefs.dimLevel = $0
            manager.relayout()
        })
        let widths = [30, 35, 40, 45, 50, 60].map { ("\($0)%", CGFloat($0) / 100) }
        menu.addItem(submenu("Center Width", widths, current: prefs.centerFraction) { [unowned self] in
            prefs.centerFraction = $0
            manager.relayout()
        })
        menu.addItem(submenu("Gaps", [("None", 0), ("Small", 6), ("Medium", 12), ("Large", 20)], current: prefs.gap) { [unowned self] in
            prefs.gap = $0
            manager.relayout()
        })
        menu.addItem(ActionItem("Pointer Follows the Window", checked: prefs.pointerFollowsFocus) { [unowned self] in
            prefs.pointerFollowsFocus.toggle()
        })
        menu.addItem(.separator())

        if let focused = manager.focusedWindow() {
            let name = focused.title.isEmpty ? (focused.app.localizedName ?? "Window") : focused.title
            menu.addItem(ActionItem("Float “\(name.truncated(36))”", key: "f", modifiers: hyper,
                                    checked: manager.floating.contains(focused.id)) { [unowned self] in
                manager.toggleFloating(focused.id)
            })
        }
        if let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular, let bundleID = app.bundleIdentifier {
            menu.addItem(ActionItem("Never Tile \(app.localizedName ?? bundleID)",
                                    checked: prefs.excludedApps.contains(bundleID)) { [unowned self] in
                manager.toggleExcluded(bundleID)
            })
        }
        menu.addItem(ActionItem("Bring Left Window to Center", key: "[", modifiers: hyper) { [unowned self] in manager.step(-1) })
        menu.addItem(ActionItem("Bring Right Window to Center", key: "]", modifiers: hyper) { [unowned self] in manager.step(1) })
        menu.addItem(ActionItem("Widen Center", key: "=", modifiers: hyper) { [unowned self] in manager.adjustCenterWidth(by: 0.05) })
        menu.addItem(ActionItem("Narrow Center", key: "-", modifiers: hyper) { [unowned self] in manager.adjustCenterWidth(by: -0.05) })
        menu.addItem(ActionItem("Re-tile From Current Positions") { [unowned self] in manager.retile() })
        if !unavailableShortcuts.isEmpty {
            menu.addItem(ActionItem("Taken by another app: \(unavailableShortcuts.joined(separator: "  "))", enabled: false))
        }
        menu.addItem(.separator())

        let loginTitle = LoginItem.needsApproval ? "Open at Login (approve in System Settings…)" : "Open at Login"
        menu.addItem(ActionItem(loginTitle, checked: LoginItem.isEnabled) {
            if LoginItem.needsApproval {
                Self.openLoginItemsSettings()
            } else {
                LoginItem.setEnabled(!LoginItem.isEnabled)
            }
        })
        menu.addItem(ActionItem("Quit Swivel", key: "q") { NSApp.terminate(nil) })
    }

    private func submenu(_ title: String, _ options: [(String, CGFloat)], current: CGFloat,
                         choose: @escaping (CGFloat) -> Void) -> NSMenuItem {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (label, value) in options {
            menu.addItem(ActionItem(label, checked: abs(value - current) < 0.001) { choose(value) })
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private static func openLoginItemsSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}

private extension String {
    func truncated(_ length: Int) -> String {
        count > length ? prefix(length - 1) + "…" : self
    }
}
