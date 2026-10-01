import Foundation
import NetworkModel
import WorkspaceChangeControl

enum AppBootstrapOutcome: Equatable {
    case ready(SyncReceipt)
    case attention(SyncReceipt)
    case offline(String)
}

@MainActor
protocol AppBootstrapServing: AnyObject {
    func start() async -> AppBootstrapOutcome
    func synchronizeForeground() async -> AppBootstrapOutcome
    func stop() async
}

/// Production bootstrap is injected with the account/workspace activation and
/// teardown operations owned by application composition. The sync coordinator
/// cannot run until activation succeeds, and teardown always revokes the
/// current account-scoped lease before the app drops its feature graph.
@MainActor
final class ProductionAppBootstrapService: AppBootstrapServing {
    private let activateWorkspace: () async throws -> Void
    private let syncCoordinator: any SyncCoordinator
    private let invalidateWorkspace: () async -> Void
    private var activated = false

    init(
        activateWorkspace: @escaping () async throws -> Void,
        syncCoordinator: any SyncCoordinator,
        invalidateWorkspace: @escaping () async -> Void
    ) {
        self.activateWorkspace = activateWorkspace
        self.syncCoordinator = syncCoordinator
        self.invalidateWorkspace = invalidateWorkspace
    }

    func start() async -> AppBootstrapOutcome {
        do {
            try await activateWorkspace()
            activated = true
            return await synchronizeForeground()
        } catch {
            activated = false
            return .offline(error.localizedDescription)
        }
    }

    func synchronizeForeground() async -> AppBootstrapOutcome {
        guard activated else {
            return .offline("No verified account-scoped workspace is active.")
        }
        return Self.outcome(for: await syncCoordinator.synchronizeForeground())
    }

    func stop() async {
        guard activated else { return }
        activated = false
        await invalidateWorkspace()
    }

    private static func outcome(for receipt: SyncReceipt) -> AppBootstrapOutcome {
        guard !receipt.failures.isEmpty else { return .ready(receipt) }
        if receipt.failures.contains(where: { $0.category == .accountUnavailable }) {
            return .offline(receipt.failures.map(\.message).joined(separator: " "))
        }
        return .attention(receipt)
    }
}

@MainActor
final class UnconfiguredAppBootstrapService: AppBootstrapServing {
    private let message: String

    init(message: String = "CloudKit workspace setup has not been configured.") {
        self.message = message
    }

    func start() async -> AppBootstrapOutcome {
        .offline(message)
    }

    func synchronizeForeground() async -> AppBootstrapOutcome {
        .offline(message)
    }

    func stop() async {}
}
