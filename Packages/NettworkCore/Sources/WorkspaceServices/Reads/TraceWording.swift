import Foundation
import NetworkModel

/// Human-readable wording for trace warnings and terminations. Ports are named
/// by their device and port label when the trace reached them; any other
/// object is referred to by its kind and a short identifier prefix, never by
/// a dumped Swift value.
struct TraceWording {
    private let portNames: [ObjectID: String]

    init(paths: [RichPhysicalPath]) {
        var names: [ObjectID: String] = [:]
        for node in paths.flatMap(\.nodes) {
            names[node.id] = [node.device?.name, node.portLabel].compactMap { $0 }.joined(separator: " · ")
        }
        portNames = names
    }

    func termination(_ termination: TraceTermination) -> String {
        switch termination {
        case .endpoint(let portID): "Ends at \(port(portID))"
        case .incompletePassiveMapping(let portID): "Stops at \(port(portID)): the passive mapping is incomplete"
        case .cycle(let portID): "Stops at \(port(portID)): the path loops back on itself"
        case .missingPort(let portID): "Stops: \(port(portID)) is not in the local mirror"
        case .tombstonedResource(let resource): "Stops: \(resourceName(resource)) was deleted"
        case .segmentLimit: "Stops: the path is longer than the trace limit"
        }
    }

    func warning(_ warning: TraceWarning) -> String {
        switch warning {
        case .ambiguousContinuation(let portID, let count):
            "\(port(portID)) continues to \(count) possible ports, so the path is ambiguous."
        case .incompletePassiveMapping(let portID): "The passive mapping at \(port(portID)) is incomplete."
        case .cycle(let portID, let resource): "\(port(portID)) loops back through \(resourceName(resource))."
        case .missingPort(let portID): "\(port(portID)) is not in the local mirror."
        default: objectWarning(warning)
        }
    }

    private func objectWarning(_ warning: TraceWarning) -> String {
        switch warning {
        case .unavailablePort(let portID): "\(port(portID)) is marked unavailable."
        case .unavailableCable(let cableID): "\(reference("cable", cableID)) is marked unavailable."
        case .tombstonedResource(let resource): "\(resourceName(resource).capitalizedFirst) was deleted."
        case .tombstonedLogicalInterface(let id): "\(reference("logical interface", id).capitalizedFirst) was deleted."
        case .tombstonedIPAddress(let address): "IP address \(address) was deleted."
        default: limitWarning(warning)
        }
    }

    private func limitWarning(_ warning: TraceWarning) -> String {
        switch warning {
        case .tombstonedVLAN(let id): "\(reference("VLAN", id).capitalizedFirst) was deleted."
        case .segmentLimitReached(let limit): "Some paths were cut off after \(limit) segments."
        case .pathLimitReached(let limit): "Only the first \(limit) paths are shown."
        default: "The trace reported a condition that has no description."
        }
    }

    private func port(_ id: ObjectID) -> String {
        guard let name = portNames[id], !name.isEmpty else { return reference("port", id) }
        return name
    }

    private func resourceName(_ resource: TraceResource) -> String {
        switch resource {
        case .port(let id): port(id)
        case .device(let id): reference("device", id)
        case .cable(let id): reference("cable", id)
        case .internalLink(let id): reference("internal link", id)
        case .rack(let id): reference("rack", id)
        default: otherResourceName(resource)
        }
    }

    private func otherResourceName(_ resource: TraceResource) -> String {
        switch resource {
        case .location(let id): reference("location", id)
        case .interface(let id): reference("logical interface", id)
        case .vlan(let id): reference("VLAN", id)
        case .ipAddress(let address): "IP address \(address)"
        default: "an object"
        }
    }

    private func reference(_ kind: String, _ id: ObjectID) -> String {
        "\(kind) \(id.description.prefix(8))"
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
