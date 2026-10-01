import CloudSync
import ContentSafety
import CryptoKit
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension SwiftDataFeatureReadAdapter {
    public func inspect(startingAt portID: ObjectID, direction: TraceDirection, in namespace: PersistenceNamespace) async throws -> TraceInspectionSnapshot {
        let projection = try await readProjection(in: namespace)
        let result = try DefaultPathTraceService.traceRich(
            from: portID, in: projection.topology, enrichment: projection.enrichment,
            limits: TraceTraversalLimits(maximumSegmentsPerPath: 256, maximumPaths: 64))
        let branches = result.paths.prefix(64).map { path in
            let orderedNodes = direction == .reverse ? Array(path.nodes.reversed()) : path.nodes
            let orderedSegments = direction == .reverse ? Array(path.segments.reversed()) : path.segments
            return TraceBranchSnapshot(
                id: Self.stableObjectID("\(portID.description):\(orderedNodes.map(\.id.description).joined(separator: ","))"),
                nodes: orderedNodes.prefix(256).map { node in
                    TraceNodeSnapshot(
                        id: node.id,
                        deviceName: node.device?.name ?? "Unknown device",
                        portLabel: node.portLabel,
                        faceName: node.portFace.rawValue,
                        roomRack: node.rack.map { "\($0.locationPath.map(\.name).joined(separator: " / ")) · \($0.assetCode.value)" } ?? "Unracked",
                        logicalContext: node.interfaces.flatMap { interface in
                            [interface.name] + interface.addresses
                                + interface.vlans.map {
                                    "VLAN \($0.number) \($0.name)"
                                }
                        }
                    )
                },
                segments: orderedSegments.prefix(255).map { Self.traceSegmentSnapshot($0, topology: projection.topology) },
                warnings: path.warnings.map { String(describing: $0) },
                termination: String(describing: path.termination)
            )
        }
        return TraceInspectionSnapshot(
            startPortID: portID,
            branches: branches,
            globalWarnings: ["Inspection direction: \(direction.rawValue)"] + result.warnings.map { String(describing: $0) },
            isStale: projection.syncState?.lastSuccessfulServerContact == nil,
            hasPendingWork: !projection.topology.plannedWork.isEmpty || projection.workOrders.contains { Self.isPending($0.status) },
            hasConflict: projection.conflictResourceKeys.contains(.object(portID))
                || result.paths.contains { path in
                    path.nodes.contains { projection.conflictResourceKeys.contains(.object($0.id)) }
                        || path.segments.contains {
                            projection.conflictResourceKeys.contains(.object(Self.stableObjectID($0.id)))
                        }
                }
        )
    }

    public func catalog(in namespace: PersistenceNamespace) async throws -> [TemplateCatalogItem] {
        let projection = try await readProjection(in: namespace)
        return projection.topology.deviceTypes.map { template in
            TemplateCatalogItem(
                id: template.id, name: template.name, version: template.version, portCount: template.portTemplates.count,
                moduleCount: template.moduleSlots.count, validationSummary: Self.templateSummary(template))
        }.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            if lhs.version != rhs.version { return lhs.version < rhs.version }
            return lhs.id < rhs.id
        }
    }

    public func migrationImpact(templateID: ObjectID, in namespace: PersistenceNamespace) async throws -> [TemplateMigrationImpactSnapshot] {
        let projection = try await readProjection(in: namespace)
        guard let target = projection.topology.deviceTypes.first(where: { $0.id == templateID }) else { return [] }
        return try projection.topology.devices
            .filter {
                $0.templateSnapshot?.templateID == target.id && ($0.templateSnapshot?.version ?? target.version) < target.version
            }
            .prefix(256)
            .flatMap { device -> [TemplateMigrationImpactSnapshot] in
                let plan = try Self.migrationPlan(for: device, target: target, topology: projection.topology)
                return plan.portImpacts.map { impact in
                    let cableEffect =
                        impact.connectedCableIDs.isEmpty
                        ? ""
                        : "; atomically disconnects \(impact.connectedCableIDs.count) cable(s)"
                    return TemplateMigrationImpactSnapshot(
                        id: Self.stableObjectID("\(device.id.description):\(impact.templatePortID.description)"),
                        action: impact.action,
                        requiresCableReview: impact.requiresCableReview,
                        explanation: "\(device.name): \(impact.action.rawValue) \(impact.templatePortID.description)\(cableEffect)"
                    )
                }
            }.prefix(256).map { $0 }
    }

    public func template(id: ObjectID, in namespace: PersistenceNamespace) async throws -> DeviceType {
        let projection = try await readProjection(in: namespace)
        guard let template = projection.topology.deviceTypes.first(where: { $0.id == id }) else {
            throw TemplateCatalogQueryError.detailUnavailable
        }
        return template
    }

    public func migrationPlans(templateID: ObjectID, in namespace: PersistenceNamespace) async throws -> [DeviceTemplateMigrationPlan] {
        let projection = try await readProjection(in: namespace)
        guard let target = projection.topology.deviceTypes.first(where: { $0.id == templateID }) else {
            throw TemplateCatalogQueryError.detailUnavailable
        }
        return try projection.topology.devices
            .filter {
                $0.templateSnapshot?.templateID == target.id && ($0.templateSnapshot?.version ?? target.version) < target.version
            }
            .sorted { $0.id < $1.id }
            .map { try Self.migrationPlan(for: $0, target: target, topology: projection.topology) }
    }

    public func moduleTemplates(in namespace: PersistenceNamespace) async throws -> [ModuleTemplate] {
        let projection = try await readProjection(in: namespace)
        return projection.moduleTemplates.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            if lhs.version != rhs.version { return lhs.version < rhs.version }
            return lhs.id < rhs.id
        }
    }

    private static func migrationPlan(for device: Device, target: DeviceType, topology: PhysicalTopology) throws -> DeviceTemplateMigrationPlan {
        let sourceIDs = Set(device.templateSnapshot?.portTemplates.map(\.id) ?? [])
        let newPortIDs = Dictionary(
            uniqueKeysWithValues: target.portTemplates.compactMap { template -> (ObjectID, ObjectID)? in
                sourceIDs.contains(template.id) ? nil : (template.id, ObjectID())
            })
        return try TemplateMigration.plan(device: device, installedPorts: topology.ports, cables: topology.cables, target: target, newPortIDs: newPortIDs)
    }
}
