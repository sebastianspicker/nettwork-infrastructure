import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension CompositeCloudRemoteReferenceValidator {
    func validateAttachmentEvidenceRelationships(candidate: [CloudRecordEnvelope], snapshot: CloudRemoteMirrorSnapshot, activeTransferIDs: Set<ObjectID>) throws
    {
        guard containsOperationalEvidenceRecord(candidate) else { return }
        let postState = attachmentPostState(candidate, snapshot: snapshot, activeTransferIDs: activeTransferIDs)
        let changes = try attachmentChanges(candidate)
        let bindings = try bindingsByReservation(in: postState)
        let impact = try attachmentImpact(candidate, changes: changes, bindings: bindings)
        let releaseBindings = try releaseBindings(for: changes.releases, bindings: bindings)
        let bindingsToValidate = Set(changes.bindings + releaseBindings + impact.dependentBindings)
        try validateAuthoritativeBindings(bindingsToValidate, in: postState)
        try validateWorkOrderEvidence(impact.workOrderIDs, bindings: bindings, in: postState)
    }

    private func containsOperationalEvidenceRecord(_ candidate: [CloudRecordEnvelope]) -> Bool {
        let types: Set<String> = [
            CloudRecordNaming.workOrderRecordType, CloudRecordNaming.auditRecordType, CloudRecordNaming.receiptRecordType,
            CloudRecordNaming.attachmentEvidenceQuotaLedgerRecordType,
            CloudRecordNaming.attachmentEvidenceReservationReleaseRecordType, CloudRecordNaming.attachmentEvidenceBindingRecordType,
        ]
        return candidate.contains { types.contains($0.recordType) }
    }

    private func attachmentPostState(_ candidate: [CloudRecordEnvelope], snapshot: CloudRemoteMirrorSnapshot, activeTransferIDs: Set<ObjectID>) -> [ResourceKey:
        CloudRecordEnvelope]
    {
        var state = snapshot.recordEnvelopesByResourceKey.filter { _, envelope in
            guard case let .staged(transferID) = envelope.visibility else { return true }
            return activeTransferIDs.contains(transferID)
        }
        for envelope in candidate {
            if envelope.isDeleted { state.removeValue(forKey: envelope.resourceKey) } else { state[envelope.resourceKey] = envelope }
        }
        return state
    }

    private func attachmentChanges(_ candidate: [CloudRecordEnvelope]) throws -> AttachmentChanges {
        let bindings = try candidate.filter { !$0.isDeleted && $0.recordType == CloudRecordNaming.attachmentEvidenceBindingRecordType }.map {
            try CloudDeterministicCoding.decode(AttachmentEvidenceBindingRecord.self, from: $0.payload)
        }
        let releases = try candidate.filter { !$0.isDeleted && $0.recordType == CloudRecordNaming.attachmentEvidenceReservationReleaseRecordType }.map {
            try CloudDeterministicCoding.decode(
                AttachmentEvidenceReservationRelease.self,
                from: $0.payload)
        }
        return AttachmentChanges(bindings: bindings, releases: releases)
    }

    private func bindingsByReservation(in postState: [ResourceKey: CloudRecordEnvelope]) throws -> [ObjectID: AttachmentEvidenceBindingRecord] {
        var bindings = [ObjectID: AttachmentEvidenceBindingRecord]()
        for envelope in postState.values where envelope.recordType == CloudRecordNaming.attachmentEvidenceBindingRecordType {
            let binding = try CloudDeterministicCoding.decode(AttachmentEvidenceBindingRecord.self, from: envelope.payload)
            guard bindings.updateValue(binding, forKey: binding.reservationID) == nil else {
                throw CloudRemoteReferenceValidationError.invalidRecords(
                    resourceKeys: [binding.resourceKey],
                    reason: "attachment evidence reservation is bound more than once")
            }
        }
        return bindings
    }

    private func attachmentImpact(_ candidate: [CloudRecordEnvelope], changes: AttachmentChanges, bindings: [ObjectID: AttachmentEvidenceBindingRecord]) throws
        -> AttachmentImpact
    {
        var workOrderIDs = Set(changes.releases.map(\.workOrderID))
        workOrderIDs.formUnion(changes.bindings.map(\.workOrderID))
        var operationIDs = Set(changes.releases.map(\.operationID))
        var auditIDs = Set<ObjectID>()
        for envelope in candidate where !envelope.isDeleted {
            switch envelope.recordType {
            case CloudRecordNaming.workOrderRecordType: workOrderIDs.insert(try CloudDeterministicCoding.decode(WorkOrder.self, from: envelope.payload).id)
            case CloudRecordNaming.attachmentEvidenceQuotaLedgerRecordType:
                workOrderIDs.insert(try CloudDeterministicCoding.decode(AttachmentEvidenceQuotaLedger.self, from: envelope.payload).workOrderID)
            case CloudRecordNaming.receiptRecordType:
                operationIDs.insert(try CloudDeterministicCoding.decode(OperationReceipt.self, from: envelope.payload).operationID)
            case CloudRecordNaming.auditRecordType: auditIDs.insert(try CloudDeterministicCoding.decode(AuditEvent.self, from: envelope.payload).id)
            default: break
            }
        }
        let dependentBindings = bindings.values.filter {
            workOrderIDs.contains($0.workOrderID) || operationIDs.contains($0.operationID) || auditIDs.contains($0.auditEventID)
        }
        return AttachmentImpact(workOrderIDs: workOrderIDs, dependentBindings: dependentBindings)
    }

    private func releaseBindings(for releases: [AttachmentEvidenceReservationRelease], bindings: [ObjectID: AttachmentEvidenceBindingRecord]) throws
        -> [AttachmentEvidenceBindingRecord]
    {
        try releases.map { release in
            guard let binding = bindings[release.id] else {
                throw CloudRemoteReferenceValidationError.invalidRecords(
                    resourceKeys: [release.resourceKey], reason: "attachment reservation release is not bound to its exact evidence record")
            }
            try verifyRelease(release, matches: binding)
            return binding
        }
    }

    private func verifyRelease(_ release: AttachmentEvidenceReservationRelease, matches binding: AttachmentEvidenceBindingRecord) throws {
        let exactMatch =
            binding.workOrderID == release.workOrderID && binding.attachmentID == release.attachmentID && binding.operationID == release.operationID
        let validTiming = release.reservedCount == 1 && release.releasedAt == binding.boundAt && release.releasedAt < release.expiresAt
        guard exactMatch, binding.provenance.byteCount == release.reservedBytes, validTiming else {
            throw CloudRemoteReferenceValidationError.invalidRecords(
                resourceKeys: [release.resourceKey],
                reason: "attachment reservation release is not bound to its exact evidence record")
        }
    }

    private func validateAuthoritativeBindings(_ bindings: Set<AttachmentEvidenceBindingRecord>, in postState: [ResourceKey: CloudRecordEnvelope]) throws {
        for binding in bindings {
            let workOrder: WorkOrder = try evidenceRecord(
                WorkOrder.self, key: .object(binding.workOrderID), type: CloudRecordNaming.workOrderRecordType, in: postState)
            let ledger: AttachmentEvidenceQuotaLedger = try evidenceRecord(
                AttachmentEvidenceQuotaLedger.self, key: .attachmentEvidenceQuotaLedger(for: binding.workOrderID),
                type: CloudRecordNaming.attachmentEvidenceQuotaLedgerRecordType, in: postState)
            let release: AttachmentEvidenceReservationRelease = try evidenceRecord(
                AttachmentEvidenceReservationRelease.self, key: .attachmentEvidenceReservationRelease(binding.reservationID),
                type: CloudRecordNaming.attachmentEvidenceReservationReleaseRecordType, in: postState)
            let receipt: OperationReceipt = try evidenceRecord(
                OperationReceipt.self, key: .operationReceipt(operationID: binding.operationID), type: CloudRecordNaming.receiptRecordType, in: postState)
            let audit: AuditEvent = try evidenceRecord(
                AuditEvent.self, key: .object(binding.auditEventID), type: CloudRecordNaming.auditRecordType, in: postState)
            try verifyAuthoritativeBinding(binding, workOrder: workOrder, ledger: ledger, release: release, receipt: receipt, audit: audit)
        }
    }

    private func verifyAuthoritativeBinding(
        _ binding: AttachmentEvidenceBindingRecord, workOrder: WorkOrder, ledger: AttachmentEvidenceQuotaLedger, release: AttachmentEvidenceReservationRelease,
        receipt: OperationReceipt, audit: AuditEvent
    ) throws {
        let matches = [
            workOrder.evidenceHashes.contains(binding.evidence), workOrder.status == .completed,
            workOrder.intentDigest == binding.intentDigest, ledger.workOrderID == binding.workOrderID,
            release.workOrderID == binding.workOrderID, release.attachmentID == binding.attachmentID,
            release.operationID == binding.operationID, release.reservedCount == 1,
            release.reservedBytes == binding.provenance.byteCount, release.releasedAt == binding.boundAt,
            release.releasedAt < release.expiresAt, receipt.operationID == binding.operationID,
            receipt.intentDigest == binding.intentDigest, receipt.auditEventID == binding.auditEventID,
            audit.id == binding.auditEventID, audit.operationID == binding.operationID,
            audit.workOrderID == binding.workOrderID,
        ]
        guard !matches.contains(false) else {
            throw CloudRemoteReferenceValidationError.invalidRecords(
                resourceKeys: [binding.resourceKey], reason: "attachment evidence records do not form one authoritative operation")
        }
    }

    private func validateWorkOrderEvidence(
        _ workOrderIDs: Set<ObjectID>, bindings: [ObjectID: AttachmentEvidenceBindingRecord], in postState: [ResourceKey: CloudRecordEnvelope]
    ) throws {
        let grouped = Dictionary(grouping: bindings.values, by: \.workOrderID)
        for workOrderID in workOrderIDs { try validateEvidenceAggregate(workOrderID, bindings: grouped[workOrderID] ?? [], in: postState) }
    }

    private func validateEvidenceAggregate(
        _ workOrderID: ObjectID, bindings: [AttachmentEvidenceBindingRecord], in postState: [ResourceKey: CloudRecordEnvelope]
    ) throws {
        let workOrder: WorkOrder = try evidenceRecord(WorkOrder.self, key: .object(workOrderID), type: CloudRecordNaming.workOrderRecordType, in: postState)
        let evidence = bindings.map(\.evidence)
        guard workOrder.evidenceHashes.count == evidence.count, Set(workOrder.evidenceHashes) == Set(evidence) else {
            throw CloudRemoteReferenceValidationError.invalidRecords(
                resourceKeys: [.object(workOrderID)],
                reason: "work order evidence is not the exact surviving binding set")
        }
        guard let envelope = postState[.attachmentEvidenceQuotaLedger(for: workOrderID)] else {
            guard bindings.isEmpty else {
                throw CloudRemoteReferenceValidationError.invalidRecords(
                    resourceKeys: [.object(workOrderID)], reason: "attachment evidence binding is missing its ledger")
            }
            return
        }
        guard envelope.recordType == CloudRecordNaming.attachmentEvidenceQuotaLedgerRecordType else {
            throw CloudRemoteReferenceValidationError.invalidRecords(
                resourceKeys: [envelope.resourceKey],
                reason: "attachment evidence ledger identity")
        }
        let ledger = try CloudDeterministicCoding.decode(AttachmentEvidenceQuotaLedger.self, from: envelope.payload)
        let totalBytes = try attachmentBytes(bindings)
        guard ledger.attachmentCount == bindings.count, ledger.totalBytes == totalBytes else {
            throw CloudRemoteReferenceValidationError.invalidRecords(
                resourceKeys: [ledger.resourceKey],
                reason: "attachment evidence ledger is not an exact binding aggregate")
        }
    }

    private func attachmentBytes(_ bindings: [AttachmentEvidenceBindingRecord]) throws -> Int {
        try bindings.reduce(into: 0) { total, binding in
            guard total <= Int.max - binding.provenance.byteCount else {
                throw CloudRemoteReferenceValidationError.invalidRecords(resourceKeys: [binding.resourceKey], reason: "attachment evidence byte overflow")
            }
            total += binding.provenance.byteCount
        }
    }

    private func evidenceRecord<T: Decodable>(_ type: T.Type, key: ResourceKey, type recordType: String, in postState: [ResourceKey: CloudRecordEnvelope])
        throws -> T
    {
        guard let envelope = postState[key], envelope.recordType == recordType else {
            throw CloudRemoteReferenceValidationError.invalidRecords(resourceKeys: [key], reason: "attachment evidence dependency is missing")
        }
        return try CloudDeterministicCoding.decode(type, from: envelope.payload)
    }

    struct AttachmentChanges {
        let bindings: [AttachmentEvidenceBindingRecord]
        let releases: [AttachmentEvidenceReservationRelease]
    }
    struct AttachmentImpact {
        let workOrderIDs: Set<ObjectID>
        let dependentBindings: [AttachmentEvidenceBindingRecord]
    }
}
