import Foundation
import NetworkModel

public enum OutboxState: String, Codable, Hashable, Sendable {
    case pending
    case uploading
    case retryScheduled
    case conflicted
    case poisoned
    case accepted
}

public enum SyncFailureCategory: String, Codable, Hashable, Sendable {
    case network
    case rateLimited
    case quotaExceeded
    case accountUnavailable
    case permissionDenied
    case validation
    case conflict
    case malformedRemoteRecord
    case security
    case unknown
}

public struct SyncFailure: Codable, Hashable, Sendable {
    public let category: SyncFailureCategory
    public let message: String
    public let retryAfter: Date?
    public let resourceKeys: Set<ResourceKey>

    public init(category: SyncFailureCategory, message: String, retryAfter: Date? = nil, resourceKeys: Set<ResourceKey> = []) {
        self.category = category
        self.message = message
        self.retryAfter = retryAfter
        self.resourceKeys = resourceKeys
    }
}

public struct ReconciliationSnapshot: Codable, Hashable, Sendable {
    public let resourceKey: ResourceKey
    public let recordType: String
    public let schemaVersion: Int
    public let encodedRecord: Data?
    public let systemFields: Data?
    public let changeTag: String?
    public let isTombstone: Bool

    public init(
        resourceKey: ResourceKey, recordType: String, schemaVersion: Int, encodedRecord: Data?, systemFields: Data?, changeTag: String?, isTombstone: Bool
    ) {
        self.resourceKey = resourceKey
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.encodedRecord = encodedRecord
        self.systemFields = systemFields
        self.changeTag = changeTag
        self.isTombstone = isTombstone
    }
}

/// Immutable offline execution evidence. The encoded mutation carries exact base preconditions.
public struct ExecutionEnvelope: Codable, Hashable, Sendable {
    public let mutation: AuthoritativeMutation
    public let accountContext: AccountContext
    public let actorContext: ActorContext
    public let clientTime: Date
    public let ticket: String?
    public let notes: String?
    public let baseSnapshots: [ResourceKey: ReconciliationSnapshot]

    public init(
        mutation: AuthoritativeMutation, accountContext: AccountContext, actorContext: ActorContext, clientTime: Date, ticket: String?, notes: String?,
        baseSnapshots: [ResourceKey: ReconciliationSnapshot]
    ) {
        self.mutation = mutation
        self.accountContext = accountContext
        self.actorContext = actorContext
        self.clientTime = clientTime
        self.ticket = ticket
        self.notes = notes
        self.baseSnapshots = baseSnapshots
    }
}

public struct OutboxOperation: Identifiable, Codable, Hashable, Sendable {
    public var id: ObjectID { operationID }
    public let operationID: ObjectID
    public let namespace: PersistenceNamespace
    public let envelope: ExecutionEnvelope
    public let resourceKeys: Set<ResourceKey>
    public let dependencyOperationIDs: Set<ObjectID>
    public let createdAt: Date
    public var state: OutboxState
    public var attemptCount: Int
    public var nextRetryAt: Date?
    public var lastFailure: SyncFailure?
    public var receipt: OperationReceipt?

    public init(
        operationID: ObjectID, namespace: PersistenceNamespace, envelope: ExecutionEnvelope, resourceKeys: Set<ResourceKey>,
        dependencyOperationIDs: Set<ObjectID>, createdAt: Date = .now,
        state: OutboxState = .pending, attemptCount: Int = 0, nextRetryAt: Date? = nil, lastFailure: SyncFailure? = nil, receipt: OperationReceipt? = nil
    ) {
        self.operationID = operationID
        self.namespace = namespace
        self.envelope = envelope
        self.resourceKeys = resourceKeys
        self.dependencyOperationIDs = dependencyOperationIDs
        self.createdAt = createdAt
        self.state = state
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.lastFailure = lastFailure
        self.receipt = receipt
    }
}

public struct OutboxStatus: Codable, Hashable, Sendable {
    public let totalCount: Int
    public let queueDepth: Int
    public let acceptedHistoryCount: Int
    public let countsByState: [OutboxState: Int]
    public let oldestQueuedAt: Date?
    public let nextRetryAt: Date?

    public init(totalCount: Int, queueDepth: Int, acceptedHistoryCount: Int, countsByState: [OutboxState: Int], oldestQueuedAt: Date?, nextRetryAt: Date?) {
        self.totalCount = totalCount
        self.queueDepth = queueDepth
        self.acceptedHistoryCount = acceptedHistoryCount
        self.countsByState = countsByState
        self.oldestQueuedAt = oldestQueuedAt
        self.nextRetryAt = nextRetryAt
    }
}

public struct SyncReceipt: Codable, Hashable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var uploadedOperationIDs: [ObjectID]
    public var downloadedRecordCount: Int
    public var downloadedAssetCount: Int
    public var failures: [SyncFailure]
    public var queueDepth: Int
    public var oldestQueuedAt: Date?
    public var quarantineCount: Int
    public var conflictCount: Int
    public var lastSuccessfulServerContact: Date?

    public init(
        startedAt: Date = .now, finishedAt: Date = .now, uploadedOperationIDs: [ObjectID] = [], downloadedRecordCount: Int = 0, downloadedAssetCount: Int = 0,
        failures: [SyncFailure] = [], queueDepth: Int = 0,
        oldestQueuedAt: Date? = nil, quarantineCount: Int = 0, conflictCount: Int = 0, lastSuccessfulServerContact: Date? = nil
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.uploadedOperationIDs = uploadedOperationIDs
        self.downloadedRecordCount = downloadedRecordCount
        self.downloadedAssetCount = downloadedAssetCount
        self.failures = failures
        self.queueDepth = queueDepth
        self.oldestQueuedAt = oldestQueuedAt
        self.quarantineCount = quarantineCount
        self.conflictCount = conflictCount
        self.lastSuccessfulServerContact = lastSuccessfulServerContact
    }

    public init(startedAt: Date = .now, finishedAt: Date = .now, uploadedOperationIDs: [ObjectID] = [], errors: [String]) {
        self.init(
            startedAt: startedAt, finishedAt: finishedAt, uploadedOperationIDs: uploadedOperationIDs,
            failures: errors.map { SyncFailure(category: .unknown, message: $0) })
    }

    public var errors: [String] { failures.map(\.message) }
}

public enum ReconciliationReason: String, Codable, Hashable, Sendable {
    case serverRecordChanged
    case receiptDigestMismatch
    case reservationInvalid
    case permissionRevoked
    case malformedPeerState
    case unknown
}

public struct ReconciliationCase: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public let namespace: PersistenceNamespace
    public let operationID: ObjectID
    public let resourceKeys: Set<ResourceKey>
    public let reason: ReconciliationReason
    public let base: [ResourceKey: ReconciliationSnapshot]
    public let intended: [ResourceKey: ReconciliationSnapshot]
    public let current: [ResourceKey: ReconciliationSnapshot]
    public let detectedAt: Date
    public let isSecurityEvent: Bool

    public init(
        id: ObjectID = .init(), namespace: PersistenceNamespace, operationID: ObjectID, resourceKeys: Set<ResourceKey>, reason: ReconciliationReason,
        base: [ResourceKey: ReconciliationSnapshot],
        intended: [ResourceKey: ReconciliationSnapshot], current: [ResourceKey: ReconciliationSnapshot], detectedAt: Date = .now, isSecurityEvent: Bool = false
    ) {
        self.id = id
        self.namespace = namespace
        self.operationID = operationID
        self.resourceKeys = resourceKeys
        self.reason = reason
        self.base = base
        self.intended = intended
        self.current = current
        self.detectedAt = detectedAt
        self.isSecurityEvent = isSecurityEvent
    }
}

public struct ImportRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var table: String
    public var values: [String: String]
    public init(id: ObjectID = .init(), table: String, values: [String: String]) {
        self.id = id
        self.table = table
        self.values = values
    }
}
