import Foundation

public struct ConnectTopologyCommand: Codable, Hashable, Sendable {
    public var operationID: ObjectID
    public var cable: Cable
    public init(operationID: ObjectID = .init(), cable: Cable) {
        self.operationID = operationID
        self.cable = cable
    }
}

public struct DisconnectTopologyCommand: Codable, Hashable, Sendable {
    public var operationID: ObjectID
    public var cableID: ObjectID
    public var deletedAt: Date
    public init(operationID: ObjectID = .init(), cableID: ObjectID, deletedAt: Date = .now) {
        self.operationID = operationID
        self.cableID = cableID
        self.deletedAt = deletedAt
    }
}

public struct MoveTopologyCommand: Codable, Hashable, Sendable {
    public var operationID: ObjectID
    public var cableID: ObjectID
    public var endpointA: ObjectID
    public var connectorA: Connector
    public var endpointB: ObjectID
    public var connectorB: Connector
    public init(operationID: ObjectID = .init(), cableID: ObjectID, endpointA: ObjectID, connectorA: Connector, endpointB: ObjectID, connectorB: Connector) {
        self.operationID = operationID
        self.cableID = cableID
        self.endpointA = endpointA
        self.connectorA = connectorA
        self.endpointB = endpointB
        self.connectorB = connectorB
    }
}

public struct InstallTopologyCommand: Codable, Hashable, Sendable {
    public var operationID: ObjectID
    public var device: Device
    public var modules: [Module]
    public var ports: [Port]
    public init(operationID: ObjectID = .init(), device: Device, modules: [Module] = [], ports: [Port]) {
        self.operationID = operationID
        self.device = device
        self.modules = modules
        self.ports = ports
    }

    private enum CodingKeys: String, CodingKey { case operationID, device, modules, ports }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try container.decode(ObjectID.self, forKey: .operationID)
        device = try container.decode(Device.self, forKey: .device)
        modules = try container.decodeIfPresent([Module].self, forKey: .modules) ?? []
        ports = try container.decode([Port].self, forKey: .ports)
    }
}

public struct RemoveTopologyCommand: Codable, Hashable, Sendable {
    public var operationID: ObjectID
    public var deviceID: ObjectID
    public var deletedAt: Date
    public init(operationID: ObjectID = .init(), deviceID: ObjectID, deletedAt: Date = .now) {
        self.operationID = operationID
        self.deviceID = deviceID
        self.deletedAt = deletedAt
    }
}

public struct MarkPortUnavailableTopologyCommand: Codable, Hashable, Sendable {
    public var operationID: ObjectID
    public var portID: ObjectID
    public var isUnavailable: Bool
    public init(operationID: ObjectID = .init(), portID: ObjectID, isUnavailable: Bool) {
        self.operationID = operationID
        self.portID = portID
        self.isUnavailable = isUnavailable
    }
}

public enum TopologyCommand: Codable, Hashable, Sendable {
    case connect(ConnectTopologyCommand)
    case disconnect(DisconnectTopologyCommand)
    case move(MoveTopologyCommand)
    case install(InstallTopologyCommand)
    case remove(RemoveTopologyCommand)
    case markUnavailable(MarkPortUnavailableTopologyCommand)

    public var operationID: ObjectID {
        switch self {
        case .connect(let command): command.operationID
        case .disconnect(let command): command.operationID
        case .move(let command): command.operationID
        case .install(let command): command.operationID
        case .remove(let command): command.operationID
        case .markUnavailable(let command): command.operationID
        }
    }
}

public struct TopologyCommandResult: Codable, Hashable, Sendable {
    public var operationID: ObjectID
    public var didApply: Bool
    public var revision: Int
    public init(operationID: ObjectID, didApply: Bool, revision: Int) {
        self.operationID = operationID
        self.didApply = didApply
        self.revision = revision
    }
}
