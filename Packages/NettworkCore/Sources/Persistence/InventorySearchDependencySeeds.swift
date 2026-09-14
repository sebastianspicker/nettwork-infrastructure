import Foundation
import NetworkModel
import WorkspaceChangeControl

extension InventorySearchIndexBuilder {
    static func addDirectDependencySeed(
        _ record: LocalMirrorRecord, dirty: inout Set<ResourceKey>,
        context: inout Set<ResourceKey>
    ) throws {
        switch record.recordType {
        case "NettworkCable", "Cable": try addCableSeed(record, dirty: &dirty)
        case "NettworkPort", "Port": try addPortSeed(record, context: &context)
        case "NettworkDevice", "Device": try addDeviceSeed(record, context: &context)
        case "NettworkModule", "Module": try addModuleSeed(record, context: &context)
        case "NettworkInternalLink", "InternalLink": try addLinkSeed(record, context: &context)
        default: try addRemainingDirectDependencySeed(record, dirty: &dirty, context: &context)
        }
    }

    static func addRemainingDirectDependencySeed(
        _ record: LocalMirrorRecord, dirty: inout Set<ResourceKey>,
        context: inout Set<ResourceKey>
    ) throws {
        switch record.recordType {
        case "NettworkRack", "Rack": try addRackSeed(record, context: &context)
        case "NettworkLocation", "Location": try addLocationSeed(record, context: &context)
        case "NettworkRackPlacement", "RackPlacement": try addPlacementSeed(record, dirty: &dirty, context: &context)
        case "NettworkInterface": try addInterfaceSeed(record, context: &context)
        case "NettworkIPAddressRecord": try addAddressSeed(record, context: &context)
        case "NettworkWorkOrder", LocalRecordKind.workOrder: try addWorkOrderSeed(record, dirty: &dirty)
        default: break
        }
    }

    static func addCableSeed(_ record: LocalMirrorRecord, dirty: inout Set<ResourceKey>) throws {
        let value = try Projection.decode(Cable.self, record: record)
        dirty.formUnion([.object(value.endpointA), .object(value.endpointB)])
    }

    static func addPortSeed(_ record: LocalMirrorRecord, context: inout Set<ResourceKey>) throws {
        let value = try Projection.decode(NetworkModel.Port.self, record: record)
        context.insert(.object(value.deviceID))
        if let moduleID = value.moduleID {
            context.insert(.object(moduleID))
        }
    }

    static func addDeviceSeed(_ record: LocalMirrorRecord, context: inout Set<ResourceKey>) throws {
        let value = try Projection.decode(Device.self, record: record)
        context.insert(.object(value.typeID))
        if let rackID = value.rackID {
            context.insert(.object(rackID))
        }
    }

    static func addModuleSeed(_ record: LocalMirrorRecord, context: inout Set<ResourceKey>) throws {
        context.insert(.object(try Projection.decode(Module.self, record: record).deviceID))
    }

    static func addLinkSeed(_ record: LocalMirrorRecord, context: inout Set<ResourceKey>) throws {
        let value = try Projection.decode(InternalLink.self, record: record)
        context.formUnion([.object(value.endpointA), .object(value.endpointB)])
    }

    static func addRackSeed(_ record: LocalMirrorRecord, context: inout Set<ResourceKey>) throws {
        context.insert(.object(try Projection.decode(Rack.self, record: record).locationID))
    }

    static func addLocationSeed(_ record: LocalMirrorRecord, context: inout Set<ResourceKey>) throws {
        guard let parentID = try Projection.decode(Location.self, record: record).parentID else { return }
        context.insert(.object(parentID))
    }

    static func addPlacementSeed(_ record: LocalMirrorRecord, dirty: inout Set<ResourceKey>, context: inout Set<ResourceKey>) throws {
        let value = try Projection.decode(RackPlacement.self, record: record)
        dirty.insert(.object(value.deviceID))
        context.insert(.object(value.rackID))
    }

    static func addInterfaceSeed(_ record: LocalMirrorRecord, context: inout Set<ResourceKey>) throws {
        let value = try Projection.decode(Interface.self, record: record)
        context.insert(.object(value.deviceID))
        if let physicalPortID = value.physicalPortID {
            context.insert(.object(physicalPortID))
        }
    }

    static func addAddressSeed(_ record: LocalMirrorRecord, context: inout Set<ResourceKey>) throws {
        guard let interfaceID = try Projection.decode(IPAddressRecord.self, record: record).assignedInterfaceID else { return }
        context.insert(.object(interfaceID))
    }

    static func addWorkOrderSeed(_ record: LocalMirrorRecord, dirty: inout Set<ResourceKey>) throws {
        dirty.formUnion(canonicalAffectedResourceKeys(for: try Projection.decode(WorkOrder.self, record: record)))
    }
}
