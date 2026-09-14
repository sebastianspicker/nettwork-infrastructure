import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum CloudActivationMutationEncodingError: Error, Hashable, Sendable {
    case duplicateRecord(ResourceKey)
    case missingCloudPrecondition(ResourceKey)
    case invalidRecordType(String)
    case invalidRecordName(ResourceKey)
}

/// Byte-stable CloudKit serialization for work-order-free authoritative activations.
public enum CloudActivationMutationEncoder {
    public static func encode(
        _ mutation: AuthoritativeActivationMutation,
        against state: AuthoritativeActivationMutationState
    ) throws -> AtomicCloudMutation {
        try AuthoritativeActivationMutationValidator.validate(mutation, against: state)
        let records = try records(for: mutation)
        let encoded = AtomicCloudMutation(
            operationID: mutation.operationID,
            workspaceZone: mutation.workspaceZone, records: records,
            preconditions: preconditions(for: mutation))
        try AtomicCloudMutationValidator.validate(encoded)
        return encoded
    }

    private static func records(for mutation: AuthoritativeActivationMutation) throws -> [CloudRecordEnvelope] {
        var assembly = RecordAssembly(mutation: mutation)
        try assembly.appendSaves()
        try assembly.appendTombstones()
        try assembly.appendAssertions()
        try assembly.appendAuditAndReceipt()
        return assembly.records
    }

    private static func preconditions(for mutation: AuthoritativeActivationMutation) -> [CloudRecordPrecondition] {
        mutation.preconditions.map { value in
            let recordName = CloudRecordNaming.recordName(
                for: value.resourceKey, workspaceID: mutation.workspaceZone.workspaceID)
            return value.cloudPrecondition(recordName: recordName)
        }.sorted { $0.preconditionRecordName < $1.preconditionRecordName }
    }

    private struct RecordAssembly {
        let mutation: AuthoritativeActivationMutation
        private var assembly = CloudRecordEnvelopeAccumulator()

        var records: [CloudRecordEnvelope] { assembly.records }

        init(mutation: AuthoritativeActivationMutation) {
            self.mutation = mutation
        }

        mutating func appendSaves() throws {
            for save in mutation.saves.sorted(by: { $0.resourceKey < $1.resourceKey }) {
                try append(save.resourceKey, type: save.recordType, version: save.schemaVersion, payload: save.encodedRecord, asset: save.recordAsset)
            }
        }

        mutating func appendTombstones() throws {
            for value in mutation.tombstones.sorted(by: { $0.resourceKey < $1.resourceKey }) {
                try append(value.resourceKey, type: value.recordType, version: CloudRecordNaming.schemaVersion, payload: value.encodedTombstone, deleted: true)
            }
        }

        mutating func appendAssertions() throws {
            for value in mutation.readAssertions.sorted(by: { $0.resourceKey < $1.resourceKey }) {
                guard CloudRecordNaming.canonicalRecordType(value.recordType) == value.recordType,
                    value.schemaVersion == CloudRecordNaming.schemaVersion
                else {
                    throw CloudActivationMutationEncodingError.invalidRecordType(value.recordType)
                }
                try append(value.resourceKey, type: value.recordType, version: value.schemaVersion, payload: value.encodedRecord, mode: .assertionPreserving)
            }
        }

        mutating func appendAuditAndReceipt() throws {
            try append(
                .object(mutation.auditEvent.id), type: CloudRecordNaming.auditRecordType, version: CloudRecordNaming.schemaVersion,
                payload: mutation.encodedAuditEvent)
            try append(
                mutation.receipt.id, type: CloudRecordNaming.receiptRecordType, version: CloudRecordNaming.schemaVersion, payload: mutation.encodedReceipt)
        }

        private mutating func append(
            _ key: ResourceKey, type: String, version: Int, payload: Data,
            asset: CloudRecordAssetDescriptor? = nil, mode: CloudRecordWriteMode = .businessSave,
            deleted: Bool = false
        ) throws {
            let mutation = mutation
            try assembly.append(
                key,
                type: type,
                version: version,
                payload: payload,
                workspaceID: mutation.workspaceZone.workspaceID,
                asset: asset,
                mode: mode,
                deleted: deleted,
                condition: { try mutation.cloudPrecondition(for: $0) },
                duplicateError: CloudActivationMutationEncodingError.duplicateRecord,
                invalidTypeError: CloudActivationMutationEncodingError.invalidRecordType,
                invalidNameError: CloudActivationMutationEncodingError.invalidRecordName)
        }
    }
}

private extension AuthoritativeActivationMutation {
    func cloudPrecondition(for key: ResourceKey) throws -> (systemFields: Data, changeTag: String) {
        guard let value = preconditions.first(where: { $0.resourceKey == key }) else {
            throw CloudActivationMutationEncodingError.missingCloudPrecondition(key)
        }
        switch value {
        case .mustNotExist: return (Data(), "")
        case .exactSystemFields(_, let exact): return (exact.systemFields, exact.changeTag)
        }
    }
}
