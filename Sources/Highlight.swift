import AppKit
import QuartzCore

/// The glow around the focused window, and the optional dimming of everything else. It lives in a
/// see-through window placed just below the focused window, so it never covers that window's content.
@MainActor
final class Highlight {
    private let window: NSWindow
    private let host = CALayer()
    private let shade = CALayer()
    private let ring = CAShapeLayer()
    private var lastCenter: WindowID?
    private(set) var hasShown = false

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]  // hidden in Mission Control
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let view = NSView()
        view.layer = host
        view.wantsLayer = true
        window.contentView = view

        shade.backgroundColor = CGColor(gray: 0, alpha: 1)
        shade.opacity = 0
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.shadowOffset = .zero
        ring.shadowRadius = 10
        ring.shadowOpacity = 1
        ring.opacity = 0
        host.addSublayer(shade)
        host.addSublayer(ring)
    }

    func show(around frame: CGRect, below windowID: WindowID, on screen: NSScreen, glow: Bool, dim: CGFloat, gap: CGFloat) {
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        let local = frame.flipped(within: screen.axFrame)
        let outset = max(2, min(gap / 2, 7))
        let accent = NSColor.controlAccentColor.cgColor
        let arrived = windowID != lastCenter
        lastCenter = windowID

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = host.bounds
        ring.frame = host.bounds
        ring.path = CGPath(roundedRect: local.insetBy(dx: -outset, dy: -outset),
                           cornerWidth: TransitionScene.cornerRadius + outset,
                           cornerHeight: TransitionScene.cornerRadius + outset, transform: nil)
        ring.strokeColor = accent
        ring.shadowColor = accent
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        shade.opacity = Float(dim)
        ring.opacity = glow && gap >= 4 ? 0.9 : 0
        CATransaction.commit()
        if arrived && glow { pulse() }

        window.order(.below, relativeTo: Int(windowID))
        hasShown = true
    }

    func hide() {
        window.orderOut(nil)
        lastCenter = nil
    }

    /// The glow flares briefly when a new window lands in the center.
    private func pulse() {
        let flare = CABasicAnimation(keyPath: "shadowRadius")
        flare.fromValue = 24
        flare.toValue = 10
        flare.duration = 0.5
        flare.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(flare, forKey: "pulse")
    }
}
