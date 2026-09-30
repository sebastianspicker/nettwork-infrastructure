import FeatureContracts
import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

enum AddressAssignmentStagingAction: String, CaseIterable, Identifiable {
    case addSecondary = "Add secondary"
    case makePrimary = "Make primary"
    case unassign = "Unassign"

    var id: String { rawValue }
}

enum VLANMembershipStagingAction: String, CaseIterable, Identifiable {
    case add = "Add VLAN"
    case remove = "Remove VLAN"
    case makeNative = "Make native"

    var id: String { rawValue }
}

enum IPAMWorkflowState: String {
    case authoritative = "Authoritative"
    case reserved = "Reserved"
    case planned = "Planned"
    case pending = "Pending"
    case conflicting = "Conflicting"

    var symbolName: String {
        switch self {
        case .authoritative: "checkmark.seal.fill"
        case .reserved: "lock.fill"
        case .planned: "calendar.badge.clock"
        case .pending: "clock.badge.checkmark"
        case .conflicting: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        statusRole.color
    }

    var statusRole: NettworkStatusRole {
        switch self {
        case .authoritative: .ready
        case .reserved: .reserved
        case .planned: .information
        case .pending: .pending
        case .conflicting: .conflict
        }
    }
}

struct VLANGroupPresentation: Identifiable {
    let name: String
    let vlans: [VLANSnapshot]

    var id: String { name }
}
