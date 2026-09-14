import Foundation
import XCTest

@testable import NetworkModel

final class IdentityHierarchyTests: XCTestCase {
    func testCanonicalHierarchyAndFixtureAreDeterministic() throws {
        let fixture = IdentityHierarchyTestData.canonical()
        try fixture.hierarchy.validate()

        let first = try fixture.deterministicJSON()
        let second = try fixture.deterministicJSON()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try IdentityHierarchyTestData.decodeDeterministicJSON(first), fixture)
    }

    func testHierarchyRejectsInvalidParentCycleAndUnsafeDeletion() throws {
        let fixture = IdentityHierarchyTestData.canonical()
        let workspace = try XCTUnwrap(fixture.hierarchy.locations.first(where: { $0.kind == .workspace }))
        let room = try XCTUnwrap(fixture.hierarchy.locations.first(where: { $0.kind == .room }))

        var invalidParent = fixture.hierarchy
        XCTAssertThrowsError(try invalidParent.move(locationID: room.id, to: workspace.id))
    }

    func testHierarchyMoveDeletionAndTombstoneRules() throws {
        var hierarchy = IdentityHierarchyTestData.canonical().hierarchy
        let site = try XCTUnwrap(hierarchy.locations.first(where: { $0.kind == .site }))
        let room = try XCTUnwrap(hierarchy.locations.first(where: { $0.kind == .room }))
        let rack = try XCTUnwrap(hierarchy.racks.first)

        XCTAssertThrowsError(try hierarchy.move(locationID: site.id, to: room.id))
        XCTAssertThrowsError(try hierarchy.softDelete(room.id, at: .distantPast))

        try hierarchy.softDelete(rack.id, at: .distantPast)
        XCTAssertEqual(hierarchy.racks.first?.deletedAt, Date.distantPast)
        try hierarchy.softDelete(room.id, at: .distantPast)

        let staleRackID = ObjectID(UUID(uuidString: "20000000-0000-0000-0000-000000000001")!)
        try hierarchy.addTombstone(HierarchyTombstone(id: staleRackID, kind: .rack, deletedAt: .distantPast))
        XCTAssertThrowsError(try hierarchy.addTombstone(HierarchyTombstone(id: staleRackID, kind: .rack, deletedAt: .distantPast)))
    }

    func testResourceKeysAssetCodesAndStrictObjectLinks() throws {
        let id = ObjectID(UUID(uuidString: "30000000-0000-0000-0000-000000000001")!)
        let keys: [ResourceKey] = [.object(id), .ipAddress(vrfID: id, address: "2001:DB8::1"), .operationReceipt(operationID: id)]
        let data = try JSONEncoder().encode(keys)
        XCTAssertEqual(try JSONDecoder().decode([ResourceKey].self, from: data), keys)

        XCTAssertEqual(AssetCode(" rack   1 ").value, "RACK-1")
        XCTAssertThrowsError(
            try AssetCodeValidator.validate(
                [
                    AssetCodeClaim(code: "RACK-1", objectID: id, objectKind: .rack, workspaceID: id),
                    AssetCodeClaim(code: "rack-1", objectID: ObjectID(), objectKind: .rack, workspaceID: id),
                ], scope: .workspace))

        let link = ObjectLink.url(for: id)
        XCTAssertEqual(ObjectLink.objectID(from: link), id)
        XCTAssertNil(ObjectLink.objectID(from: "nettwork://object/\(id.description)/extra"))
        XCTAssertEqual(ObjectLink.objectID(from: "NETTWORK://OBJECT/\(id.description.uppercased())"), id)
        XCTAssertNil(ObjectLink.objectID(from: "nettwork://object/\(id.description)?label=RACK-1"))
    }

    func testCustomFieldDefaultsRequiredAndChoiceValidation() throws {
        let schemas = [
            CustomFieldSchema(key: "role", displayName: "Role", kind: .choice, isRequired: true, choices: ["core", "access"]),
            CustomFieldSchema(key: "managed", displayName: "Managed", kind: .flag, defaultValue: .flag(true)),
        ]
        let resolved = try CustomFieldValidator.resolvedValues(values: [CustomFieldValue(key: "ROLE", value: .text("core"))], against: schemas)
        XCTAssertEqual(resolved, [CustomFieldValue(key: "role", value: .text("core")), CustomFieldValue(key: "managed", value: .flag(true))])

        XCTAssertThrowsError(try CustomFieldValidator.validate(values: [], against: schemas))
        XCTAssertThrowsError(try CustomFieldValidator.validate(values: [CustomFieldValue(key: "role", value: .text("edge"))], against: schemas))
        XCTAssertThrowsError(try CustomFieldValidator.validate(values: [CustomFieldValue(key: "managed", value: .text("yes"))], against: schemas))
    }
}
