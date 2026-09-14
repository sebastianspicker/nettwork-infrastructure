import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum RemoteRecordValidationError: Error, Hashable, Sendable {
    case unknownRecordType(String)
    case unsupportedSchema(recordType: String, version: Int)
    case recordOutsideWorkspace(ResourceKey)
    case invalidRecordName(String)
    case nonDeterministicRecordName(ResourceKey)
    case payloadTooLarge(ResourceKey, actual: Int, maximum: Int)
    case systemFieldsTooLarge(ResourceKey, actual: Int, maximum: Int)
    case emptyPayload(ResourceKey)
    case missingChangeTag(ResourceKey)
    case tombstoneNotAllowed(ResourceKey)
    case invalidRecordAsset(ResourceKey)
    case invalidVisibility(ResourceKey)
    case duplicateResource(ResourceKey)
}

public struct VerifiedCloudRecord: Codable, Hashable, Sendable, Identifiable {
    public let envelope: CloudRecordEnvelope
    public var id: ObjectID { envelope.id }
    public init(envelope: CloudRecordEnvelope) { self.envelope = envelope }
}

/// Stored separately from authoritative mirrors. Invalid input is never decoded
/// into a feature model or allowed to advance the persisted sync state.
public struct QuarantinedCloudRecord: Codable, Hashable, Sendable, Identifiable {
    public static let maximumPreservedEnvelopeBytes = 65_536
    public let id: ObjectID
    public let recordName: String
    public let resourceKey: ResourceKey
    public let recordType: String
    public let reason: String
    /// Bounded canonical envelope evidence. It is never decoded as a domain record.
    public let boundedEnvelope: Data
    public let observedAt: Date

    public init(id: ObjectID = .init(), envelope: CloudRecordEnvelope, reason: String, observedAt: Date = .now) throws {
        self.id = id
        self.recordName = envelope.recordName
        self.resourceKey = envelope.resourceKey
        self.recordType = envelope.recordType
        self.reason = reason
        let encoded = try CloudDeterministicCoding.encode(envelope)
        self.boundedEnvelope = Data(encoded.prefix(Self.maximumPreservedEnvelopeBytes))
        self.observedAt = observedAt
    }
}

public struct CloudRemoteRecordValidator: Sendable {
    public let schemas: [String: CloudRecordSchema]
    public let maximumSystemFieldsBytes: Int

    public init(schemas: Set<CloudRecordSchema> = CloudRecordSchema.authoritative, maximumSystemFieldsBytes: Int = 262_144) {
        var indexed: [String: CloudRecordSchema] = [:]
        for schema in schemas where indexed[schema.recordType] == nil { indexed[schema.recordType] = schema }
        self.schemas = indexed
        self.maximumSystemFieldsBytes = maximumSystemFieldsBytes
    }

    public func validate(_ envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) throws -> VerifiedCloudRecord {
        try validateIdentity(envelope, namespace: namespace)
        let schema = try validateSchemaAndPayload(envelope)
        try validateTombstoneAndAsset(envelope, schema: schema)
        try validateVisibility(envelope, namespace: namespace)
        return VerifiedCloudRecord(envelope: envelope)
    }

    private func validateIdentity(_ envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) throws {
        guard envelope.workspaceID == namespace.workspaceID else { throw RemoteRecordValidationError.recordOutsideWorkspace(envelope.resourceKey) }
        guard envelope.id == CloudRecordNaming.envelopeID(for: envelope.resourceKey, workspaceID: namespace.workspaceID) else {
            throw RemoteRecordValidationError.nonDeterministicRecordName(envelope.resourceKey)
        }
        guard CloudRecordNaming.isValidRecordName(envelope.recordName) else { throw RemoteRecordValidationError.invalidRecordName(envelope.recordName) }
        guard envelope.recordName == CloudRecordNaming.recordName(for: envelope.resourceKey, workspaceID: namespace.workspaceID) else {
            throw RemoteRecordValidationError.nonDeterministicRecordName(envelope.resourceKey)
        }
    }

    private func validateSchemaAndPayload(_ envelope: CloudRecordEnvelope) throws -> CloudRecordSchema {
        guard let schema = schemas[envelope.recordType] else { throw RemoteRecordValidationError.unknownRecordType(envelope.recordType) }
        guard envelope.schemaVersion == schema.schemaVersion else {
            throw RemoteRecordValidationError.unsupportedSchema(recordType: envelope.recordType, version: envelope.schemaVersion)
        }
        guard envelope.payload.count <= schema.maximumPayloadBytes else {
            throw RemoteRecordValidationError.payloadTooLarge(envelope.resourceKey, actual: envelope.payload.count, maximum: schema.maximumPayloadBytes)
        }
        guard envelope.systemFields.count <= maximumSystemFieldsBytes else {
            throw RemoteRecordValidationError.systemFieldsTooLarge(envelope.resourceKey, actual: envelope.systemFields.count, maximum: maximumSystemFieldsBytes)
        }
        return schema
    }

    private func validateTombstoneAndAsset(_ envelope: CloudRecordEnvelope, schema: CloudRecordSchema) throws {
        guard !envelope.isDeleted || schema.allowsTombstone else { throw RemoteRecordValidationError.tombstoneNotAllowed(envelope.resourceKey) }
        guard envelope.isDeleted || !envelope.payload.isEmpty else { throw RemoteRecordValidationError.emptyPayload(envelope.resourceKey) }
        guard !envelope.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteRecordValidationError.missingChangeTag(envelope.resourceKey)
        }
        if case .staged = envelope.visibility,
            CloudStagedTransferRecordType.infrastructure.contains(envelope.recordType)
        {
            throw RemoteRecordValidationError.invalidVisibility(envelope.resourceKey)
        }
        if let asset = envelope.recordAsset {
            guard !envelope.isDeleted,
                CloudRecordNaming.recordAssetRecordTypes.contains(envelope.recordType),
                (try? asset.validatedBytes()) != nil
            else {
                throw RemoteRecordValidationError.invalidRecordAsset(envelope.resourceKey)
            }
        }
    }

    private func validateVisibility(_ envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) throws {
        if envelope.recordType == CloudRecordNaming.importedHistoricalReferenceRecordType {
            try validateImportedHistoricalReference(envelope, namespace: namespace)
        }
    }

    private func validateImportedHistoricalReference(_ envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) throws {
        guard envelope.isDeleted, case .staged = envelope.visibility,
            let marker = try? CloudDeterministicCoding.decode(ImportedHistoricalReferenceRecord.self, from: envelope.payload),
            (try? CloudDeterministicCoding.encode(marker)) == envelope.payload
        else { throw RemoteRecordValidationError.invalidVisibility(envelope.resourceKey) }
        guard marker.resourceKey == envelope.resourceKey, marker.sourceWorkspaceID != namespace.workspaceID else {
            throw RemoteRecordValidationError.invalidVisibility(envelope.resourceKey)
        }
        guard !marker.sourceContainerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !marker.sourceZoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !marker.sourceZoneOwnerRecordName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw RemoteRecordValidationError.invalidVisibility(envelope.resourceKey) }
        guard !marker.auditEventIDs.isEmpty, marker.auditEventIDs == marker.auditEventIDs.sorted(),
            Set(marker.auditEventIDs).count == marker.auditEventIDs.count
        else { throw RemoteRecordValidationError.invalidVisibility(envelope.resourceKey) }
    }

    public func validate(_ batch: CloudChangeBatch, namespace: PersistenceNamespace) throws -> [VerifiedCloudRecord] {
        var seen = Set<ResourceKey>()
        var verified: [VerifiedCloudRecord] = []
        for record in batch.records {
            guard seen.insert(record.resourceKey).inserted else { throw RemoteRecordValidationError.duplicateResource(record.resourceKey) }
            verified.append(try validate(record, namespace: namespace))
        }
        return verified
    }

    /// Keeps valid peer records out of quarantine when one envelope makes the
    /// whole batch/cursor ineligible for application. Unknown errors identify
    /// no record rather than broadening quarantine evidence speculatively.
    public func offendingRecords(in batch: CloudChangeBatch, for error: Error) -> [CloudRecordEnvelope] {
        guard let validation = error as? RemoteRecordValidationError else { return [] }
        switch validation {
        case let .unknownRecordType(recordType):
            return batch.records.filter { $0.recordType == recordType }
        case let .unsupportedSchema(recordType, version):
            return batch.records.filter { $0.recordType == recordType && $0.schemaVersion == version }
        case let .recordOutsideWorkspace(key), let .nonDeterministicRecordName(key), let .payloadTooLarge(key, _, _), let .systemFieldsTooLarge(key, _, _),
            let .emptyPayload(key), let .missingChangeTag(key),
            let .tombstoneNotAllowed(key), let .invalidRecordAsset(key), let .invalidVisibility(key), let .duplicateResource(key):
            return batch.records.filter { $0.resourceKey == key }
        case let .invalidRecordName(recordName):
            return batch.records.filter { $0.recordName == recordName }
        }
    }
}

public enum CloudRemoteQuarantineSelection {
    public static func records(in batch: CloudChangeBatch, validator: CloudRemoteRecordValidator, error: Error) -> [CloudRecordEnvelope] {
        let structural = validator.offendingRecords(in: batch, for: error)
        guard structural.isEmpty else { return structural }
        if let semantic = error as? CloudMirrorAdapterError {
            switch semantic {
            case let .malformedPayload(key, _): return batch.records.filter { $0.resourceKey == key }
            case let .unsupportedSemanticRecord(recordType): return batch.records.filter { $0.recordType == recordType }
            case .namespaceNotOpen: return []
            }
        }
        if let reference = error as? CloudRemoteReferenceValidationError {
            return batch.records.filter { reference.invalidResourceKeys.contains($0.resourceKey) }
        }
        return []
    }
}

public enum CloudFailureClassifier {
    public static func classify(_ error: Error) -> SyncFailure {
        if let transport = error as? CloudTransportFailure { return transport.failure }
        return SyncFailure(category: category(for: error), message: String(describing: error))
    }

    private static func category(for error: Error) -> SyncFailureCategory {
        if error is RemoteRecordValidationError || error is CloudMirrorAdapterError || error is CloudRemoteReferenceValidationError {
            return .malformedRemoteRecord
        }
        if isValidationError(error) { return .validation }
        if error is OfficialClientPolicyError { return .permissionDenied }
        if error is CloudSessionError { return .accountUnavailable }
        return .unknown
    }

    private static func isValidationError(_ error: Error) -> Bool {
        error is OfflineEligibilityError
            || error is CloudMutationEncodingError
            || error is AtomicCloudMutationValidationError
            || error is AuthoritativeMutationValidationError
            || error is AuthoritativeActivationMutationValidationError
            || error is CloudStagedTransferError
            || error is WorkOrderTransitionError
    }

    public static func isPoison(_ failure: SyncFailure) -> Bool {
        switch failure.category {
        case .validation, .permissionDenied, .security, .malformedRemoteRecord: true
        case .network, .rateLimited, .quotaExceeded, .accountUnavailable, .conflict, .unknown: false
        }
    }
}
