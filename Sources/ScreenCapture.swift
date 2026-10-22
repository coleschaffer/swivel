import AppKit
import ScreenCaptureKit

/// Takes the picture that transitions animate. Needs Screen Recording permission; without it,
/// Swivel snaps windows into place instead. Pictures stay in memory for the length of one transition.
@MainActor
final class ScreenCapture {
    private var filter: SCContentFilter?
    private var filterDisplay: CGDirectDisplayID = 0
    private var loading: Task<Void, Never>?
    private static var allowed: (value: Bool, checked: Date)?

    static var isAllowed: Bool {
        if let allowed, Date().timeIntervalSince(allowed.checked) < 2 { return allowed.value }
        let value = CGPreflightScreenCaptureAccess()
        allowed = (value, Date())
        return value
    }

    /// Looks the display up ahead of time; doing it mid-transition would add a noticeable delay.
    func prepare(for screen: NSScreen, force: Bool = false) {
        guard Self.isAllowed, loading == nil else { return }
        guard force || filter == nil || filterDisplay != screen.displayID else { return }
        let displayID = screen.displayID
        loading = Task { [weak self] in
            // All windows, not just visible ones: Swivel's overlay is hidden between transitions but must
            // still be left out of every picture, or a picture taken mid-transition would show the overlay.
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
               let display = content.displays.first(where: { $0.displayID == displayID }) {
                let pid = ProcessInfo.processInfo.processIdentifier
                let own = content.windows.filter { $0.owningApplication?.processID == pid }
                self?.filter = SCContentFilter(display: display, excludingWindows: own)
                self?.filterDisplay = displayID
                Log.write("capture: ready, leaving out \(own.count) Swivel windows")
            } else {
                Log.write("capture: couldn't look up the display")
            }
            self?.loading = nil
        }
    }

    /// `rect` (Accessibility coordinates) as it looks right now.
    func capture(_ rect: CGRect, on screen: NSScreen) async -> CGImage? {
        guard Self.isAllowed else { return nil }
        if filter == nil || filterDisplay != screen.displayID {
            prepare(for: screen)
            await loading?.value
        }
        guard let filter else { return nil }
        let config = SCStreamConfiguration()
        let origin = screen.axFrame.origin
        config.sourceRect = CGRect(x: rect.minX - origin.x, y: rect.minY - origin.y, width: rect.width, height: rect.height)
        config.width = Int(rect.width * screen.backingScaleFactor)
        config.height = Int(rect.height * screen.backingScaleFactor)
        config.showsCursor = false
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            Log.write("capture failed: \(error.localizedDescription)")
            self.filter = nil
            return nil
        }
    }
}

/// The desktop picture, shown in the slots windows are leaving during a transition.
@MainActor
enum Wallpaper {
    private static var cache: (url: URL, image: CGImage)?

    static func image(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let cache, cache.url == url { return cache.image }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 5120,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        cache = (url, image)
        return image
    }
}
