import NetworkModel
import Observation
import SwiftUI

/// Builds the screens behind each shell route. Composition supplies the
/// implementation; the shell only asks for destinations.
@MainActor
protocol AppDestinationProviding: AnyObject {
    func destination(for section: AppSection) -> AnyView
    func destination(for objectID: ObjectID) -> AnyView
    func workbench(router: AppRouter) -> AnyView
}

/// View-facing workspace state that the shell reads from the environment.
/// Composition creates it, owns bootstrap, and publishes the sync status here;
/// the shell only displays that status and requests foreground synchronization.
@MainActor
@Observable
final class WorkspaceShellState {
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

    var syncStatus: SyncStatus
    let features: any AppDestinationProviding
    @ObservationIgnored var onSynchronizeRequest: (@MainActor () async -> Void)?

    init(syncStatus: SyncStatus, features: any AppDestinationProviding) {
        self.syncStatus = syncStatus
        self.features = features
    }

    func synchronizeForeground() async {
        await onSynchronizeRequest?()
    }
}
