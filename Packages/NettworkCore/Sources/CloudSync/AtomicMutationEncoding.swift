import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum CloudMutationEncodingError: Error, Hashable, Sendable {
    case duplicateRecord(ResourceKey)
    case missingCloudPrecondition(ResourceKey)
    case invalidRecordType(String)
    case invalidRecordName(ResourceKey)
    case invalidReadAssertion(ResourceKey)
}

/// Serializes the domain's single commit object without generating any new IDs,
/// dates, digests, or receipt data. This makes a lost-response retry byte-stable.
public enum CloudMutationEncoder {
    public static func encode(_ mutation: AuthoritativeMutation, against state: AuthoritativeMutationState) throws -> AtomicCloudMutation {
        try AuthoritativeMutationValidator.validate(mutation, against: state)
        let encoded = AtomicCloudMutation(
            operationID: mutation.operationID, workspaceZone: mutation.workspaceZone, records: try records(for: mutation),
            preconditions: preconditions(for: mutation))
        try AtomicCloudMutationValidator.validate(encoded)
        return encoded
    }

    private static func records(for mutation: AuthoritativeMutation) throws -> [CloudRecordEnvelope] {
        var assembly = CloudMutationRecordAssembly(mutation: mutation)
        try assembly.appendBusinessRecords()
        try assembly.appendReadAssertions()
        try assembly.appendOperationEvidence()
        return assembly.records
    }

    private static func preconditions(for mutation: AuthoritativeMutation) -> [CloudRecordPrecondition] {
        mutation.preconditions.map { value in
            value.cloudPrecondition(recordName: CloudRecordNaming.recordName(for: value.resourceKey, workspaceID: mutation.workspaceZone.workspaceID))
        }.sorted { $0.preconditionRecordName < $1.preconditionRecordName }
    }

    fileprivate static func cloudPrecondition(for key: ResourceKey, mutation: AuthoritativeMutation) throws -> (systemFields: Data, changeTag: String) {
        guard let value = mutation.preconditions.first(where: { $0.resourceKey == key }) else { throw CloudMutationEncodingError.missingCloudPrecondition(key) }
        switch value {
        case .mustNotExist: return (Data(), "")
        case .exactSystemFields(_, let exact): return (exact.systemFields, exact.changeTag)
        }
    }
}

private struct CloudMutationRecordAssembly {
    let mutation: AuthoritativeMutation
    private var assembly = CloudRecordEnvelopeAccumulator()

    var records: [CloudRecordEnvelope] { assembly.records }

    init(mutation: AuthoritativeMutation) {
        self.mutation = mutation
    }

    mutating func appendBusinessRecords() throws {
        for value in mutation.saves.sorted(by: { $0.resourceKey < $1.resourceKey }) {
            try append(value.resourceKey, type: value.recordType, version: value.schemaVersion, payload: value.encodedRecord, asset: value.recordAsset)
        }
        for value in mutation.tombstones.sorted(by: { $0.resourceKey < $1.resourceKey }) {
            try append(value.resourceKey, type: value.recordType, version: CloudRecordNaming.schemaVersion, payload: value.encodedTombstone, deleted: true)
        }
    }

    mutating func appendReadAssertions() throws {
        for value in mutation.readAssertions.sorted(by: { $0.resourceKey < $1.resourceKey }) {
            guard CloudRecordNaming.canonicalRecordType(value.recordType) == value.recordType, value.schemaVersion == CloudRecordNaming.schemaVersion else {
                throw CloudMutationEncodingError.invalidReadAssertion(value.resourceKey)
            }
            try append(value.resourceKey, type: value.recordType, version: value.schemaVersion, payload: value.encodedRecord, mode: .assertionPreserving)
        }
    }

    mutating func appendOperationEvidence() throws {
        try append(
            .object(mutation.workOrder.id), type: CloudRecordNaming.workOrderRecordType, version: CloudRecordNaming.schemaVersion,
            payload: mutation.encodedWorkOrder)
        try append(
            .object(mutation.auditEvent.id), type: CloudRecordNaming.auditRecordType, version: CloudRecordNaming.schemaVersion,
            payload: mutation.encodedAuditEvent)
        try append(mutation.receipt.id, type: CloudRecordNaming.receiptRecordType, version: CloudRecordNaming.schemaVersion, payload: mutation.encodedReceipt)
    }

    private mutating func append(
        _ key: ResourceKey, type: String, version: Int, payload: Data, asset: CloudRecordAssetDescriptor? = nil, mode: CloudRecordWriteMode = .businessSave,
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
            condition: { try CloudMutationEncoder.cloudPrecondition(for: $0, mutation: mutation) },
            duplicateError: CloudMutationEncodingError.duplicateRecord,
            invalidTypeError: CloudMutationEncodingError.invalidRecordType,
            invalidNameError: CloudMutationEncodingError.invalidRecordName)
    }
}

public enum CloudDeterministicCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

public enum OfflineEligibilityError: Error, Hashable, Sendable {
    case namespaceMismatch
    case staleSession
    case actorMismatch
    case intentMismatch
    case reservationMissing
    case reservationNotAcknowledged
    case reservationOwnerMismatch
    case reservationDoesNotExactlyCoverMutation
    case acknowledgementScopeMismatch
    case acknowledgementSessionMismatch
    case acknowledgementReservationMismatch
    case acknowledgementIntentMismatch
    case acknowledgementMissingConditionalMetadata
    case acknowledgementExpired
    case operationResourceSetMismatch
}

public enum OfflineExecutionEligibility {
    public static func validate(_ operation: OutboxOperation, account: AccountContext, actor: ActorContext) throws {
        try OfflineEligibilitySnapshot(operation: operation, account: account, actor: actor).validate()
    }
}

private struct OfflineEligibilitySnapshot {
    let operation: OutboxOperation
    let account: AccountContext
    let actor: ActorContext

    func validate() throws {
        try validateSessionAndActor()
        let reservation = try requireReservation()
        let acknowledgement = try requireAcknowledgement(reservation)
        try validateIntent(reservation, acknowledgement)
        try validateConditionalWindow(acknowledgement)
        try validateResourceCoverage(reservation)
    }

    private func validateSessionAndActor() throws {
        let envelope = operation.envelope
        guard operation.namespace == account.namespace, CloudAccountContextMatcher.sameScope(envelope.accountContext, account) else {
            throw OfflineEligibilityError.namespaceMismatch
        }
        guard actor.sessionGeneration == account.namespace.sessionGeneration, envelope.actorContext == actor else { throw OfflineEligibilityError.staleSession }
        guard envelope.mutation.actor.actorID == actor.cloudKitUserRecordName, envelope.mutation.actor.installationID == actor.installationID,
            envelope.mutation.actor.sessionGeneration == actor.sessionGeneration
        else { throw OfflineEligibilityError.actorMismatch }
        guard envelope.mutation.intentDigest == envelope.mutation.workOrder.intentDigest else { throw OfflineEligibilityError.intentMismatch }
    }

    private func requireReservation() throws -> WorkOrderReservation {
        guard let value = operation.envelope.mutation.workOrder.reservation else { throw OfflineEligibilityError.reservationMissing }
        guard value.ownerID == actor.cloudKitUserRecordName else { throw OfflineEligibilityError.reservationOwnerMismatch }
        return value
    }

    private func requireAcknowledgement(_ reservation: WorkOrderReservation) throws -> CloudKitAcknowledgement {
        guard let value = reservation.acknowledgedByCloudKit else { throw OfflineEligibilityError.reservationNotAcknowledged }
        guard value.workspaceZone == account.namespace.workspaceZone, value.cloudKitAccountRecordName == account.namespace.cloudKitAccountRecordName else {
            throw OfflineEligibilityError.acknowledgementScopeMismatch
        }
        guard value.sessionGeneration == account.namespace.sessionGeneration else { throw OfflineEligibilityError.acknowledgementSessionMismatch }
        guard value.reservationID == reservation.id, value.workOrderID == operation.envelope.mutation.workOrder.id, value.ownerID == reservation.ownerID,
            value.resourceKeys == reservation.resourceKeys
        else { throw OfflineEligibilityError.acknowledgementReservationMismatch }
        return value
    }

    private func validateIntent(_ reservation: WorkOrderReservation, _ acknowledgement: CloudKitAcknowledgement) throws {
        let workOrder = operation.envelope.mutation.workOrder
        let intent = CanonicalWorkIntent(
            intentSchemaVersion: workOrder.intentSchemaVersion ?? 1, workOrderID: workOrder.id, kind: workOrder.kind, creatorID: workOrder.creatorID,
            ticket: workOrder.ticket,
            notes: workOrder.notes, operations: workOrder.plannedOperations, resourceKeys: reservation.resourceKeys, evidenceHashes: workOrder.evidenceHashes)
        let digest = try intent.digest()
        guard digest == operation.envelope.mutation.intentDigest, acknowledgement.intentDigest == digest else {
            throw OfflineEligibilityError.acknowledgementIntentMismatch
        }
    }

    private func validateConditionalWindow(_ acknowledgement: CloudKitAcknowledgement) throws {
        guard !acknowledgement.systemFields.isEmpty, !acknowledgement.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OfflineEligibilityError.acknowledgementMissingConditionalMetadata
        }
        let time = operation.envelope.clientTime
        guard acknowledgement.acknowledgedAt <= time, time < acknowledgement.expiresAt else { throw OfflineEligibilityError.acknowledgementExpired }
    }

    private func validateResourceCoverage(_ reservation: WorkOrderReservation) throws {
        let mutation = operation.envelope.mutation
        guard operation.resourceKeys == mutation.resourceKeys else { throw OfflineEligibilityError.operationResourceSetMismatch }
        let bookkeeping: Set<ResourceKey> = [.object(mutation.workOrder.id), .object(mutation.auditEvent.id), mutation.receipt.id]
        guard operation.resourceKeys.subtracting(bookkeeping) == reservation.resourceKeys else {
            throw OfflineEligibilityError.reservationDoesNotExactlyCoverMutation
        }
    }
}
