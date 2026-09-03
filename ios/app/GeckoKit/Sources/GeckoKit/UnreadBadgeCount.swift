import Foundation

/// Sums per-conversation unread counts for the app icon badge.
/// Invalid negative values are ignored and an impossible overflow saturates.
func unreadBadgeCount<Counts: Sequence>(_ counts: Counts) -> Int where Counts.Element == Int {
    var total = 0
    for count in counts where count > 0 {
        let (sum, overflow) = total.addingReportingOverflow(count)
        if overflow { return Int.max }
        total = sum
    }
    return total
}
