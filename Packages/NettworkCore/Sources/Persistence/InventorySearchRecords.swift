import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension InventorySearchIndexBuilder {
    static func build(records: [LocalMirrorRecord], namespace: PersistenceNamespace) throws -> [LocalInventorySearchRecord] {
        try Task.checkCancellation()
        let projection = try Projection(records: records)
        let builder = try InventorySearchRecordBuilder(projection: projection, namespace: namespace)
        let result = try builder.build()
        try Task.checkCancellation()
        return result
    }

    static func customFields(_ fields: [CustomFieldValue]) -> [String] {
        fields.flatMap { field in
            let value: String
            switch field.value {
            case .text(let text): value = text
            case .number(let number): value = String(number)
            case .flag(let flag): value = String(flag)
            case .date(let date): value = String(date.timeIntervalSince1970)
            }
            return [field.key, value]
        }
    }

    static func stableObjectID(_ string: String) -> ObjectID {
        let hex = SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
        let value =
            "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        guard let uuid = UUID(uuidString: value) else {
            preconditionFailure("A SHA-256-derived UUID must be syntactically valid.")
        }
        return ObjectID(uuid)
    }

    static func isPending(_ workOrder: WorkOrder) -> Bool {
        [.draft, .reserved, .approved, .executing, .cancellationRequested, .reconciliation].contains(workOrder.status)
    }

    /// WorkOrder.reservedResourceKeys combines the immutable reservation's
    /// resource-key identity with legacy object-only reservations. Keeping the
    /// conversion here prevents string address identities from being lost.
    static func canonicalAffectedResourceKeys(for workOrder: WorkOrder) -> Set<ResourceKey> {
        workOrder.reservedResourceKeys
    }

    static func portStateFactKey(_ portID: ObjectID) -> String {
        "inventory-port-state-fact:\(portID.description)"
    }

    /// Converts aggregate-seeded values into canonical granular records. This
    /// is what makes a later direct port/device delta reconstructable from its
    /// dirty component without treating the original aggregate payload as a
    /// whole-workspace dependency.
    static func canonicalNodeRecords(
        projection: Projection, namespace: PersistenceNamespace
    ) throws -> [LocalMirrorRecord] {
        var values: [LocalMirrorRecord] = []
        try appendTopologyNodes(projection, namespace: namespace, to: &values)
        try appendHierarchyNodes(projection, namespace: namespace, to: &values)
        try appendSupplementalNodes(projection, namespace: namespace, to: &values)
        try appendPortStateNodes(projection, namespace: namespace, to: &values)
        return values
    }

    static func portStates(
        in topology: PhysicalTopology, facts: [ObjectID: PortStateFact] = [:]
    ) -> [ObjectID: PortState] {
        var endpoints: [ObjectID: (hasCable: Bool, installed: Bool)] = [:]
        for cable in topology.cables {
            for endpoint in [cable.endpointA, cable.endpointB] {
                let current = endpoints[endpoint] ?? (false, false)
                endpoints[endpoint] = (true, current.installed || cable.status == .installed)
            }
        }
        let reserved = Set(topology.reservations.flatMap(\.portIDs)).union(facts.values.filter(\.isReserved).map(\.portID))
        let planned = Set(topology.plannedWork.flatMap(\.portIDs)).union(facts.values.filter(\.isPlanned).map(\.portID))
        return Dictionary(
            uniqueKeysWithValues: topology.ports.map { port in
                let state: PortState
                if port.availability == .unavailable {
                    state = .unavailable
                } else if let endpoint = endpoints[port.id], endpoint.hasCable {
                    state = endpoint.installed ? .occupied : .planned
                } else if reserved.contains(port.id) {
                    state = .reserved
                } else if planned.contains(port.id) {
                    state = .planned
                } else {
                    state = .free
                }
                return (port.id, state)
            })
    }
}
