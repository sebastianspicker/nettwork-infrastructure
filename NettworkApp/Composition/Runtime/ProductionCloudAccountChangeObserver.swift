import CloudKit
import Foundation

/// Forwards `.CKAccountChanged` to the launch controller on the main actor.
/// It only signals: the controller closes the account-scoped graph and runs a
/// fresh activation, which verifies the current iCloud account before any sync.
@MainActor
final class ProductionCloudAccountChangeObserver {
    private let center: NotificationCenter
    private var token: (any NSObjectProtocol)?

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        guard token == nil else { return }
        token = center.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { _ in
            Task { @MainActor in onChange() }
        }
    }

    func stop() {
        if let token { center.removeObserver(token) }
        token = nil
    }
}
