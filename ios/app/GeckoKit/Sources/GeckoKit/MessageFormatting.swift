import Foundation

// Pure message-body formatting helpers, shared between the app (compiled in by
// build-app.sh) and GeckoKitTests. No SwiftUI here — the view that consumes
// these (`messageBody`) lives in GeckoApp.swift; this is only the testable logic.

private let messageLinkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

/// Keeps a queued message visibly pending while the core makes another send
/// attempt. A retry reports `sending` before room/encryption readiness can put
/// it straight back to `unsent`; that provisional transition should not make
/// an already-pending row look as though it has left the queue.
func reconciledDeliveryMark(previous: String?, incoming: String) -> String {
    if previous == "unsent", incoming == "sending" { return "unsent" }
    return incoming
}

/// Message text with tappable links (URLs, emails); falls back to plain text.
/// Sets Foundation's native `.link` attribute, which SwiftUI's Text renders as
/// a tappable link.
func linkifiedBody(_ text: String) -> AttributedString {
    var attributed = AttributedString(text)
    guard !text.isEmpty, let detector = messageLinkDetector else { return attributed }
    let full = NSRange(location: 0, length: (text as NSString).length)
    for match in detector.matches(in: text, options: [], range: full) {
        guard let url = match.url,
              let stringRange = Range(match.range, in: text),
              let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
              let upper = AttributedString.Index(stringRange.upperBound, within: attributed)
        else { continue }
        attributed[lower..<upper].link = url
    }
    return attributed
}

/// Split a body into consecutive runs of quoted (leading `>`) and normal lines,
/// so a multi-line quote shares one bar and adjacent normal lines stay together.
func messageRuns(_ text: String) -> [(isQuote: Bool, text: String)] {
    var runs: [(isQuote: Bool, text: String)] = []
    for rawLine in text.components(separatedBy: "\n") {
        let isQuote = rawLine.hasPrefix(">")
        var line = rawLine
        if isQuote {
            line = String(line.dropFirst())
            if line.hasPrefix(" ") { line = String(line.dropFirst()) }
        }
        if let last = runs.last, last.isQuote == isQuote {
            runs[runs.count - 1].text += "\n" + line
        } else {
            runs.append((isQuote, line))
        }
    }
    return runs
}
