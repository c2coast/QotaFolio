import Foundation

public nonisolated func reorderedIDs(
    _ current: [AccountID],
    moving id: AccountID,
    toGap gap: Int
) -> [AccountID] {
    guard let from = current.firstIndex(of: id) else { return current }
    let boundedGap = min(max(gap, 0), current.count)
    let insertionIndex = boundedGap > from ? boundedGap - 1 : boundedGap
    guard insertionIndex != from else { return current }

    var result = current
    result.remove(at: from)
    result.insert(id, at: insertionIndex)
    return result
}

/// Where a carried card lands.
///
/// `heights` are the visible rows in their current order, `gap` the space between them, and
/// the row at `index` has been carried `translation` points (down is positive). The answer is
/// the gap `reorderedIDs(_:moving:toGap:)` takes — 0 before the first row, `heights.count`
/// after the last. The card takes the slot whose centre is nearest its own, so a neighbour
/// gives way once the card is more than half-way across it, and not before; a tall neighbour
/// asks for a longer carry than a short one.
public nonisolated func liftedGap(
    from index: Int,
    translation: Double,
    heights: [Double],
    gap: Double
) -> Int {
    guard heights.indices.contains(index) else { return index }
    let carried = heights[index]
    var top = 0.0
    for row in 0..<index {
        top += heights[row] + gap
    }
    let centre = top + carried / 2 + translation

    // The other rows in order; the carried card can sit before any of them or after the last.
    var others = heights
    others.remove(at: index)
    var slotTop = 0.0
    var nearest = 0
    var nearestDistance = Double.infinity
    for slot in 0...others.count {
        let distance = abs(slotTop + carried / 2 - centre)
        if distance < nearestDistance {
            nearestDistance = distance
            nearest = slot
        }
        if slot < others.count {
            slotTop += others[slot] + gap
        }
    }
    return nearest > index ? nearest + 1 : nearest
}
