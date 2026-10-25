import AppKit
import QuartzCore

/// One window's trip during a transition, in Accessibility coordinates.
struct Flight {
    let id: WindowID
    let from: CGRect
    let to: CGRect
    /// Was in the center slot before the transition.
    let fromCenter: Bool
    /// Lands in the center slot. It travels on top.
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
    private let pictureArea: CGRect
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
        self.pictureArea = pictureArea
        root.frame = CGRect(origin: .zero, size: screenFrame.size)
        func local(_ rect: CGRect) -> CGRect { rect.flipped(within: screenFrame) }

        if includeBackdrop {
            let slots = flights.flatMap { [local($0.from), local($0.to)] }
            root.addSublayer(Self.backdrop(covering: slots, size: screenFrame.size, wallpaper: wallpaper, dim: dim))
        }

        // The window heading for the center goes last, so it travels on top.
        for flight in flights.sorted(by: { !$0.toCenter && $1.toCenter }) {
            let image = Self.crop(picture, area: pictureArea, to: flight.from)

            let content = CALayer()
            content.contents = image
            content.contentsScale = CGFloat(picture.width) / pictureArea.width
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
            container.shadowColor = CGColor(gray: 0, alpha: 1)
            container.shadowOffset = CGSize(width: 0, height: -8)
            container.shadowRadius = 18
            container.addSublayer(content)
            root.addSublayer(container)
            parts.append(Part(flight: flight, from: local(flight.from), to: local(flight.to),
                              container: container, content: content, shade: shade))
        }
        place(at: 0)
    }

    /// Puts every picture a fraction `t` of the way along, without animating. For setting up and test renders.
    func place(at t: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in parts {
            let frame = part.from.interpolated(to: part.to, t)
            set(part, frame: frame, shade: shade(part, at: t))
            part.container.shadowOpacity = liftOpacity(part) * Float(4 * t * (1 - t))
        }
        CATransaction.commit()
    }

    /// Glides every picture to where its window is going. Core Animation draws the frames in between
    /// on its own thread, at the display's refresh rate.
    func animate(duration: TimeInterval) {
        // Eases in and out, so nothing lurches at the start or jolts at the end.
        let timing = CAMediaTimingFunction(controlPoints: 0.32, 0, 0.18, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in parts {
            let fromBounds = CGRect(origin: .zero, size: part.from.size)
            let toBounds = CGRect(origin: .zero, size: part.to.size)
            func animate(_ layer: CALayer, _ keyPath: String, from: Any, to: Any) {
                let animation = CABasicAnimation(keyPath: keyPath)
                animation.fromValue = from
                animation.toValue = to
                animation.duration = duration
                animation.timingFunction = timing
                layer.add(animation, forKey: keyPath)
            }
            animate(part.container, "position", from: NSValue(point: part.from.center), to: NSValue(point: part.to.center))
            animate(part.container, "bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: toBounds))
            animate(part.container, "shadowPath", from: Self.roundedPath(fromBounds), to: Self.roundedPath(toBounds))
            for layer in [part.content, part.shade] {
                animate(layer, "position", from: NSValue(point: fromBounds.center), to: NSValue(point: toBounds.center))
                animate(layer, "bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: toBounds))
            }
            animate(part.shade, "opacity", from: shade(part, at: 0), to: shade(part, at: 1))
            // A shadow while it travels, gone again by the time it lands where the real window's own shadow is.
            let lift = CAKeyframeAnimation(keyPath: "shadowOpacity")
            lift.values = [0, liftOpacity(part), 0]
            lift.keyTimes = [0, 0.45, 1]
            lift.duration = duration
            part.container.add(lift, forKey: "lift")

            set(part, frame: part.to, shade: shade(part, at: 1))
            part.container.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    /// Fades each picture over to how its window really looks after the move, so the overlay ends up
    /// matching the screen beneath it and can be taken away without a visible change.
    func land(on picture: CGImage, fade: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in parts {
            guard let image = Self.crop(picture, area: pictureArea, to: part.flight.to) else { continue }
            let crossfade = CABasicAnimation(keyPath: "contents")
            crossfade.fromValue = part.content.contents
            crossfade.toValue = image
            crossfade.duration = fade
            crossfade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            part.content.contents = image
            part.content.add(crossfade, forKey: "land")
        }
        CATransaction.commit()
    }

    private func set(_ part: Part, frame: CGRect, shade opacity: Float) {
        let bounds = CGRect(origin: .zero, size: frame.size)
        part.container.frame = frame
        part.container.shadowPath = Self.roundedPath(bounds)
        part.content.frame = bounds
        part.shade.frame = bounds
        part.shade.opacity = opacity
    }

    private func shade(_ part: Part, at t: CGFloat) -> Float {
        let start = part.flight.fromCenter ? 0 : dim
        let end = part.flight.toCenter ? 0 : dim
        return Float(start + (end - start) * t)
    }

    private func liftOpacity(_ part: Part) -> Float { part.flight.toCenter ? 0.4 : 0.25 }

    /// The part of `picture` (which shows `area`) covering `rect`; both in Accessibility coordinates.
    private static func crop(_ picture: CGImage, area: CGRect, to rect: CGRect) -> CGImage? {
        let scale = CGFloat(picture.width) / area.width
        return picture.cropping(to: CGRect(x: (rect.minX - area.minX) * scale, y: (rect.minY - area.minY) * scale,
                                           width: rect.width * scale, height: rect.height * scale).integral)
    }

    private static func roundedPath(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
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

/// Plays a `TransitionScene` above every window while the real windows are moved underneath it, then
/// hands over to them.
@MainActor
final class TransitionOverlay {
    private let panel: NSPanel
    private let host = CALayer()
    private var generation = 0

    private final class Progress {
        var animationDone = false
        var landed = false
        var finished = false
    }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]  // hidden in Mission Control
        panel.sharingType = .none
        let view = NSView()
        view.layer = host
        view.wantsLayer = true
        panel.contentView = view
    }

    /// The overlay's window number, so screen pictures can leave it out.
    var windowNumber: Int { panel.windowNumber }

    /// - Parameters:
    ///   - moveWindows: moves the real windows, calling back once they're in place.
    ///   - pictureLanding: pictures the screen after the move, for the pictures to fade into.
    ///   - beforeFinish: runs just before the overlay hands over to the real windows.
    func play(_ scene: TransitionScene, on screen: NSScreen, duration: TimeInterval,
              moveWindows: @escaping (@escaping () -> Void) -> Void,
              pictureLanding: @escaping (@escaping (CGImage?) -> Void) -> Void,
              beforeFinish: @escaping () -> Void) {
        generation += 1
        let generation = self.generation
        let progress = Progress()
        let started = CACurrentMediaTime()

        panel.setFrame(screen.frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.root.frame = host.bounds
        host.sublayers = [scene.root]
        CATransaction.commit()
        // Catches clicks on the moving pictures (clear areas pass through), so the second click of a
        // double-click can't land on whichever window just slid in underneath.
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        CATransaction.flush()

        let finish = { [weak self] (matched: Bool) in
            guard let self, generation == self.generation, !progress.finished else { return }
            progress.finished = true
            beforeFinish()
            // When the pictures already match the real windows this is invisible; otherwise it softens the change.
            self.dissolve(generation, duration: matched ? 0.06 : 0.14)
        }
        let finishIfReady = {
            if progress.animationDone && progress.landed { finish(true) }
        }

        // One frame later the overlay is on screen, so the windows can move behind it.
        after(0.012) {
            guard generation == self.generation else { return }
            scene.animate(duration: duration)
            moveWindows {
                // Give the apps a moment to draw at their new sizes, then picture the result.
                after(0.09) {
                    guard generation == self.generation else { return }
                    pictureLanding { picture in
                        guard generation == self.generation else { return }
                        guard let picture else {
                            progress.landed = true
                            finishIfReady()
                            return
                        }
                        let fade = max(0.08, started + 0.012 + duration - CACurrentMediaTime())
                        scene.land(on: picture, fade: fade)
                        after(fade) {
                            progress.landed = true
                            finishIfReady()
                        }
                    }
                }
            }
        }
        after(0.012 + duration) {
            guard generation == self.generation else { return }
            progress.animationDone = true
            self.panel.ignoresMouseEvents = true
            finishIfReady()
        }
        // Never leave the overlay up because an app or the screen picture is slow.
        after(duration + 1.0) { finish(false) }
    }

    /// Stops a transition partway; its windows are already where it was taking them.
    func cancel() {
        generation += 1
        panel.orderOut(nil)
        host.sublayers = nil
    }

    private func dissolve(_ generation: Int, duration: TimeInterval) {
        guard generation == self.generation else { return }
        let finish = { [weak self] in
            guard let self, generation == self.generation, self.panel.isVisible else { return }
            self.panel.orderOut(nil)
            self.host.sublayers = nil
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { finish() }
        })
        // In case the completion never comes: an invisible overlay must not linger over the screen.
        after(duration + 0.2) { finish() }
    }
}

/// Runs `body` on the main thread after `delay` seconds.
@MainActor
func after(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        MainActor.assumeIsolated { body() }
    }
}
