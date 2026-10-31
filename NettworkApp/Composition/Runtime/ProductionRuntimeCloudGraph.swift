import CloudSync
import Foundation
import WorkspaceServices

struct ProductionRuntimeCloudGraph {
    let transport: any ProductionRuntimeRecordTransport
    let exactMutationState: CloudExactAuthoritativeMutationStateProvider
    let mutationRepository: CloudAuthoritativeMutationRepository
    let stagedTransferRepository: CloudStagedTransferRepository
    let outboxReplayer: CloudOutboxReplayer
    let syncCoordinator: CloudForegroundSyncCoordinator
    let stagedTransferGC: CloudStagedTransferGarbageCollector?
}

/// The selected backend's transport. Staged-transfer GC is offered only by
/// backends that implement its transport; others leave it nil and fail closed.
struct ProductionRuntimeBackendTransport {
    let transport: any ProductionRuntimeRecordTransport
    let garbageCollection: (any CloudStagedTransferGCTransport)?
}

extension ProductionRuntimeAssembly {
    private static func makeTransport(_ input: OrganizationInput, foundation: ProductionRuntimeFoundation) async throws -> ProductionRuntimeBackendTransport {
        switch input.cloudWorkspace.backend {
        case .cloudKit(let cloudKit):
            let batchSource = try CloudKitSyncEngineBatchSourceAdapter(
                database: CloudKitProductionBoundary.database(
                    in: cloudKit.cloudKitContainer,
                    account: input.cloudWorkspace.account
                ),
                namespace: input.cloudWorkspace.account.namespace,
                persistedState: try await foundation.stateStore.persistedState(in: input.cloudWorkspace.account.namespace),
                identityIndex: foundation.identityIndex,
                maximumRecordNameIdentities: input.cloudWorkspace.maximumRecordNameIdentities,
                subscriptionID: cloudKit.cloudKitSubscriptionID
            )
            // The transport retains the driver, which retains the batch source.
            let syncDriver = CloudKitStatefulSyncEngineDriver(source: batchSource, durableState: foundation.stateStore)
            let transport = CloudKitRecordTransport(
                container: cloudKit.cloudKitContainer,
                account: input.cloudWorkspace.account,
                engine: syncDriver,
                stateStore: foundation.stateStore
            )
            return ProductionRuntimeBackendTransport(transport: transport, garbageCollection: transport)
        case .local(let local):
            return ProductionRuntimeBackendTransport(transport: try await local.makeTransport(foundation.stateStore), garbageCollection: nil)
        }
    }

    static func makeRuntimeCloudGraph(_ input: OrganizationInput, foundation: ProductionRuntimeFoundation) async throws -> ProductionRuntimeCloudGraph {
        let backendTransport = try await makeTransport(input, foundation: foundation)
        let transport = backendTransport.transport
        let exactMutationState = CloudExactAuthoritativeMutationStateProvider(reader: transport, account: input.cloudWorkspace.account)
        let mutationRepository = CloudAuthoritativeMutationRepository(transport: transport, stateProvider: exactMutationState)
        let stagedTransferRepository = CloudStagedTransferRepository(transport: transport, reader: transport)
        let outboxReplayer = CloudOutboxReplayer(
            transport: transport, receiptLookup: transport, outbox: foundation.persistence, conflicts: foundation.persistence)
        let syncCoordinator = CloudForegroundSyncCoordinator(
            session: foundation.lifecycle,
            transport: transport,
            mirror: foundation.mirror,
            membershipVerifier: foundation.sessionAuthorizer,
            validator: input.cloudWorkspace.remoteRecordValidator,
            outboxReplayer: outboxReplayer,
            actorContextProvider: input.cloudWorkspace.actorContextProvider,
            mutationStateProvider: exactMutationState
        )
        let garbageCollector = try input.cloudWorkspace.stagedTransferGCPolicy.map { policy in
            guard let gcTransport = backendTransport.garbageCollection else {
                throw ProductionRuntimeAssemblyError.invalidConfiguration("stagedTransferGCPolicy")
            }
            return CloudStagedTransferGarbageCollector(
                policy: policy,
                transport: gcTransport,
                authorizer: ProductionStagedTransferGCAuthorizer(
                    account: input.cloudWorkspace.account,
                    sessionAuthorizer: foundation.sessionAuthorizer
                )
            )
        }
        return ProductionRuntimeCloudGraph(
            transport: transport,
            exactMutationState: exactMutationState,
            mutationRepository: mutationRepository,
            stagedTransferRepository: stagedTransferRepository,
            outboxReplayer: outboxReplayer,
            syncCoordinator: syncCoordinator,
            stagedTransferGC: garbageCollector
        )
    }
}
