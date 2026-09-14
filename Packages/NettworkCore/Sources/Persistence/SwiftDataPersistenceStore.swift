import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

public enum PersistenceStoreError: Error, Hashable, Sendable {
    case invalidNamespace
    case invalidMirrorRecord(ResourceKey)
    case staleMirrorUpdate(ResourceKey)
    case tombstoneResurrection(ResourceKey)
    case malformedStoredValue(String)
    case duplicateOperation(ObjectID)
    case unknownOperation(ObjectID)
    case invalidOperation(ObjectID)
    case invalidLifecycleTransition(ObjectID)
    case missingDependency(ObjectID, ObjectID)
    case missingSharedResourceDependency(ObjectID, ObjectID)
    case invalidReceipt(ObjectID)
    case missingAttachment(ObjectID)
    case attachmentCorrupt(ObjectID)
    case invalidNamespaceLease
    case invalidReservationAcknowledgement(ObjectID)
    case invalidReadLimit
    case invalidCloudRecordNameIdentity(String)
    case cloudRecordNameIdentityCapacityExceeded(Int)
    case inventorySearchIndexCapacityExceeded(Int)
    case inventorySearchTextTooLarge(ObjectID)
    case inventoryProjectionTraversalExceeded(Int)
    case inventoryProjectionNodeCapacityExceeded(Int)
    case inventoryProjectionIncomplete
    case conflictResourceIndexCapacityExceeded(Int)
    case mirrorMaintenanceIncomplete
    case mirrorMaintenanceInvalid(String)
    case mirrorMaintenanceCapacityExceeded(Int)
}

/// A lease is issued by persistence after account/workspace activation. A
/// generation or account switch revokes older leases before the old store is
/// torn down, preventing stale sync callbacks from committing into a mirror.
public struct PersistenceNamespaceLease: Codable, Hashable, Sendable {
    public let id: UUID
    public let namespace: PersistenceNamespace
    public let issuedAt: Date

    public init(id: UUID = UUID(), namespace: PersistenceNamespace, issuedAt: Date = .now) {
        self.id = id
        self.namespace = namespace
        self.issuedAt = issuedAt
    }
}

public struct LocalMirrorBatch: Sendable {
    public let records: [LocalMirrorRecord]
    public let syncState: LocalSyncState?
    public let workspaceVisibility: LocalWorkspaceVisibilityState?
    public let maintenance: LocalMirrorMaintenanceBatch?

    public init(
        records: [LocalMirrorRecord], syncState: LocalSyncState? = nil, workspaceVisibility: LocalWorkspaceVisibilityState? = nil,
        maintenance: LocalMirrorMaintenanceBatch? = nil
    ) {
        self.records = records
        self.syncState = syncState
        self.workspaceVisibility = workspaceVisibility
        self.maintenance = maintenance
    }
}

public struct MirrorRebuildResult: Sendable, Hashable {
    public let deletedMirrorCount: Int
    public let preservedOperationIDs: [ObjectID]
    public let preservedReceiptCount: Int
    public let preservedConflictCount: Int

    public init(deletedMirrorCount: Int, preservedOperationIDs: [ObjectID], preservedReceiptCount: Int, preservedConflictCount: Int) {
        self.deletedMirrorCount = deletedMirrorCount
        self.preservedOperationIDs = preservedOperationIDs
        self.preservedReceiptCount = preservedReceiptCount
        self.preservedConflictCount = preservedConflictCount
    }
}

public extension OutboxStatus {
    /// The caller supplies one namespace only. Every lifecycle state is
    /// represented, including zero counts, so callers never infer a state from
    /// a missing dictionary key. Queued age includes all unaccepted durable
    /// work, including poisoned and conflicted items that require attention.
    static func summarize(_ operations: [OutboxOperation]) -> OutboxStatus {
        let states: [OutboxState] = [.pending, .uploading, .retryScheduled, .conflicted, .poisoned, .accepted]
        var counts = Dictionary(uniqueKeysWithValues: states.map { ($0, 0) })
        for operation in operations {
            counts[operation.state, default: 0] += 1
        }
        let queued = operations.filter { $0.state != .accepted }
        return OutboxStatus(
            totalCount: operations.count, queueDepth: queued.count,
            acceptedHistoryCount: counts[.accepted, default: 0], countsByState: counts,
            oldestQueuedAt: queued.map(\.createdAt).min(),
            nextRetryAt: operations.filter { $0.state == .retryScheduled }.compactMap(\.nextRetryAt).min())
    }
}

/// This is deliberately a scoped byte primitive. F02 is responsible for
/// validating untrusted imports, attachment provenance, image metadata, and
/// authorization before it reaches this store.
actor NamespacedAttachmentFiles {
    let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    func write(_ data: Data, id: ObjectID, namespace: PersistenceNamespace) throws -> String {
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        let directory = rootDirectory.appendingPathComponent(namespaceKey, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = id.description
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        let temporary = directory.appendingPathComponent(".\(fileName).tmp", isDirectory: false)
        try data.write(to: temporary, options: .atomic)
        try protect(temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return "\(namespaceKey)/\(fileName)"
    }

    func read(relativePath: String, id: ObjectID, expectedByteCount: Int) throws -> Data {
        let file = try resolvedFile(relativePath: relativePath, id: id)
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == expectedByteCount else { throw PersistenceStoreError.attachmentCorrupt(id) }
        return data
    }

    func remove(relativePath: String, id: ObjectID) throws {
        let file = try resolvedFile(relativePath: relativePath, id: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    func resolvedFile(relativePath: String, id: ObjectID) throws -> URL {
        let expectedSuffix = "/\(id.description)"
        guard relativePath.hasSuffix(expectedSuffix), !relativePath.contains("..") else {
            throw PersistenceStoreError.attachmentCorrupt(id)
        }
        let file = rootDirectory.appendingPathComponent(relativePath, isDirectory: false)
        guard file.path.hasPrefix(rootDirectory.path + "/") else {
            throw PersistenceStoreError.attachmentCorrupt(id)
        }
        return file
    }

    func protect(_ file: URL) throws {
        #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        #endif
    }
}

/// The actor owns one SwiftData context. Every query and mutation enters this
/// isolation boundary, so model instances never escape into features or sync.
public actor SwiftDataPersistenceStore: TopologyRepository, IPAMRepository, WorkOrderRepository, AuditRepository, AttachmentStore, MutationOutbox,
    ConflictResolver
{
    let modelContext: ModelContext
    let attachmentFiles: NamespacedAttachmentFiles
    var activeLeaseIDs = [String: UUID]()

    public init(container: ModelContainer, attachmentDirectory: URL) {
        modelContext = ModelContext(container)
        attachmentFiles = NamespacedAttachmentFiles(rootDirectory: attachmentDirectory)
    }

    public func activateLease(for namespace: PersistenceNamespace, issuedAt: Date = .now) -> PersistenceNamespaceLease {
        activeLeaseIDs.removeAll()
        let lease = PersistenceNamespaceLease(namespace: namespace, issuedAt: issuedAt)
        activeLeaseIDs[PersistenceNamespaceKey.value(for: namespace)] = lease.id
        return lease
    }

    public func invalidate(_ lease: PersistenceNamespaceLease) {
        let key = PersistenceNamespaceKey.value(for: lease.namespace)
        guard activeLeaseIDs[key] == lease.id else { return }
        activeLeaseIDs.removeValue(forKey: key)
    }

    public func invalidateLease(for namespace: PersistenceNamespace) {
        activeLeaseIDs.removeValue(forKey: PersistenceNamespaceKey.value(for: namespace))
    }

    // MARK: Durable CloudKit record-name identities

    /// Returns deletion identity evidence only while this exact account and
    /// workspace generation owns an active persistence lease.
    public func cloudRecordNameIdentity(
        for recordName: String, in namespace: PersistenceNamespace
    ) throws -> LocalCloudRecordNameIdentity? {
        try validateActiveLease(for: namespace)
        let storageKey = PersistenceNamespaceKey.storageKey(
            namespace: namespace,
            identity: "cloud-record-name-identity:\(recordName)")
        guard let model = try cloudRecordNameIdentityModel(matching: storageKey) else {
            return nil
        }
        return try decodeCloudRecordNameIdentity(model, namespace: namespace)
    }
}
