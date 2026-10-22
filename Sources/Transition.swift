import AppKit
import QuartzCore

/// One window's trip during a transition, in Accessibility coordinates.
struct Flight {
    let id: WindowID
    let from: CGRect
    let to: CGRect
    /// Was in the center slot before the transition.
    let fromCenter: Bool
    /// Lands in the center slot. It travels on top, lifted a little.
    let toCenter: Bool
}

/// The layers for one transition: pictures of the moving windows, over the wallpaper in the slots
/// they're leaving and arriving at. Layers use AppKit's usual coordinates: origin at the screen's
/// bottom-left, y growing upward.
@MainActor
final class TransitionScene {
    static let cornerRadius: CGFloat = 12

    let root = CALayer()
    private let dim: CGFloat
    private var parts: [Part] = []

    private struct Part {
        let flight: Flight
        let from: CGRect
        let to: CGRect
        let container: CALayer
        let content: CALayer
        let shade: CALayer
    }

    init(flights: [Flight], picture: CGImage, pictureArea: CGRect, screenFrame: CGRect, wallpaper: CGImage?,
         dim: CGFloat, includeBackdrop: Bool = true) {
        self.dim = dim
        root.frame = CGRect(origin: .zero, size: screenFrame.size)
        func local(_ rect: CGRect) -> CGRect { rect.flipped(within: screenFrame) }

        if includeBackdrop {
            let slots = flights.flatMap { [local($0.from), local($0.to)] }
            root.addSublayer(Self.backdrop(covering: slots, size: screenFrame.size, wallpaper: wallpaper, dim: dim))
        }

        let scale = CGFloat(picture.width) / pictureArea.width
        // The window heading for the center goes last, so it travels on top.
        for flight in flights.sorted(by: { !$0.toCenter && $1.toCenter }) {
            let pixels = CGRect(x: (flight.from.minX - pictureArea.minX) * scale, y: (flight.from.minY - pictureArea.minY) * scale,
                                width: flight.from.width * scale, height: flight.from.height * scale).integral
            let image = picture.cropping(to: pixels)

            let content = CALayer()
            content.contents = image
            content.contentsScale = scale
            // Unscaled, so text stays crisp; a growing window shows its own edge color in the new space.
            content.contentsGravity = .top
            content.backgroundColor = image.map(edgeColor) ?? CGColor(gray: 0.15, alpha: 1)
            content.cornerRadius = Self.cornerRadius
            content.cornerCurve = .continuous
            content.masksToBounds = true

            let shade = CALayer()
            shade.backgroundColor = CGColor(gray: 0, alpha: 1)
            content.addSublayer(shade)

            let container = CALayer()
            container.zPosition = flight.toCenter ? 2 : 1
            container.shadowColor = CGColor(gray: 0, alpha: 1)
            container.shadowOffset = CGSize(width: 0, height: -10)
            container.addSublayer(content)
            root.addSublayer(container)
            parts.append(Part(flight: flight, from: local(flight.from), to: local(flight.to),
                              container: container, content: content, shade: shade))
        }
        place(at: 0, animated: false)
    }

    /// Puts every picture a fraction `t` of the way along. When animated, Core Animation draws the frames
    /// in between on its own thread, at the display's refresh rate.
    func place(at t: CGFloat, animated: Bool, duration: TimeInterval = 0.22) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
        for part in parts {
            let frame = part.from.interpolated(to: part.to, t)
            let bounds = CGRect(origin: .zero, size: frame.size)
            part.container.frame = frame
            part.container.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius,
                                               cornerHeight: Self.cornerRadius, transform: nil)
            part.container.shadowOpacity = Float(part.flight.toCenter ? 0.3 + 0.2 * t : 0.3)
            part.container.shadowRadius = part.flight.toCenter ? 16 + 14 * t : 16
            part.content.frame = bounds
            part.shade.frame = bounds
            let start = part.flight.fromCenter ? 0 : dim
            let end = part.flight.toCenter ? 0 : dim
            part.shade.opacity = Float(start + (end - start) * t)
        }
        CATransaction.commit()
    }

    private static func backdrop(covering slots: [CGRect], size: CGSize, wallpaper: CGImage?, dim: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: size)
        layer.backgroundColor = CGColor(gray: 0.12, alpha: 1)
        layer.masksToBounds = true
        if let wallpaper {
            layer.contents = wallpaper
            layer.contentsGravity = .resizeAspectFill
        }
        if dim > 0 {
            let shade = CALayer()
            shade.frame = layer.bounds
            shade.backgroundColor = CGColor(gray: 0, alpha: dim)
            layer.addSublayer(shade)
        }
        let path = CGMutablePath()
        for slot in slots { path.addRoundedRect(in: slot, cornerWidth: cornerRadius, cornerHeight: cornerRadius) }
        let mask = CAShapeLayer()
        mask.frame = layer.bounds
        mask.path = path
        layer.mask = mask
        return layer
    }
}

/// The average color along a picture's right edge: what a window being widened shows in the new space.
/// Measured and returned in the picture's own color space, so there's no seam where they meet.
private func edgeColor(_ image: CGImage) -> CGColor {
    let fallback = CGColor(gray: 0.15, alpha: 1)
    let strip = image.cropping(to: CGRect(x: max(0, image.width - 6), y: image.height / 4,
                                          width: min(4, image.width), height: max(1, image.height / 2))) ?? image
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = context.data else { return fallback }
    context.interpolationQuality = .medium
    context.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let pixel = data.assumingMemoryBound(to: UInt8.self)
    let components = [CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255, 1]
    return CGColor(colorSpace: space, components: components) ?? fallback
}

/// Plays a `TransitionScene` above every window while the real windows are moved underneath it,
/// then dissolves to reveal them in their new places.
@MainActor
final class TransitionOverlay {
    private let panel: NSPanel
    private let host = CALayer()
    private var generation = 0

    private final class Progress {
        var animationDone = false
        var windowsMoved = false
        var revealed = false
    }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        // Catches clicks on the moving pictures (clear areas pass through), so the second click of a
        // double-click can't land on whichever window just slid in underneath.
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = .none
        let view = NSView()
        view.layer = host
        view.wantsLayer = true
        panel.contentView = view
    }

    var isPlaying: Bool { panel.isVisible }

    /// - Parameters:
    ///   - moveWindows: moves the real windows, calling back once they're in place.
    ///   - beforeReveal: runs just before the pictures dissolve.
    func play(_ scene: TransitionScene, on screen: NSScreen, duration: TimeInterval,
              moveWindows: @escaping (@escaping () -> Void) -> Void, beforeReveal: @escaping () -> Void) {
        generation += 1
        let generation = self.generation
        let progress = Progress()

        panel.setFrame(screen.frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.root.frame = host.bounds
        host.sublayers = [scene.root]
        CATransaction.commit()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        CATransaction.flush()

        let reveal = { [weak self] in
            guard let self, progress.animationDone, progress.windowsMoved, !progress.revealed,
                  generation == self.generation else { return }
            progress.revealed = true
            beforeReveal()
            // A moment for the apps to draw at their new sizes before the pictures dissolve.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                MainActor.assumeIsolated { self.dissolve(generation) }
            }
        }
        // One frame later the overlay is on screen, so the windows can move behind it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
            MainActor.assumeIsolated {
                guard generation == self.generation else { return }
                scene.place(at: 1, animated: true, duration: duration)
                moveWindows {
                    progress.windowsMoved = true
                    reveal()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012 + duration) {
            MainActor.assumeIsolated {
                progress.animationDone = true
                reveal()
            }
        }
        // Never leave the overlay up because an app is slow to respond.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 1.2) {
            MainActor.assumeIsolated {
                progress.animationDone = true
                progress.windowsMoved = true
                reveal()
            }
        }
    }

    /// Stops a transition partway; its windows are already where it was taking them.
    func cancel() {
        generation += 1
        panel.orderOut(nil)
        host.sublayers = nil
    }

    private func dissolve(_ generation: Int) {
        guard generation == self.generation else { return }
        let finish = { [weak self] in
            guard let self, generation == self.generation, self.panel.isVisible else { return }
            self.panel.orderOut(nil)
            self.host.sublayers = nil
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { finish() }
        })
        // In case the completion never comes: an invisible overlay must not linger over the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated { finish() }
        }
    }
}
