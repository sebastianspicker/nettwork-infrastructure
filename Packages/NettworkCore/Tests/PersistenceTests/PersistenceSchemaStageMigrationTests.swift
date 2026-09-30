import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl
import XCTest

@testable import Persistence

/// Creates an on-disk store with each historical schema, then reopens it through
/// the production container factory (current schema plus migration plan).
final class PersistenceSchemaStageMigrationTests: XCTestCase {
    func testV1StoreMigratesMirrorRowAndRetainsOpaqueOutboxEvidence() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let outboxStorageKey = PersistenceNamespaceKey.storageKey(namespace: fixture.namespace, identity: "outbox:legacy-operation")
        try seed(NettworkLocalSchemaV1.self, in: fixture) { context in
            context.insert(try legacyMirror(fixture.liveRecord, as: NettworkLocalSchemaV1.LocalRecordMirror.init))
            context.insert(
                NettworkLocalSchemaV1.OutboxMutationModel(
                    storageKey: outboxStorageKey, namespaceKey: PersistenceNamespaceKey.value(for: fixture.namespace),
                    operationID: "legacy-operation", kind: "obsolete", payload: Data([1, 2]), baseChangeTags: Data([3]),
                    createdAt: fixture.timestamp, attemptCount: 4, lastError: "legacy failure"))
        }

        let (store, container) = try makeCurrentStore(for: fixture)
        try await assertLiveMirror(store, fixture: fixture)
        let rows = try ModelContext(container).fetch(FetchDescriptor<OutboxMutationModel>())
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.storageKey, outboxStorageKey)
        XCTAssertEqual(row.operationID, "legacy-operation")
        XCTAssertEqual(row.kind, "obsolete")
        XCTAssertEqual(row.payload, Data([1, 2]))
        XCTAssertEqual(row.baseChangeTags, Data([3]))
        XCTAssertEqual(row.lastError, "legacy failure")
        XCTAssertEqual(row.createdAt, fixture.timestamp)
        XCTAssertEqual(row.attemptCount, 4)
        // The obsolete row has no envelope: it stays inert evidence, never replayable.
        XCTAssertEqual(row.operationData, Data())
        XCTAssertEqual(row.stateRaw, OutboxState.poisoned.rawValue)
        XCTAssertNil(row.nextRetryAt)
        XCTAssertNil(row.receiptData)
    }

    func testV2StoreMigratesMirrorAndSyncState() async throws {
        try await assertPreVisibilityStageMigrates(NettworkLocalSchemaV2.self)
    }

    func testV3StoreMigratesMirrorAndSyncState() async throws {
        try await assertPreVisibilityStageMigrates(NettworkLocalSchemaV3.self)
    }

    func testV4StoreMigratesMirrorAndSyncState() async throws {
        try await assertPreVisibilityStageMigrates(NettworkLocalSchemaV4.self)
    }

    func testV5StoreMigratesVisibilityRowsAndWorkspaceState() async throws {
        try await assertVisibilityStageMigrates(NettworkLocalSchemaV5.self, searchIndex: false)
    }

    func testV6StoreMigratesInventorySearchIndex() async throws {
        try await assertVisibilityStageMigrates(NettworkLocalSchemaV6.self, searchIndex: true)
    }

    func testV7StoreMigratesInventorySearchIndex() async throws {
        try await assertVisibilityStageMigrates(NettworkLocalSchemaV7.self, searchIndex: true)
    }

    func testV8StoreMigratesInventorySearchIndex() async throws {
        try await assertVisibilityStageMigrates(NettworkLocalSchemaV8.self, searchIndex: true)
    }

    // MARK: - Stage assertions

    /// V2-V4 persisted mirror rows without visibility; V5 reads them as live.
    private func assertPreVisibilityStageMigrates(_ schema: any VersionedSchema.Type) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        try seed(schema, in: fixture) { context in
            context.insert(try legacyMirror(fixture.liveRecord, as: NettworkLocalSchemaV4.LocalRecordMirror.init))
            context.insert(try LocalSyncStateModel(state: fixture.syncState))
        }

        let (store, container) = try makeCurrentStore(for: fixture)
        try await assertLiveMirror(store, fixture: fixture)
        let migratedRow = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<LocalRecordMirror>()).first)
        XCTAssertNil(migratedRow.visibilityData)
        XCTAssertNil(migratedRow.recordAssetMetadataData)
        let syncState = try await store.syncState(in: fixture.namespace)
        XCTAssertEqual(syncState, fixture.syncState)
        let visibility = try await store.workspaceVisibilityState(in: fixture.namespace)
        XCTAssertEqual(visibility.lifecycle, .empty(epoch: 0))
    }

    /// V5-V8 already store explicit visibility; staged rows must stay staged.
    private func assertVisibilityStageMigrates(_ schema: any VersionedSchema.Type, searchIndex: Bool) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        try seed(schema, in: fixture) { context in
            context.insert(try LocalRecordMirror(record: fixture.liveRecord))
            context.insert(try LocalRecordMirror(record: fixture.stagedRecord))
            context.insert(try LocalSyncStateModel(state: fixture.syncState))
            context.insert(try LocalWorkspaceVisibilityStateModel(state: fixture.workspaceVisibilityState))
            if searchIndex { context.insert(try LocalInventorySearchIndexModel(record: fixture.searchRecord)) }
        }

        let (store, container) = try makeCurrentStore(for: fixture)
        try await assertLiveMirror(store, fixture: fixture)
        let staged = try await store.storedLocalMirror(for: fixture.stagedRecord.resourceKey, in: fixture.namespace)
        XCTAssertEqual(staged, fixture.stagedRecord)
        XCTAssertEqual(staged?.visibility, .staged(transferID: fixture.transferID))
        let syncState = try await store.syncState(in: fixture.namespace)
        XCTAssertEqual(syncState, fixture.syncState)
        let visibility = try await store.workspaceVisibilityState(in: fixture.namespace)
        XCTAssertEqual(visibility, fixture.workspaceVisibilityState)

        let indexRows = try ModelContext(container).fetch(FetchDescriptor<LocalInventorySearchIndexModel>())
        XCTAssertEqual(indexRows.map { $0.title }, searchIndex ? [fixture.searchRecord.title] : [])
        XCTAssertEqual(indexRows.first?.objectIDValue, searchIndex ? fixture.searchRecord.objectID.description : nil)
    }

    private func assertLiveMirror(_ store: SwiftDataPersistenceStore, fixture: Fixture) async throws {
        _ = await store.activateLease(for: fixture.namespace)
        let live = try await store.storedLocalMirror(for: fixture.liveRecord.resourceKey, in: fixture.namespace)
        XCTAssertEqual(live, fixture.liveRecord)
        XCTAssertEqual(live?.visibility, .live)
    }

    // MARK: - Setup

    private func seed(_ schema: any VersionedSchema.Type, in fixture: Fixture, _ insert: (ModelContext) throws -> Void) throws {
        let container = try ModelContainer(
            for: Schema(versionedSchema: schema), configurations: [ModelConfiguration(url: fixture.databaseURL)])
        let context = ModelContext(container)
        try insert(context)
        try context.save()
    }

    private func makeCurrentStore(for fixture: Fixture) throws -> (SwiftDataPersistenceStore, ModelContainer) {
        let container = try NettworkPersistenceContainerFactory.make(configuration: ModelConfiguration(url: fixture.databaseURL))
        let store = SwiftDataPersistenceStore(
            container: container, attachmentDirectory: fixture.rootDirectory.appendingPathComponent("attachments", isDirectory: true))
        return (store, container)
    }

    private func legacyMirror<Row: PersistentModel>(
        _ record: LocalMirrorRecord,
        as make: (String, String, Data, String, Int, Data?, Data?, String?, Bool, Date, Date) -> Row
    ) throws -> Row {
        make(
            PersistenceNamespaceKey.storageKey(namespace: record.namespace, identity: record.resourceKey.description),
            PersistenceNamespaceKey.value(for: record.namespace), try PersistenceCoding.encode(record.resourceKey), record.recordType,
            record.schemaVersion, record.payload, record.systemFields, record.changeTag, record.isTombstone, record.serverModifiedAt, record.verifiedAt)
    }

    private func makeFixture() throws -> Fixture {
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PersistenceSchemaStageMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork", cloudKitAccountRecordName: "stage-owner",
            workspaceID: ObjectID(UUID(uuidString: "91000000-0000-0000-0000-000000000001")!), zoneName: "stage-zone",
            zoneOwnerRecordName: "stage-owner", sessionGeneration: 3)
        let transferID = ObjectID(UUID(uuidString: "91000000-0000-0000-0000-000000000002")!)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let liveRecord = LocalMirrorRecord(
            namespace: namespace, resourceKey: .string("stage-live"), recordType: "NettworkDevice", schemaVersion: 1,
            payload: Data("live-payload".utf8), systemFields: Data("live-system-fields".utf8), changeTag: "live-tag", isTombstone: false,
            serverModifiedAt: timestamp, verifiedAt: timestamp)
        let stagedRecord = LocalMirrorRecord(
            namespace: namespace, resourceKey: .string("stage-staged"), recordType: "NettworkCable", schemaVersion: 1,
            payload: Data("staged-payload".utf8), systemFields: Data("staged-system-fields".utf8), changeTag: "staged-tag", isTombstone: false,
            visibility: .staged(transferID: transferID), serverModifiedAt: timestamp, verifiedAt: timestamp)
        let objectID = ObjectID(UUID(uuidString: "91000000-0000-0000-0000-000000000003")!)
        return Fixture(
            rootDirectory: rootDirectory, databaseURL: rootDirectory.appendingPathComponent("stage.store"), namespace: namespace,
            transferID: transferID, timestamp: timestamp, liveRecord: liveRecord, stagedRecord: stagedRecord,
            syncState: LocalSyncState(
                namespace: namespace, engineState: Data("engine".utf8), changeToken: Data("token".utf8), lastSuccessfulServerContact: timestamp,
                updatedAt: timestamp),
            workspaceVisibilityState: LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: .empty(epoch: 5), updatedAt: timestamp),
            searchRecord: LocalInventorySearchRecord(
                namespace: namespace, objectID: objectID, resourceKey: .object(objectID), kind: "device", title: "Core Switch",
                subtitle: "Rack 1", siteName: "HQ", siteIDs: [], searchTerms: ["core"], isPending: false))
    }
}

private struct Fixture {
    let rootDirectory: URL
    let databaseURL: URL
    let namespace: PersistenceNamespace
    let transferID: ObjectID
    let timestamp: Date
    let liveRecord: LocalMirrorRecord
    let stagedRecord: LocalMirrorRecord
    let syncState: LocalSyncState
    let workspaceVisibilityState: LocalWorkspaceVisibilityState
    let searchRecord: LocalInventorySearchRecord
}
