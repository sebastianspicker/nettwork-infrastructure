import Foundation
import NetworkModel
import Observation
import WorkspaceChangeControl

@MainActor
@Observable
final class AppDependencies {
    enum SyncStatus: Equatable {
        case loading
        case syncing
        case ready
        case attention(reason: String)
        case offline(reason: String)

        var title: String {
            switch self {
            case .loading:
                "Preparing workspace"
            case .syncing:
                "Synchronizing changes"
            case .ready:
                "Up to date"
            case .attention:
                "Sync needs attention"
            case .offline:
                "Offline workspace"
            }
        }

        var detail: String {
            switch self {
            case .loading:
                "Loading the local workspace mirror."
            case .syncing:
                "Pending changes are being checked with the workspace."
            case .ready:
                "The local workspace mirror is current."
            case .attention(let reason):
                reason
            case .offline(let reason):
                reason
            }
        }
    }

    private(set) var syncStatus: SyncStatus
    private(set) var lastSyncReceipt: SyncReceipt?
    let features: AppFeatureRegistry
    private let bootstrapService: any AppBootstrapServing
    private var hasBootstrapped = false

    init(
        syncStatus: SyncStatus = .loading,
        features: AppFeatureRegistry,
        bootstrapService: any AppBootstrapServing
    ) {
        self.syncStatus = syncStatus
        self.features = features
        self.bootstrapService = bootstrapService
    }

    convenience init(
        syncStatus: SyncStatus = .loading,
        bootstrapService: any AppBootstrapServing
    ) {
        self.init(syncStatus: syncStatus, features: .unconfigured, bootstrapService: bootstrapService)
    }

    convenience init(syncStatus: SyncStatus = .loading) {
        self.init(
            syncStatus: syncStatus,
            features: .unconfigured,
            bootstrapService: UnconfiguredAppBootstrapService()
        )
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        syncStatus = .loading
        apply(await bootstrapService.start())
    }

    func synchronizeForeground() async {
        syncStatus = .syncing
        apply(await bootstrapService.synchronizeForeground())
    }

    func shutdown() async {
        await bootstrapService.stop()
        hasBootstrapped = false
        lastSyncReceipt = nil
        syncStatus = .offline(reason: "The account-scoped workspace is closed.")
    }

    private func apply(_ outcome: AppBootstrapOutcome) {
        switch outcome {
        case .ready(let receipt):
            lastSyncReceipt = receipt
            syncStatus = .ready
        case .attention(let receipt):
            lastSyncReceipt = receipt
            syncStatus = .attention(reason: receipt.failures.map(\.message).joined(separator: " "))
        case .offline(let reason):
            lastSyncReceipt = nil
            syncStatus = .offline(reason: reason)
        }
    }
}
