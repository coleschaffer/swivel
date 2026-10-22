import Foundation

// Layout tests. Run with ./build.sh --test

var failures = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message())")
    }
}

/// Screen order, left to right, with the center in brackets: "1 2 [3] 4 5".
func describe(_ row: Row) -> String {
    let center = row.center.map { "[\($0)]" } ?? "[]"
    return (row.left.reversed().map(String.init) + [center] + row.right.map(String.init)).joined(separator: " ")
}

// Five windows spread across a 5120-wide screen; 3 has focus.
let spread: [(id: WindowID, midX: CGFloat)] = [(1, 100), (2, 900), (3, 2500), (4, 3500), (5, 4800)]
let start = Row(arranging: spread, center: 3, screenMidX: 2560)
check(describe(start) == "1 2 [3] 4 5", "keeps screen order: \(describe(start))")

// Without focus, the window nearest the middle takes the center.
check(Row(arranging: spread, center: nil, screenMidX: 2560).center == 3, "nearest the middle")

// Everything piled on one side gets balanced by wrapping the outermost windows around.
let piled = Row(arranging: [(1, 100), (2, 200), (3, 300), (4, 400), (5, 4000)], center: 5, screenMidX: 2560)
check(describe(piled) == "3 4 [5] 1 2", "balanced: \(describe(piled))")

do {
    var row = start
    row.focus(5, style: .swap)
    check(describe(row) == "1 2 [5] 4 3", "swap trades places: \(describe(row))")
    row.focus(3, style: .swap)
    check(describe(row) == "1 2 [3] 4 5", "swapping back restores: \(describe(row))")
}

do {
    var row = start
    row.focus(5, style: .carousel)
    check(describe(row) == "3 4 [5] 1 2", "carousel rotates: \(describe(row))")
    row.focus(3, style: .carousel)
    check(describe(row) == "1 2 [3] 4 5", "carousel back: \(describe(row))")
}

do {
    var row = start
    row.rotate(by: 1)
    check(describe(row) == "2 3 [4] 5 1", "step right: \(describe(row))")
    row.rotate(by: -2)
    check(describe(row) == "5 1 [2] 3 4", "two steps left: \(describe(row))")
}

do {
    var row = start
    row.insertAtCenter(9)
    check(describe(row) == "1 2 [9] 3 4 5", "new focused window takes the center: \(describe(row))")
    row.insertAtCenter(8)
    check(describe(row) == "1 2 9 [8] 3 4 5", "old center goes to the emptier side: \(describe(row))")
}

do {
    var row = start
    row.insertAtEdge(9)
    check(describe(row) == "1 2 [3] 4 5 9", "background window joins at the edge: \(describe(row))")
    row.insertAtEdge(8)
    check(describe(row) == "8 1 2 [3] 4 5 9", "then the other edge: \(describe(row))")
}

do {
    var row = start
    row.remove([4])
    check(describe(row) == "1 2 [3] 5", "closing a side window closes the gap: \(describe(row))")
    row.remove([5])
    check(describe(row) == "2 [3] 1", "and rebalances when a side runs short: \(describe(row))")
}

do {
    var row = start
    row.remove([3], successor: 1)
    check(describe(row) == "2 [1] 4 5", "closing the center hands it to the newly focused window: \(describe(row))")
    var other = start
    other.remove([3])
    check(describe(other) == "1 2 [4] 5", "or to the nearest neighbor: \(describe(other))")
    var empty = start
    empty.remove([1, 2, 3, 4, 5])
    check(empty.isEmpty && empty.all.isEmpty, "removing everything empties the row")
}

// Frames on the Odyssey G9: 5120 x 1440 with a 25pt menu bar.
let area = CGRect(x: 0, y: 25, width: 5120, height: 1415)
let settings = LayoutSettings(centerFraction: 0.35, gap: 8, minColumnWidth: 480)

func checkFrames(_ row: Row, _ label: String) {
    let frames = row.frames(in: area, settings: settings)
    check(frames.count == row.all.count, "\(label): every window placed")
    guard let center = row.center, let c = frames[center] else { return check(false, "\(label): no center") }
    check(abs(c.midX - area.midX) <= 1, "\(label): center window is centered (\(c.midX))")
    check(c.width == 1792, "\(label): center width \(c.width)")
    let inset = area.insetBy(dx: settings.gap, dy: settings.gap)
    for (id, frame) in frames {
        check(inset.contains(frame), "\(label): \(id) inside the screen \(frame)")
        check(frame.width >= 100 && frame.height >= 100, "\(label): \(id) has a usable size \(frame)")
    }
    for id in row.left { check(frames[id]!.maxX <= c.minX - settings.gap, "\(label): \(id) left of center") }
    for id in row.right { check(frames[id]!.minX >= c.maxX + settings.gap, "\(label): \(id) right of center") }
    let all = Array(frames)
    for i in all.indices {
        for j in all.indices where j > i {
            let overlap = all[i].value.intersection(all[j].value)
            check(overlap.isNull || overlap.width * overlap.height < 1, "\(label): \(all[i].key) overlaps \(all[j].key)")
        }
    }
    // Inner windows on each side are at least as wide as outer ones.
    for side in [row.left, row.right] where side.count > 1 {
        for (a, b) in zip(side, side.dropFirst()) {
            check(frames[a]!.width * frames[a]!.height >= frames[b]!.width * frames[b]!.height - 1,
                  "\(label): inner \(a) at least as big as outer \(b)")
        }
    }
}

checkFrames(Row(center: 1, left: [], right: []), "one window")
checkFrames(Row(center: 1, left: [], right: [2]), "two windows")
checkFrames(start, "five windows")
checkFrames(Row(center: 1, left: [2, 3, 4], right: [5, 6, 7]), "seven windows")
checkFrames(Row(center: 1, left: [2, 3, 4, 5, 6], right: [7, 8, 9, 10, 11]), "eleven windows")

do {
    let frames = start.frames(in: area, settings: settings)
    check(frames[2]!.maxX == frames[3]!.minX - 8, "side windows hug the center with one gap")
    check(frames[1]!.minX >= 8 && frames[1]!.minX <= 10, "outer window reaches the screen edge: \(frames[1]!)")
    check(frames[4]!.width == frames[2]!.width, "both sides get the same width")
}

if failures == 0 {
    print("All layout tests passed")
} else {
    print("\(failures) failure(s)")
    exit(1)
}
