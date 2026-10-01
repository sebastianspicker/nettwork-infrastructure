import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Delivers staged-transfer batches to the in-memory server, which applies
/// each one conditionally, and keeps every accepted batch in order.
actor ServerBatchTransport: CloudConditionalBatchTransport {
    private let server: FakeCloudServer
    private(set) var accepted: [AtomicCloudMutation] = []

    init(server: FakeCloudServer) { self.server = server }

    func saveConditionally(_ mutation: AtomicCloudMutation) async throws -> CloudConditionalBatchResult {
        let result = await server.applyConditionally(mutation)
        if result == .accepted { accepted.append(mutation) }
        return result
    }

    /// The staged members of each accepted batch, excluding the session record.
    var memberBatches: [[CloudRecordEnvelope]] {
        accepted.map { $0.records.filter { $0.recordType != CloudStagedTransferRecordType.session } }
    }
}

/// A transfer authority whose staged batches and final activation both reach
/// one precondition-enforcing server. The target sentinel starts empty.
struct StagedTransferHarness {
    let session: SessionHarness
    let server: FakeCloudServer
    let transport: ServerBatchTransport
    let authority: ProductionWorkspaceTransferAuthority

    static let emptyEpoch: UInt64 = 3
    static let emptyTag = "empty-target"

    var namespace: PersistenceNamespace { session.namespace }

    static func make() async throws -> StagedTransferHarness {
        let session = try await SessionHarness.make()
        let server = FakeCloudServer()
        try await server.putSentinel(session.namespace, lifecycle: .empty(epoch: emptyEpoch), tag: emptyTag)
        await server.enforcePreconditions()
        let transport = ServerBatchTransport(server: server)
        let store = try ServiceFixture.makeStore()
        _ = await store.activateLease(for: session.namespace)
        let authority = ProductionWorkspaceTransferAuthority(
            account: session.account, persistence: store, sessionAuthorizer: session.authorizer, exactRecords: server,
            stagedTransfers: CloudStagedTransferRepository(transport: transport, reader: server), mutations: server,
            assetSource: EmptyArchiveAssetSource())
        return StagedTransferHarness(session: session, server: server, transport: transport, authority: authority)
    }

    /// One workspace root and `siteCount` sites beneath it, as v1 CSV rows.
    static func siteImports(siteCount: Int) -> (rootID: ObjectID, siteIDs: [ObjectID], records: [ImportRecord]) {
        let table = CSVTable.locations.rawValue
        let rootID = ObjectID()
        let siteIDs = (0..<siteCount).map { _ in ObjectID() }
        let root = ImportRecord(table: table, values: ["id": rootID.description, "name": "Example", "kind": "workspace", "parentID": "", "deletedAt": ""])
        let sites = siteIDs.enumerated().map { index, id in
            ImportRecord(
                table: table, values: ["id": id.description, "name": "Site \(index)", "kind": "site", "parentID": rootID.description, "deletedAt": ""])
        }
        return (rootID, siteIDs, [root] + sites)
    }

    /// What a mirroring client would observe: the staged members delivered
    /// to the server, plus the server's session and workspace sentinel.
    func observedMirror(sessionKey: ResourceKey) async throws -> [LocalMirrorRecord] {
        let members = await transport.memberBatches.flatMap { $0 }.map { member in
            LocalMirrorRecord(
                namespace: namespace, resourceKey: member.resourceKey, recordType: member.recordType, schemaVersion: member.schemaVersion,
                payload: member.payload, systemFields: Data("staged".utf8), changeTag: "staged", isTombstone: member.isDeleted,
                visibility: member.visibility, recordAssetMetadata: member.recordAsset?.metadata, serverModifiedAt: ServiceFixture.epoch,
                verifiedAt: ServiceFixture.epoch)
        }
        var live: [LocalMirrorRecord] = []
        for key in [sessionKey, ServiceFixture.sentinelKey(namespace)] {
            let snapshot = try await server.requiredSnapshot(for: key)
            live.append(
                LocalMirrorRecord(
                    namespace: namespace, resourceKey: key, recordType: snapshot.recordType, schemaVersion: snapshot.schemaVersion,
                    payload: snapshot.payload, systemFields: snapshot.exactPrecondition.systemFields, changeTag: snapshot.exactPrecondition.changeTag,
                    isTombstone: false, serverModifiedAt: snapshot.serverModifiedAt, verifiedAt: snapshot.serverModifiedAt))
        }
        return members + live
    }

    func activatedCommit(file: StaticString = #filePath, line: UInt = #line) async throws -> WorkspaceActivationCommit {
        let snapshot = try await server.requiredSnapshot(for: ServiceFixture.sentinelKey(namespace))
        let workspace = try CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: snapshot.payload)
        guard case let .active(commit) = workspace.lifecycle else {
            XCTFail("The target workspace was not activated: \(workspace.lifecycle)", file: file, line: line)
            throw ServiceTestError(reason: "inactive target")
        }
        return commit
    }
}
