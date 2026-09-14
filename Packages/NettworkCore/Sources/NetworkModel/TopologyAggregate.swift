import Foundation

public struct PhysicalTopology: Codable, Hashable, Sendable {
    public var deviceTypes: [DeviceType]
    public var devices: [Device]
    public var modules: [Module]
    public var ports: [Port]
    public var cables: [Cable]
    public var internalLinks: [InternalLink]
    public var reservations: [TopologyReservation]
    public var plannedWork: [PlannedTopologyWork]
    public var tombstones: [TopologyTombstone]
    public private(set) var revision: Int
    public private(set) var appliedOperationIDs: Set<ObjectID>

    public init(
        deviceTypes: [DeviceType] = [], devices: [Device] = [], modules: [Module] = [],
        ports: [Port] = [], cables: [Cable] = [], internalLinks: [InternalLink] = [],
        reservations: [TopologyReservation] = [], plannedWork: [PlannedTopologyWork] = [],
        tombstones: [TopologyTombstone] = [], revision: Int = 0, appliedOperationIDs: Set<ObjectID> = []
    ) {
        self.deviceTypes = deviceTypes
        self.devices = devices
        self.modules = modules
        self.ports = ports
        self.cables = cables
        self.internalLinks = internalLinks
        self.reservations = reservations
        self.plannedWork = plannedWork
        self.tombstones = tombstones
        self.revision = revision
        self.appliedOperationIDs = appliedOperationIDs
    }

    private enum CodingKeys: String, CodingKey {
        case deviceTypes, devices, modules, ports, cables, internalLinks, reservations, plannedWork, tombstones, revision, appliedOperationIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceTypes = try container.decodeIfPresent([DeviceType].self, forKey: .deviceTypes) ?? []
        devices = try container.decodeIfPresent([Device].self, forKey: .devices) ?? []
        modules = try container.decodeIfPresent([Module].self, forKey: .modules) ?? []
        ports = try container.decodeIfPresent([Port].self, forKey: .ports) ?? []
        cables = try container.decodeIfPresent([Cable].self, forKey: .cables) ?? []
        internalLinks = try container.decodeIfPresent([InternalLink].self, forKey: .internalLinks) ?? []
        reservations = try container.decodeIfPresent([TopologyReservation].self, forKey: .reservations) ?? []
        plannedWork = try container.decodeIfPresent([PlannedTopologyWork].self, forKey: .plannedWork) ?? []
        tombstones = try container.decodeIfPresent([TopologyTombstone].self, forKey: .tombstones) ?? []
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        appliedOperationIDs = try container.decodeIfPresent(Set<ObjectID>.self, forKey: .appliedOperationIDs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceTypes, forKey: .deviceTypes)
        try container.encode(devices, forKey: .devices)
        try container.encode(modules, forKey: .modules)
        try container.encode(ports, forKey: .ports)
        try container.encode(cables, forKey: .cables)
        try container.encode(internalLinks, forKey: .internalLinks)
        try container.encode(reservations, forKey: .reservations)
        try container.encode(plannedWork, forKey: .plannedWork)
        try container.encode(tombstones, forKey: .tombstones)
        try container.encode(revision, forKey: .revision)
        try container.encode(appliedOperationIDs, forKey: .appliedOperationIDs)
    }

    public func portState(for portID: ObjectID) -> PortState? {
        guard let port = ports.first(where: { $0.id == portID }) else { return nil }
        if port.availability == .unavailable { return .unavailable }
        if let cableState = cableState(for: portID) { return cableState }
        if reservations.contains(where: { $0.portIDs.contains(portID) }) { return .reserved }
        if plannedWork.contains(where: { $0.portIDs.contains(portID) }) { return .planned }
        return .free
    }

    private func cableState(for portID: ObjectID) -> PortState? {
        let attached = cables.filter { $0.endpointA == portID || $0.endpointB == portID }
        guard !attached.isEmpty else { return nil }
        return attached.contains(where: { $0.status == .installed }) ? .occupied : .planned
    }

    public mutating func apply(_ command: TopologyCommand) throws -> TopologyCommandResult {
        try DefaultTopologyEngine.validate(self)
        if appliedOperationIDs.contains(command.operationID) {
            return TopologyCommandResult(operationID: command.operationID, didApply: false, revision: revision)
        }
        guard revision < Int.max else { throw TopologyValidationError.revisionOverflow }

        var candidate = self
        try candidate.applyUnchecked(command)
        try DefaultTopologyEngine.validate(candidate)
        candidate.appliedOperationIDs.insert(command.operationID)
        candidate.revision += 1
        self = candidate
        return TopologyCommandResult(operationID: command.operationID, didApply: true, revision: revision)
    }

    private mutating func applyUnchecked(_ command: TopologyCommand) throws {
        switch command {
        case .connect(let request): try connect(request)
        case .disconnect(let request): try disconnect(request)
        case .move(let request): try move(request)
        case .install(let request): try install(request)
        case .remove(let request): try remove(request)
        case .markUnavailable(let request): try markUnavailable(request)
        }
    }

    private mutating func connect(_ request: ConnectTopologyCommand) throws {
        guard !cables.contains(where: { $0.id == request.cable.id }) else { throw TopologyValidationError.duplicateCable(request.cable.id) }
        cables.append(request.cable)
    }

    private mutating func disconnect(_ request: DisconnectTopologyCommand) throws {
        guard let index = cables.firstIndex(where: { $0.id == request.cableID }) else { throw TopologyValidationError.missingCable(request.cableID) }
        cables.remove(at: index)
        tombstones.append(TopologyTombstone(id: request.cableID, kind: .cable, deletedAt: request.deletedAt))
    }

    private mutating func move(_ request: MoveTopologyCommand) throws {
        guard let index = cables.firstIndex(where: { $0.id == request.cableID }) else { throw TopologyValidationError.missingCable(request.cableID) }
        cables[index].endpointA = request.endpointA
        cables[index].connectorA = request.connectorA
        cables[index].endpointB = request.endpointB
        cables[index].connectorB = request.connectorB
        cables[index].connector = request.connectorA == request.connectorB ? request.connectorA : .other
    }

    private mutating func install(_ request: InstallTopologyCommand) throws {
        guard !devices.contains(where: { $0.id == request.device.id }) else { throw TopologyValidationError.duplicateDevice(request.device.id) }
        try validateInstallation(request)
        devices.append(request.device)
        modules.append(contentsOf: request.modules)
        ports.append(contentsOf: request.ports)
    }

    private func validateInstallation(_ request: InstallTopologyCommand) throws {
        guard request.modules.allSatisfy({ $0.deviceID == request.device.id }),
            Set(request.modules.map(\.id)).count == request.modules.count
        else {
            throw TopologyValidationError.invalidInstalledModuleOwner(request.device.id)
        }
        let moduleIDs = Set(request.modules.map(\.id))
        guard
            request.ports.allSatisfy({ port in
                port.deviceID == request.device.id && port.moduleID.map(moduleIDs.contains) != false
            })
        else {
            throw TopologyValidationError.invalidInstalledPortOwner(request.device.id)
        }
    }

    private mutating func remove(_ request: RemoveTopologyCommand) throws {
        guard let index = devices.firstIndex(where: { $0.id == request.deviceID }) else { throw TopologyValidationError.missingDevice(request.deviceID) }
        let portIDs = Set(ports.filter { $0.deviceID == request.deviceID }.map(\.id))
        try validateRemoval(of: request.deviceID, portIDs: portIDs)
        let moduleIDs = Set(modules.filter { $0.deviceID == request.deviceID }.map(\.id))
        devices.remove(at: index)
        ports.removeAll { portIDs.contains($0.id) }
        modules.removeAll { $0.deviceID == request.deviceID }
        appendRemovalTombstones(request, moduleIDs: moduleIDs, portIDs: portIDs)
    }

    private func validateRemoval(of deviceID: ObjectID, portIDs: Set<ObjectID>) throws {
        guard !cables.contains(where: { portIDs.contains($0.endpointA) || portIDs.contains($0.endpointB) }) else {
            throw TopologyValidationError.deviceHasCableOccupancy(deviceID)
        }
        guard !internalLinks.contains(where: { portIDs.contains($0.endpointA) || portIDs.contains($0.endpointB) }) else {
            throw TopologyValidationError.deviceHasInternalLinks(deviceID)
        }
    }

    private mutating func appendRemovalTombstones(_ request: RemoveTopologyCommand, moduleIDs: Set<ObjectID>, portIDs: Set<ObjectID>) {
        tombstones.append(TopologyTombstone(id: request.deviceID, kind: .device, deletedAt: request.deletedAt))
        tombstones.append(contentsOf: moduleIDs.map { TopologyTombstone(id: $0, kind: .module, deletedAt: request.deletedAt) })
        tombstones.append(contentsOf: portIDs.map { TopologyTombstone(id: $0, kind: .port, deletedAt: request.deletedAt) })
    }

    private mutating func markUnavailable(_ request: MarkPortUnavailableTopologyCommand) throws {
        guard let index = ports.firstIndex(where: { $0.id == request.portID }) else { throw TopologyValidationError.missingPort(request.portID) }
        ports[index].availability = request.isUnavailable ? .unavailable : .available
    }
}
