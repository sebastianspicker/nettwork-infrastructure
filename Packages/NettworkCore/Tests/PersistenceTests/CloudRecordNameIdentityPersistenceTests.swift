import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl
import XCTest

@testable import Persistence

final class CloudRecordNameIdentityPersistenceTests: XCTestCase {
    func testIdentityEvidenceRequiresAnActiveExactNamespaceLease() async throws {
        let store = try makeStore()
        let namespace = fixtureNamespace
        let identity = fixtureIdentity(in: namespace)

        do {
            try await store.storeCloudRecordNameIdentity(
                identity,
                in: namespace,
                maximumEntries: LocalCloudRecordNameIdentityIndexLimits.minimumCapacity
            )
            XCTFail("Expected inactive namespace rejection")
        } catch let error as PersistenceStoreError {
            XCTAssertEqual(error, .invalidNamespaceLease)
        }

        _ = await store.activateLease(for: namespace)
        try await store.storeCloudRecordNameIdentity(
            identity,
            in: namespace,
            maximumEntries: LocalCloudRecordNameIdentityIndexLimits.minimumCapacity
        )

        let storedIdentity = try await store.cloudRecordNameIdentity(for: identity.recordName, in: namespace)
        XCTAssertEqual(storedIdentity, identity)
    }

    func testIdentityCapacityBelowSupportedImportCorpusFailsClosed() async throws {
        let store = try makeStore()
        let namespace = fixtureNamespace
        let identity = fixtureIdentity(in: namespace)
        _ = await store.activateLease(for: namespace)

        do {
            try await store.storeCloudRecordNameIdentity(
                identity,
                in: namespace,
                maximumEntries: LocalCloudRecordNameIdentityIndexLimits.minimumCapacity - 1
            )
            XCTFail("Expected capacity rejection")
        } catch let error as PersistenceStoreError {
            XCTAssertEqual(
                error,
                .cloudRecordNameIdentityCapacityExceeded(
                    LocalCloudRecordNameIdentityIndexLimits.minimumCapacity - 1
                )
            )
        }

        let missingIdentity = try await store.cloudRecordNameIdentity(for: identity.recordName, in: namespace)
        XCTAssertNil(missingIdentity)
    }

    func testExplicitPurgeRemovesOnlyDurableIdentityEvidenceAndInvalidationStopsReads() async throws {
        let store = try makeStore()
        let namespace = fixtureNamespace
        let identity = fixtureIdentity(in: namespace)
        let lease = await store.activateLease(for: namespace)
        try await store.storeCloudRecordNameIdentity(
            identity,
            in: namespace,
            maximumEntries: LocalCloudRecordNameIdentityIndexLimits.minimumCapacity
        )

        let purgedCount = try await store.purgeCloudRecordNameIdentities(in: namespace)
        XCTAssertEqual(purgedCount, 1)
        let missingIdentity = try await store.cloudRecordNameIdentity(for: identity.recordName, in: namespace)
        XCTAssertNil(missingIdentity)

        await store.invalidate(lease)
        do {
            _ = try await store.cloudRecordNameIdentity(for: identity.recordName, in: namespace)
            XCTFail("Expected invalidated namespace rejection")
        } catch let error as PersistenceStoreError {
            XCTAssertEqual(error, .invalidNamespaceLease)
        }
    }

    func testSchemaHistoryRetainsV4DurableIdentityStorage() {
        XCTAssertEqual(NettworkLocalSchema.version, 9)
        assertSchemaV4ThroughV9()
    }

    private func makeStore() throws -> SwiftDataPersistenceStore {
        let container = try NettworkPersistenceContainerFactory.make(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return SwiftDataPersistenceStore(
            container: container,
            attachmentDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("cloud-record-name-index-tests", isDirectory: true)
        )
    }

    private var fixtureNamespace: PersistenceNamespace {
        PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "owner-record",
            workspaceID: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000099")!),
            zoneName: "nettwork.workspace.00000000-0000-0000-0000-000000000099",
            zoneOwnerRecordName: "owner-record",
            sessionGeneration: 1
        )
    }

    private func fixtureIdentity(in namespace: PersistenceNamespace) -> LocalCloudRecordNameIdentity {
        let resourceKey = ResourceKey.object(
            ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        )
        return LocalCloudRecordNameIdentity(
            namespace: namespace,
            recordName: "nw.00000000-0000-0000-0000-000000000099.identity",
            resourceKey: resourceKey,
            recordType: "NettworkDevice",
            schemaVersion: 1,
            systemFields: Data("system-fields".utf8),
            changeTag: "change-tag"
        )
    }
}
