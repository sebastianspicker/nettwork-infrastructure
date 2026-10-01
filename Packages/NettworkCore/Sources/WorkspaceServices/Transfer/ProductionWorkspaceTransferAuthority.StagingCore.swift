import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension ProductionWorkspaceTransferAuthority {
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

    func acceptedAuditEvent(operationID: ObjectID, actor: ActorInstallationSnapshot, sentinel: AuthoritativeRecordSave) -> AuditEvent {
        AuditEvent(
            id: AuditEvent.deterministicID(for: operationID), operationID: operationID, actorID: actor.actorID, affectedObjectIDs: [],
            occurredAt: actor.capturedAt, result: .accepted, installationID: actor.installationID, sessionID: actor.sessionID,
            sessionGeneration: actor.sessionGeneration, source: .importExport, affectedResourceKeys: [sentinel.resourceKey],
            changes: [AuditRecordChange(resourceKey: sentinel.resourceKey, after: sentinel.encodedRecord)], policyVersion: Self.activationPolicyVersion
        )
    }

    func sortedEnvelopes(_ envelopes: [CloudRecordEnvelope]) throws -> [CloudRecordEnvelope] {
        let sorted = envelopes.sorted { $0.resourceKey < $1.resourceKey }
        guard Set(sorted.map(\.resourceKey)).count == sorted.count else {
            throw ProductionWorkspaceTransferAuthorityError.duplicateActivationResource(
                sorted.first?.resourceKey ?? .string("workspace-transfer")
            )
        }
        return sorted
    }

    func rollingDigest(of envelopes: [CloudRecordEnvelope], transferID: ObjectID, operationID: ObjectID) -> String {
        envelopes.enumerated().reduce(
            CloudStagedTransferCommitment.initial(
                transferID: transferID,
                operationID: operationID)
        ) {
            CloudStagedTransferCommitment.append(
                previous: $0, index: $1.offset,
                memberDigest: CloudStagedTransferCommitment.member($1.element))
        }
    }
}
