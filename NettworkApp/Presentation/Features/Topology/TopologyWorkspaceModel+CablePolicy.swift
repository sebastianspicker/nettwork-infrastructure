import NetworkModel

extension TopologyWorkspaceModel {
    static func isCompatible(kind: CableKind, medium: PortMedium, connectorA: Connector, connectorB: Connector) -> Bool {
        compatibleKind(kind, medium: medium)
            && compatibleConnectors(medium: medium, connectorA: connectorA, connectorB: connectorB)
    }

    private static func compatibleKind(_ kind: CableKind, medium: PortMedium) -> Bool {
        switch medium {
        case .fiber:
            kind == .fiberLink
        case .copper, .power, .other:
            [.fixed, .patchCord].contains(kind)
        }
    }

    private static func compatibleConnectors(medium: PortMedium, connectorA: Connector, connectorB: Connector) -> Bool {
        switch medium {
        case .copper:
            connectorA == .rj45 && connectorB == .rj45
        case .fiber:
            connectorA == connectorB && [.lc, .sc, .mpo].contains(connectorA)
        case .power:
            Set([connectorA, connectorB]) == Set([.c13, .c14])
        case .other:
            connectorA == .other && connectorB == .other
        }
    }
}
