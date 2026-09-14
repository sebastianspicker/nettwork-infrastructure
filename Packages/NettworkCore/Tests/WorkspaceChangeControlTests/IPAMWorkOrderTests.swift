import XCTest

@testable import NetworkModel
@testable import WorkspaceChangeControl

final class IPAMWorkOrderTests: XCTestCase {
    func testWorkOrderRequiresReservationAndCancellationReason() throws {
        var order = WorkOrder(kind: .connect, title: "Connect desk")
        XCTAssertThrowsError(try WorkOrderStateMachine.transition(order, to: .reserved))
        order.reservedResourceIDs = [ObjectID()]
        order = try WorkOrderStateMachine.transition(order, to: .reserved)
        order = try WorkOrderStateMachine.transition(order, to: .approved)
        XCTAssertThrowsError(try WorkOrderStateMachine.transition(order, to: .cancelled))
        let cancelled = try WorkOrderStateMachine.transition(order, to: .cancelled, cancellationReason: "No access to room")
        XCTAssertEqual(cancelled.status, .cancelled)
    }
}
