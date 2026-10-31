import Foundation
import NetworkModel
import WorkspaceChangeControl

/// One authoritative work order as the local mirror last received it.
public struct WorkOrderSummary: Identifiable, Equatable, Sendable {
    public let id: ObjectID
    public let title: String
    public let status: WorkOrderStatus
    public let ticket: String?
    /// The acknowledged reservation expiry; nil while the reservation is
    /// unacknowledged or the work order holds none.
    public let reservationExpiresAt: Date?
    public let updatedAt: Date

    public init(id: ObjectID, title: String, status: WorkOrderStatus, ticket: String?, reservationExpiresAt: Date?, updatedAt: Date) {
        self.id = id
        self.title = title
        self.status = status
        self.ticket = ticket
        self.reservationExpiresAt = reservationExpiresAt
        self.updatedAt = updatedAt
    }
}

/// An authoritative work order read back for its remaining lifecycle actions.
/// `draft` carries the reviewed intent under the work order's own id; the
/// reservation is nil only when the work order never held one.
public struct ReopenedWorkOrder: Equatable, Sendable {
    public let draft: WorkOrderDraft
    public let status: WorkOrderStatus
    public let reservation: WorkOrderReservationPresentation?

    public init(draft: WorkOrderDraft, status: WorkOrderStatus, reservation: WorkOrderReservationPresentation?) {
        self.draft = draft
        self.status = status
        self.reservation = reservation
    }
}
