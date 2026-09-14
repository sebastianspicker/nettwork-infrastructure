import CloudSync
import Foundation

struct ProductionRuntimeCloudGraph {
    let batchSource: CloudKitSyncEngineBatchSourceAdapter
    let syncDriver: CloudKitStatefulSyncEngineDriver
    let transport: CloudKitRecordTransport
    let exactMutationState: CloudExactAuthoritativeMutationStateProvider
    let mutationRepository: CloudAuthoritativeMutationRepository
    let stagedTransferRepository: CloudStagedTransferRepository
    let outboxReplayer: CloudOutboxReplayer
    let syncCoordinator: CloudForegroundSyncCoordinator
    let stagedTransferGC: CloudStagedTransferGarbageCollector?
}

extension ProductionRuntimeAssembly {
    static func makeRuntimeCloudGraph(_ input: OrganizationInput, foundation: ProductionRuntimeFoundation) async throws -> ProductionRuntimeCloudGraph {
        let batchSource = try CloudKitSyncEngineBatchSourceAdapter(
            database: CloudKitProductionBoundary.database(
                in: input.cloudWorkspace.cloudKitContainer,
                account: input.cloudWorkspace.account
            ),
            namespace: input.cloudWorkspace.account.namespace,
            persistedState: try await foundation.stateStore.persistedState(in: input.cloudWorkspace.account.namespace),
            identityIndex: foundation.identityIndex,
            maximumRecordNameIdentities: input.cloudWorkspace.maximumRecordNameIdentities,
            subscriptionID: input.cloudWorkspace.cloudKitSubscriptionID
        )
        let syncDriver = CloudKitStatefulSyncEngineDriver(source: batchSource, durableState: foundation.stateStore)
        let transport = CloudKitRecordTransport(
            container: input.cloudWorkspace.cloudKitContainer,
            account: input.cloudWorkspace.account,
            engine: syncDriver,
            stateStore: foundation.stateStore
        )
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
        let garbageCollector = input.cloudWorkspace.stagedTransferGCPolicy.map {
            CloudStagedTransferGarbageCollector(
                policy: $0,
                transport: transport,
                authorizer: ProductionStagedTransferGCAuthorizer(
                    account: input.cloudWorkspace.account,
                    sessionAuthorizer: foundation.sessionAuthorizer
                )
            )
        }
        return ProductionRuntimeCloudGraph(
            batchSource: batchSource,
            syncDriver: syncDriver,
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
