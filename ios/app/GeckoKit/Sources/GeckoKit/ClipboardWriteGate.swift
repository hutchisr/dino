struct ClipboardWriteGate {
    struct Ticket {
        fileprivate let generation: UInt
        fileprivate let changeCount: Int
    }

    private var generation: UInt = 0

    mutating func begin(changeCount: Int) -> Ticket {
        generation &+= 1
        return Ticket(generation: generation, changeCount: changeCount)
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        ticket.generation == generation
    }

    func permits(_ ticket: Ticket, changeCount: Int) -> Bool {
        isCurrent(ticket) && ticket.changeCount == changeCount
    }
}
