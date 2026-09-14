import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

final class CloudRecordNameIdentityIndexTests: XCTestCase {
    func testBoundedIndexEvictsOldestEntryWithinNamespace() async throws {
        let index = BoundedCloudRecordNameIdentityIndex()
        let namespace = fixtureNamespace
        let first = identity(for: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
        let second = identity(for: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!))

        try await index.store(first, in: namespace, maximumEntries: 1)
        try await index.store(second, in: namespace, maximumEntries: 1)

        let evicted = try await index.identity(for: first.recordName, in: namespace)
        let retained = try await index.identity(for: second.recordName, in: namespace)
        XCTAssertNil(evicted)
        XCTAssertEqual(retained, second)
    }

    func testIndexRejectsNonDeterministicRecordName() async {
        let index = BoundedCloudRecordNameIdentityIndex()
        let malformed = CloudRecordNameIdentity(
            recordName: "not-a-namespaced-record",
            resourceKey: .object(ObjectID()),
            recordType: "NettworkDevice",
            schemaVersion: 1,
            systemFields: Data("system-fields".utf8),
            changeTag: "change-tag"
        )

        do {
            try await index.store(malformed, in: fixtureNamespace, maximumEntries: 10)
            XCTFail("Expected malformed identity rejection")
        } catch let error as CloudRecordNameIdentityIndexError {
            XCTAssertEqual(error, .invalidIdentity)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private var fixtureNamespace: PersistenceNamespace {
        let workspaceID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000099")!)
        return PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "owner-record",
            workspaceID: workspaceID,
            zoneName: CloudRecordNaming.zoneName(for: workspaceID),
            zoneOwnerRecordName: "owner-record",
            sessionGeneration: 1
        )
    }

    private func identity(for id: ObjectID) -> CloudRecordNameIdentity {
        let key = ResourceKey.object(id)
        return CloudRecordNameIdentity(
            recordName: CloudRecordNaming.recordName(for: key, workspaceID: fixtureNamespace.workspaceID),
            resourceKey: key,
            recordType: "NettworkDevice",
            schemaVersion: 1,
            systemFields: Data("system-fields".utf8),
            changeTag: "change-tag"
        )
    }
}
