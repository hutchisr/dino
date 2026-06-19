import Foundation

func redactedIdentifier(_ value: String, visiblePrefix: Int = 6, visibleSuffix: Int = 4) -> String {
    guard !value.isEmpty else { return "<empty>" }

    let prefix = max(0, visiblePrefix)
    let suffix = max(0, visibleSuffix)
    guard value.count > prefix + suffix + 2 else {
        return "<redacted:\(value.count)>"
    }

    return "\(value.prefix(prefix))...\(value.suffix(suffix))"
}
