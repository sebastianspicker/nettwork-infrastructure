import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl
import XCTest

@testable import Persistence

final class InventorySearchIndexMaintenanceBehaviorTests: XCTestCase {
    func testIndexClassificationSeparatesOrdinaryDeltasFullRebuildsAndVisibilityMarkers() {
        let namespace = makeNamespace()
        let ordinary = mirrorRecord(type: "NettworkPort", key: .object(ObjectID()), namespace: namespace)
        let aggregate = mirrorRecord(type: "NettworkPhysicalTopology", key: .string("topology"), namespace: namespace)
        let marker = mirrorRecord(type: "NettworkWorkspaceTransferSession", key: .string("session"), namespace: namespace)

        XCTAssertTrue(InventorySearchIndexBuilder.isIndexAffecting([ordinary]))
        XCTAssertFalse(InventorySearchIndexBuilder.requiresFullRebuild([ordinary]))
        XCTAssertFalse(InventorySearchIndexBuilder.containsVisibilitySentinel([ordinary]))
        XCTAssertTrue(InventorySearchIndexBuilder.isIndexAffecting([aggregate]))
        XCTAssertTrue(InventorySearchIndexBuilder.requiresFullRebuild([aggregate]))
        XCTAssertTrue(InventorySearchIndexBuilder.containsVisibilitySentinel([marker]))
    }

    func testDirtyClosureTraversesDirtyEdgesWithoutFollowingContextBackToSibling() throws {
        let root = ResourceKey.string("root")
        let leaf = ResourceKey.string("leaf")
        let sibling = ResourceKey.string("sibling")
        let edges = [
            InventorySearchIndexBuilder.DependencyEdge(source: root, target: leaf, kind: "dirty.parent.child"),
            InventorySearchIndexBuilder.DependencyEdge(source: leaf, target: sibling, kind: "context.child.sibling"),
        ]

        XCTAssertEqual(
            try InventorySearchIndexBuilder.dirtyClosure(from: [root.description], edges: edges),
            [root.description, leaf.description]
        )
    }

    func testDirectPortAndCableDeltasKeepTheirDifferentDependencyRoles() throws {
        let namespace = makeNamespace()
        let deviceID = ObjectID()
        let port = NetworkModel.Port(deviceID: deviceID, label: "Gi0/1", medium: .copper, connector: .rj45, state: .free)
        let cable = Cable(
            assetCode: AssetCode("PATCH-1"), endpointA: port.id, endpointB: ObjectID(),
            medium: .copper, connector: .rj45, kind: .patchCord, status: .installed
        )
        let portRecord = try mirrorRecord(
            type: "NettworkPort", key: .object(port.id), payload: CanonicalJSONCoding.encode(port), namespace: namespace
        )
        let cableRecord = try mirrorRecord(
            type: "NettworkCable", key: .object(cable.id), payload: CanonicalJSONCoding.encode(cable), namespace: namespace
        )

        let portSeeds = try InventorySearchIndexBuilder.directDependencySeeds([portRecord])
        let cableSeeds = try InventorySearchIndexBuilder.directDependencySeeds([cableRecord])

        XCTAssertEqual(portSeeds.dirty, [])
        XCTAssertEqual(portSeeds.context, [.object(deviceID)])
        XCTAssertEqual(cableSeeds.context, [])
        XCTAssertEqual(cableSeeds.dirty, [.object(cable.endpointA), .object(cable.endpointB)])
    }

    func testPortDerivedNodeIsIncludedForBothLiveAndTombstonedDeltas() throws {
        let namespace = makeNamespace()
        let portID = ObjectID()
        let live = mirrorRecord(type: "NettworkPort", key: .object(portID), namespace: namespace)
        let tombstone = LocalMirrorRecord(
            namespace: namespace, resourceKey: .object(portID), recordType: "NettworkPort", schemaVersion: 1,
            payload: nil, systemFields: nil, changeTag: nil, isTombstone: true,
            serverModifiedAt: .distantPast, verifiedAt: .distantPast
        )
        let derived = ResourceKey.string("inventory-port-state-fact:\(portID.description)")

        XCTAssertEqual(try InventorySearchIndexBuilder.derivedNodeKeys(for: [live]), [.object(portID), derived])
        XCTAssertEqual(try InventorySearchIndexBuilder.derivedNodeKeys(for: [tombstone]), [.object(portID), derived])
    }

    func testPredicateBackedHelpersExecuteDeterministicBoundedFetches() async throws {
        let store = try makeStore()
        let namespace = makeNamespace()
        let keys = (0..<1_801).map { "key-\($0)" }
        let counts = try await store.testPredicateFetchCounts(keys: keys, namespace: namespace)

        XCTAssertEqual(counts[.projectionNode], 3)
        XCTAssertEqual(counts[.incidentSource], 3)
        XCTAssertEqual(counts[.incidentTarget], 3)
        XCTAssertEqual(counts[.incidentSource, default: 0] + counts[.incidentTarget, default: 0], 6)
        XCTAssertEqual(counts[.searchEntry], 3)
    }

    func testBatchedDependencyFrontierTerminatesCyclesAndKeepsNamespaceIsolation() async throws {
        let store = try makeStore()
        let namespace = makeNamespace()
        let other = makeNamespace()
        try await store.insertTestProjectionEdges(
            [
                .init(source: .string("a"), target: .string("b"), kind: "dirty.test"),
                .init(source: .string("b"), target: .string("a"), kind: "dirty.test"),
            ], in: namespace)
        try await store.insertTestProjectionEdges(
            [.init(source: .string("a"), target: .string("foreign"), kind: "dirty.test")],
            in: other)
        let a = ResourceKey.string("a").description
        let b = ResourceKey.string("b").description
        let (result, frontierFetches) = try await store.testReachability(
            from: [a], in: namespace)

        XCTAssertEqual(result, [a, b])
        XCTAssertEqual(frontierFetches, 2)
    }

    func testIncrementalProjectionMatchesFreshFullMaterialization() async throws {
        let namespace = makeNamespace()
        let incrementalStore = try makeStore()
        let fullStore = try makeStore()
        _ = await incrementalStore.activateLease(for: namespace)
        _ = await fullStore.activateLease(for: namespace)
        let emptyMaintenance = LocalMirrorMaintenanceBatch(records: [])
        try await incrementalStore.repairMirrorMaintenanceIndexes(
            records: [], maintenance: emptyMaintenance, in: namespace)
        try await fullStore.repairMirrorMaintenanceIndexes(
            records: [], maintenance: emptyMaintenance, in: namespace)

        let firstID = ObjectID()
        let secondID = ObjectID()
        let typeID = ObjectID()
        let type = try deviceTypeRecord(id: typeID, namespace: namespace)
        let initialFirst = try deviceRecord(
            id: firstID, name: "Before", typeID: typeID, revision: 1, namespace: namespace)
        let updatedFirst = try deviceRecord(
            id: firstID, name: "After", typeID: typeID, revision: 2, namespace: namespace)
        let second = try deviceRecord(
            id: secondID, name: "Unchanged", typeID: typeID, revision: 1, namespace: namespace)
        let active = LocalWorkspaceVisibilityState(
            namespace: namespace,
            lifecycle: .active(commit: .init(transferID: ObjectID(), memberCount: 3, rollingDigest: "projection-test")))

        try await incrementalStore.applyVerifiedMirrorBatch(
            batch(records: [type, initialFirst, second], visibility: active), in: namespace)
        try await incrementalStore.applyVerifiedMirrorBatch(
            batch(records: [updatedFirst]), in: namespace)
        try await fullStore.applyVerifiedMirrorBatch(
            batch(records: [type, updatedFirst, second], visibility: active), in: namespace)

        let incrementalDigest = try await incrementalStore.testInventoryProjectionDigest(in: namespace)
        let fullDigest = try await fullStore.testInventoryProjectionDigest(in: namespace)
        let incrementalRecords = try await incrementalStore.inventorySearchRecords(
            in: namespace, kinds: ["device"], siteID: nil, text: "", limit: 50)
        let fullRecords = try await fullStore.inventorySearchRecords(
            in: namespace, kinds: ["device"], siteID: nil, text: "", limit: 50)

        XCTAssertEqual(incrementalDigest, fullDigest)
        XCTAssertEqual(incrementalRecords, fullRecords)
    }

    func testIncrementalProjectionDoesNotPublishStagedRecordBeforeActivation() async throws {
        let namespace = makeNamespace()
        let store = try makeStore()
        _ = await store.activateLease(for: namespace)
        try await store.repairMirrorMaintenanceIndexes(
            records: [], maintenance: LocalMirrorMaintenanceBatch(records: []), in: namespace)

        let activeTransferID = ObjectID()
        let typeID = ObjectID()
        let active = LocalWorkspaceVisibilityState(
            namespace: namespace,
            lifecycle: .active(
                commit: .init(
                    transferID: activeTransferID, memberCount: 1,
                    rollingDigest: "active-projection")))
        try await store.applyVerifiedMirrorBatch(
            batch(records: [try deviceTypeRecord(id: typeID, namespace: namespace)], visibility: active),
            in: namespace)

        let stagedTransferID = ObjectID()
        let staged = try deviceRecord(
            id: ObjectID(), name: "Unactivated Secret", typeID: typeID, revision: 2,
            namespace: namespace, visibility: .staged(transferID: stagedTransferID))
        let stagedMaintenance = LocalMirrorMaintenanceBatch(
            records: [
                LocalMirrorMaintenanceRecord(
                    resourceKey: staged.resourceKey,
                    transferMember: LocalMirrorTransferMember(
                        transferID: stagedTransferID, resourceKey: staged.resourceKey,
                        digest: "staged-projection"))
            ])
        try await store.applyVerifiedMirrorBatch(
            LocalMirrorBatch(records: [staged], maintenance: stagedMaintenance),
            in: namespace)

        let searchRecords = try await store.inventorySearchRecords(
            in: namespace, kinds: ["device"], siteID: nil, text: "Secret", limit: 50)
        let projection = try await store.testInventoryProjectionDigest(in: namespace)

        XCTAssertTrue(searchRecords.isEmpty)
        XCTAssertFalse(projection.nodes.contains { $0.contains(staged.resourceKey.description) })
    }

    private func makeNamespace() -> PersistenceNamespace {
        let workspaceID = ObjectID()
        return PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork", cloudKitAccountRecordName: "projection-owner",
            workspaceID: workspaceID, zoneName: "projection-zone", zoneOwnerRecordName: "projection-owner", sessionGeneration: 1
        )
    }

    private func makeStore() throws -> SwiftDataPersistenceStore {
        let container = try NettworkPersistenceContainerFactory.make(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        return SwiftDataPersistenceStore(
            container: container,
            attachmentDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func batch(
        records: [LocalMirrorRecord], visibility: LocalWorkspaceVisibilityState? = nil
    ) -> LocalMirrorBatch {
        LocalMirrorBatch(
            records: records, workspaceVisibility: visibility,
            maintenance: LocalMirrorMaintenanceBatch(
                records: records.map { LocalMirrorMaintenanceRecord(resourceKey: $0.resourceKey) }))
    }

    private func deviceRecord(
        id: ObjectID, name: String, typeID: ObjectID, revision: TimeInterval,
        namespace: PersistenceNamespace, visibility: WorkspaceRecordVisibility = .live
    ) throws -> LocalMirrorRecord {
        let device = Device(
            id: id, assetCode: AssetCode("DEVICE-\(id.description.prefix(8))"),
            name: name, typeID: typeID)
        let timestamp = Date(timeIntervalSince1970: revision)
        return LocalMirrorRecord(
            namespace: namespace, resourceKey: .object(id), recordType: "NettworkDevice",
            schemaVersion: 1, payload: try CanonicalJSONCoding.encode(device),
            systemFields: Data("fields-\(revision)".utf8), changeTag: "tag-\(revision)",
            isTombstone: false, visibility: visibility,
            serverModifiedAt: timestamp, verifiedAt: timestamp)
    }

    private func deviceTypeRecord(
        id: ObjectID, namespace: PersistenceNamespace
    ) throws -> LocalMirrorRecord {
        let deviceType = DeviceType(id: id, name: "Switch", kind: .switchDevice)
        return LocalMirrorRecord(
            namespace: namespace, resourceKey: .object(id), recordType: "NettworkDeviceType",
            schemaVersion: 1, payload: try CanonicalJSONCoding.encode(deviceType),
            systemFields: Data("type-fields".utf8), changeTag: "type-tag", isTombstone: false,
            serverModifiedAt: .distantPast, verifiedAt: .distantPast)
    }

    private func mirrorRecord(type: String, key: ResourceKey, payload: Data? = nil, namespace: PersistenceNamespace) -> LocalMirrorRecord {
        LocalMirrorRecord(
            namespace: namespace, resourceKey: key, recordType: type, schemaVersion: 1, payload: payload,
            systemFields: nil, changeTag: nil, isTombstone: false, serverModifiedAt: .distantPast, verifiedAt: .distantPast
        )
    }
}

extension SwiftDataPersistenceStore {
    struct TestInventoryProjectionDigest: Equatable {
        let nodes: [String]
        let edges: [String]
        let entries: [String]
    }

    func testInventoryProjectionDigest(
        in namespace: PersistenceNamespace
    ) throws -> TestInventoryProjectionDigest {
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        let nodes = try inventoryProjectionNodeModels(namespaceKey: namespaceKey).map {
            [$0.storageKey, $0.recordType, $0.payload?.base64EncodedString() ?? "", String($0.isTombstone)]
                .joined(separator: "|")
        }.sorted()
        let edges = try inventoryProjectionEdgeModels(namespaceKey: namespaceKey).map(\.storageKey).sorted()
        let entries = try inventorySearchIndexModels(namespaceKey: namespaceKey).map {
            [$0.storageKey, $0.title, $0.subtitle, $0.searchText, String($0.isPending)]
                .joined(separator: "|")
        }.sorted()
        return TestInventoryProjectionDigest(nodes: nodes, edges: edges, entries: entries)
    }

    func testPredicateFetchCounts(
        keys: [String], namespace: PersistenceNamespace
    ) throws -> [SwiftDataPredicateFetchKind: Int] {
        var counts: [SwiftDataPredicateFetchKind: Int] = [:]
        let observer: SwiftDataPredicateFetchObserver = { kind, size in
            XCTAssertLessThanOrEqual(size, SwiftDataPredicateBatching.maximumKeysPerFetch)
            counts[kind, default: 0] += 1
        }
        _ = try inventoryProjectionNodeModels(storageKeys: keys, namespace: namespace, observer: observer)
        _ = try inventoryProjectionEdges(incidentTo: keys, in: namespace, observer: observer)
        _ = try inventorySearchIndexModels(objectIDValues: keys, in: namespace, observer: observer)
        return counts
    }

    func testReachability(
        from seeds: Set<String>, in namespace: PersistenceNamespace
    ) throws -> (Set<String>, Int) {
        var frontierFetches = 0
        let result = try inventoryProjectionReachable(
            from: seeds, edgePrefix: "dirty.", maximumVisited: 10,
            in: namespace,
            observer: { kind, _ in if kind == .dependencyFrontier { frontierFetches += 1 } })
        return (result, frontierFetches)
    }

    func insertTestProjectionEdges(
        _ edges: [InventorySearchIndexBuilder.DependencyEdge],
        in namespace: PersistenceNamespace
    ) throws {
        for edge in edges {
            modelContext.insert(
                LocalInventoryProjectionEdgeModel(
                    namespace: namespace,
                    sourceKey: edge.source.description,
                    targetKey: edge.target.description,
                    kind: edge.kind))
        }
        try modelContext.save()
    }
}
