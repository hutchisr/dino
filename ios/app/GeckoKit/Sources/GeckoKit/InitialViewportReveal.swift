/// Tracks the one event that makes an initially hidden message viewport safe to reveal.
/// Row geometry is deliberately not part of this state: geometry can arrive after the
/// programmatic bottom scroll, especially on Mac Catalyst.
struct InitialViewportReveal: Equatable {
    private(set) var isReady = false

    mutating func initialScrollCompleted() {
        isReady = true
    }
}
