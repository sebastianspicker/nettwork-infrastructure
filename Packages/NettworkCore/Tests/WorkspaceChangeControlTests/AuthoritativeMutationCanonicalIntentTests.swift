import XCTest

@testable import NetworkModel
@testable import WorkspaceChangeControl

final class AuthoritativeMutationCanonicalIntentTests: XCTestCase {
    func testCanonicalIntentDigestIgnoresSetInsertionOrderAndDetectsIntentChange() throws {
        let first = ResourceKey.object(ObjectID())
        let second = ResourceKey.object(ObjectID())
        let workOrderID = ObjectID()
        let vrf = VRF(name: "Production", revision: 4)
        let firstPrefix = Prefix(vrfID: vrf.id, cidr: "10.0.0.0/24", name: "First")!
        let secondPrefix = Prefix(vrfID: vrf.id, cidr: "10.0.1.0/24", name: "Second")!
        let operation: PlannedWorkOperation = .ipam(
            .prefixLayout(vrf: vrf, expectedRevision: 4, currentPrefixes: [firstPrefix], desiredPrefixes: [secondPrefix, firstPrefix]))
        let lhs = CanonicalWorkIntent(
            workOrderID: workOrderID, kind: .ipam, creatorID: "technician", ticket: "CHG-1", notes: nil, operations: [operation],
            resourceKeys: [first, second], evidenceHashes: [])
        let rhs = CanonicalWorkIntent(
            workOrderID: workOrderID, kind: .ipam, creatorID: "technician", ticket: "CHG-1", notes: nil, operations: [operation],
            resourceKeys: [second, first], evidenceHashes: [])
        XCTAssertEqual(try lhs.digest(), try rhs.digest())

        let changed = CanonicalWorkIntent(
            workOrderID: workOrderID, kind: .ipam, creatorID: "technician", ticket: "CHG-2", notes: nil, operations: [operation],
            resourceKeys: [first, second], evidenceHashes: [])
        XCTAssertNotEqual(try lhs.digest(), try changed.digest())
    }

    func testIntentSchemaV1PreservesLegacyIPAMShapesAndV2BindsCurrentState() throws {
        let fixture = try intentSchemaFixture()
        try assertV1IntentIgnoresCurrentState(fixture)
        try assertV2IntentBindsCurrentState(fixture)
    }

    private func intentSchemaFixture() throws -> IntentSchemaFixture {
        let workOrderID = ObjectID()
        let vrf = VRF(name: "Production", revision: 4)
        let firstPrefix = Prefix(vrfID: vrf.id, cidr: "10.0.0.0/24", name: "First")!
        let secondPrefix = Prefix(vrfID: vrf.id, cidr: "10.0.1.0/24", name: "Second")!
        let legacyKey = ResourceKey.string("ip-address:production:10.0.0.42")
        let legacyOperation = PlannedIPAMOperation.legacyAddressAssignment(
            addressKey: legacyKey,
            interfaceID: ObjectID()
        )
        XCTAssertEqual(try JSONDecoder().decode(PlannedIPAMOperation.self, from: JSONEncoder().encode(legacyOperation)), legacyOperation)
        return IntentSchemaFixture(
            workOrderID: workOrderID, vrf: vrf, firstPrefix: firstPrefix, secondPrefix: secondPrefix, legacyKey: legacyKey, legacyOperation: legacyOperation)
    }

    private func assertV1IntentIgnoresCurrentState(_ fixture: IntentSchemaFixture) throws {
        let v1First = intent(schema: 1, current: fixture.firstPrefix, fixture)
        let v1ChangedCurrent = intent(schema: 1, current: fixture.secondPrefix, fixture)
        XCTAssertEqual(try v1First.digest(), try v1ChangedCurrent.digest())
    }

    private func assertV2IntentBindsCurrentState(_ fixture: IntentSchemaFixture) throws {
        let v2First = intent(schema: 2, current: fixture.firstPrefix, fixture)
        let v2ChangedCurrent = intent(schema: 2, current: fixture.secondPrefix, fixture)
        XCTAssertNotEqual(try v2First.digest(), try v2ChangedCurrent.digest())
        XCTAssertThrowsError(
            try CanonicalWorkIntent(
                intentSchemaVersion: 2,
                workOrderID: fixture.workOrderID,
                kind: .ipam,
                creatorID: "technician",
                ticket: nil,
                notes: nil,
                operations: [.ipam(fixture.legacyOperation)],
                resourceKeys: [fixture.legacyKey],
                evidenceHashes: []
            ).digest())
    }

    private func intent(schema: Int, current: Prefix, _ fixture: IntentSchemaFixture) -> CanonicalWorkIntent {
        CanonicalWorkIntent(
            intentSchemaVersion: schema, workOrderID: fixture.workOrderID, kind: .ipam, creatorID: "technician", ticket: nil, notes: nil,
            operations: [.ipam(.prefixLayout(vrf: fixture.vrf, expectedRevision: 4, currentPrefixes: [current], desiredPrefixes: [fixture.secondPrefix]))],
            resourceKeys: [.object(fixture.vrf.id)], evidenceHashes: [])
    }
}
