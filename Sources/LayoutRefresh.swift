import Foundation

/// A bounded exit/re-entry of the system overview. Never reopen after an unrelated input,
/// a natural overview exit while queued, or a failed exit. Time uses monotonic uptime.
struct LayoutRefresh {
    enum Command { case dismiss, reopen }
    private enum Phase {
        case idle
        case queued(until: TimeInterval)
        case closing(deadline: TimeInterval, closedAt: TimeInterval?)
        case opening(deadline: TimeInterval)
    }
    private var phase: Phase = .idle

    var isTransitioning: Bool {
        switch phase {
        case .closing, .opening: return true
        default: return false
        }
    }

    mutating func request(at now: TimeInterval) {
        guard !isTransitioning else { return }
        phase = .queued(until: now + 0.2)
    }

    mutating func cancel() { phase = .idle }

    mutating func advance(at now: TimeInterval, overviewVisible: Bool, ready: Bool) -> Command? {
        switch phase {
        case .idle:
            return nil
        case .queued(let until):
            guard overviewVisible else { cancel(); return nil }
            guard ready, now >= until else { return nil }
            phase = .closing(deadline: now + 2, closedAt: nil)
            return .dismiss
        case .closing(let deadline, let closedAt):
            guard now < deadline else { cancel(); return nil }
            if overviewVisible {
                // Someone reopened it while we were waiting: leave their overview alone.
                if closedAt != nil { cancel() }
                return nil
            }
            guard let closedAt else {
                phase = .closing(deadline: deadline, closedAt: now)
                return nil
            }
            guard ready, now - closedAt >= 0.35 else { return nil }
            phase = .opening(deadline: now + 2)
            return .reopen
        case .opening(let deadline):
            if overviewVisible || now >= deadline { cancel() }
            return nil
        }
    }
}

/// A delivered close request is not a closed window (a save prompt may still be open).
/// Require two consecutive positive observations; unknown reads cannot confirm removal.
struct RemovalConfirmation {
    enum Result { case waiting, removed, timedOut }
    let deadline: TimeInterval
    private var absentSamples = 0

    init(now: TimeInterval) { deadline = now + 3 }

    mutating func observe(removed: Bool?, at now: TimeInterval) -> Result {
        guard now < deadline else { return .timedOut }
        absentSamples = removed == true ? absentSamples + 1 : 0
        return absentSamples >= 2 ? .removed : .waiting
    }
}
