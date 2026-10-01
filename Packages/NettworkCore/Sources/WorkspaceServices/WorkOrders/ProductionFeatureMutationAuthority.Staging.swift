import CloudSync
import CryptoKit
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension ProductionFeatureMutationAuthority {
    public func validateDraft(
        _ draft: WorkOrderDraft, authorization: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> WorkOrderValidation {
        let trusted = try await sessionAuthorizer.authorizeMutation(namespace: namespace, presentation: authorization)
        var issues = structuralIssues(for: draft)
        if issues.isEmpty {
            issues.append(contentsOf: try await semanticValidator.issues(for: draft, in: namespace))
        }
        try await sessionAuthorizer.revalidate(trusted)
        guard issues.isEmpty else {
            return WorkOrderValidation(isValid: false, exactIntentDigest: nil, issues: issues)
        }
        let digest = try canonicalIntent(for: draft, creatorID: trusted.actor.cloudKitUserRecordName).digest()
        return WorkOrderValidation(isValid: true, exactIntentDigest: digest, issues: [])
    }

    public func stagedDraft(id: ObjectID, in namespace: PersistenceNamespace) async throws -> WorkOrderDraft {
        guard namespace == account.namespace else {
            throw ProductionFeatureMutationAuthorityError.namespaceMismatch
        }
        guard let draft = await draftStore.draft(id: id, in: namespace) else {
            throw ProductionFeatureMutationAuthorityError.workOrderMissing
        }
        return draft
    }

    public func stageTopology(_ request: TopologyWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        let kind: WorkOrderKind
        let operation: PlannedWorkOperation
        let requiresAdministrator: Bool
        switch request.action {
        case .connect(let value):
            operation = .topology(.connect(value))
            kind = .connect
            requiresAdministrator = false
        case .disconnect(let value):
            operation = .topology(.disconnect(value))
            kind = .disconnect
            requiresAdministrator = false
        case .move(let value):
            operation = .topology(.move(value))
            kind = .move
            requiresAdministrator = false
        case .remove:
            throw ProductionFeatureMutationAuthorityError.unsupportedDraft
        case .deviceDecommission(let value):
            operation = .deviceDecommission(value)
            kind = .device
            requiresAdministrator = false
        case .markUnavailable(let value):
            operation = .topology(.markUnavailable(value))
            kind = .device
            requiresAdministrator = false
        case .hierarchy(let value):
            operation = .hierarchy(value)
            kind = .hierarchy
            requiresAdministrator = true
        }
        let trusted = try await sessionAuthorizer.verifiedSession(namespace: namespace)
        try OfficialClientPolicy.authorizeMutation(actor: trusted.actor, account: trusted.account, requiresAdministrator: requiresAdministrator)
        let draft = WorkOrderDraft(
            title: request.title, kind: kind, ticket: request.ticket, notes: request.notes, resourceKeys: request.resourceKeys, operations: [operation]
        )
        return try await finalizeStagedDraft(draft, trusted: trusted, in: namespace)
    }

    public func stageTemplate(_ request: TemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        let trusted = try await sessionAuthorizer.verifiedSession(namespace: namespace)
        try OfficialClientPolicy.authorizeMutation(actor: trusted.actor, account: trusted.account, requiresAdministrator: true)
        if case let .instantiate(installation) = request.requestKind {
            return try await stageTemplateInstantiation(installation, request: request, trusted: trusted, namespace: namespace)
        }
        let components = try templateChangeComponents(request.requestKind)
        let draft = WorkOrderDraft(
            title: request.title,
            kind: .device,
            ticket: request.ticketID,
            notes: request.notes,
            resourceKeys: templateChangeResourceKeys(target: request.targetTemplate, source: components.source, migrations: components.migrations),
            operations: [
                .template(
                    kind: components.kind, target: request.targetTemplate, sourceTemplateID: components.source, migrations: components.migrations
                )
            ]
        )
        return try await finalizeStagedDraft(draft, trusted: trusted, in: namespace)
    }

    private func templateChangeComponents(
        _ requestKind: TemplateChangeRequest.RequestKind
    ) throws -> (kind: PlannedTemplateChangeKind, source: ObjectID?, migrations: [DeviceTemplateMigrationPlan]) {
        switch requestKind {
        case .create: return (.create, nil, [])
        case .clone(let source): return (.clone, source, [])
        case .newVersion(let source): return (.newVersion, source, [])
        case .migration(let plans): return (.migration, plans.first?.sourceSnapshot.templateID, plans)
        case .instantiate: throw ProductionFeatureMutationAuthorityError.unsupportedDraft
        }
    }

    private func templateChangeResourceKeys(target: DeviceType, source: ObjectID?, migrations: [DeviceTemplateMigrationPlan]) -> Set<ResourceKey> {
        var resources: Set<ResourceKey> = [.object(target.id)]
        if let source { resources.insert(.object(source)) }
        for migration in migrations {
            resources.insert(.object(migration.deviceID))
            for impact in migration.portImpacts {
                if let currentPort = impact.currentPort { resources.insert(.object(currentPort.id)) }
                if let desiredPort = impact.desiredPort { resources.insert(.object(desiredPort.id)) }
                resources.formUnion(impact.connectedCableIDs.map { .object($0) })
            }
        }
        return resources
    }

    private func stageTemplateInstantiation(
        _ installation: DeviceInstantiation, request: TemplateChangeRequest, trusted: TrustedProductionSession, namespace: PersistenceNamespace
    ) async throws -> ObjectID {
        guard installation.device.templateSnapshot == DeviceTemplateSnapshot(template: request.targetTemplate) else {
            throw ProductionFeatureMutationAuthorityError.unsupportedDraft
        }
        let objectIDs = [installation.device.id] + installation.modules.map(\.id) + installation.ports.map(\.id)
        var resources: Set<ResourceKey> = [.object(request.targetTemplate.id)]
        resources.formUnion(objectIDs.map { .object($0) })
        let operation = PlannedWorkOperation.topology(
            .install(
                InstallTopologyCommand(
                    device: installation.device,
                    modules: installation.modules,
                    ports: installation.ports
                )))
        let draft = WorkOrderDraft(
            title: request.title, kind: .device, ticket: request.ticketID, notes: request.notes, resourceKeys: resources, operations: [operation]
        )
        return try await finalizeStagedDraft(draft, trusted: trusted, in: namespace)
    }

    public func stageModuleTemplate(_ request: ModuleTemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        let trusted = try await sessionAuthorizer.verifiedSession(namespace: namespace)
        try OfficialClientPolicy.authorizeMutation(actor: trusted.actor, account: trusted.account, requiresAdministrator: true)
        let kind: PlannedTemplateChangeKind
        let source: ObjectID?
        switch request.requestKind {
        case .create:
            kind = .create
            source = nil
        case .clone(let id):
            kind = .clone
            source = id
        case .newVersion(let id):
            kind = .newVersion
            source = id
        }
        var resources: Set<ResourceKey> = [.object(request.targetTemplate.id)]
        if let source { resources.insert(.object(source)) }
        let draft = WorkOrderDraft(
            title: request.title,
            kind: .device,
            ticket: request.ticketID,
            notes: request.notes,
            resourceKeys: resources,
            operations: [.moduleTemplate(kind: kind, target: request.targetTemplate, sourceTemplateID: source)]
        )
        return try await finalizeStagedDraft(draft, trusted: trusted, in: namespace)
    }

    public func stageIPAM(_ request: IPAMWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        let trusted = try await sessionAuthorizer.verifiedSession(namespace: namespace)
        try OfficialClientPolicy.authorizeMutation(actor: trusted.actor, account: trusted.account, requiresAdministrator: false)
        let staging = try validatedIPAMStaging(for: request)
        let draft = WorkOrderDraft(
            title: request.title,
            kind: .ipam,
            ticket: request.ticketID,
            notes: request.notes,
            resourceKeys: staging.resourceKeys,
            operations: [.ipam(staging.operation)]
        )
        return try await finalizeStagedDraft(draft, trusted: trusted, in: namespace)
    }

    private func validatedIPAMStaging(for request: IPAMWorkOrderRequest) throws -> (operation: PlannedIPAMOperation, resourceKeys: Set<ResourceKey>) {
        switch request.operation {
        case let .prefixLayout(layout):
            return try prefixLayoutStaging(layout, revisionKey: request.perVRFRevisionKey)
        case let .addressAssignment(assignments):
            guard request.perVRFRevisionKey == .object(assignments.revisionVRF.id), isWellFormed(assignments) else {
                throw ProductionFeatureMutationAuthorityError.unsupportedDraft
            }
            return (.addressAssignment(assignments), Set([request.perVRFRevisionKey]).union(resourceKeys(for: assignments)))
        case let .vlanMembership(memberships):
            guard request.perVRFRevisionKey == .object(memberships.revisionVRF.id), isWellFormed(memberships) else {
                throw ProductionFeatureMutationAuthorityError.unsupportedDraft
            }
            return (.vlanMembership(memberships), Set([request.perVRFRevisionKey]).union(resourceKeys(for: memberships)))
        }
    }

    private func prefixLayoutStaging(
        _ layout: PrefixLayoutWorkOrderRequest,
        revisionKey: ResourceKey
    ) throws -> (operation: PlannedIPAMOperation, resourceKeys: Set<ResourceKey>) {
        guard revisionKey == .object(layout.vrf.id), layout.expectedRevision == layout.vrf.revision,
            layout.currentPrefixes.allSatisfy({ $0.vrfID == layout.vrf.id }),
            Set(layout.currentPrefixes.map(\.id)).count == layout.currentPrefixes.count,
            layout.desiredPrefixes.allSatisfy({ $0.vrfID == layout.vrf.id })
        else {
            throw ProductionFeatureMutationAuthorityError.unsupportedDraft
        }
        _ = try PrefixLayoutMutation.apply(prefixes: layout.desiredPrefixes, to: layout.vrf, expectedRevision: layout.expectedRevision)
        let operation = PlannedIPAMOperation.prefixLayout(
            vrf: layout.vrf, expectedRevision: layout.expectedRevision, currentPrefixes: layout.currentPrefixes, desiredPrefixes: layout.desiredPrefixes
        )
        let resourceKeys = Set([revisionKey, .object(layout.vrf.id)])
            .union(layout.currentPrefixes.map { .object($0.id) })
            .union(layout.desiredPrefixes.map { .object($0.id) })
        return (operation, resourceKeys)
    }

    public func stageFloorPlan(
        _ request: FloorPlanWorkOrderRequest, authorization: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> ObjectID {
        let trusted = try await sessionAuthorizer.authorizeMutation(namespace: namespace, presentation: authorization)
        let operation: PlannedFloorPlanOperation
        switch request.mutation {
        case .upsert(let value):
            operation = .upsert(value)
        case .remove(let value):
            operation = .remove(value)
        }
        let draft = WorkOrderDraft(
            title: request.metadata.title,
            kind: .floorPlan,
            ticket: request.metadata.ticket,
            notes: request.metadata.notes,
            resourceKeys: operation.resourceKeys,
            operations: [.floorPlan(operation)]
        )
        return try await finalizeStagedDraft(draft, trusted: trusted, in: namespace)
    }

    public func stageFloorPlanAsset(
        _ asset: PlannedFloorPlanAsset, metadata: FloorPlanWorkOrderMetadata, authorization: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> ObjectID {
        let trusted = try await sessionAuthorizer.authorizeMutation(namespace: namespace, presentation: authorization)
        let planned = try PlannedFloorPlanAsset(floorID: asset.floorID, assetMetadata: asset.assetMetadata)
        let operation = PlannedFloorPlanOperation.bindAsset(planned)
        let draft = WorkOrderDraft(
            title: metadata.title,
            kind: .floorPlan,
            ticket: metadata.ticket,
            notes: metadata.notes,
            resourceKeys: operation.resourceKeys,
            operations: [.floorPlan(operation)]
        )
        try requireStructurallyValid(draft)
        try await sessionAuthorizer.revalidate(trusted)
        await draftStore.store(draft, in: namespace)
        return draft.id
    }
}

extension ProductionFeatureMutationAuthority {
    func finalizeStagedDraft(_ draft: WorkOrderDraft, trusted: TrustedProductionSession, in namespace: PersistenceNamespace) async throws -> ObjectID {
        try requireStructurallyValid(draft)
        try await sessionAuthorizer.revalidate(trusted)
        await draftStore.store(draft, in: namespace)
        return draft.id
    }
}
