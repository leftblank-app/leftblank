import Foundation

/// Admits shared holders together and exclusive holders alone, strictly in arrival order.
/// A waiting exclusive holder blocks later shared ones, so writes are never starved.
@MainActor
final class AgentToolGate {
    private(set) var shared = 0
    private(set) var exclusive = false
    private(set) var waiters: [(id: UUID, exclusive: Bool, continuation: CheckedContinuation<Bool, Never>)] = []

    /// Returns false, without holding the gate, when the caller is cancelled while waiting.
    func acquire(exclusive wantsExclusive: Bool) async -> Bool {
        let free = wantsExclusive ? !exclusive && shared == 0 : !exclusive
        if waiters.isEmpty, free {
            take(exclusive: wantsExclusive)
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, wantsExclusive, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.drop(id) }
        }
    }

    func release(exclusive held: Bool) {
        if held {
            exclusive = false
        } else {
            shared -= 1
        }
        admit()
    }

    private func take(exclusive wantsExclusive: Bool) {
        if wantsExclusive {
            exclusive = true
        } else {
            shared += 1
        }
    }

    private func drop(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
        // A cancelled exclusive waiter may have been holding back shared ones behind it.
        admit()
    }

    private func admit() {
        while let next = waiters.first, !exclusive, !next.exclusive || shared == 0 {
            waiters.removeFirst()
            take(exclusive: next.exclusive)
            next.continuation.resume(returning: true)
            if next.exclusive {
                return
            }
        }
    }
}
