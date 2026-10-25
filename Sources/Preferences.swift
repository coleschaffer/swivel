import Foundation

@MainActor
final class Preferences {
    private let defaults = UserDefaults.standard

    private func bool(_ key: String, default value: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? value }
    private func number(_ key: String, default value: Double) -> Double { defaults.object(forKey: key) as? Double ?? value }

    var enabled: Bool {
        get { bool("enabled", default: true) }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    var style: FocusStyle {
        get { defaults.string(forKey: "style").flatMap(FocusStyle.init(rawValue:)) ?? .swap }
        set { defaults.set(newValue.rawValue, forKey: "style") }
    }

    /// Share of the screen width the center window gets. Each screen size keeps its own, since a laptop screen
    /// wants a wider center than an ultrawide; a screen that hasn't had one set uses the shared one.
    func centerFraction(on screen: CGSize?) -> CGFloat {
        let saved = screen.flatMap { defaults.dictionary(forKey: "centerFractions")?[Self.key($0)] as? Double }
        return CGFloat(saved ?? number("centerFraction", default: 0.35))
    }

    func setCenterFraction(_ value: CGFloat, on screen: CGSize?) {
        let clamped = Double(min(0.8, max(0.2, value)))
        guard let screen else { return defaults.set(clamped, forKey: "centerFraction") }
        var saved = defaults.dictionary(forKey: "centerFractions") ?? [:]
        saved[Self.key(screen)] = clamped
        defaults.set(saved, forKey: "centerFractions")
    }

    private static func key(_ screen: CGSize) -> String { "\(Int(screen.width))x\(Int(screen.height))" }

    var gap: CGFloat {
        get { CGFloat(number("gapSize", default: 12)) }
        set { defaults.set(Double(newValue), forKey: "gapSize") }
    }

    /// Glide windows into place (needs Screen Recording) instead of snapping them.
    var smoothTransitions: Bool {
        get { bool("smoothTransitions", default: true) }
        set { defaults.set(newValue, forKey: "smoothTransitions") }
    }

    var transitionDuration: TimeInterval {
        get { number("transitionDuration", default: 0.28) }
        set { defaults.set(newValue, forKey: "transitionDuration") }
    }

    var glow: Bool {
        get { bool("glow", default: true) }
        set { defaults.set(newValue, forKey: "glow") }
    }

    /// How much to darken everything but the focused window, from 0 to 1.
    var dimLevel: CGFloat {
        get { CGFloat(number("dimLevel", default: 0)) }
        set { defaults.set(Double(newValue), forKey: "dimLevel") }
    }

    var pointerFollowsFocus: Bool {
        get { bool("pointerFollowsFocus", default: false) }
        set { defaults.set(newValue, forKey: "pointerFollowsFocus") }
    }

    /// Bundle ids of apps whose windows are left alone. Fixed-size apps are excluded out of the box.
    var excludedApps: Set<String> {
        get { Set(defaults.stringArray(forKey: "excludedApps") ?? ["com.apple.systempreferences", "com.apple.calculator"]) }
        set { defaults.set(newValue.sorted(), forKey: "excludedApps") }
    }

    /// Whether Swivel has set itself up to open at login yet (it does on first launch).
    var loginItemConfigured: Bool {
        get { bool("loginItemConfigured", default: false) }
        set { defaults.set(newValue, forKey: "loginItemConfigured") }
    }

    func layout(on screen: CGSize?) -> LayoutSettings {
        LayoutSettings(centerFraction: centerFraction(on: screen), gap: gap)
    }
}
