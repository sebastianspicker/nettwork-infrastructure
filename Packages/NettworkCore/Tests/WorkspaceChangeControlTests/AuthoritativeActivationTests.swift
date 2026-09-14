import CryptoKit
import Foundation
import XCTest

@testable import NetworkModel
@testable import WorkspaceChangeControl

final class AuthoritativeActivationTests: XCTestCase {
    func testRecordBoundAssetRequiresMatchingEvidenceBindingMetadataAndBytes() throws {
        let attachmentID = ObjectID()
        let bytes = Data("sanitized-jpeg-bytes".utf8)
        let evidenceDigest = AttachmentEvidenceBindingRecord.evidenceDigest(for: bytes)
        let asset = try CloudRecordAssetDescriptor(
            id: attachmentID,
            fieldName: "sanitizedAsset",
            sha256: CloudRecordAssetDescriptor.sha256(for: bytes),
            contentType: "image/jpeg",
            byteCount: bytes.count,
            storage: .inline(bytes)
        )
        let provenance = try AttachmentEvidenceProvenanceRecord(
            domainSeparatedSHA256: evidenceDigest,
            purpose: "evidence",
            contentType: "image/jpeg",
            byteCount: bytes.count
        )
        let domain = Data("netzwerkdoku.content-safety.sanitized.v1\0evidence\0".utf8)
        let evidence = EvidenceHash(
            id: attachmentID,
            digest: try IntentDigest(algorithm: .sha256, bytes: Array(SHA256.hash(data: domain + bytes))),
            contentType: "image/jpeg"
        )
        let binding = try AttachmentEvidenceBindingRecord(
            workOrderID: ObjectID(),
            attachmentID: attachmentID,
            reservationID: ObjectID(),
            provenance: provenance,
            evidence: evidence,
            assetMetadata: asset.metadata,
            intentDigest: try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 7, count: 32)),
            operationID: ObjectID(),
            auditEventID: ObjectID(),
            boundAt: .distantPast
        )

        XCTAssertEqual(binding.assetMetadata, asset.metadata)
        XCTAssertEqual(try asset.validatedBytes(), bytes)
        XCTAssertThrowsError(
            try CloudRecordAssetDescriptor(
                id: attachmentID,
                fieldName: "sanitizedAsset",
                sha256: String(repeating: "0", count: 64),
                contentType: "image/jpeg",
                byteCount: bytes.count,
                storage: .inline(bytes)
            ))
    }

    func testGenericActivationCannotBypassTypedCapabilityAndStillRequiresExactSentinel() throws {
        let fixture = try ActivationFixture.make()

        XCTAssertThrowsError(
            try AuthoritativeActivationMutationValidator.validate(
                fixture.mutation,
                against: fixture.state
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthoritativeActivationMutationValidationError,
                .invalidActivationRecordSet(fixture.sentinel.resourceKey)
            )
        }
        XCTAssertNil(fixture.mutation.auditEvent.workOrderID)
        XCTAssertEqual(
            fixture.mutation.auditEvent.id,
            AuditEvent.deterministicID(for: fixture.mutation.operationID)
        )

        let absentSentinel = AuthoritativeActivationMutationState()
        XCTAssertThrowsError(
            try AuthoritativeActivationMutationValidator.validate(fixture.mutation, against: absentSentinel)
        ) { error in
            XCTAssertEqual(
                error as? AuthoritativeActivationMutationValidationError,
                .missingRecord(fixture.sentinel.resourceKey)
            )
        }

        let mustNotExistSentinel = try fixture.replacing(
            preconditions: fixture.mutation.preconditions.map {
                $0.resourceKey == fixture.sentinel.resourceKey ? .mustNotExist($0.resourceKey) : $0
            })
        XCTAssertThrowsError(
            try AuthoritativeActivationMutationValidator.validate(mustNotExistSentinel, against: fixture.state)
        ) { error in
            XCTAssertEqual(
                error as? AuthoritativeActivationMutationValidationError,
                .invalidBootstrapSentinelPrecondition(fixture.sentinel.resourceKey)
            )
        }
    }

    func testActivationRejectsHostileAuditReceiptPreconditionAndDuplicateInputs() throws {
        let fixture = try FloorPlanAssetActivationFixture.make()

        var wrongAudit = fixture.mutation.auditEvent
        wrongAudit.actorID = "other"
        let invalidAudit = try fixture.replacing(auditEvent: wrongAudit)
        XCTAssertThrowsError(
            try AuthoritativeActivationMutationValidator.validate(invalidAudit, against: fixture.state)
        ) { error in
            XCTAssertEqual(error as? AuthoritativeActivationMutationValidationError, .invalidAuditEvent)
        }

        let wrongReceipt = OperationReceipt(
            workspaceZone: AuthoritativeWorkspaceZone(
                workspaceID: ObjectID(),
                containerIdentifier: fixture.mutation.workspaceZone.containerIdentifier,
                zoneName: "other-zone",
                zoneOwnerRecordName: fixture.mutation.workspaceZone.zoneOwnerRecordName
            ),
            operationID: fixture.mutation.operationID,
            intentDigest: fixture.mutation.intentDigest,
            auditEventID: fixture.mutation.auditEvent.id
        )
        let invalidReceipt = try fixture.replacing(receipt: wrongReceipt)
        XCTAssertThrowsError(
            try AuthoritativeActivationMutationValidator.validate(invalidReceipt, against: fixture.state)
        ) { error in
            XCTAssertEqual(error as? AuthoritativeActivationMutationValidationError, .invalidReceipt)
        }

        let missingPrecondition = try fixture.replacing(
            preconditions: fixture.mutation.preconditions.filter {
                $0.resourceKey != fixture.binding.resourceKey
            })
        XCTAssertThrowsError(
            try AuthoritativeActivationMutationValidator.validate(missingPrecondition, against: fixture.state)
        ) { error in
            XCTAssertEqual(
                error as? AuthoritativeActivationMutationValidationError,
                .missingPrecondition(fixture.binding.resourceKey)
            )
        }

        let duplicateSave = try fixture.replacing(
            saves: fixture.mutation.saves + [
                try XCTUnwrap(fixture.mutation.saves.first { $0.resourceKey == fixture.binding.resourceKey })
            ])
        XCTAssertThrowsError(
            try AuthoritativeActivationMutationValidator.validate(duplicateSave, against: fixture.state)
        ) { error in
            XCTAssertEqual(
                error as? AuthoritativeActivationMutationValidationError,
                .duplicateTouchedResource(fixture.binding.resourceKey)
            )
        }
    }

    func testActivationCapabilityRejectsHostileSentinelAndTransferInputs() throws {
        let fixture = try ActivationFixture.make()
        XCTAssertThrowsError(try AuthoritativeActivationMutationValidator.validate(fixture.mutation, against: fixture.state))
        try assertHostileSentinelAndDirectTransferInputs(fixture)
        try assertMalformedTransferSessionAssertion(fixture)
    }

    private func assertHostileSentinelAndDirectTransferInputs(_ fixture: ActivationFixture) throws {
        let activeSentinel = try fixture.sentinel(
            replacing: .active(
                commit: .init(
                    transferID: ObjectID(), memberCount: 1, rollingDigest: "digest"
                )))
        let emptyToActive = try fixture.replacing(saves: [activeSentinel, fixture.businessSave])
        XCTAssertThrowsError(try AuthoritativeActivationMutationValidator.validate(emptyToActive, against: fixture.state))

        let ordinarySentinelWrite = try fixture.replacing(saves: [
            AuthoritativeRecordSave(
                resourceKey: fixture.sentinel.resourceKey,
                recordType: fixture.sentinel.recordType,
                schemaVersion: fixture.sentinel.schemaVersion,
                encodedRecord: Data("ordinary-write".utf8)
            ),
            fixture.businessSave,
        ])
        XCTAssertThrowsError(try AuthoritativeActivationMutationValidator.validate(ordinarySentinelWrite, against: fixture.state))

        let directSessionSave = AuthoritativeRecordSave(
            resourceKey: .string("workspace-transfer-session:\(ObjectID().description)"),
            recordType: AuthoritativeActivationMutation.transferSessionRecordType,
            schemaVersion: 1,
            encodedRecord: Data("live-transfer-member".utf8)
        )
        let directLiveTransfer = try fixture.replacing(saves: fixture.mutation.saves + [directSessionSave])
        XCTAssertThrowsError(try AuthoritativeActivationMutationValidator.validate(directLiveTransfer, against: fixture.state))

        let directLiveMember = AuthoritativeRecordSave(
            resourceKey: .object(ObjectID()),
            recordType: "NettworkLocation",
            schemaVersion: 1,
            encodedRecord: Data("live-transfer-member".utf8)
        )
        let directLiveMemberMutation = try fixture.replacing(
            saves: fixture.mutation.saves + [directLiveMember],
            preconditions: fixture.mutation.preconditions + [.mustNotExist(directLiveMember.resourceKey)]
        )
        XCTAssertThrowsError(
            try AuthoritativeActivationMutationValidator.validate(
                directLiveMemberMutation,
                against: fixture.state
            ))
    }

    private func assertMalformedTransferSessionAssertion(_ fixture: ActivationFixture) throws {
        let activeSentinel = try fixture.sentinel(replacing: .active(commit: .init(transferID: ObjectID(), memberCount: 1, rollingDigest: "digest")))
        let malformedAssertion = AuthoritativeReadAssertion(
            resourceKey: .string("workspace-transfer-session:\(ObjectID().description)"),
            recordType: AuthoritativeActivationMutation.transferSessionRecordType,
            schemaVersion: 1,
            encodedRecord: Data("not-a-session".utf8),
            precondition: ExactRecordPrecondition(systemFields: Data([7]), changeTag: "session-v1")
        )
        let malformedAssertionMutation = try AuthoritativeActivationMutation(
            workspaceZone: fixture.mutation.workspaceZone,
            operationID: fixture.mutation.operationID,
            intentDigest: fixture.mutation.intentDigest,
            actor: fixture.mutation.actor,
            saves: [activeSentinel],
            tombstones: [],
            preconditions: fixture.mutation.preconditions.filter { $0.resourceKey != fixture.businessSave.resourceKey }
                + [.exactSystemFields(malformedAssertion.resourceKey, malformedAssertion.precondition)],
            readAssertions: [malformedAssertion],
            auditEvent: fixture.mutation.auditEvent,
            receipt: fixture.mutation.receipt
        )
        var malformedAssertionState = fixture.state
        malformedAssertionState.knownRecords[malformedAssertion.resourceKey] = malformedAssertion.precondition
        malformedAssertionState.currentRecords[malformedAssertion.resourceKey] = .init(
            recordType: malformedAssertion.recordType,
            schemaVersion: malformedAssertion.schemaVersion,
            encodedRecord: malformedAssertion.encodedRecord,
            precondition: malformedAssertion.precondition
        )
        XCTAssertThrowsError(
            try AuthoritativeActivationMutationValidator.validate(
                malformedAssertionMutation,
                against: malformedAssertionState
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthoritativeActivationMutationValidationError,
                .invalidTransferSessionAssertion(malformedAssertion.resourceKey)
            )
        }
    }

    func testFloorPlanAssetActivationRequiresUnchangedCompletedPlannedWorkOrder() throws {
        let fixture = try FloorPlanAssetActivationFixture.make()

        try AuthoritativeActivationMutationValidator.validate(fixture.mutation, against: fixture.state)
        XCTAssertEqual(fixture.mutation.auditEvent.workOrderID, fixture.workOrder.id)
        XCTAssertEqual(fixture.binding.resourceKey, .floorPlanAssetBinding(for: fixture.binding.floorID))

        let missingAsset = try fixture.replacing(
            saves: fixture.mutation.saves.map { save in
                guard save.resourceKey == fixture.binding.resourceKey else { return save }
                return AuthoritativeRecordSave(
                    resourceKey: save.resourceKey,
                    recordType: save.recordType,
                    schemaVersion: save.schemaVersion,
                    encodedRecord: save.encodedRecord
                )
            }
        )
        XCTAssertThrowsError(try AuthoritativeActivationMutationValidator.validate(missingAsset, against: fixture.state))
    }
}

private struct FloorPlanAssetActivationFixture {
    let mutation: AuthoritativeActivationMutation
    let state: AuthoritativeActivationMutationState
    let workOrder: WorkOrder
    let workOrderExact: ExactRecordPrecondition
    let binding: FloorPlanAssetBindingRecord

    static func make() throws -> Self {
        let workspaceID = ObjectID()
        let workspaceZone = AuthoritativeWorkspaceZone(
            workspaceID: workspaceID, containerIdentifier: "iCloud.example.nettwork", zoneName: "nettwork.workspace.\(workspaceID.description)",
            zoneOwnerRecordName: "owner")
        let actor = ActorInstallationSnapshot(
            actorID: "owner", installationID: "test-installation", sessionID: "test-session", sessionGeneration: 1, capturedAt: .distantPast)
        let operationID = ObjectID()
        let digest = try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 9, count: 32))
        let floorID = ObjectID()
        let bytes = Data("floor-plan-jpeg".utf8)
        let asset = try CloudRecordAssetDescriptor(
            id: ObjectID(), fieldName: "floorPlanAsset", sha256: CloudRecordAssetDescriptor.sha256(for: bytes), contentType: "image/jpeg",
            byteCount: bytes.count, storage: .inline(bytes))
        let planned = try PlannedFloorPlanAsset(floorID: floorID, assetMetadata: asset.metadata)
        let workOrder = WorkOrder(
            kind: .floorPlan, title: "Bind floor plan", status: .completed, creatorID: actor.actorID, plannedOperations: [.floorPlan(.bindAsset(planned))],
            intentDigest: digest)
        let audit = AuditEvent(
            id: AuditEvent.deterministicID(for: operationID), operationID: operationID, actorID: actor.actorID, affectedObjectIDs: [],
            workOrderID: workOrder.id, occurredAt: actor.capturedAt, result: .accepted, installationID: actor.installationID, sessionID: actor.sessionID,
            sessionGeneration: actor.sessionGeneration, affectedResourceKeys: [], changes: [], policyVersion: "activation-v1")
        let binding = try FloorPlanAssetBindingRecord(
            floorID: floorID, workOrderID: workOrder.id, assetMetadata: asset.metadata, intentDigest: digest, operationID: operationID, auditEventID: audit.id,
            boundAt: actor.capturedAt)
        let sentinelPayload = try JSONEncoder().encode(
            WorkspaceSentinelTestPayload(
                workspaceID: workspaceID, zoneName: workspaceZone.zoneName, zoneOwnerRecordName: workspaceZone.zoneOwnerRecordName,
                lifecycle: .active(commit: .init(transferID: ObjectID(), memberCount: 1, rollingDigest: "active-workspace"))))
        let sentinel = AuthoritativeRecordSave(
            resourceKey: AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: workspaceID),
            recordType: AuthoritativeActivationMutation.workspaceSentinelRecordType, schemaVersion: 1, encodedRecord: sentinelPayload)
        let bindingSave = AuthoritativeRecordSave(
            resourceKey: binding.resourceKey, recordType: AuthoritativeActivationMutation.floorPlanAssetBindingRecordType, schemaVersion: 1,
            encodedRecord: try stableEncode(binding), recordAsset: asset)
        let touched = Set([sentinel.resourceKey, bindingSave.resourceKey])
        let completedAudit = completedAudit(audit, workOrder: workOrder, touched: touched, saves: [sentinel, bindingSave])
        let receipt = OperationReceipt(workspaceZone: workspaceZone, operationID: operationID, intentDigest: digest, auditEventID: completedAudit.id)
        let sentinelExact = ExactRecordPrecondition(systemFields: Data([1]), changeTag: "sentinel-v1")
        let workOrderExact = ExactRecordPrecondition(systemFields: Data([2]), changeTag: "work-order-v1")
        let workOrderAssertion = AuthoritativeReadAssertion(
            resourceKey: .object(workOrder.id), recordType: "NettworkWorkOrder", schemaVersion: 1, encodedRecord: try stableEncode(workOrder),
            precondition: workOrderExact)
        let mutation = try AuthoritativeActivationMutation(
            workspaceZone: workspaceZone, operationID: operationID, intentDigest: digest, actor: actor, saves: [sentinel, bindingSave], tombstones: [],
            preconditions: [
                .exactSystemFields(sentinel.resourceKey, sentinelExact), .mustNotExist(bindingSave.resourceKey),
                .exactSystemFields(workOrderAssertion.resourceKey, workOrderExact), .mustNotExist(.object(completedAudit.id)), .mustNotExist(receipt.id),
            ], readAssertions: [workOrderAssertion], auditEvent: completedAudit, receipt: receipt)
        return Self(
            mutation: mutation,
            state: .init(
                knownRecords: [sentinel.resourceKey: sentinelExact, workOrderAssertion.resourceKey: workOrderExact],
                currentRecords: [
                    workOrderAssertion.resourceKey: .init(
                        recordType: workOrderAssertion.recordType, schemaVersion: workOrderAssertion.schemaVersion,
                        encodedRecord: workOrderAssertion.encodedRecord, precondition: workOrderExact)
                ], currentSentinel: .init(recordType: sentinel.recordType, schemaVersion: sentinel.schemaVersion, encodedRecord: sentinel.encodedRecord)),
            workOrder: workOrder, workOrderExact: workOrderExact, binding: binding)
    }

    private static func completedAudit(
        _ audit: AuditEvent,
        workOrder: WorkOrder,
        touched: Set<ResourceKey>,
        saves: [AuthoritativeRecordSave]
    ) -> AuditEvent {
        AuditEvent(
            id: audit.id, operationID: audit.operationID, actorID: audit.actorID, affectedObjectIDs: [], workOrderID: workOrder.id,
            occurredAt: audit.occurredAt, result: audit.result, installationID: audit.installationID, sessionID: audit.sessionID,
            sessionGeneration: audit.sessionGeneration, affectedResourceKeys: touched.sorted(),
            changes: saves.map { AuditRecordChange(resourceKey: $0.resourceKey, after: $0.encodedRecord) }.sorted { $0.resourceKey < $1.resourceKey },
            policyVersion: audit.policyVersion)
    }

    func replacing(
        saves: [AuthoritativeRecordSave]? = nil,
        preconditions: [MutationPrecondition]? = nil,
        readAssertions: [AuthoritativeReadAssertion]? = nil,
        auditEvent: AuditEvent? = nil,
        receipt: OperationReceipt? = nil
    ) throws -> AuthoritativeActivationMutation {
        try AuthoritativeActivationMutation(
            workspaceZone: mutation.workspaceZone,
            operationID: mutation.operationID,
            intentDigest: mutation.intentDigest,
            actor: mutation.actor,
            saves: saves ?? mutation.saves,
            tombstones: mutation.tombstones,
            preconditions: preconditions ?? mutation.preconditions,
            readAssertions: readAssertions ?? mutation.readAssertions,
            auditEvent: auditEvent ?? mutation.auditEvent,
            receipt: receipt ?? mutation.receipt
        )
    }

    private static func stableEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private struct ActivationFixture {
    let mutation: AuthoritativeActivationMutation
    let state: AuthoritativeActivationMutationState
    let sentinel: AuthoritativeRecordSave
    let businessSave: AuthoritativeRecordSave

    static func make() throws -> ActivationFixture {
        let workspaceID = ObjectID()
        let workspaceZone = AuthoritativeWorkspaceZone(
            workspaceID: workspaceID, containerIdentifier: "iCloud.example.nettwork", zoneName: "nettwork.workspace.\(workspaceID.description)",
            zoneOwnerRecordName: "owner")
        let actor = ActorInstallationSnapshot(
            actorID: "owner", installationID: "test-installation", sessionID: "test-session", sessionGeneration: 1, capturedAt: .distantPast)
        let operationID = ObjectID()
        let digest = try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 4, count: 32))
        let sentinelPayload = try JSONEncoder().encode(
            WorkspaceSentinelTestPayload(
                workspaceID: workspaceID, zoneName: workspaceZone.zoneName, zoneOwnerRecordName: workspaceZone.zoneOwnerRecordName, lifecycle: .empty(epoch: 0))
        )
        let sentinel = AuthoritativeRecordSave(
            resourceKey: AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: workspaceID),
            recordType: AuthoritativeActivationMutation.workspaceSentinelRecordType, schemaVersion: 1, encodedRecord: sentinelPayload)
        let businessSave = AuthoritativeRecordSave(
            resourceKey: .object(ObjectID()), recordType: "NettworkAttachmentEvidenceQuotaLedger", schemaVersion: 1,
            encodedRecord: Data("{\"label\":\"activated\"}".utf8))
        let saves = [sentinel, businessSave]
        let touched = Set(saves.map(\.resourceKey))
        let audit = AuditEvent(
            id: AuditEvent.deterministicID(for: operationID), operationID: operationID, actorID: actor.actorID,
            affectedObjectIDs: touched.compactMap {
                guard case let .object(id) = $0 else { return nil }
                return id
            }.sorted(), occurredAt: actor.capturedAt, result: .accepted, installationID: actor.installationID, sessionID: actor.sessionID,
            sessionGeneration: actor.sessionGeneration, affectedResourceKeys: touched.sorted(),
            changes: saves.map { AuditRecordChange(resourceKey: $0.resourceKey, after: $0.encodedRecord) }.sorted { $0.resourceKey < $1.resourceKey },
            policyVersion: "activation-v1")
        let receipt = OperationReceipt(workspaceZone: workspaceZone, operationID: operationID, intentDigest: digest, auditEventID: audit.id)
        let sentinelExact = ExactRecordPrecondition(systemFields: Data([1]), changeTag: "bootstrap-v1")
        let mutation = try AuthoritativeActivationMutation(
            workspaceZone: workspaceZone, operationID: operationID, intentDigest: digest, actor: actor, saves: saves, tombstones: [],
            preconditions: [
                .exactSystemFields(sentinel.resourceKey, sentinelExact), .mustNotExist(businessSave.resourceKey), .mustNotExist(.object(audit.id)),
                .mustNotExist(receipt.id),
            ], auditEvent: audit, receipt: receipt)
        return ActivationFixture(
            mutation: mutation,
            state: AuthoritativeActivationMutationState(
                knownRecords: [sentinel.resourceKey: sentinelExact],
                currentSentinel: .init(recordType: sentinel.recordType, schemaVersion: sentinel.schemaVersion, encodedRecord: sentinel.encodedRecord)),
            sentinel: sentinel, businessSave: businessSave)
    }

    func replacing(
        saves: [AuthoritativeRecordSave]? = nil,
        preconditions: [MutationPrecondition]? = nil,
        auditEvent: AuditEvent? = nil,
        receipt: OperationReceipt? = nil
    ) throws -> AuthoritativeActivationMutation {
        try AuthoritativeActivationMutation(
            workspaceZone: mutation.workspaceZone,
            operationID: mutation.operationID,
            intentDigest: mutation.intentDigest,
            actor: mutation.actor,
            saves: saves ?? mutation.saves,
            tombstones: mutation.tombstones,
            preconditions: preconditions ?? mutation.preconditions,
            auditEvent: auditEvent ?? mutation.auditEvent,
            receipt: receipt
        )
    }

    func sentinel(replacing lifecycle: WorkspaceLifecycle) throws -> AuthoritativeRecordSave {
        let payload = try JSONEncoder().encode(
            WorkspaceSentinelTestPayload(
                workspaceID: mutation.workspaceZone.workspaceID,
                zoneName: mutation.workspaceZone.zoneName,
                zoneOwnerRecordName: mutation.workspaceZone.zoneOwnerRecordName,
                lifecycle: lifecycle
            ))
        return AuthoritativeRecordSave(
            resourceKey: sentinel.resourceKey,
            recordType: sentinel.recordType,
            schemaVersion: sentinel.schemaVersion,
            encodedRecord: payload
        )
    }
}

private struct WorkspaceSentinelTestPayload: Codable {
    let workspaceID: ObjectID
    let zoneName: String
    let zoneOwnerRecordName: String
    let lifecycle: WorkspaceLifecycle
}
