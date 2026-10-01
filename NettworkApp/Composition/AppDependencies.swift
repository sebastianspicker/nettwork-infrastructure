import Foundation
import NetworkModel
import Observation
import WorkspaceChangeControl

/// Owns bootstrap and synchronization for one composed app runtime. The shell
/// only sees the Presentation-owned `shell` state injected into its environment.
@MainActor
@Observable
final class AppDependencies {
    let shell: WorkspaceShellState
    private(set) var lastSyncReceipt: SyncReceipt?
    private let bootstrapService: any AppBootstrapServing
    private var hasBootstrapped = false

    var syncStatus: WorkspaceShellState.SyncStatus { shell.syncStatus }

    init(
        syncStatus: WorkspaceShellState.SyncStatus = .loading,
        features: AppFeatureRegistry,
        bootstrapService: any AppBootstrapServing
    ) {
        shell = WorkspaceShellState(syncStatus: syncStatus, features: features)
        self.bootstrapService = bootstrapService
        shell.onSynchronizeRequest = { [weak self] in
            await self?.synchronizeForeground()
        }
    }

    convenience init(
        syncStatus: WorkspaceShellState.SyncStatus = .loading,
        bootstrapService: any AppBootstrapServing
    ) {
        self.init(syncStatus: syncStatus, features: .unconfigured, bootstrapService: bootstrapService)
    }

    convenience init(syncStatus: WorkspaceShellState.SyncStatus = .loading) {
        self.init(
            syncStatus: syncStatus,
            features: .unconfigured,
            bootstrapService: UnconfiguredAppBootstrapService()
        )
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        shell.syncStatus = .loading
        apply(await bootstrapService.start())
    }

    func synchronizeForeground() async {
        shell.syncStatus = .syncing
        apply(await bootstrapService.synchronizeForeground())
    }

    func shutdown() async {
        await bootstrapService.stop()
        hasBootstrapped = false
        lastSyncReceipt = nil
        shell.syncStatus = .offline(reason: "The account-scoped workspace is closed.")
    }

    private func apply(_ outcome: AppBootstrapOutcome) {
        switch outcome {
        case .ready(let receipt):
            lastSyncReceipt = receipt
            shell.syncStatus = .ready
        case .attention(let receipt):
            lastSyncReceipt = receipt
            shell.syncStatus = .attention(reason: receipt.failures.map(\.message).joined(separator: " "))
        case .offline(let reason):
            lastSyncReceipt = nil
            shell.syncStatus = .offline(reason: reason)
        }
    }
}
