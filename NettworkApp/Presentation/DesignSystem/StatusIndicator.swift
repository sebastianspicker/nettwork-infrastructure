import SwiftUI

enum NettworkStatusRole: Sendable {
    case information
    case ready
    case pending
    case offline
    case conflict
    case reserved

    var color: Color {
        switch self {
        case .information: Color.nettworkAccent
        case .ready: Color.nettworkReady
        case .pending: Color.nettworkPending
        case .offline: Color.nettworkOffline
        case .conflict: Color.nettworkConflict
        case .reserved: Color.nettworkReserved
        }
    }

    var symbolName: String {
        switch self {
        case .information: "info.circle.fill"
        case .ready: "checkmark.circle.fill"
        case .pending: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .conflict: "exclamationmark.triangle.fill"
        case .reserved: "lock.fill"
        }
    }
}

enum StatusIndicatorStyle: Sendable {
    /// A compact toolbar affordance. Its parent button supplies the tap target.
    case iconOnly
    /// Text-plus-icon status for inline operational context.
    case inline
    /// A labeled, softly tinted status for prominent operational context.
    case badge
}

struct StatusBadge: View {
    let title: String
    let role: NettworkStatusRole

    var body: some View {
        Label(title, systemImage: role.symbolName)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(role.color)
            .padding(.horizontal, NettworkSpacing.small)
            .frame(minHeight: 28)
            .background(role.color.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

struct StatusIndicator: View {
    let status: AppDependencies.SyncStatus
    let style: StatusIndicatorStyle

    init(status: AppDependencies.SyncStatus, style: StatusIndicatorStyle = .iconOnly) {
        self.status = status
        self.style = style
    }

    var body: some View {
        Group {
            switch style {
            case .iconOnly:
                Label(status.title, systemImage: role.symbolName)
                    .labelStyle(.iconOnly)
            case .inline:
                Label(status.title, systemImage: role.symbolName)
                    .font(.footnote.weight(.semibold))
                    .labelStyle(.titleAndIcon)
            case .badge:
                StatusBadge(title: status.title, role: role)
            }
        }
        .foregroundStyle(role.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.title)
        .accessibilityHint(status.detail)
    }

    private var role: NettworkStatusRole {
        switch status {
        case .loading, .syncing: .pending
        case .ready: .ready
        case .attention: .conflict
        case .offline: .offline
        }
    }
}

#if canImport(PreviewsMacros)
    #Preview("Workspace status") {
        HStack {
            StatusIndicator(status: .loading, style: .badge)
            StatusIndicator(status: .syncing, style: .inline)
            StatusIndicator(status: .ready, style: .badge)
            StatusIndicator(status: .attention(reason: "A retry is scheduled."), style: .badge)
            StatusIndicator(status: .offline(reason: "No verified workspace."), style: .badge)
        }
        .padding()
    }
#endif
