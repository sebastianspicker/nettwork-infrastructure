import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl
import XCTest

@testable import Persistence

final class PersistenceV9BehaviorTests: XCTestCase {
    func testV8RowsMigrateThroughFactoryAndV9MaintenanceBackfillSurvivesReopen() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        try seedV8Store(with: fixture)

        do {
            let store = try makeV9Store(for: fixture)
            _ = await store.activateLease(for: fixture.namespace)

            let retained = try await store.mirrorRecordsForExplicitMaintenanceRepair(in: fixture.namespace)
            XCTAssertEqual(retained.map(\.resourceKey), fixture.records.map(\.resourceKey).sorted())

            let recoveredSyncState = try await store.syncState(in: fixture.namespace)
            let retainedSyncState = try XCTUnwrap(recoveredSyncState)
            XCTAssertEqual(retainedSyncState.engineState, fixture.syncState.engineState)
            XCTAssertEqual(retainedSyncState.changeToken, fixture.syncState.changeToken)
            XCTAssertEqual(retainedSyncState.lastSuccessfulServerContact, fixture.syncState.lastSuccessfulServerContact)
            XCTAssertEqual(retainedSyncState.updatedAt, fixture.syncState.updatedAt)
            let workspaceVisibilityState = try await store.workspaceVisibilityState(in: fixture.namespace)
            XCTAssertEqual(workspaceVisibilityState, fixture.workspaceVisibilityState)

            let needsRepair = try await store.mirrorMaintenanceNeedsRepair(in: fixture.namespace)
            XCTAssertTrue(needsRepair)
            try await store.repairMirrorMaintenanceIndexes(
                records: retained,
                maintenance: fixture.validMaintenance,
                in: fixture.namespace
            )
            try await assertRepairedIndexes(store, fixture: fixture)
        }

        do {
            let reopened = try makeV9Store(for: fixture)
            _ = await reopened.activateLease(for: fixture.namespace)

            let reopenedNeedsRepair = try await reopened.mirrorMaintenanceNeedsRepair(in: fixture.namespace)
            XCTAssertFalse(reopenedNeedsRepair)
            let reopenedResourceKeys =
                try await reopened
                .mirrorRecordsForExplicitMaintenanceRepair(in: fixture.namespace)
                .map(\.resourceKey)
            XCTAssertEqual(reopenedResourceKeys, fixture.records.map(\.resourceKey).sorted())
            try await assertRepairedIndexes(reopened, fixture: fixture)
        }
    }

    func testFailedV9MaintenanceRepairRollsBackExistingIndexes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        try seedV8Store(with: fixture)

        let store = try makeV9Store(for: fixture)
        _ = await store.activateLease(for: fixture.namespace)
        let records = try await store.mirrorRecordsForExplicitMaintenanceRepair(in: fixture.namespace)
        try await store.repairMirrorMaintenanceIndexes(
            records: records,
            maintenance: fixture.validMaintenance,
            in: fixture.namespace
        )

        let invalidMaintenance = LocalMirrorMaintenanceBatch(
            records: [
                LocalMirrorMaintenanceRecord(
                    resourceKey: fixture.liveRecord.resourceKey,
                    references: [
                        LocalMirrorReferenceEdge(
                            source: fixture.stagedRecord.resourceKey,
                            target: fixture.liveRecord.resourceKey
                        )
                    ]
                ),
                LocalMirrorMaintenanceRecord(
                    resourceKey: fixture.stagedRecord.resourceKey,
                    transferMember: LocalMirrorTransferMember(
                        transferID: ObjectID(),
                        resourceKey: fixture.stagedRecord.resourceKey,
                        digest: "incorrect-transfer"
                    )
                ),
            ]
        )

        do {
            try await store.repairMirrorMaintenanceIndexes(
                records: records,
                maintenance: invalidMaintenance,
                in: fixture.namespace
            )
            XCTFail("Expected staged transfer identity validation failure")
        } catch let error as PersistenceStoreError {
            guard case .mirrorMaintenanceInvalid = error else {
                return XCTFail("Expected mirror maintenance validation error, got \(error)")
            }
        }

        try await assertRepairedIndexes(store, fixture: fixture)
    }

    private func seedV8Store(with fixture: Fixture) throws {
        let container = try ModelContainer(
            for: Schema(versionedSchema: NettworkLocalSchemaV8.self),
            configurations: [ModelConfiguration(url: fixture.databaseURL)]
        )
        let context = ModelContext(container)
        context.insert(try LocalRecordMirror(record: fixture.liveRecord))
        context.insert(try LocalRecordMirror(record: fixture.stagedRecord))
        context.insert(try LocalSyncStateModel(state: fixture.syncState))
        context.insert(try LocalWorkspaceVisibilityStateModel(state: fixture.workspaceVisibilityState))
        try context.save()
    }

    private func makeV9Store(for fixture: Fixture) throws -> SwiftDataPersistenceStore {
        let container = try NettworkPersistenceContainerFactory.make(
            configuration: ModelConfiguration(url: fixture.databaseURL)
        )
        return SwiftDataPersistenceStore(
            container: container,
            attachmentDirectory: fixture.rootDirectory.appendingPathComponent("attachments", isDirectory: true)
        )
    }

    private func assertRepairedIndexes(_ store: SwiftDataPersistenceStore, fixture: Fixture) async throws {
        let needsRepair = try await store.mirrorMaintenanceNeedsRepair(in: fixture.namespace)
        XCTAssertFalse(needsRepair)
        let referenceSources = try await store.mirrorReferenceSources(
            targeting: [fixture.liveRecord.resourceKey],
            remainingBudget: 10,
            in: fixture.namespace
        )
        XCTAssertEqual(referenceSources, [fixture.stagedRecord.resourceKey])
        let transferMembers = try await store.mirrorTransferMembers(
            transferID: fixture.transferID,
            in: fixture.namespace
        ).map(\.resourceKey)
        XCTAssertEqual(transferMembers, [fixture.stagedRecord.resourceKey])
    }

    private func makeFixture() throws -> Fixture {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PersistenceV9BehaviorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork", cloudKitAccountRecordName: "v8-owner",
            workspaceID: ObjectID(UUID(uuidString: "90000000-0000-0000-0000-000000000001")!), zoneName: "v8-workspace-zone", zoneOwnerRecordName: "v8-owner",
            sessionGeneration: 8)
        let transferID = ObjectID(UUID(uuidString: "90000000-0000-0000-0000-000000000002")!)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let liveRecord = LocalMirrorRecord(
            namespace: namespace, resourceKey: .string("v8-live-record"), recordType: "NettworkDevice", schemaVersion: 8, payload: Data("live-payload".utf8),
            systemFields: Data("live-system-fields".utf8), changeTag: "live-tag", isTombstone: false, serverModifiedAt: timestamp, verifiedAt: timestamp)
        let stagedRecord = LocalMirrorRecord(
            namespace: namespace, resourceKey: .string("v8-staged-record"), recordType: "NettworkCable", schemaVersion: 8, payload: Data("staged-payload".utf8),
            systemFields: Data("staged-system-fields".utf8), changeTag: "staged-tag", isTombstone: false, visibility: .staged(transferID: transferID),
            serverModifiedAt: timestamp, verifiedAt: timestamp)
        let syncState = LocalSyncState(
            namespace: namespace, engineState: Data("v8-engine-state".utf8), changeToken: Data("v8-change-token".utf8), lastSuccessfulServerContact: timestamp,
            updatedAt: timestamp)
        let workspaceVisibilityState = LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: .empty(epoch: 8), updatedAt: timestamp)
        let validMaintenance = LocalMirrorMaintenanceBatch(records: [
            LocalMirrorMaintenanceRecord(
                resourceKey: liveRecord.resourceKey
            ),
            LocalMirrorMaintenanceRecord(
                resourceKey: stagedRecord.resourceKey,
                references: [
                    LocalMirrorReferenceEdge(
                        source: stagedRecord.resourceKey,
                        target: liveRecord.resourceKey
                    )
                ],
                transferMember: LocalMirrorTransferMember(
                    transferID: transferID,
                    resourceKey: stagedRecord.resourceKey,
                    digest: "v8-staged-member"
                )
            ),
        ])
        return Fixture(
            rootDirectory: rootDirectory, databaseURL: rootDirectory.appendingPathComponent("v8-to-v9.store"), namespace: namespace, transferID: transferID,
            liveRecord: liveRecord, stagedRecord: stagedRecord, syncState: syncState, workspaceVisibilityState: workspaceVisibilityState,
            validMaintenance: validMaintenance)
    }
}

private struct Fixture {
    let rootDirectory: URL
    let databaseURL: URL
    let namespace: PersistenceNamespace
    let transferID: ObjectID
    let liveRecord: LocalMirrorRecord
    let stagedRecord: LocalMirrorRecord
    let syncState: LocalSyncState
    let workspaceVisibilityState: LocalWorkspaceVisibilityState
    let validMaintenance: LocalMirrorMaintenanceBatch

    var records: [LocalMirrorRecord] {
        [liveRecord, stagedRecord]
    }
}
