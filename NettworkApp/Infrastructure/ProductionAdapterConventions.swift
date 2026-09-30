import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

/// Accepts only a payload that round-trips through the deterministic Cloud
/// codec. Archive and mirror readers use this before trusting record fields.
func canonicalDecoded<Value: Codable>(_ type: Value.Type, from payload: Data) -> Value? {
    guard let value = try? CloudDeterministicCoding.decode(type, from: payload),
        (try? CloudDeterministicCoding.encode(value)) == payload
    else {
        return nil
    }
    return value
}

extension ProductionFeatureMutationAuthority {
    func finalizeStagedDraft(_ draft: WorkOrderDraft, trusted: TrustedProductionSession, in namespace: PersistenceNamespace) async throws -> ObjectID {
        try requireStructurallyValid(draft)
        try await sessionAuthorizer.revalidate(trusted)
        await draftStore.store(draft, in: namespace)
        return draft.id
    }
}

extension PlannedWorkOperation {
    var productionResourceKeys: Set<ResourceKey> {
        switch self {
        case .topology(let command):
            return ProductionResourceKeyProjection.topology(command)
        case .deviceDecommission(let value):
            return value.resourceKeys
        case .ipam(let operation):
            return ProductionResourceKeyProjection.ipam(operation)
        case let .device(resourceKey, _):
            return [resourceKey]
        case let .template(_, target, sourceTemplateID, migrations):
            return ProductionResourceKeyProjection.template(
                target: target,
                sourceTemplateID: sourceTemplateID,
                migrations: migrations
            )
        case let .moduleTemplate(_, target, sourceTemplateID):
            return Set([target.id, sourceTemplateID].compactMap { $0 }.map(ResourceKey.object))
        case .floorPlan(let operation):
            return operation.resourceKeys
        case .hierarchy(let operation):
            return operation.resourceKeys
        }
    }
}

extension WorkOrder {
    var productionResourceKeys: Set<ResourceKey> {
        plannedOperations.reduce(into: reservedResourceKeys) { keys, operation in
            keys.formUnion(operation.productionResourceKeys)
        }
    }
}

private enum ProductionResourceKeyProjection {
    static func topology(_ command: TopologyCommand) -> Set<ResourceKey> {
        switch command {
        case .connect(let value):
            return [.object(value.cable.id), .object(value.cable.endpointA), .object(value.cable.endpointB)]
        case .disconnect(let value):
            return [.object(value.cableID)]
        case .move(let value):
            return [.object(value.cableID), .object(value.endpointA), .object(value.endpointB)]
        case .install(let value):
            return Set(([value.device.id] + value.modules.map(\.id) + value.ports.map(\.id)).map(ResourceKey.object))
        case .remove(let value):
            return [.object(value.deviceID)]
        case .markUnavailable(let value):
            return [.object(value.portID)]
        }
    }

    static func ipam(_ operation: PlannedIPAMOperation) -> Set<ResourceKey> {
        switch operation {
        case let .prefixLayout(vrf, _, current, desired):
            return Set(([vrf.id] + (current + desired).map(\.id)).map(ResourceKey.object))
        case .addressAssignment(let assignments):
            return addressAssignments(assignments)
        case .vlanMembership(let memberships):
            return vlanMemberships(memberships)
        case let .legacyAddressAssignment(addressKey, interfaceID):
            return [addressKey, .object(interfaceID)]
        case let .legacyVLANMembership(interfaceID, vlanID, _):
            return [.object(interfaceID), .object(vlanID)]
        }
    }

    static func template(
        target: DeviceType,
        sourceTemplateID: ObjectID?,
        migrations: [DeviceTemplateMigrationPlan]
    ) -> Set<ResourceKey> {
        var keys = Set([target.id, sourceTemplateID].compactMap { $0 }.map(ResourceKey.object))
        for migration in migrations {
            keys.insert(.object(migration.deviceID))
            for impact in migration.portImpacts {
                if let currentPort = impact.currentPort { keys.insert(.object(currentPort.id)) }
                if let desiredPort = impact.desiredPort { keys.insert(.object(desiredPort.id)) }
                keys.formUnion(impact.connectedCableIDs.map(ResourceKey.object))
            }
        }
        return keys
    }

    private static func addressAssignments(_ value: InterfaceAddressAssignmentSet) -> Set<ResourceKey> {
        var keys: Set<ResourceKey> = [.object(value.revisionVRF.id), .object(value.interfaceID)]
        for assignment in value.currentAssignments + value.desiredAssignments {
            keys.formUnion([.object(assignment.id), .string(assignment.addressID), .object(assignment.interfaceID)])
        }
        return keys
    }

    private static func vlanMemberships(_ value: InterfaceVLANMembershipSet) -> Set<ResourceKey> {
        var keys: Set<ResourceKey> = [.object(value.revisionVRF.id), .object(value.interfaceID)]
        for membership in value.currentMemberships + value.desiredMemberships {
            keys.formUnion([.object(membership.id), .object(membership.interfaceID), .object(membership.vlanID)])
        }
        return keys
    }
}
