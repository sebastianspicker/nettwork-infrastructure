import Foundation

public enum TopologyValidationError: Error, Hashable, Sendable {
    case duplicateObjectID(ObjectID)
    case revisionOverflow
    case duplicateDeviceType(ObjectID)
    case duplicateDevice(ObjectID)
    case duplicateModule(ObjectID)
    case duplicatePort(ObjectID)
    case duplicateCable(ObjectID)
    case duplicateInternalLinkID(ObjectID)
    case duplicateReservation(ObjectID)
    case
        duplicatePlannedWork(ObjectID)
    case missingDeviceType(ObjectID)
    case missingDevice(ObjectID)
    case missingModule(ObjectID)
    case missingPort(ObjectID)
    case missingCable(ObjectID)
    case tombstoneConflictsWithLiveObject(ObjectID)
    case duplicateTombstone(TopologyObjectKind, ObjectID)
    case tombstonedReference(TopologyObjectKind, ObjectID)
    case invalidModuleOwner(ObjectID)
    case invalidInstalledModuleOwner(ObjectID)
    case invalidInstalledPortOwner(ObjectID)
    case selfConnection(ObjectID)
    case incompatibleEndpoints(ObjectID)
    case incompatibleCableKind(ObjectID)
    case
        invalidFiberMode(ObjectID)
    case invalidPowerTermination(ObjectID)
    case invalidCableLength(ObjectID)
    case duplicateCableOccupancy(ObjectID)
    case duplicateInternalLink(ObjectID)
    case invalidPassThrough(ObjectID)
    case deviceHasCableOccupancy(ObjectID)
    case deviceHasInternalLinks(ObjectID)
    case invalidRackPlacement(ObjectID)
}

public enum DefaultTopologyEngine {
    public static func validate(_ topology: PhysicalTopology) throws {
        try validateReferences(topology)
        let ports = Dictionary(uniqueKeysWithValues: topology.ports.map { ($0.id, $0) })
        try validateCables(topology.cables, ports: ports)
        try validateInternalLinks(topology.internalLinks, ports: ports, devices: topology.devices, types: topology.deviceTypes)
    }

    private static func validateReferences(_ topology: PhysicalTopology) throws {
        try validateUniqueness(topology)
        try validateTombstones(topology)
        let context = ReferenceContext(topology)
        try validateDevices(topology.devices, types: context.deviceTypes)
        try validateModules(topology.modules, devices: context.devices, tombstones: context.tombstonedDevices)
        try validatePorts(topology.ports, devices: context.devices, modules: context.modules, tombstones: context)
        try validatePortCollections(topology, ports: context.ports, tombstones: context.tombstonedPorts)
    }

    private struct ReferenceContext {
        let devices: Set<ObjectID>
        let deviceTypes: Set<ObjectID>
        let modules: [ObjectID: Module]
        let ports: Set<ObjectID>
        let tombstonedDevices: Set<ObjectID>
        let tombstonedModules: Set<ObjectID>
        let tombstonedPorts: Set<ObjectID>

        init(_ topology: PhysicalTopology) {
            devices = Set(topology.devices.map(\.id))
            deviceTypes = Set(topology.deviceTypes.map(\.id))
            modules = Dictionary(uniqueKeysWithValues: topology.modules.map { ($0.id, $0) })
            ports = Set(topology.ports.map(\.id))
            tombstonedDevices = Set(topology.tombstones.filter { $0.kind == .device }.map(\.id))
            tombstonedModules = Set(topology.tombstones.filter { $0.kind == .module }.map(\.id))
            tombstonedPorts = Set(topology.tombstones.filter { $0.kind == .port }.map(\.id))
        }
    }

    private static func validateUniqueness(_ topology: PhysicalTopology) throws {
        try requireUnique(topology.deviceTypes.map(\.id), error: TopologyValidationError.duplicateDeviceType)
        try requireUnique(topology.devices.map(\.id), error: TopologyValidationError.duplicateDevice)
        try requireUnique(topology.modules.map(\.id), error: TopologyValidationError.duplicateModule)
        try requireUnique(topology.ports.map(\.id), error: TopologyValidationError.duplicatePort)
        try requireUnique(topology.cables.map(\.id), error: TopologyValidationError.duplicateCable)
        try requireUnique(topology.internalLinks.map(\.id), error: TopologyValidationError.duplicateInternalLinkID)
        try requireUnique(topology.reservations.map(\.id), error: TopologyValidationError.duplicateReservation)
        try requireUnique(topology.plannedWork.map(\.id), error: TopologyValidationError.duplicatePlannedWork)
        let ids =
            topology.deviceTypes.map(\.id) + topology.devices.map(\.id) + topology.modules.map(\.id) + topology.ports.map(\.id) + topology.cables.map(\.id)
            + topology.internalLinks.map(\.id)
        try requireUnique(ids, error: TopologyValidationError.duplicateObjectID)
    }

    private static func validateTombstones(_ topology: PhysicalTopology) throws {
        var seen = Set<String>()
        for tombstone in topology.tombstones {
            let key = "\(tombstone.kind.rawValue):\(tombstone.id.description)"
            guard seen.insert(key).inserted else { throw TopologyValidationError.duplicateTombstone(tombstone.kind, tombstone.id) }
        }
        let liveObjects =
            topology.devices.map { $0.id } + topology.modules.map { $0.id } + topology.ports.map { $0.id } + topology.cables.map { $0.id }
            + topology.internalLinks.map { $0.id }
        let tombstoneIDs = Set(topology.tombstones.map(\.id))
        for id in liveObjects where tombstoneIDs.contains(id) { throw TopologyValidationError.tombstoneConflictsWithLiveObject(id) }
    }

    private static func validateDevices(_ devices: [Device], types: Set<ObjectID>) throws {
        for device in devices where !types.contains(device.typeID) { throw TopologyValidationError.missingDeviceType(device.typeID) }
    }

    private static func validateModules(_ modules: [Module], devices: Set<ObjectID>, tombstones: Set<ObjectID>) throws {
        for module in modules {
            if tombstones.contains(module.deviceID) { throw TopologyValidationError.tombstonedReference(.device, module.deviceID) }
            guard devices.contains(module.deviceID) else { throw TopologyValidationError.missingDevice(module.deviceID) }
        }
    }

    private static func validatePorts(_ ports: [Port], devices: Set<ObjectID>, modules: [ObjectID: Module], tombstones: ReferenceContext) throws {
        for port in ports {
            if tombstones.tombstonedDevices.contains(port.deviceID) { throw TopologyValidationError.tombstonedReference(.device, port.deviceID) }
            guard devices.contains(port.deviceID) else { throw TopologyValidationError.missingDevice(port.deviceID) }
            try validateModuleOwner(port, modules: modules, tombstones: tombstones.tombstonedModules)
        }
    }

    private static func validateModuleOwner(_ port: Port, modules: [ObjectID: Module], tombstones: Set<ObjectID>) throws {
        guard let moduleID = port.moduleID else { return }
        if tombstones.contains(moduleID) { throw TopologyValidationError.tombstonedReference(.module, moduleID) }
        guard let module = modules[moduleID], module.deviceID == port.deviceID else { throw TopologyValidationError.invalidModuleOwner(port.id) }
    }

    private static func validatePortCollections(_ topology: PhysicalTopology, ports: Set<ObjectID>, tombstones: Set<ObjectID>) throws {
        try validatePortIDs(topology.reservations.map(\.portIDs), ports: ports, tombstones: tombstones)
        try validatePortIDs(topology.plannedWork.map(\.portIDs), ports: ports, tombstones: tombstones)
        try validatePortIDs(topology.cables.map { [$0.endpointA, $0.endpointB] }, ports: ports, tombstones: tombstones)
        try validatePortIDs(topology.internalLinks.map { [$0.endpointA, $0.endpointB] }, ports: ports, tombstones: tombstones)
    }

    private static func validatePortIDs(_ groups: [Set<ObjectID>], ports: Set<ObjectID>, tombstones: Set<ObjectID>) throws {
        for group in groups { try validatePortIDs(Array(group), ports: ports, tombstones: tombstones) }
    }

    private static func validatePortIDs(_ ids: [[ObjectID]], ports: Set<ObjectID>, tombstones: Set<ObjectID>) throws {
        for ids in ids { try validatePortIDs(ids, ports: ports, tombstones: tombstones) }
    }

    private static func validatePortIDs(_ ids: [ObjectID], ports: Set<ObjectID>, tombstones: Set<ObjectID>) throws {
        for id in ids {
            if tombstones.contains(id) { throw TopologyValidationError.tombstonedReference(.port, id) }
            guard ports.contains(id) else { throw TopologyValidationError.missingPort(id) }
        }
    }

    private static func requireUnique(_ ids: [ObjectID], error: (ObjectID) -> TopologyValidationError) throws {
        var seen = Set<ObjectID>()
        for id in ids where !seen.insert(id).inserted { throw error(id) }
    }

    private static func validateCables(_ cables: [Cable], ports: [ObjectID: Port]) throws {
        var usedPorts = Set<ObjectID>()
        for cable in cables {
            let endpoints = try cableEndpoints(cable, ports: ports)
            try validate(cable: cable, endpointA: endpoints.0, endpointB: endpoints.1)
            guard usedPorts.insert(cable.endpointA).inserted, usedPorts.insert(cable.endpointB).inserted else {
                throw TopologyValidationError.duplicateCableOccupancy(cable.id)
            }
        }
    }

    private static func cableEndpoints(_ cable: Cable, ports: [ObjectID: Port]) throws -> (Port, Port) {
        guard let a = ports[cable.endpointA] else { throw TopologyValidationError.missingPort(cable.endpointA) }
        guard let b = ports[cable.endpointB] else { throw TopologyValidationError.missingPort(cable.endpointB) }
        guard cable.endpointA != cable.endpointB else { throw TopologyValidationError.selfConnection(cable.id) }
        return (a, b)
    }

    private static func validateInternalLinks(_ links: [InternalLink], ports: [ObjectID: Port], devices: [Device], types: [DeviceType]) throws {
        var usedPorts = Set<ObjectID>()
        for link in links {
            let endpoints = try linkEndpoints(link, ports: ports)
            try validate(link: link, endpointA: endpoints.0, endpointB: endpoints.1, devices: devices, types: types)
            guard usedPorts.insert(link.endpointA).inserted, usedPorts.insert(link.endpointB).inserted else {
                throw TopologyValidationError.duplicateInternalLink(link.id)
            }
        }
    }

    private static func linkEndpoints(_ link: InternalLink, ports: [ObjectID: Port]) throws -> (Port, Port) {
        guard let a = ports[link.endpointA] else { throw TopologyValidationError.missingPort(link.endpointA) }
        guard let b = ports[link.endpointB] else { throw TopologyValidationError.missingPort(link.endpointB) }
        guard link.endpointA != link.endpointB else { throw TopologyValidationError.selfConnection(link.id) }
        return (a, b)
    }

    private static func validate(link: InternalLink, endpointA: Port, endpointB: Port, devices: [Device], types: [DeviceType]) throws {
        guard endpointA.deviceID == endpointB.deviceID,
            endpointA.face != endpointB.face,
            endpointA.medium == endpointB.medium,
            endpointA.connector == endpointB.connector
        else { throw TopologyValidationError.invalidPassThrough(link.id) }
        guard let device = devices.first(where: { $0.id == endpointA.deviceID }),
            let type = types.first(where: { $0.id == device.typeID }),
            type.kind.permitsPassThrough
        else { throw TopologyValidationError.invalidPassThrough(link.id) }
    }

    private static func validate(cable: Cable, endpointA: Port, endpointB: Port) throws {
        try validateCableLength(cable)
        try validateCableEndpoints(cable, endpointA: endpointA, endpointB: endpointB)
        try validateCableMedium(cable, endpointA: endpointA, endpointB: endpointB)
    }

    private static func validateCableLength(_ cable: Cable) throws {
        guard cable.lengthMeters.map({ $0 > 0 && $0.isFinite }) ?? true else { throw TopologyValidationError.invalidCableLength(cable.id) }
    }

    private static func validateCableEndpoints(_ cable: Cable, endpointA: Port, endpointB: Port) throws {
        guard endpointA.medium == cable.medium, endpointB.medium == cable.medium,
            endpointA.connector == cable.connectorA, endpointB.connector == cable.connectorB
        else {
            throw TopologyValidationError.incompatibleEndpoints(cable.id)
        }
    }

    private static func validateCableMedium(_ cable: Cable, endpointA: Port, endpointB: Port) throws {
        switch cable.medium {
        case .copper:
            try validateCopperCable(cable)
        case .fiber:
            try validateFiberCable(cable, endpointA: endpointA, endpointB: endpointB)
        case .power:
            try validatePowerCable(cable)
        case .other:
            try validateOtherCable(cable)
        }
    }

    private static func validateCopperCable(_ cable: Cable) throws {
        guard cable.kind == .fixed || cable.kind == .patchCord,
            cable.connectorA == .rj45, cable.connectorB == .rj45
        else { throw TopologyValidationError.incompatibleCableKind(cable.id) }
    }

    private static func validateFiberCable(_ cable: Cable, endpointA: Port, endpointB: Port) throws {
        guard cable.kind == .fiberLink else { throw TopologyValidationError.incompatibleCableKind(cable.id) }
        guard endpointA.fiberMode == .duplex, endpointB.fiberMode == .duplex,
            cable.connectorA == cable.connectorB,
            [.lc, .sc, .mpo].contains(cable.connectorA)
        else { throw TopologyValidationError.invalidFiberMode(cable.id) }
    }

    private static func validatePowerCable(_ cable: Cable) throws {
        guard cable.kind == .fixed || cable.kind == .patchCord else { throw TopologyValidationError.incompatibleCableKind(cable.id) }
        guard Set([cable.connectorA, cable.connectorB]) == Set([.c13, .c14]) else { throw TopologyValidationError.invalidPowerTermination(cable.id) }
    }

    private static func validateOtherCable(_ cable: Cable) throws {
        guard cable.kind == .fixed || cable.kind == .patchCord,
            cable.connectorA == .other, cable.connectorB == .other
        else { throw TopologyValidationError.incompatibleCableKind(cable.id) }
    }

    public static func validate(_ placement: RackPlacement, in rack: Rack) throws {
        guard placement.startRU > 0, placement.heightRU > 0, placement.startRU + placement.heightRU - 1 <= rack.heightRU else {
            throw TopologyValidationError.invalidRackPlacement(placement.deviceID)
        }
    }
}
