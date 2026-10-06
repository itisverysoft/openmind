import Foundation

/// Explicit stacking commands. New items are created on top; otherwise the
/// order changes solely through these operations — never via selection.
enum ArrangeOperation: CaseIterable {
    case bringToFront
    case bringForward
    case sendBackward
    case sendToBack

    var title: String {
        switch self {
        case .bringToFront:  return "Bring to Front"
        case .bringForward:  return "Bring Forward"
        case .sendBackward:  return "Send Backward"
        case .sendToBack:    return "Send to Back"
        }
    }

    /// SF Symbol used in menus.
    var symbol: String {
        switch self {
        case .bringToFront:  return "arrow.up.to.line"
        case .bringForward:  return "arrow.up"
        case .sendBackward:  return "arrow.down"
        case .sendToBack:    return "arrow.down.to.line"
        }
    }
}

/// Returns the new bottom→top order of IDs after applying `operation`.
///
/// - Parameters:
///   - sortedIDs: current order, bottom first.
///   - selectedIDs: the items to move; unknown IDs are ignored.
/// - Returns: the reordered IDs, or `sortedIDs` unchanged when the
///   selection is empty or the operation is a no-op (already at the limit).
func arrangedOrder(sortedIDs: [UUID],
                   selectedIDs: Set<UUID>,
                   operation: ArrangeOperation) -> [UUID] {
    let selected = sortedIDs.filter { selectedIDs.contains($0) }
    guard !selected.isEmpty else { return sortedIDs }
    let selectedSet = Set(selected)

    switch operation {
    case .bringToFront:
        let rest = sortedIDs.filter { !selectedSet.contains($0) }
        let result = rest + selected
        return result == sortedIDs ? sortedIDs : result
    case .sendToBack:
        let rest = sortedIDs.filter { !selectedSet.contains($0) }
        let result = selected + rest
        return result == sortedIDs ? sortedIDs : result
    case .bringForward:
        // Simultaneous one-step rise: top-down, each selected item swaps
        // with the unselected item directly above it. Adjacent selected
        // items travel together without leapfrogging.
        var order = sortedIDs
        for i in stride(from: order.count - 1, through: 0, by: -1) {
            if selectedSet.contains(order[i]),
               i + 1 < order.count,
               !selectedSet.contains(order[i + 1]) {
                order.swapAt(i, i + 1)
            }
        }
        return order
    case .sendBackward:
        // Mirror image: bottom-up, each selected item swaps with the
        // unselected item directly below it.
        var order = sortedIDs
        for i in 0..<order.count {
            if selectedSet.contains(order[i]),
               i - 1 >= 0,
               !selectedSet.contains(order[i - 1]) {
                order.swapAt(i, i - 1)
            }
        }
        return order
    }
}
