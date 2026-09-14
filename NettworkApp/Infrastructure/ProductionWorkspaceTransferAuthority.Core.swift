import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension ProductionWorkspaceTransferAuthority {
    func dryRun(_ records: [ImportRecord], in namespace: PersistenceNamespace) async throws -> ImportDryRunReport {
        let trusted = try await trustedSession(in: namespace)
        let transfer = try ValidatedWorkspaceTransfer.reconstructAndValidate(imports: records)
        try await sessionAuthorizer.revalidate(trusted)
        return ImportDryRunReport(
            canonicalSHA256: CanonicalImportDigest.digest(records: records),
            validatorVersion: WorkspaceTransferRecord.currentSchemaVersion, validatedRecordCount: transfer.candidate.records.count)
    }
    func activateStagedCSV(
        records: [ImportRecord], plan: ImportPlan, requiringEmptyWorkspace: Bool,
        expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt {
        let canonicalReceipt = try CSVImportActivationReceipt.expected(for: plan)
        guard requiringEmptyWorkspace, plan.namespace == account.namespace,
            expectedReceipt == canonicalReceipt,
            plan.canonicalSHA256 == CanonicalImportDigest.digest(records: records)
        else { throw ProductionWorkspaceTransferAuthorityError.receiptMismatch }
        let trusted = try await trustedSession(in: plan.namespace)
        let sentinel = try await emptyBootstrapSentinel(in: plan.namespace)
        let transfer = try ValidatedWorkspaceTransfer.reconstructAndValidate(imports: records)
        guard transfer.candidate.records.count == plan.totalRecordCount,
            transfer.candidate.records.count == plan.dryRunReport.validatedRecordCount
        else {
            throw ProductionWorkspaceTransferAuthorityError.nonCanonicalTransfer
        }
        let complete = try await stage(
            envelopes: try stagedEnvelopes(
                transfer: transfer, audits: [], assets: [], namespace: plan.namespace,
                transferID: plan.transferID), transferID: plan.transferID, operationID: plan.operationID, epoch: sentinel.emptyEpoch,
            namespace: plan.namespace, trusted: trusted)
        return try await activate(
            sentinel: sentinel, completeSession: complete, namespace: plan.namespace, operationID: plan.operationID,
            expectedReceipt: expectedReceipt, trusted: trusted)
    }
    func snapshot(for namespace: PersistenceNamespace) async throws -> ArchiveExportInput {
        let trusted = try await trustedSession(in: namespace)
        let records = try await persistence.mirroredRecords(in: namespace)
        let provenance = ArchiveSourceProvenance(
            workspaceID: namespace.workspaceID, containerIdentifier: namespace.containerIdentifier,
            zoneName: namespace.zoneName, zoneOwnerRecordName: namespace.zoneOwnerRecordName)
        let transferRecords = try canonicalTransferRecords(from: records, provenance: provenance)
        let recordsJSONL = try WorkspaceTransferJSONL.encode(transferRecords)
        guard try WorkspaceTransferJSONL.decode(recordsJSONL) == transferRecords.sorted(by: transferLess) else {
            throw ProductionWorkspaceTransferAuthorityError.nonCanonicalTransfer
        }
        let transfer = try ValidatedWorkspaceTransfer(records: transferRecords)
        let audits = try auditEvents(from: records)
        try validateArchiveOperationalReferences(transfer, audits: audits, provenance: provenance)
        let chain = try ArchiveAuditChain.encode(events: audits.map { try CloudDeterministicCoding.encode($0) })
        let assets = try await archiveAssets(in: namespace, records: records)
        try await sessionAuthorizer.revalidate(trusted)
        return ArchiveExportInput(
            recordCounts: Dictionary(grouping: transferRecords, by: { $0.recordType.rawValue }).mapValues(\.count),
            recordsJSONL: recordsJSONL, auditJSONL: chain.jsonl, auditHeadSHA256: chain.headSHA256, assets: assets)
    }
    func trustedSession(in namespace: PersistenceNamespace) async throws -> TrustedProductionSession {
        guard namespace == account.namespace else { throw ProductionWorkspaceTransferAuthorityError.namespaceMismatch }
        let trusted = try await sessionAuthorizer.verifiedSession(namespace: namespace)
        guard trusted.account == account else { throw ProductionWorkspaceTransferAuthorityError.namespaceMismatch }
        return trusted
    }
    func bootstrapSentinel(in namespace: PersistenceNamespace) async throws -> (snapshot: CloudExactRecordSnapshot, workspace: CloudWorkspaceRecord) {
        let key = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
        guard let snapshot = try await exactRecords.exactRecord(for: key, in: namespace.workspaceZone),
            snapshot.workspaceZone == namespace.workspaceZone, snapshot.resourceKey == key, snapshot.recordType == CloudRecordNaming.workspaceRecordType,
            snapshot.schemaVersion == CloudRecordNaming.schemaVersion, !snapshot.payload.isEmpty, !snapshot.exactPrecondition.systemFields.isEmpty,
            !snapshot.exactPrecondition.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ProductionWorkspaceTransferAuthorityError.bootstrapSentinelMissing
        }
        guard let workspace = try? CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: snapshot.payload),
            (try? CloudDeterministicCoding.encode(workspace)) == snapshot.payload, workspace.workspaceID == namespace.workspaceID,
            workspace.zoneName == namespace.zoneName,
            workspace.zoneOwnerRecordName == namespace.zoneOwnerRecordName
        else { throw ProductionWorkspaceTransferAuthorityError.malformedBootstrapSentinel }
        return (snapshot, workspace)
    }
    func emptyBootstrapSentinel(in namespace: PersistenceNamespace) async throws -> (
        snapshot: CloudExactRecordSnapshot,
        workspace: CloudWorkspaceRecord, emptyEpoch: UInt64
    ) {
        let sentinel = try await bootstrapSentinel(in: namespace)
        guard case let .empty(epoch) = sentinel.workspace.lifecycle else { throw ProductionWorkspaceTransferAuthorityError.workspaceNotEmpty }
        return (sentinel.snapshot, sentinel.workspace, epoch)
    }
    func stage(
        envelopes: [CloudRecordEnvelope], transferID: ObjectID, operationID: ObjectID, epoch: UInt64,
        namespace: PersistenceNamespace, trusted: TrustedProductionSession
    ) async throws -> CloudExactRecordSnapshot {
        let sorted = try sortedEnvelopes(envelopes)
        let digest = rollingDigest(of: sorted, transferID: transferID, operationID: operationID)
        let expected = try CloudStagedTransferSession(
            transferID: transferID, operationID: operationID, epoch: epoch,
            expectedMemberCount: sorted.count, expectedRollingDigest: digest)
        var snapshot = try await openSession(expected, in: namespace.workspaceZone)
        var session = try stagedSession(from: snapshot, matching: expected)
        do {
            guard session.status != .abandoned, session.cursor <= sorted.count,
                rollingDigest(
                    of: Array(sorted.prefix(session.cursor)), transferID: transferID,
                    operationID: operationID) == session.rollingDigest
            else { throw ProductionWorkspaceTransferAuthorityError.malformedStagedTransfer }
            while session.cursor < sorted.count {
                try Task.checkCancellation()
                try await sessionAuthorizer.revalidate(trusted)
                let end = min(session.cursor + CloudStagedTransferLimits.maximumMembersPerBatch, sorted.count)
                let next = try await stagedTransfers.append(
                    Array(sorted[session.cursor..<end]), session: session,
                    sessionPrecondition: snapshot.exactPrecondition, in: namespace.workspaceZone)
                snapshot = try await stagedTransfers.exactSession(expected: next, in: namespace.workspaceZone)
                session = try stagedSession(from: snapshot, matching: expected)
            }
            guard session.rollingDigest == digest else { throw ProductionWorkspaceTransferAuthorityError.malformedStagedTransfer }
            if session.status == .complete { return snapshot }
            try Task.checkCancellation()
            try await sessionAuthorizer.revalidate(trusted)
            let complete = try await stagedTransfers.complete(session: session, sessionPrecondition: snapshot.exactPrecondition, in: namespace.workspaceZone)
            snapshot = try await stagedTransfers.exactSession(expected: complete, in: namespace.workspaceZone)
            _ = try stagedSession(from: snapshot, matching: expected, requiringComplete: true)
            return snapshot
        } catch is CancellationError {
            if session.status == .staging {
                _ = try? await stagedTransfers.abandon(
                    session: session,
                    sessionPrecondition: snapshot.exactPrecondition, in: namespace.workspaceZone)
            }
            throw CancellationError()
        }
    }
    private func openSession(_ expected: CloudStagedTransferSession, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> CloudExactRecordSnapshot {
        if let snapshot = try await exactRecords.exactRecord(for: expected.resourceKey, in: workspaceZone) {
            _ = try stagedSession(from: snapshot, matching: expected)
            return snapshot
        }
        do {
            let snapshot = try await stagedTransfers.begin(expected, in: workspaceZone)
            _ = try stagedSession(from: snapshot, matching: expected)
            return snapshot
        } catch {
            guard let snapshot = try await exactRecords.exactRecord(for: expected.resourceKey, in: workspaceZone) else {
                throw error
            }
            _ = try stagedSession(from: snapshot, matching: expected)
            return snapshot
        }
    }
    private func stagedSession(
        from snapshot: CloudExactRecordSnapshot, matching expected: CloudStagedTransferSession,
        requiringComplete: Bool = false
    ) throws -> CloudStagedTransferSession {
        guard snapshot.workspaceZone == account.namespace.workspaceZone, snapshot.resourceKey == expected.resourceKey,
            snapshot.recordType == CloudStagedTransferRecordType.session, snapshot.schemaVersion == CloudRecordNaming.schemaVersion,
            !snapshot.exactPrecondition.systemFields.isEmpty, !snapshot.exactPrecondition.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let actual = try? CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: snapshot.payload),
            actual.transferID == expected.transferID, actual.operationID == expected.operationID, actual.epoch == expected.epoch,
            actual.expectedMemberCount == expected.expectedMemberCount, actual.expectedRollingDigest == expected.expectedRollingDigest,
            actual.cursor <= actual.expectedMemberCount, !actual.rollingDigest.isEmpty,
            !requiringComplete || actual.status == .complete
        else { throw ProductionWorkspaceTransferAuthorityError.malformedStagedTransfer }
        return actual
    }
    func activate(
        sentinel: (snapshot: CloudExactRecordSnapshot, workspace: CloudWorkspaceRecord, emptyEpoch: UInt64),
        completeSession: CloudExactRecordSnapshot, namespace: PersistenceNamespace, operationID: ObjectID, expectedReceipt: OperationReceipt,
        trusted: TrustedProductionSession
    ) async throws -> OperationReceipt {
        guard expectedReceipt.workspaceZone == namespace.workspaceZone, expectedReceipt.operationID == operationID,
            expectedReceipt.auditEventID == AuditEvent.deterministicID(for: operationID)
        else {
            throw ProductionWorkspaceTransferAuthorityError.receiptMismatch
        }
        try await sessionAuthorizer.revalidate(trusted)
        let decodedComplete = try CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: completeSession.payload)
        let exactComplete = try await stagedTransfers.exactSession(expected: decodedComplete, in: namespace.workspaceZone)
        let complete = try stagedSession(from: exactComplete, matching: decodedComplete, requiringComplete: true)
        let freshSentinel = try await emptyBootstrapSentinel(in: namespace)
        guard freshSentinel.emptyEpoch == sentinel.emptyEpoch else { throw ProductionWorkspaceTransferAuthorityError.workspaceNotEmpty }
        let sentinelKey = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
        let workspace = CloudWorkspaceRecord(
            workspaceID: namespace.workspaceID, zoneName: namespace.zoneName,
            zoneOwnerRecordName: namespace.zoneOwnerRecordName,
            lifecycle: .active(
                commit: WorkspaceActivationCommit(
                    transferID: complete.transferID,
                    memberCount: complete.cursor, rollingDigest: complete.rollingDigest)))
        let save = AuthoritativeRecordSave(
            resourceKey: sentinelKey, recordType: CloudRecordNaming.workspaceRecordType,
            schemaVersion: CloudRecordNaming.schemaVersion, encodedRecord: try CloudDeterministicCoding.encode(workspace))
        let audit = acceptedAuditEvent(operationID: operationID, actor: trusted.actorSnapshot, sentinel: save)
        let assertion = AuthoritativeReadAssertion(
            resourceKey: exactComplete.resourceKey, recordType: exactComplete.recordType,
            schemaVersion: exactComplete.schemaVersion, encodedRecord: exactComplete.payload, precondition: exactComplete.exactPrecondition)
        let mutation = try AuthoritativeActivationMutation(
            workspaceZone: namespace.workspaceZone, operationID: operationID,
            intentDigest: expectedReceipt.intentDigest, actor: trusted.actorSnapshot, saves: [save], tombstones: [],
            preconditions: [
                .exactSystemFields(sentinelKey, freshSentinel.snapshot.exactPrecondition),
                .exactSystemFields(
                    assertion.resourceKey,
                    assertion.precondition), .mustNotExist(.object(audit.id)), .mustNotExist(expectedReceipt.id),
            ].sorted { $0.resourceKey < $1.resourceKey },
            readAssertions: [assertion], auditEvent: audit, receipt: expectedReceipt)
        try CloudStagedTransferFinalActivationContract.validate(mutation)
        try await sessionAuthorizer.revalidate(trusted)
        let receipt = try await mutations.commit(mutation)
        guard receipt == expectedReceipt else { throw ProductionWorkspaceTransferAuthorityError.receiptMismatch }
        return receipt
    }

    func stagedEnvelopes(
        transfer: ValidatedWorkspaceTransfer, audits: [AuditEvent], assets: [CloudRecordEnvelope],
        provenance: ArchiveSourceProvenance? = nil, recordedAt: Date? = nil, namespace: PersistenceNamespace, transferID: ObjectID
    ) throws -> [CloudRecordEnvelope] {
        let visibility = WorkspaceRecordVisibility.staged(transferID: transferID)
        let restoration = try restoredWorkOrderContext(transfer.candidate.workOrders, target: namespace)
        let records =
            try stagedTransferRecords(
                transfer,
                restoration: restoration,
                namespace: namespace,
                visibility: visibility
            )
            + stagedTransferTombstones(
                transfer.tombstones,
                namespace: namespace,
                visibility: visibility
            )
            + reconciledReservationTombstones(
                transfer.saves, reservationIDs: restoration.reconciledReservationIDs, namespace: namespace, visibility: visibility
            ) + (try stagedAuditEnvelopes(audits, namespace: namespace, visibility: visibility))
        let historicalReferences = try importedHistoricalReferenceEnvelopes(
            transfer: transfer, audits: audits, assets: assets, provenance: provenance, recordedAt: recordedAt, namespace: namespace, transferID: transferID
        )
        return try sortedEnvelopes(records + assets + historicalReferences)
    }

    private func restoredWorkOrderContext(
        _ workOrders: [WorkOrder],
        target: PersistenceNamespace
    ) throws -> (
        restoredWorkOrders: [ObjectID: (original: WorkOrder, restored: WorkOrder)],
        reconciledReservationIDs: Set<ObjectID>
    ) {
        let restoredWorkOrders = try restoredWorkOrders(workOrders, target: target)
        let reconciledReservationIDs = Set(
            restoredWorkOrders.values.compactMap { entry in
                entry.original.status == entry.restored.status ? nil : entry.original.reservation?.id
            })
        return (restoredWorkOrders, reconciledReservationIDs)
    }

    private func stagedTransferRecords(
        _ transfer: ValidatedWorkspaceTransfer,
        restoration: (
            restoredWorkOrders: [ObjectID: (original: WorkOrder, restored: WorkOrder)],
            reconciledReservationIDs: Set<ObjectID>
        ),
        namespace: PersistenceNamespace,
        visibility: WorkspaceRecordVisibility
    ) throws -> [CloudRecordEnvelope] {
        // Evidence bindings carry their protected bytes in their own envelope;
        // staging a second payload-only envelope would lose that relationship.
        try transfer.saves.compactMap { save in
            guard save.recordType != WorkspaceTransferRecordType.attachmentEvidenceBinding.rawValue,
                save.recordType != WorkspaceTransferRecordType.floorPlanAssetBinding.rawValue,
                !isReconciledReservationLock(save, reservationIDs: restoration.reconciledReservationIDs)
            else {
                return nil
            }
            return CloudRecordEnvelope(
                resourceKey: save.resourceKey,
                workspaceID: namespace.workspaceID,
                recordType: save.recordType,
                schemaVersion: save.schemaVersion,
                payload: try restoredPayload(for: save, target: namespace, restoredWorkOrders: restoration.restoredWorkOrders),
                visibility: visibility,
                systemFields: Data(),
                changeTag: ""
            )
        }
    }

    private func stagedTransferTombstones(
        _ tombstones: [AuthoritativeTombstone], namespace: PersistenceNamespace, visibility: WorkspaceRecordVisibility
    ) -> [CloudRecordEnvelope] {
        tombstones.map { tombstone in
            CloudRecordEnvelope(
                resourceKey: tombstone.resourceKey,
                workspaceID: namespace.workspaceID,
                recordType: tombstone.recordType,
                schemaVersion: CloudRecordNaming.schemaVersion,
                payload: tombstone.encodedTombstone,
                visibility: visibility,
                systemFields: Data(),
                changeTag: "",
                isDeleted: true
            )
        }
    }

    private func reconciledReservationTombstones(
        _ saves: [AuthoritativeRecordSave], reservationIDs: Set<ObjectID>, namespace: PersistenceNamespace, visibility: WorkspaceRecordVisibility
    ) -> [CloudRecordEnvelope] {
        saves.compactMap { save in
            guard isReconciledReservationLock(save, reservationIDs: reservationIDs) else {
                return nil
            }
            return CloudRecordEnvelope(
                resourceKey: save.resourceKey,
                workspaceID: namespace.workspaceID,
                recordType: save.recordType,
                schemaVersion: save.schemaVersion,
                payload: save.encodedRecord,
                visibility: visibility,
                systemFields: Data(),
                changeTag: "",
                isDeleted: true
            )
        }
    }
}
