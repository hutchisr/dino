import Foundation

public func typingIndicatorLabel(names: [String]) -> String {
    var seen = Set<String>()
    let cleaned = names.compactMap { name -> String? in
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
        return trimmed
    }

    switch cleaned.count {
    case 0:
        return "typing..."
    case 1:
        return "\(cleaned[0]) is typing..."
    case 2:
        return "\(cleaned[0]) and \(cleaned[1]) are typing..."
    case 3:
        return "\(cleaned[0]), \(cleaned[1]), and \(cleaned[2]) are typing..."
    default:
        return "\(cleaned[0]), \(cleaned[1]), and \(cleaned.count - 2) others are typing..."
    }
}
