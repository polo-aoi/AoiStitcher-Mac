import Foundation

/// Original guillotine layouts composed from row/column split primitives.
nonisolated enum GridCollageTemplates {
    static let supportedCounts = 1...16
    static let maximumPhotoCount = 16
    static let all: [CollageTemplate] = supportedCounts.flatMap { makeTemplates(count: $0) }

    static func templates(for count: Int) -> [CollageTemplate] { all.filter { $0.slotCount == count } }

    private static func makeTemplates(count: Int) -> [CollageTemplate] {
        guard count > 1 else {
            return [CollageTemplate(id: "grid-1-single", name: "单张", slotCount: 1, rootNode: .slot(slotId: "slot-1"))]
        }
        var nodeIndex = 0
        func split(_ direction: CollageSplitDirection, _ children: [SplitNode], _ ratios: [CGFloat]? = nil) -> SplitNode {
            nodeIndex += 1
            return .split(id: "split-\(nodeIndex)", direction: direction,
                          ratios: ratios ?? Array(repeating: 1 / CGFloat(children.count), count: children.count), children: children)
        }
        func slot(_ number: Int) -> SplitNode { .slot(slotId: "slot-\(number)") }
        func strip(_ numbers: [Int], _ direction: CollageSplitDirection) -> SplitNode {
            guard numbers.count > 1 else { return slot(numbers[0]) }
            // Large sets form balanced groups instead of creating impractically
            // narrow 16-way divisions. Up to nine columns remain available.
            if numbers.count <= 9 { return split(direction, numbers.map(slot)) }
            let midpoint = (numbers.count + 1) / 2
            let cross: CollageSplitDirection = direction == .horizontal ? .vertical : .horizontal
            return split(cross, [strip(Array(numbers.prefix(midpoint)), direction), strip(Array(numbers.dropFirst(midpoint)), direction)])
        }
        func grid(_ numbers: [Int], columns: Int, direction: CollageSplitDirection = .vertical) -> SplitNode {
            let columns = max(1, columns)
            let rows = stride(from: 0, to: numbers.count, by: columns).map { offset in
                strip(Array(numbers[offset..<min(numbers.count, offset + columns)]), direction == .vertical ? .horizontal : .vertical)
            }
            return rows.count == 1 ? rows[0] : split(direction, rows)
        }
        let numbers = Array(1...count)
        let remaining = Array(numbers.dropFirst())
        let columns = max(2, Int(ceil(sqrt(Double(count)))))
        let definitions: [(String, String, SplitNode)] = [
            ("balanced", "均衡网格", grid(numbers, columns: columns)),
            ("rows", "横向等分", strip(numbers, .horizontal)),
            ("columns", "纵向等分", strip(numbers, .vertical)),
            ("hero-left", "左侧主图", split(.horizontal, [slot(1), grid(remaining, columns: max(1, Int(ceil(sqrt(Double(count - 1))))))], [0.55, 0.45])),
            ("hero-top", "上方主图", split(.vertical, [slot(1), grid(remaining, columns: min(4, max(2, count - 1)))], [0.5, 0.5])),
            ("alternating", "错落分组", split(.vertical, [strip(Array(numbers.prefix(max(1, count / 2))), .horizontal),
                                                        strip(Array(numbers.dropFirst(max(1, count / 2))), .horizontal)], [0.4, 0.6]))
        ]
        // Tiny counts cannot have six topologically unique axis-only trees. Their
        // weight variants still provide visibly distinct, valid compositions.
        return definitions.map { key, name, node in
            CollageTemplate(id: "grid-\(count)-\(key)", name: name, slotCount: count, rootNode: node)
        }
    }
}
