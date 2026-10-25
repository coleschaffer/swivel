import CoreGraphics

/// A window's id in the window server (`CGWindowID`). It stays the same for the window's lifetime.
typealias WindowID = UInt32

/// What happens when you focus a window that isn't in the center.
enum FocusStyle: String, CaseIterable {
    /// The focused window and the center window trade places. Nothing else moves.
    case swap
    /// The whole row shifts along, keeping every window's neighbors, until the focused one is centered.
    case carousel
}

/// The tiled windows: one in the middle of the screen, the rest split across the two sides.
/// Both sides are listed from the center outward.
struct Row: Equatable {
    private(set) var center: WindowID?
    private(set) var left: [WindowID] = []
    private(set) var right: [WindowID] = []

    init() {}

    init(center: WindowID?, left: [WindowID], right: [WindowID]) {
        self.center = center
        self.left = left
        self.right = right
    }

    /// Starts a row from where the windows already are, so nothing jumps across the screen:
    /// windows left of the middle stay on the left, windows right of it stay on the right.
    init(arranging windows: [(id: WindowID, midX: CGFloat)], center preferred: WindowID?, screenMidX: CGFloat) {
        guard let nearest = windows.min(by: { abs($0.midX - screenMidX) < abs($1.midX - screenMidX) }) else { return }
        let center = preferred.flatMap { id in windows.contains { $0.id == id } ? id : nil } ?? nearest.id
        let others = windows.filter { $0.id != center }
        self.center = center
        left = others.filter { $0.midX < screenMidX }.sorted { $0.midX > $1.midX }.map { $0.id }
        right = others.filter { $0.midX >= screenMidX }.sorted { $0.midX < $1.midX }.map { $0.id }
        rebalance()
    }

    var all: [WindowID] { (center.map { [$0] } ?? []) + left + right }
    var isEmpty: Bool { center == nil }

    func contains(_ id: WindowID) -> Bool {
        center == id || left.contains(id) || right.contains(id)
    }

    /// Puts `id` in the center.
    mutating func focus(_ id: WindowID, style: FocusStyle) {
        guard let old = center, old != id else { return }
        switch style {
        case .swap:
            if let i = left.firstIndex(of: id) {
                left[i] = old
                center = id
            } else if let i = right.firstIndex(of: id) {
                right[i] = old
                center = id
            }
        case .carousel:
            if let i = ring.firstIndex(of: id) { rotate(by: i) }
        }
    }

    /// Shifts the whole row: +1 brings the nearest window on the right into the center, -1 the nearest on the left.
    mutating func rotate(by steps: Int) {
        let ring = self.ring
        guard ring.count > 1 else { return }
        let k = ((steps % ring.count) + ring.count) % ring.count
        let rotated = Array(ring[k...] + ring[..<k])
        let rightCount = right.count
        center = rotated[0]
        right = Array(rotated.dropFirst().prefix(rightCount))
        left = Array(rotated.dropFirst(1 + rightCount).reversed())
    }

    /// Clockwise around the screen: the center, the right side outward, then the left side back in.
    private var ring: [WindowID] { (center.map { [$0] } ?? []) + right + left.reversed() }

    /// A new window that has focus takes the center, and the old center steps aside into the emptier side.
    mutating func insertAtCenter(_ id: WindowID) {
        guard !contains(id) else { return }
        if let old = center {
            if right.count <= left.count { right.insert(old, at: 0) } else { left.insert(old, at: 0) }
        }
        center = id
    }

    /// A new window without focus joins at the outer edge of the emptier side.
    mutating func insertAtEdge(_ id: WindowID) {
        guard !contains(id) else { return }
        if center == nil {
            center = id
        } else if right.count <= left.count {
            right.append(id)
        } else {
            left.append(id)
        }
    }

    /// Takes windows out. If the center goes, `successor` moves in when it's in the row;
    /// otherwise the nearest window on the right (or left) slides over.
    mutating func remove(_ gone: Set<WindowID>, successor: WindowID? = nil) {
        left.removeAll { gone.contains($0) }
        right.removeAll { gone.contains($0) }
        if let old = center, gone.contains(old) {
            center = nil
            if let s = successor, let i = left.firstIndex(of: s) {
                center = left.remove(at: i)
            } else if let s = successor, let i = right.firstIndex(of: s) {
                center = right.remove(at: i)
            } else if !right.isEmpty {
                center = right.removeFirst()
            } else if !left.isEmpty {
                center = left.removeFirst()
            }
        }
        rebalance()
    }

    /// Keeps the sides within one window of each other by wrapping an outer window around to the other side.
    private mutating func rebalance() {
        while right.count > left.count + 1 { left.append(right.removeLast()) }
        while left.count > right.count + 1 { right.append(left.removeLast()) }
    }
}

extension CGRect {
    /// Covers nearly all of `area`, the way a zoomed or full-screen window does. Swivel never lays a window
    /// out this big (the center tops out at 80% of the width), so a window like this was made big on purpose.
    func fills(_ area: CGRect) -> Bool {
        width >= area.width * 0.9 && height >= area.height * 0.9
    }
}

struct LayoutSettings: Equatable {
    /// Share of the screen width the center window gets.
    var centerFraction: CGFloat = 0.35
    /// Space between windows and around the screen edges, in points.
    var gap: CGFloat = 8
    /// Side windows narrower than this are stacked into rows instead of squeezed into more columns.
    var minColumnWidth: CGFloat = 480
}

extension Row {
    /// Where every window goes. `area` and the results use Accessibility coordinates:
    /// origin at the top-left of the main display, y growing downward.
    func frames(in area: CGRect, settings: LayoutSettings) -> [WindowID: CGRect] {
        guard let center else { return [:] }
        let gap = settings.gap
        let usable = area.insetBy(dx: gap, dy: gap)
        let centerWidth = min(usable.width, (area.width * settings.centerFraction).rounded())
        let centerFrame = CGRect(x: (area.midX - centerWidth / 2).rounded(), y: usable.minY,
                                 width: centerWidth, height: usable.height)
        let leftArea = CGRect(x: usable.minX, y: usable.minY,
                              width: max(0, centerFrame.minX - gap - usable.minX), height: usable.height)
        let rightArea = CGRect(x: centerFrame.maxX + gap, y: usable.minY,
                               width: max(0, usable.maxX - centerFrame.maxX - gap), height: usable.height)

        var frames = [center: centerFrame]
        for (id, frame) in Row.columns(left, in: leftArea, gap: gap, minWidth: settings.minColumnWidth, growsLeft: true) {
            frames[id] = frame
        }
        for (id, frame) in Row.columns(right, in: rightArea, gap: gap, minWidth: settings.minColumnWidth, growsLeft: false) {
            frames[id] = frame
        }
        return frames
    }

    /// Lays `ids` out in columns from the center outward. Inner columns are filled first and get the
    /// fewest rows, so the windows nearest the center stay the biggest.
    private static func columns(_ ids: [WindowID], in area: CGRect, gap: CGFloat, minWidth: CGFloat,
                                growsLeft: Bool) -> [(WindowID, CGRect)] {
        guard !ids.isEmpty, area.width > 0 else { return [] }
        let fit = Int((area.width + gap) / (minWidth + gap))
        let columnCount = max(1, min(ids.count, fit))
        let width = ((area.width - gap * CGFloat(columnCount - 1)) / CGFloat(columnCount)).rounded(.down)
        let base = ids.count / columnCount
        let extra = ids.count % columnCount

        var result: [(WindowID, CGRect)] = []
        var next = 0
        for column in 0..<columnCount {
            let rows = base + (column >= columnCount - extra ? 1 : 0)
            let x = growsLeft
                ? area.maxX - CGFloat(column + 1) * width - CGFloat(column) * gap
                : area.minX + CGFloat(column) * (width + gap)
            let height = ((area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)).rounded(.down)
            for row in 0..<rows {
                let y = area.minY + CGFloat(row) * (height + gap)
                result.append((ids[next], CGRect(x: x, y: y, width: width, height: height)))
                next += 1
            }
        }
        return result
    }
}
