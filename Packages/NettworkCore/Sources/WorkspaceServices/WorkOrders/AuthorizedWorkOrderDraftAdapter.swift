import CloudSync
import ContentSafety
import CryptoKit
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

@MainActor
public final class AuthorizedWorkOrderDraftAdapter: TopologyWorkOrderDrafting, TemplateChangeRequesting, IPAMWorkOrderDrafting {
    private let account: AccountContext
    private let authority: any ProductionFeatureMutationAuthorizing
    private let onStagedWorkOrder: @MainActor (ObjectID) async -> Void

    public init(
        account: AccountContext,
        authority: any ProductionFeatureMutationAuthorizing,
        onStagedWorkOrder: @escaping @MainActor (ObjectID) async -> Void
    ) {
        self.account = account
        self.authority = authority
        self.onStagedWorkOrder = onStagedWorkOrder
    }

    public func stage(_ request: TopologyWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        try require(namespace)
        let id = try await authority.stageTopology(request, in: namespace)
        await onStagedWorkOrder(id)
        return id
    }

    public func stage(_ request: TemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        try require(namespace)
        let id = try await authority.stageTemplate(request, in: namespace)
        await onStagedWorkOrder(id)
        return id
    }

    public func stage(_ request: ModuleTemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        try require(namespace)
        let id = try await authority.stageModuleTemplate(request, in: namespace)
        await onStagedWorkOrder(id)
        return id
    }

    public func stage(_ request: IPAMWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        try require(namespace)
        let id = try await authority.stageIPAM(request, in: namespace)
        await onStagedWorkOrder(id)
        return id
    }
    private func require(_ namespace: PersistenceNamespace) throws {
        guard namespace == account.namespace else {
            throw ProductionAdapterError.namespaceMismatch
        }
    }
}
