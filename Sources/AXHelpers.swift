import AppKit
import ApplicationServices

/// Private but long-stable: maps an Accessibility window to its window-server id.
/// Every macOS window manager relies on it (Rectangle, Amethyst, yabai, AeroSpace).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success ? value : nil
    }

    func string(_ name: String) -> String? { attribute(name) as? String }

    func bool(_ name: String) -> Bool? { attribute(name) as? Bool }

    func element(_ name: String) -> AXUIElement? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ name: String) -> [AXUIElement] {
        guard let values = attribute(name) as? [CFTypeRef] else { return [] }
        return values.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    var windowID: WindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var frame: CGRect? {
        guard let position = attribute(kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success && settable.boolValue
    }

    func set(_ name: String, _ value: CFTypeRef) {
        _ = AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    func setPosition(_ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) { set(kAXPositionAttribute, value) }
    }

    func setSize(_ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { set(kAXSizeAttribute, value) }
    }

    /// Moves and resizes in the order that keeps the window inside its old or new spot the whole time:
    /// a growing window moves first, a shrinking one shrinks first. The last call fixes up anything the
    /// system adjusted to keep the window on screen.
    func setFrame(_ frame: CGRect, growing: Bool) {
        if growing {
            setPosition(frame.origin)
            setSize(frame.size)
            setPosition(frame.origin)
        } else {
            setSize(frame.size)
            setPosition(frame.origin)
            setSize(frame.size)
        }
    }
}

extension NSScreen {
    /// `frame` in Accessibility coordinates: origin at the top-left of the main display, y growing downward.
    var axFrame: CGRect { Self.flipped(frame) }
    var axVisibleFrame: CGRect { Self.flipped(visibleFrame) }

    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private static func flipped(_ rect: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    /// This rect (Accessibility coordinates) in the bottom-left-origin coordinates of a layer covering `screen`.
    func flipped(within screen: CGRect) -> CGRect {
        CGRect(x: minX - screen.minX, y: screen.maxY - maxY, width: width, height: height)
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func interpolated(to other: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: (minX + (other.minX - minX) * t).rounded(), y: (minY + (other.minY - minY) * t).rounded(),
               width: (width + (other.width - width) * t).rounded(), height: (height + (other.height - height) * t).rounded())
    }
}
