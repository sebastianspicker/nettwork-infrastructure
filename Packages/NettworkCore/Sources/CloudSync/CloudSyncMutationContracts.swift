import Foundation
import NetworkModel
import WorkspaceChangeControl

public struct CloudChangeBatch: Codable, Hashable, Sendable {
    public var records: [CloudRecordEnvelope]
    /// Opaque CKSyncEngine state. The store persists it only after all records apply.
    public var newState: Data
    public init(records: [CloudRecordEnvelope], newState: Data) {
        self.records = records
        self.newState = newState
    }
}

public enum CloudRecordPrecondition: Codable, Hashable, Sendable {
    case mustNotExist(recordName: String)
    case exact(recordName: String, systemFields: Data, changeTag: String)

    private enum CodingKeys: String, CodingKey { case kind, recordName, systemFields, changeTag }
    private enum Kind: String, Codable { case mustNotExist, exact }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .recordName)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .mustNotExist: self = .mustNotExist(recordName: name)
        case .exact:
            self = .exact(
                recordName: name, systemFields: try container.decode(Data.self, forKey: .systemFields),
                changeTag: try container.decode(String.self, forKey: .changeTag))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .mustNotExist(let name):
            try container.encode(Kind.mustNotExist, forKey: .kind)
            try container.encode(name, forKey: .recordName)
        case let .exact(name, fields, tag):
            try container.encode(Kind.exact, forKey: .kind)
            try container.encode(name, forKey: .recordName)
            try container.encode(fields, forKey: .systemFields)
            try container.encode(tag, forKey: .changeTag)
        }
    }
}

/// An all-or-nothing same-zone operation. Adapters translate each precondition
/// to its platform conditional-save equivalent; they must not split this batch.
public struct AtomicCloudMutation: Codable, Hashable, Sendable, Identifiable {
    /// Conservative ceiling below CloudKit's operation limit. Staged transfer
    /// append operations may add their one session cursor record separately.
    public static let maximumBusinessRecordsPerOperation = 200
    public let id: ObjectID
    public var operationID: ObjectID
    public var workspaceZone: AuthoritativeWorkspaceZone
    public var records: [CloudRecordEnvelope]
    public var preconditions: [CloudRecordPrecondition]

    public init(
        id _: ObjectID? = nil, operationID: ObjectID, workspaceZone: AuthoritativeWorkspaceZone, records: [CloudRecordEnvelope],
        preconditions: [CloudRecordPrecondition]
    ) {
        self.id = CloudRecordNaming.mutationID(for: operationID)
        self.operationID = operationID
        self.workspaceZone = workspaceZone
        self.records = records
        self.preconditions = preconditions
    }
}

public enum AtomicCloudMutationValidationError: Error, Hashable, Sendable {
    case recordOutsideWorkspace(ResourceKey)
    case nondeterministicRecordName(ResourceKey)
    case duplicateResource(ResourceKey)
    case invalidRecordAsset(ResourceKey)
    case assertionPreservationRequiresExactPrecondition(ResourceKey)
    case preconditionSetMismatch
    case invalidExactPrecondition(String)
    case stagedBatchTooLarge
    case atomicBatchTooLarge
}

public enum AtomicCloudMutationValidator {
    public static func validate(_ mutation: AtomicCloudMutation) throws {
        guard mutation.id == CloudRecordNaming.mutationID(for: mutation.operationID) else {
            throw AtomicCloudMutationValidationError.preconditionSetMismatch
        }
        try validateBatchSize(mutation.records)
        let recordNames = try validateRecords(mutation.records, in: mutation.workspaceZone)
        let preconditions = try indexPreconditions(mutation.preconditions)
        try validatePreconditionSet(preconditions, recordNames: recordNames, count: mutation.preconditions.count)
        try validateAssertionPreservation(mutation.records, preconditions: preconditions)
    }

    private static func validateBatchSize(_ records: [CloudRecordEnvelope]) throws {
        let sessionCount = records.count { $0.recordType == CloudStagedTransferRecordType.session }
        guard sessionCount == 0 || sessionCount == 1 else {
            throw AtomicCloudMutationValidationError.stagedBatchTooLarge
        }
        if sessionCount == 1 {
            let memberCount = records.count - sessionCount
            guard records.count <= CloudStagedTransferLimits.maximumMembersPerBatch + 1,
                memberCount <= CloudStagedTransferLimits.maximumMembersPerBatch
            else {
                throw AtomicCloudMutationValidationError.stagedBatchTooLarge
            }
        } else if records.count > AtomicCloudMutation.maximumBusinessRecordsPerOperation {
            throw AtomicCloudMutationValidationError.atomicBatchTooLarge
        }
    }

    private static func validateRecords(
        _ records: [CloudRecordEnvelope],
        in workspaceZone: AuthoritativeWorkspaceZone
    ) throws -> Set<String> {
        var recordNames = Set<String>()
        var resourceKeys = Set<ResourceKey>()
        for record in records {
            try validateRecordIdentity(record, in: workspaceZone, resourceKeys: &resourceKeys, recordNames: &recordNames)
            try validateRecordAsset(record)
        }
        return recordNames
    }

    private static func validateRecordIdentity(
        _ record: CloudRecordEnvelope,
        in workspaceZone: AuthoritativeWorkspaceZone, resourceKeys: inout Set<ResourceKey>,
        recordNames: inout Set<String>
    ) throws {
        guard record.workspaceID == workspaceZone.workspaceID else {
            throw AtomicCloudMutationValidationError.recordOutsideWorkspace(record.resourceKey)
        }
        guard record.recordName == CloudRecordNaming.recordName(for: record.resourceKey, workspaceID: workspaceZone.workspaceID) else {
            throw AtomicCloudMutationValidationError.nondeterministicRecordName(record.resourceKey)
        }
        guard resourceKeys.insert(record.resourceKey).inserted,
            recordNames.insert(record.recordName).inserted
        else {
            throw AtomicCloudMutationValidationError.duplicateResource(record.resourceKey)
        }
    }

    private static func validateRecordAsset(_ record: CloudRecordEnvelope) throws {
        guard let asset = record.recordAsset else { return }
        guard !record.isDeleted,
            CloudRecordNaming.recordAssetRecordTypes.contains(record.recordType),
            (try? asset.validatedBytes()) != nil
        else {
            throw AtomicCloudMutationValidationError.invalidRecordAsset(record.resourceKey)
        }
    }

    private static func indexPreconditions(_ preconditions: [CloudRecordPrecondition]) throws -> [String: CloudRecordPrecondition] {
        var indexed = [String: CloudRecordPrecondition]()
        for precondition in preconditions {
            let recordName = try validatedRecordName(for: precondition)
            guard indexed[recordName] == nil else {
                throw AtomicCloudMutationValidationError.preconditionSetMismatch
            }
            indexed[recordName] = precondition
        }
        return indexed
    }

    private static func validatedRecordName(for precondition: CloudRecordPrecondition) throws -> String {
        switch precondition {
        case let .mustNotExist(recordName):
            return recordName
        case let .exact(recordName, systemFields, changeTag):
            guard !systemFields.isEmpty,
                !changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw AtomicCloudMutationValidationError.invalidExactPrecondition(recordName)
            }
            return recordName
        }
    }

    private static func validatePreconditionSet(
        _ preconditions: [String: CloudRecordPrecondition],
        recordNames: Set<String>, count: Int
    ) throws {
        guard Set(preconditions.keys) == recordNames, preconditions.count == count else {
            throw AtomicCloudMutationValidationError.preconditionSetMismatch
        }
    }

    private static func validateAssertionPreservation(
        _ records: [CloudRecordEnvelope],
        preconditions: [String: CloudRecordPrecondition]
    ) throws {
        for record in records where record.writeMode == .assertionPreserving {
            guard !record.isDeleted,
                record.recordAsset == nil,
                case .exact? = preconditions[record.recordName]
            else {
                throw AtomicCloudMutationValidationError.assertionPreservationRequiresExactPrecondition(record.resourceKey)
            }
        }
    }
}

public extension CloudRecordNaming {
    /// Only these immutable records are allowed to carry bytes. Every one has
    /// a payload contract that commits the asset metadata and identity.
    static let recordAssetRecordTypes: Set<String> = [
        attachmentEvidenceBindingRecordType,
        floorPlanAssetBindingRecordType, workspaceAssetRecordType,
    ]
}
