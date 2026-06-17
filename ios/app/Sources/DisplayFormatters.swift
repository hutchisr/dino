import Foundation

@MainActor
enum GeckoDisplayFormatters {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func conversationTime(_ date: Date) -> String {
        if date.timeIntervalSince1970 == 0 { return "" }
        if Calendar.current.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        return shortDateFormatter.string(from: date)
    }

    static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return mediumDateFormatter.string(from: date)
    }

    static func fileSize(_ bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        return byteFormatter.string(fromByteCount: Int64(bytes))
    }
}
