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
///
/// A foreground sync after a failed activation, or after the session lifecycle
/// invalidated its lease, re-runs the full activation, which re-verifies the
/// assembled account and membership before any sync. A transient verification
/// failure keeps the lease, so the coordinator itself re-verifies next time.
@MainActor
final class ProductionAppBootstrapService: AppBootstrapServing {
    private let activateWorkspace: () async throws -> Void
    private let syncCoordinator: any SyncCoordinator
    private let invalidateWorkspace: () async -> Void
    private let hasActiveWorkspaceSession: () async -> Bool
    private var started = false
    private var activated = false

    init(
        activateWorkspace: @escaping () async throws -> Void,
        syncCoordinator: any SyncCoordinator,
        invalidateWorkspace: @escaping () async -> Void,
        hasActiveWorkspaceSession: @escaping () async -> Bool = { true }
    ) {
        self.activateWorkspace = activateWorkspace
        self.syncCoordinator = syncCoordinator
        self.invalidateWorkspace = invalidateWorkspace
        self.hasActiveWorkspaceSession = hasActiveWorkspaceSession
    }

    func start() async -> AppBootstrapOutcome {
        started = true
        return await activateAndSynchronize()
    }

    func synchronizeForeground() async -> AppBootstrapOutcome {
        guard started else {
            return .offline("No verified account-scoped workspace is active.")
        }
        guard activated, await hasActiveWorkspaceSession() else {
            return await activateAndSynchronize()
        }
        return Self.outcome(for: await syncCoordinator.synchronizeForeground())
    }

    func stop() async {
        started = false
        guard activated else { return }
        activated = false
        await invalidateWorkspace()
    }

    private func activateAndSynchronize() async -> AppBootstrapOutcome {
        do {
            try await activateWorkspace()
        } catch {
            activated = false
            return .offline(error.localizedDescription)
        }
        guard started else {
            // stop() ran while activation was in flight; never leave a lease open.
            await invalidateWorkspace()
            return .offline("No verified account-scoped workspace is active.")
        }
        activated = true
        return Self.outcome(for: await syncCoordinator.synchronizeForeground())
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
