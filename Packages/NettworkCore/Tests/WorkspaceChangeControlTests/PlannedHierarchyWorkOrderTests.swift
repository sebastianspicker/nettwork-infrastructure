import Foundation
import XCTest

@testable import NetworkModel
@testable import WorkspaceChangeControl

final class PlannedHierarchyWorkOrderTests: XCTestCase {
    func testLocationOperationReservesItsObjectAndExactParentDependency() throws {
        let parentID = ObjectID()
        let location = Location(name: "Closet A", kind: .room, parentID: parentID)
        let operation = PlannedHierarchyOperation.upsertLocation(location)

        XCTAssertEqual(operation.resourceKeys, [.object(location.id), .object(parentID)])
        XCTAssertEqual(try roundTrip(operation), operation)
    }

    func testRackOperationReservesItsObjectAndOwningRoomDependency() throws {
        let roomID = ObjectID()
        let rack = Rack(assetCode: "rack-a", locationID: roomID, heightRU: 42)
        let operation = PlannedHierarchyOperation.removeRack(rack)

        XCTAssertEqual(operation.resourceKeys, [.object(rack.id), .object(roomID)])
        XCTAssertEqual(try roundTrip(operation), operation)
    }

    private func roundTrip(_ operation: PlannedHierarchyOperation) throws -> PlannedHierarchyOperation {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        return try decoder.decode(PlannedHierarchyOperation.self, from: encoder.encode(operation))
    }
}
