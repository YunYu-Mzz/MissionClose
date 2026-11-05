import Foundation

/// Cancellation is checked between AX calls; cancelling never waits for a remote app to reply.
final class WorkCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Main-thread owned, with at most one operation in flight. Slow apps cannot build a queue
/// of obsolete snapshots/actions, and a cancelled result can never restore an old overlay.
final class BackgroundWork<Value> {
    private let queue: DispatchQueue
    private var current: WorkCancellation?

    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }
    var isBusy: Bool { current != nil }

    @discardableResult
    func start(_ operation: @escaping (WorkCancellation) -> Value,
               completion: @escaping (Value) -> Void) -> Bool {
        precondition(Thread.isMainThread)
        guard current == nil else { return false }
        let token = WorkCancellation()
        current = token
        queue.async { [weak self] in
            let value = operation(token)
            DispatchQueue.main.async {
                guard let self else { return }
                self.current = nil
                if !token.isCancelled { completion(value) }
            }
        }
        return true
    }

    func cancel() {
        precondition(Thread.isMainThread)
        current?.cancel()
    }
}
