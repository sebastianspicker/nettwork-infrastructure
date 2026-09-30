import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

/// Stable presentation labels for aggregate port state and conflict messages.
/// Filters expose direct availability and aggregate state separately.
enum InventoryPortAvailability: String, CaseIterable, Identifiable, Hashable, Sendable {
    case available, occupied, reserved, planned, conflicted, unavailable
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum TopologyPortAvailabilityFilter: String, CaseIterable, Identifiable, Sendable {
    case all, available, unavailable
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum TopologyPortStateFilter: String, CaseIterable, Identifiable, Sendable {
    case all, free, occupied, reserved, planned, unavailable
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
