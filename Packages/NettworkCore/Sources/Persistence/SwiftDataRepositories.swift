import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

extension SwiftDataPersistenceStore {
    public func topology(in namespace: PersistenceNamespace) async throws -> PhysicalTopology {
        try validateActiveLease(for: namespace)
        let records = try mirrorModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
            .map { try decodeMirror($0, namespace: namespace) }
            .filter { try $0.recordType == LocalRecordKind.physicalTopology && !$0.isTombstone && isVisibleToFeatureProjection($0, in: namespace) }
        guard let newest = records.max(by: { $0.serverModifiedAt < $1.serverModifiedAt }) else { return PhysicalTopology() }
        guard let payload = newest.payload else { throw PersistenceStoreError.malformedStoredValue("topology payload") }
        return try PersistenceCoding.decode(PhysicalTopology.self, from: payload)
    }

    public func prefixes(in vrfID: ObjectID, namespace: PersistenceNamespace) async throws -> [Prefix] {
        try validateActiveLease(for: namespace)
        return try mirrorModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
            .map { try decodeMirror($0, namespace: namespace) }
            .filter { try $0.recordType == LocalRecordKind.prefix && !$0.isTombstone && isVisibleToFeatureProjection($0, in: namespace) }
            .compactMap { record -> Prefix? in
                guard let payload = record.payload else { throw PersistenceStoreError.malformedStoredValue("prefix payload") }
                let prefix = try PersistenceCoding.decode(Prefix.self, from: payload)
                return prefix.vrfID == vrfID ? prefix : nil
            }
            .sorted { $0.cidr < $1.cidr }
    }

    public func workOrder(id: ObjectID, namespace: PersistenceNamespace) async throws -> WorkOrder? {
        try validateActiveLease(for: namespace)
        guard let record = try localMirror(for: .object(id), in: namespace),
            record.recordType == LocalRecordKind.workOrder,
            !record.isTombstone,
            let payload = record.payload
        else { return nil }
        return try PersistenceCoding.decode(WorkOrder.self, from: payload)
    }

    public func auditEvents(for resourceKey: ResourceKey, namespace: PersistenceNamespace) async throws -> [AuditEvent] {
        try validateActiveLease(for: namespace)
        return try mirrorModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
            .map { try decodeMirror($0, namespace: namespace) }
            .filter { try $0.recordType == LocalRecordKind.auditEvent && !$0.isTombstone && isVisibleToFeatureProjection($0, in: namespace) }
            .compactMap { record -> AuditEvent? in
                guard let payload = record.payload else { throw PersistenceStoreError.malformedStoredValue("audit payload") }
                let event = try PersistenceCoding.decode(AuditEvent.self, from: payload)
                return event.affectedResourceKeys.contains(resourceKey) ? event : nil
            }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    // MARK: AttachmentStore

    /// Stores bytes whose content-safety checks have already completed under
    /// the evidence identifier that was bound into the authoritative intent.
    /// This is deliberately separate from the generic attachment store, which
    /// allocates its own identifier and therefore cannot preserve an evidence
    /// hash's identity.
    public func storeVerifiedAttachment(
        _ data: Data, id: ObjectID, contentType: String,
        namespace: PersistenceNamespace
    ) async throws {
        try validateActiveLease(for: namespace)
        let normalizedType = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !data.isEmpty, !normalizedType.isEmpty else {
            throw PersistenceStoreError.invalidNamespace
        }
        let key = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "attachment:\(id.description)")
        if let existing = try attachmentModel(matching: key) {
            guard existing.contentType == normalizedType, existing.byteCount == data.count,
                try await attachmentFiles.read(
                    relativePath: existing.relativePath, id: id,
                    expectedByteCount: existing.byteCount) == data
            else {
                throw PersistenceStoreError.attachmentCorrupt(id)
            }
            return
        }

        let relativePath = try await attachmentFiles.write(data, id: id, namespace: namespace)
        do {
            try transaction {
                try validateActiveLease(for: namespace)
                guard try attachmentModel(matching: key) == nil else {
                    throw PersistenceStoreError.attachmentCorrupt(id)
                }
                modelContext.insert(
                    LocalAttachmentModel(
                        id: id, namespace: namespace,
                        contentType: normalizedType, relativePath: relativePath, byteCount: data.count,
                        createdAt: .now))
            }
        } catch {
            try? await attachmentFiles.remove(relativePath: relativePath, id: id)
            throw error
        }
    }

    /// Marks mirror-owned bytes before their corresponding mirror transaction.
    /// The durable marker makes crash recovery and launch cleanup precise: an
    /// unrelated local attachment is never inferred to be disposable.
    public func stageVerifiedMirrorAttachment(
        _ data: Data, id: ObjectID, contentType: String,
        namespace: PersistenceNamespace
    ) async throws {
        let markerKey = PersistenceNamespaceKey.storageKey(
            namespace: namespace,
            identity: "mirror-asset-staging:\(id.description)")
        try transaction {
            try validateActiveLease(for: namespace)
            if try mirrorAssetStagingModel(matching: markerKey) == nil {
                modelContext.insert(LocalMirrorAssetStagingModel(id: id, namespace: namespace))
            }
        }
        try await storeVerifiedAttachment(data, id: id, contentType: contentType, namespace: namespace)
    }

    /// Finalizes successful mirror downloads and sweeps interrupted or
    /// superseded mirror-owned bytes. Pending evidence reservations and bound
    /// evidence metadata are always retained.
    @discardableResult
    public func reconcileVerifiedMirrorAttachments(
        candidates: Set<ObjectID> = [],
        namespace: PersistenceNamespace
    ) async throws -> Int {
        try validateActiveLease(for: namespace)
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        // Marker enumeration is intentional crash recovery. Mirror ownership
        // and evidence protection are exact-key V9/index lookups below.
        let markers = try mirrorAssetStagingModels(namespaceKey: namespaceKey)
        let markedIDs = Set(markers.compactMap { UUID(uuidString: $0.attachmentID).map(ObjectID.init) })
        var removed = 0
        for id in candidates.union(markedIDs).sorted() {
            removed += try await reconcileVerifiedMirrorAttachment(id, namespace: namespace)
        }
        return removed
    }

    /// Atomically reserves one attachment count and byte allocation against a
    /// single work order. Expired reservations are swept in the same local
    /// transaction before usage is calculated, so they cannot indefinitely
    /// consume quota after a cancelled or interrupted bind.
    public func reserveAttachmentEvidence(
        workOrderID: ObjectID, attachmentID: ObjectID, byteCount: Int,
        policy: AttachmentEvidenceQuotaPolicy, namespace: PersistenceNamespace, at now: Date = .now
    ) throws -> AttachmentEvidenceReservationMetadata {
        guard byteCount > 0 else { throw AttachmentEvidencePersistenceError.invalidReservation }
        return try transaction {
            try validateActiveLease(for: namespace)
            try removeExpiredAttachmentEvidenceReservations(in: namespace, at: now)
            let reservationKey = attachmentEvidenceReservationStorageKey(
                attachmentID: attachmentID,
                namespace: namespace)
            if let existing = try attachmentEvidenceReservationModel(matching: reservationKey) {
                let decoded = try decodeAttachmentEvidenceReservation(existing, namespace: namespace)
                guard decoded.workOrderID == workOrderID, decoded.reservedBytes == byteCount else {
                    throw AttachmentEvidencePersistenceError.reservationConflict(attachmentID)
                }
                return decoded
            }
            if try attachmentEvidenceModel(matching: attachmentEvidenceStorageKey(attachmentID: attachmentID, namespace: namespace)) != nil {
                throw AttachmentEvidencePersistenceError.attachmentAlreadyBound(attachmentID)
            }

            let reservations = try attachmentEvidenceReservationModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
                .map { try decodeAttachmentEvidenceReservation($0, namespace: namespace) }
                .filter { $0.workOrderID == workOrderID }
            let evidence = try attachmentEvidenceModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
                .map { try decodeAttachmentEvidence($0, namespace: namespace) }
                .filter { $0.workOrderID == workOrderID }
            let consumedCount = evidence.count + reservations.reduce(0) { $0 + $1.reservedCount }
            let consumedBytes =
                evidence.reduce(0) { $0 + $1.provenance.byteCount }
                + reservations.reduce(0) { $0 + $1.reservedBytes }
            guard consumedCount < policy.maximumAttachmentCount,
                byteCount <= policy.maximumTotalBytes - consumedBytes
            else {
                throw AttachmentEvidencePersistenceError.quotaExceeded
            }

            let reservation = try AttachmentEvidenceReservationMetadata(
                namespace: namespace,
                workOrderID: workOrderID, attachmentID: attachmentID, reservedCount: 1,
                reservedBytes: byteCount, createdAt: now,
                expiresAt: now.addingTimeInterval(policy.reservationLifetime))
            modelContext.insert(try LocalAttachmentEvidenceReservationModel(reservation: reservation))
            return reservation
        }
    }

    /// Returns the exact durable reservation only while it remains fresh.
    /// Call this immediately before the authoritative Cloud mutation.
    public func attachmentEvidenceReservation(
        id: ObjectID, namespace: PersistenceNamespace,
        at now: Date = .now
    ) throws -> AttachmentEvidenceReservationMetadata {
        try validateActiveLease(for: namespace)
        let models = try attachmentEvidenceReservationModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
        guard let model = models.first(where: { $0.reservationID == id.description }) else {
            throw AttachmentEvidencePersistenceError.reservationConflict(id)
        }
        let reservation = try decodeAttachmentEvidenceReservation(model, namespace: namespace)
        guard reservation.expiresAt > now else {
            throw AttachmentEvidencePersistenceError.reservationExpired(id)
        }
        return reservation
    }

    /// Commits only the local durable provenance for an already-authoritative
    /// work-order mutation. The caller supplies the expected receipt so this
    /// store cannot substitute a different operation acknowledgement.
    public func bindAttachmentEvidence(
        reservationID: ObjectID, provenance: SanitizedAttachmentProvenance,
        evidence: EvidenceHash, receipt: OperationReceipt, expectedReceipt: OperationReceipt,
        namespace: PersistenceNamespace, at now: Date = .now
    ) throws -> AttachmentEvidenceMetadata {
        guard receipt == expectedReceipt else {
            throw AttachmentEvidencePersistenceError.receiptMismatch(reservationID)
        }
        return try transaction {
            try validateActiveLease(for: namespace)
            let reservationModels = try attachmentEvidenceReservationModels(
                namespaceKey: PersistenceNamespaceKey.value(for: namespace))
            guard let reservationModel = reservationModels.first(where: { $0.reservationID == reservationID.description }) else {
                throw AttachmentEvidencePersistenceError.reservationConflict(reservationID)
            }
            // Freshness is enforced immediately before the authoritative
            // commit. Once the exact receipt exists, retaining its durable
            // local provenance must not fail merely because that round trip
            // crossed the reservation expiry instant.
            let reservation = try decodeAttachmentEvidenceReservation(reservationModel, namespace: namespace)
            guard reservation.reservedBytes == provenance.byteCount,
                evidence.id == reservation.attachmentID
            else {
                throw AttachmentEvidencePersistenceError.invalidEvidenceBinding
            }
            let attachmentKey = PersistenceNamespaceKey.storageKey(
                namespace: namespace,
                identity: "attachment:\(reservation.attachmentID.description)")
            guard let attachment = try attachmentModel(matching: attachmentKey),
                attachment.contentType == provenance.contentType,
                attachment.byteCount == provenance.byteCount
            else {
                throw PersistenceStoreError.missingAttachment(reservation.attachmentID)
            }
            let metadata = try AttachmentEvidenceMetadata(
                namespace: namespace,
                workOrderID: reservation.workOrderID, attachmentID: reservation.attachmentID,
                reservationID: reservation.id, provenance: provenance, evidence: evidence, receipt: receipt,
                boundAt: now)
            let evidenceKey = attachmentEvidenceStorageKey(attachmentID: reservation.attachmentID, namespace: namespace)
            if let existing = try attachmentEvidenceModel(matching: evidenceKey) {
                guard try decodeAttachmentEvidence(existing, namespace: namespace) == metadata else {
                    throw AttachmentEvidencePersistenceError.attachmentAlreadyBound(reservation.attachmentID)
                }
            } else {
                modelContext.insert(try LocalAttachmentEvidenceModel(metadata: metadata))
            }
            modelContext.delete(reservationModel)
            return metadata
        }
    }

    public func attachmentEvidence(
        for attachmentID: ObjectID, namespace: PersistenceNamespace
    ) throws -> AttachmentEvidenceMetadata? {
        try validateActiveLease(for: namespace)
        guard
            let model = try attachmentEvidenceModel(
                matching: attachmentEvidenceStorageKey(attachmentID: attachmentID, namespace: namespace))
        else {
            return nil
        }
        return try decodeAttachmentEvidence(model, namespace: namespace)
    }

    /// Rebuilds the local evidence cache from verified authoritative mirror
    /// records. This is idempotent and deliberately runs after mirror assets
    /// are durable, so a local post-commit failure cannot invalidate the
    /// already accepted binding receipt.
}
