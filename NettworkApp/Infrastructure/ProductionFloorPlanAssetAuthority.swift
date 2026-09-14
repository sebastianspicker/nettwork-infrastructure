import CloudSync
import ContentSafety
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

/// App-level handoff to the core work-order mutation boundary. The concrete
/// implementation belongs with the authoritative schema because it must bind
/// the work-order transition, replacement precondition, metadata, and CKAsset
/// in one conditional mutation.
protocol FloorPlanAssetAtomicBinding: Sendable {
    func bindOrReplaceFloorPlanAsset(
        _ request: FloorPlanAssetBindingRequest, account: AccountContext, authorization: AuthorizedOperationContext
    ) async throws -> OperationReceipt
}

/// The feature never supplies a path or bytes. The descriptor refers to the
/// private, sanitized staging lease; the core atomic binding claims it only at
/// the authoritative work-order boundary.
struct FloorPlanAssetBindingRequest: Hashable, Sendable {
    let workOrderID: ObjectID
    let floorID: ObjectID
    let descriptor: SanitizedContentDescriptor

    init(workOrderID: ObjectID, floorID: ObjectID, descriptor: SanitizedContentDescriptor) {
        self.workOrderID = workOrderID
        self.floorID = floorID
        self.descriptor = descriptor
    }
}

enum ProductionFloorPlanAssetAuthorityError: Error, Equatable, Sendable {
    case staleAuthorization
    case invalidDescriptor
    case malformedAuthoritativeRecord(ResourceKey)
    case invalidWorkOrder
    case receiptMismatch
}

/// Claims the private sanitized lease only for the duration of one conditional
/// activation. The unchanged workspace sentinel, completed work-order
/// assertion, floor-keyed binding, CKAsset, audit, and receipt are committed by
/// the same authoritative repository operation.
actor ProductionFloorPlanAssetAtomicBinding: FloorPlanAssetAtomicBinding {
    static let policyVersion = "floor-plan-asset-binding-v1"
    let staging: any PrivateAttachmentStaging
    let sessionAuthorizer: ProductionSessionAuthorizer
    let exactRecords: any CloudExactRecordReading
    let mutations: any AuthoritativeMutationRepository

    init(
        staging: any PrivateAttachmentStaging, sessionAuthorizer: ProductionSessionAuthorizer, exactRecords: any CloudExactRecordReading,
        mutations: any AuthoritativeMutationRepository
    ) {
        self.staging = staging
        self.sessionAuthorizer = sessionAuthorizer
        self.exactRecords = exactRecords
        self.mutations = mutations
    }

    func bindOrReplaceFloorPlanAsset(
        _ request: FloorPlanAssetBindingRequest, account: AccountContext, authorization: AuthorizedOperationContext
    ) async throws -> OperationReceipt {
        try validateFloorPlanRequest(request, account: account, authorization: authorization)
        let trusted = try await sessionAuthorizer.authorizeOperation(authorization, action: .createAttachment, requiresAdministrator: false)
        let claim = try await staging.claim(request.descriptor.stagingToken, namespace: request.descriptor.namespace)
        var committed = false
        do {
            let prepared = try await prepareFloorPlanMutation(request, account: account, authorization: authorization, trusted: trusted, claim: claim)
            try await sessionAuthorizer.revalidate(trusted)
            let accepted = try await mutations.commit(prepared.mutation)
            guard accepted == prepared.receipt else { throw ProductionFloorPlanAssetAuthorityError.receiptMismatch }
            committed = true
            await staging.finalizeCommitted(claim)
            return accepted
        } catch {
            if !committed { await staging.release(claim) }
            throw error
        }
    }

    func requiredExactRecord(_ key: ResourceKey, recordType: String, namespace: PersistenceNamespace) async throws -> CloudExactRecordSnapshot {
        guard let snapshot = try await exactRecords.exactRecord(for: key, in: namespace.workspaceZone), snapshot.workspaceZone == namespace.workspaceZone,
            snapshot.resourceKey == key,
            snapshot.recordType == recordType,
            snapshot.schemaVersion == CloudRecordNaming.schemaVersion,
            !snapshot.exactPrecondition.systemFields.isEmpty,
            !snapshot.exactPrecondition.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ProductionFloorPlanAssetAuthorityError.malformedAuthoritativeRecord(key)
        }
        return snapshot
    }
}

/// App-side authority for floor-plan asset binding. This deliberately has no CloudKit, persistence, or
/// direct-write capability. It validates the current session and delegates the
/// actual bind/replace to the core atomic work-order boundary injected at
/// composition time.
@MainActor
struct ProductionFloorPlanAssetAuthority {
    private let account: AccountContext
    private let floorID: ObjectID
    private let sessionAuthorizer: ProductionSessionAuthorizer
    private let atomicBinding: any FloorPlanAssetAtomicBinding

    init(account: AccountContext, floorID: ObjectID, sessionAuthorizer: ProductionSessionAuthorizer, atomicBinding: any FloorPlanAssetAtomicBinding) {
        self.account = account
        self.floorID = floorID
        self.sessionAuthorizer = sessionAuthorizer
        self.atomicBinding = atomicBinding
    }

    func bindOrReplace(_ request: FloorPlanAssetBindingRequest, authorization: AuthorizedOperationContext) async throws -> OperationReceipt {
        guard request.floorID == floorID,
            request.descriptor.namespace == AttachmentNamespace(account: account),
            request.descriptor.purpose == .floorPlan,
            request.descriptor.contentType == .jpeg,
            request.descriptor.byteCount > 0,
            authorization.account == account
        else {
            throw ProductionFloorPlanAssetAuthorityError.invalidDescriptor
        }
        let trusted: TrustedProductionSession
        do {
            trusted = try await sessionAuthorizer.authorizeOperation(authorization, action: .createAttachment, requiresAdministrator: false)
        } catch {
            throw ProductionFloorPlanAssetAuthorityError.staleAuthorization
        }
        guard trusted.account == account else {
            throw ProductionFloorPlanAssetAuthorityError.staleAuthorization
        }
        // The atomic boundary performs the final live-session revalidation
        // immediately before commit and returns only the exact accepted or
        // recovered receipt. A second revalidation here would be post-commit
        // and could misreport a successful bind while the staging claim has
        // already been finalized.
        return try await atomicBinding.bindOrReplaceFloorPlanAsset(request, account: account, authorization: authorization)
    }
}

/// Persisted feature data derived only from the verified local mirror. The
/// static organization input is therefore a bootstrap fallback, not the sole
/// source of production anchors or the current bound floor-plan asset.
struct FloorPlanAssetReadProjection: Equatable, Sendable {
    let assetID: ObjectID
    let metadata: CloudRecordAssetMetadata
}

struct FloorPlanReadProjection: Equatable, Sendable {
    let anchors: [FloorPlanAnchor]
    let asset: FloorPlanAssetReadProjection?
}

protocol FloorPlanReadProjecting: Sendable {
    func floorPlan(for floorID: ObjectID, in namespace: PersistenceNamespace) async throws -> FloorPlanReadProjection
}

actor SwiftDataFloorPlanReadProjection: FloorPlanReadProjecting {
    private static let anchorLimit = 100_000

    private let account: AccountContext
    private let persistence: SwiftDataPersistenceStore

    init(account: AccountContext, persistence: SwiftDataPersistenceStore) {
        self.account = account
        self.persistence = persistence
    }

    func floorPlan(for floorID: ObjectID, in namespace: PersistenceNamespace) async throws -> FloorPlanReadProjection {
        guard namespace == account.namespace else { throw ProductionAdapterError.namespaceMismatch }
        let records = try await persistence.mirroredRecords(in: namespace, recordType: "NettworkFloorPlanAnchor", limit: Self.anchorLimit)
        let anchors = try records.compactMap { record -> FloorPlanAnchor? in
            guard !record.isTombstone,
                record.recordType == "NettworkFloorPlanAnchor",
                let payload = record.payload
            else { return nil }
            let anchor = try CloudDeterministicCoding.decode(FloorPlanAnchor.self, from: payload)
            return anchor.floorID == floorID ? anchor : nil
        }
        let bindingRecord = try await persistence.mirroredRecord(
            for: .floorPlanAssetBinding(for: floorID),
            in: namespace
        )
        let bindingRecords = bindingRecord.map { [$0] } ?? []
        let assets = try bindingRecords.compactMap { record -> FloorPlanAssetReadProjection? in
            guard !record.isTombstone,
                record.recordType == CloudRecordNaming.floorPlanAssetBindingRecordType,
                let payload = record.payload,
                let metadata = record.recordAssetMetadata
            else { return nil }
            let binding = try CloudDeterministicCoding.decode(FloorPlanAssetBindingRecord.self, from: payload)
            guard binding.floorID == floorID,
                binding.resourceKey == record.resourceKey,
                binding.assetMetadata == metadata
            else { return nil }
            return FloorPlanAssetReadProjection(assetID: metadata.id, metadata: metadata)
        }
        return FloorPlanReadProjection(
            anchors: anchors.sorted { $0.id < $1.id },
            asset: assets.sorted { $0.assetID < $1.assetID }.first
        )
    }
}
