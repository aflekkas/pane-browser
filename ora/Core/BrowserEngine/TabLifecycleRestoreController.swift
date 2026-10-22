import Foundation

enum TabLifecycleRestoreOutcome: Equatable {
    case restored
    case invalid
    case superseded
}

/// A queued restore is not a successful restore. Navigation supersedes it even
/// before privacy preparation completes, and every request completes once.
final class TabLifecycleRestoreController {
    private struct Pending {
        let data: Data
        let completion: (TabLifecycleRestoreOutcome) -> Void
    }

    private var pending: Pending?

    func enqueue(_ data: Data, completion: @escaping (TabLifecycleRestoreOutcome) -> Void) {
        supersede()
        guard TabInteractionStateCodec.isValid(data) else {
            completion(.invalid)
            return
        }
        pending = Pending(data: data, completion: completion)
    }

    func applyIfReady(_ ready: Bool, assignAndVerify: (Data) -> Bool) -> Bool {
        guard ready, let request = pending else { return false }
        pending = nil
        request.completion(assignAndVerify(request.data) ? .restored : .invalid)
        return true
    }

    func supersede() {
        let request = pending
        pending = nil
        request?.completion(.superseded)
    }
}
