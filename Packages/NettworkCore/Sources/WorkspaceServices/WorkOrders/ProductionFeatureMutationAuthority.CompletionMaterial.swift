import CloudSync
import NetworkModel
import WorkspaceChangeControl

extension ProductionFeatureMutationAuthority {
    func validateCompletionEvidence(_ evidence: [EvidenceHash], current: WorkOrder) throws {
        guard evidence == current.evidenceHashes,
            Set(evidence.map(\.id)).count == evidence.count
        else {
            throw ProductionFeatureMutationAuthorityError.invalidReservation
        }
    }

    func completionTransitionMaterial(
        current: WorkOrder, trusted: TrustedProductionSession, namespace: PersistenceNamespace
    ) async throws -> ProductionMutationMaterial {
        let evidenceAssertions = try await evidenceBindingAssertions(for: current, in: namespace)
        let lockTombstones = try ResourceReservationLockFactory.tombstones(for: current, deletedAt: trusted.actorSnapshot.capturedAt)
        let lockPreconditions = try await completionLockPreconditions(lockTombstones, in: namespace)
        let material = try await completionMaterializer.materializeCompletion(of: current, at: trusted.actorSnapshot.capturedAt, in: namespace)
        try validateCompletionMaterial(material, current: current, namespace: namespace)
        var allTombstones = material.tombstones
        allTombstones.append(contentsOf: lockTombstones)
        var touchedPreconditions = material.touchedPreconditions
        for (key, precondition) in lockPreconditions {
            guard touchedPreconditions[key] == nil else {
                throw ProductionFeatureMutationAuthorityError.malformedMaterialPrecondition(key)
            }
            touchedPreconditions[key] = precondition
        }
        return .init(
            saves: material.saves, tombstones: allTombstones, touchedPreconditions: touchedPreconditions,
            readOnlyDependencies: material.readOnlyDependencies + evidenceAssertions
        )
    }

    func completionLockPreconditions(
        _ tombstones: [AuthoritativeTombstone], in namespace: PersistenceNamespace
    ) async throws -> [ResourceKey: MutationPrecondition] {
        var result: [ResourceKey: MutationPrecondition] = [:]
        for tombstone in tombstones {
            result[tombstone.resourceKey] = try await materializationPrecondition(for: tombstone.resourceKey, in: namespace)
        }
        return result
    }

    func validateCompletionMaterial(_ material: ProductionMutationMaterial, current: WorkOrder, namespace: PersistenceNamespace) throws {
        guard let reservation = current.reservation else {
            throw ProductionFeatureMutationAuthorityError.invalidReservation
        }
        let sentinelKey = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceZone.workspaceID)
        let businessKeys = Set(material.saves.map(\.resourceKey))
            .union(material.tombstones.map(\.resourceKey))
            .union(material.readOnlyDependencies.map(\.resourceKey).filter { $0 != sentinelKey })
        if let unreserved = businessKeys.subtracting(reservation.resourceKeys).sorted().first {
            throw ProductionFeatureMutationAuthorityError.materialOutsideReservation(unreserved)
        }
    }
}
