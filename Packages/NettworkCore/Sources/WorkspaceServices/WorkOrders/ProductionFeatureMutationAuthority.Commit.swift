import CloudSync
import CryptoKit
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension ProductionFeatureMutationAuthority {
    public func exportImmutableAudit(authorization: AuthorizedOperationContext, in namespace: PersistenceNamespace) async throws -> URL {
        guard authorization.account.namespace == namespace,
            authorization.action == .exportAudit
        else {
            throw ProductionFeatureMutationAuthorityError.namespaceMismatch
        }
        let trusted = try await sessionAuthorizer.authorizeOperation(authorization, action: .exportAudit, requiresAdministrator: true)
        let staged = try await auditExporter.prepareAudit(operationID: authorization.operationID, in: namespace)
        do {
            try await sessionAuthorizer.revalidate(trusted)
            return try await auditExporter.publishAudit(staged, in: namespace)
        } catch {
            await auditExporter.abortAudit(staged, in: namespace)
            throw error
        }
    }

    func authorize(_ presentation: OperationsAuthorization, namespace: PersistenceNamespace) async throws -> TrustedProductionSession {
        try await sessionAuthorizer.authorizeMutation(namespace: namespace, presentation: presentation)
    }

    func validateCancellationReleaseAuthorization(
        _ releaseAuthorization: CancellationReleaseAuthorization, workOrder: WorkOrder, namespace: PersistenceNamespace, trusted: TrustedProductionSession
    ) throws {
        guard let reservation = workOrder.reservation,
            let cancellation = workOrder.cancellationHistory.last,
            cancellation.releaseAuthorization == nil
        else {
            throw ProductionFeatureMutationAuthorityError.invalidCancellationReleaseAuthorization
        }
        let scope = releaseAuthorization.scope
        guard scope.workspaceZone == namespace.workspaceZone,
            scope.workOrderID == workOrder.id,
            scope.reservationID == reservation.id,
            scope.cancellationRequestID == cancellation.id,
            scope.actorID == trusted.actor.cloudKitUserRecordName,
            scope.installationID == trusted.actor.installationID,
            scope.sessionID == trusted.actorSnapshot.sessionID,
            scope.sessionGeneration == trusted.actor.sessionGeneration,
            scope.issuedAt <= trusted.actorSnapshot.capturedAt,
            trusted.actorSnapshot.capturedAt < scope.expiresAt
        else {
            throw ProductionFeatureMutationAuthorityError.invalidCancellationReleaseAuthorization
        }
        switch releaseAuthorization {
        case let .attestation(_, statement):
            guard !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProductionFeatureMutationAuthorityError.invalidCancellationReleaseAuthorization
            }
        case let .emergencyOverride(_, reason):
            guard trusted.actor.role == .administrator,
                !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ProductionFeatureMutationAuthorityError.invalidCancellationReleaseAuthorization
            }
        }
    }

    func commitTransition(
        workOrderID: ObjectID,
        namespace: PersistenceNamespace,
        trusted: TrustedProductionSession,
        phase: String,
        material: ProductionMutationMaterial,
        update: (WorkOrder) throws -> WorkOrder
    ) async throws -> (OperationReceipt, WorkOrder) {
        let (current, workOrderExact) = try await exactWorkOrder(id: workOrderID, in: namespace)
        let updated = try update(current)
        let operationID = stableID(
            domain: "work-order-transition",
            components: [workOrderID.description, phase, String(current.revision)]
        )
        let dependencies = try await transitionDependencies(material, in: namespace)
        let businessKeys = Set(material.saves.map(\.resourceKey)).union(material.tombstones.map(\.resourceKey))
        let known = try transitionKnownRecords(
            workOrderID: workOrderID, workOrderExact: workOrderExact, workspaceAssertion: dependencies.workspace, material: material,
            businessKeys: businessKeys, dependencies: dependencies.others
        )
        try validateTransitionRecordCount(material: material, dependencies: dependencies.others)
        let state = AuthoritativeMutationState(knownRecords: known, currentWorkOrder: current)
        let mutation = try AuthoritativeWorkOrderMutationFactory.make(
            operationID: operationID, workspaceZone: namespace.workspaceZone, actor: trusted.actorSnapshot, currentWorkOrder: current,
            updatedWorkOrder: updated, state: state, saves: material.saves, tombstones: material.tombstones,
            readAssertions: dependencies.others + [dependencies.workspace], policyVersion: policy.policyVersion
        )
        try await sessionAuthorizer.revalidate(trusted)
        let receipt = try await mutations.commit(mutation)
        guard receipt == mutation.receipt else { throw ProductionFeatureMutationAuthorityError.receiptMismatch }
        return (receipt, updated)
    }

    private func transitionDependencies(
        _ material: ProductionMutationMaterial, in namespace: PersistenceNamespace
    ) async throws -> (workspace: AuthoritativeReadAssertion, others: [AuthoritativeReadAssertion]) {
        let sentinelKey = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
        let workspaceAssertions = material.readOnlyDependencies.filter { $0.resourceKey == sentinelKey }
        guard workspaceAssertions.count <= 1 else {
            throw ProductionFeatureMutationAuthorityError.malformedMaterialPrecondition(sentinelKey)
        }
        let workspace: AuthoritativeReadAssertion
        if let captured = workspaceAssertions.first {
            workspace = try validateActiveWorkspaceAssertion(captured, in: namespace)
        } else {
            workspace = try await activeWorkspaceAssertion(in: namespace)
        }
        return (workspace, material.readOnlyDependencies.filter { $0.resourceKey != sentinelKey })
    }

    private func transitionKnownRecords(
        workOrderID: ObjectID, workOrderExact: ExactRecordPrecondition, workspaceAssertion: AuthoritativeReadAssertion,
        material: ProductionMutationMaterial, businessKeys: Set<ResourceKey>, dependencies: [AuthoritativeReadAssertion]
    ) throws -> [ResourceKey: ExactRecordPrecondition] {
        var known: [ResourceKey: ExactRecordPrecondition] = [.object(workOrderID): workOrderExact]
        known[workspaceAssertion.resourceKey] = workspaceAssertion.precondition
        for key in businessKeys.sorted() {
            try addBusinessPrecondition(for: key, from: material, to: &known)
        }
        for assertion in dependencies {
            guard known[assertion.resourceKey] == nil,
                !businessKeys.contains(assertion.resourceKey)
            else {
                throw ProductionFeatureMutationAuthorityError.malformedMaterialPrecondition(assertion.resourceKey)
            }
            known[assertion.resourceKey] = assertion.precondition
        }
        return known
    }

    private func addBusinessPrecondition(
        for key: ResourceKey, from material: ProductionMutationMaterial, to known: inout [ResourceKey: ExactRecordPrecondition]
    ) throws {
        guard let precondition = material.touchedPreconditions[key] else {
            throw ProductionFeatureMutationAuthorityError.missingMaterialPrecondition(key)
        }
        switch precondition {
        case .exactSystemFields(let preconditionKey, let exact):
            guard preconditionKey == key,
                !exact.systemFields.isEmpty,
                !exact.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ProductionFeatureMutationAuthorityError.malformedMaterialPrecondition(key)
            }
            known[key] = exact
        case .mustNotExist(let preconditionKey):
            guard preconditionKey == key else {
                throw ProductionFeatureMutationAuthorityError.malformedMaterialPrecondition(key)
            }
        }
    }

    private func validateTransitionRecordCount(material: ProductionMutationMaterial, dependencies: [AuthoritativeReadAssertion]) throws {
        let count = material.saves.count + material.tombstones.count + dependencies.count + 4
        guard count <= AtomicCloudMutation.maximumBusinessRecordsPerOperation else {
            throw ProductionFeatureMutationAuthorityError.invalidDraft([
                "Split this change into smaller work orders before execution; it exceeds the atomic record limit."
            ])
        }
    }

    func exactWorkOrder(id: ObjectID, in namespace: PersistenceNamespace) async throws -> (WorkOrder, ExactRecordPrecondition) {
        guard
            let snapshot = try await exactRecords.exactRecord(
                for: .object(id),
                in: namespace.workspaceZone
            )
        else {
            throw ProductionFeatureMutationAuthorityError.workOrderMissing
        }
        guard snapshot.workspaceZone == namespace.workspaceZone,
            snapshot.resourceKey == .object(id),
            snapshot.recordType == CloudRecordNaming.workOrderRecordType,
            snapshot.schemaVersion == CloudRecordNaming.schemaVersion,
            let workOrder = canonicalDecoded(WorkOrder.self, from: snapshot.payload),
            workOrder.id == id
        else {
            throw ProductionFeatureMutationAuthorityError.malformedWorkOrder
        }
        return (workOrder, snapshot.exactPrecondition)
    }

    func activeWorkspaceAssertion(in namespace: PersistenceNamespace) async throws -> AuthoritativeReadAssertion {
        let key = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
        guard let snapshot = try await exactRecords.exactRecord(for: key, in: namespace.workspaceZone), snapshot.workspaceZone == namespace.workspaceZone,
            snapshot.resourceKey == key,
            snapshot.recordType == CloudRecordNaming.workspaceRecordType,
            snapshot.schemaVersion == CloudRecordNaming.schemaVersion,
            let workspace = canonicalDecoded(CloudWorkspaceRecord.self, from: snapshot.payload),
            workspace.workspaceID == namespace.workspaceID,
            workspace.zoneName == namespace.zoneName,
            workspace.zoneOwnerRecordName == namespace.zoneOwnerRecordName,
            case .active = workspace.lifecycle
        else {
            throw ProductionFeatureMutationAuthorityError.workspaceInactive
        }
        return try validateActiveWorkspaceAssertion(
            AuthoritativeReadAssertion(
                resourceKey: key,
                recordType: snapshot.recordType,
                schemaVersion: snapshot.schemaVersion,
                encodedRecord: snapshot.payload,
                precondition: snapshot.exactPrecondition
            ), in: namespace)
    }

    private func validateActiveWorkspaceAssertion(
        _ assertion: AuthoritativeReadAssertion, in namespace: PersistenceNamespace
    ) throws -> AuthoritativeReadAssertion {
        let key = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
        guard assertion.resourceKey == key,
            assertion.recordType == CloudRecordNaming.workspaceRecordType,
            assertion.schemaVersion == CloudRecordNaming.schemaVersion,
            !assertion.precondition.systemFields.isEmpty,
            !assertion.precondition.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let workspace = canonicalDecoded(CloudWorkspaceRecord.self, from: assertion.encodedRecord),
            workspace.workspaceID == namespace.workspaceID,
            workspace.zoneName == namespace.zoneName,
            workspace.zoneOwnerRecordName == namespace.zoneOwnerRecordName,
            case .active = workspace.lifecycle
        else {
            throw ProductionFeatureMutationAuthorityError.workspaceInactive
        }
        return assertion
    }

    func evidenceBindingAssertions(for workOrder: WorkOrder, in namespace: PersistenceNamespace) async throws -> [AuthoritativeReadAssertion] {
        guard let intentDigest = workOrder.intentDigest else {
            throw ProductionFeatureMutationAuthorityError.invalidReservation
        }
        var assertions: [AuthoritativeReadAssertion] = []
        assertions.reserveCapacity(workOrder.evidenceHashes.count)
        for evidence in workOrder.evidenceHashes.sorted(by: { $0.id < $1.id }) {
            let key = ResourceKey.attachmentEvidenceBinding(for: evidence.id)
            guard let snapshot = try await exactRecords.exactRecord(for: key, in: namespace.workspaceZone), snapshot.workspaceZone == namespace.workspaceZone,
                snapshot.resourceKey == key,
                snapshot.recordType == CloudRecordNaming.attachmentEvidenceBindingRecordType,
                snapshot.schemaVersion == CloudRecordNaming.schemaVersion,
                let binding = canonicalDecoded(AttachmentEvidenceBindingRecord.self, from: snapshot.payload),
                binding.resourceKey == key,
                binding.workOrderID == workOrder.id,
                binding.attachmentID == evidence.id,
                binding.evidence == evidence,
                binding.intentDigest == intentDigest,
                binding.assetMetadata.id == evidence.id,
                binding.assetMetadata.contentType == evidence.contentType,
                binding.auditEventID == AuditEvent.deterministicID(for: binding.operationID)
            else {
                throw ProductionFeatureMutationAuthorityError.invalidReservation
            }
            assertions.append(
                AuthoritativeReadAssertion(
                    resourceKey: key,
                    recordType: snapshot.recordType,
                    schemaVersion: snapshot.schemaVersion,
                    encodedRecord: snapshot.payload,
                    precondition: snapshot.exactPrecondition
                ))
        }
        return assertions
    }

    /// Captures a lock's state before it becomes part of completion material.
    /// `commitTransition` deliberately never refreshes this value.
    func materializationPrecondition(for key: ResourceKey, in namespace: PersistenceNamespace) async throws -> MutationPrecondition {
        guard let snapshot = try await exactRecords.exactRecord(for: key, in: namespace.workspaceZone) else {
            return .mustNotExist(key)
        }
        guard snapshot.workspaceZone == namespace.workspaceZone,
            snapshot.resourceKey == key,
            !snapshot.exactPrecondition.systemFields.isEmpty,
            !snapshot.exactPrecondition.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ProductionFeatureMutationAuthorityError.malformedMaterialPrecondition(key)
        }
        return .exactSystemFields(key, snapshot.exactPrecondition)
    }
}
