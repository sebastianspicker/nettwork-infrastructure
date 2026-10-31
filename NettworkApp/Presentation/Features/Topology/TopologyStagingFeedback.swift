import SwiftUI

/// Shows the outcome of the last topology or hierarchy staging attempt.
struct TopologyStagingFeedback: View {
    let model: TopologyWorkspaceModel

    var body: some View {
        if let feedback = model.stagingFeedback {
            switch feedback {
            case .pending(let message):
                Label(message, systemImage: NettworkStatusRole.pending.symbolName)
                    .foregroundStyle(NettworkStatusRole.pending.color)
                    .accessibilityIdentifier("topology.stagingFeedback")
            case .conflict(let message), .unavailable(let message), .offline(let message),
                .permissionDenied(let message), .quarantined(let message):
                Label(message, systemImage: NettworkStatusRole.conflict.symbolName)
                    .foregroundStyle(NettworkStatusRole.conflict.color)
                    .accessibilityIdentifier("topology.stagingFeedback")
            case .loading, .ready, .empty:
                EmptyView()
            }
        }
    }
}
