import Foundation
import NetworkModel

public enum PlannedWorkOperation: Codable, Hashable, Sendable {
    case topology(TopologyCommand)
    case deviceDecommission(PlannedDeviceDecommission)
    case ipam(PlannedIPAMOperation)
    case device(resourceKey: ResourceKey, description: String)
    case template(kind: PlannedTemplateChangeKind, target: DeviceType, sourceTemplateID: ObjectID?, migrations: [DeviceTemplateMigrationPlan])
    case moduleTemplate(kind: PlannedTemplateChangeKind, target: ModuleTemplate, sourceTemplateID: ObjectID?)
    case floorPlan(PlannedFloorPlanOperation)
    case hierarchy(PlannedHierarchyOperation)

    private enum CodingKeys: String, CodingKey {
        case kind, topology, deviceDecommission, ipam, resourceKey, description, templateKind, target, moduleTarget, sourceTemplateID, migrations, floorPlan,
            hierarchy
    }
    private enum Kind: String, Codable { case topology, deviceDecommission, ipam, device, template, moduleTemplate, floorPlan, hierarchy }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .topology: self = .topology(try container.decode(TopologyCommand.self, forKey: .topology))
        case .deviceDecommission: self = .deviceDecommission(try container.decode(PlannedDeviceDecommission.self, forKey: .deviceDecommission))
        case .ipam: self = .ipam(try container.decode(PlannedIPAMOperation.self, forKey: .ipam))
        case .device:
            self = .device(
                resourceKey: try container.decode(ResourceKey.self, forKey: .resourceKey), description: try container.decode(String.self, forKey: .description))
        case .template:
            self = .template(
                kind: try container.decode(PlannedTemplateChangeKind.self, forKey: .templateKind),
                target: try container.decode(DeviceType.self, forKey: .target),
                sourceTemplateID: try container.decodeIfPresent(ObjectID.self, forKey: .sourceTemplateID),
                migrations: try container.decode([DeviceTemplateMigrationPlan].self, forKey: .migrations))
        case .moduleTemplate:
            self = .moduleTemplate(
                kind: try container.decode(PlannedTemplateChangeKind.self, forKey: .templateKind),
                target: try container.decode(ModuleTemplate.self, forKey: .moduleTarget),
                sourceTemplateID: try container.decodeIfPresent(ObjectID.self, forKey: .sourceTemplateID))
        case .floorPlan: self = .floorPlan(try container.decode(PlannedFloorPlanOperation.self, forKey: .floorPlan))
        case .hierarchy: self = .hierarchy(try container.decode(PlannedHierarchyOperation.self, forKey: .hierarchy))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .topology(let command):
            try container.encode(Kind.topology, forKey: .kind)
            try container.encode(command, forKey: .topology)
        case .deviceDecommission(let decommission):
            try container.encode(Kind.deviceDecommission, forKey: .kind)
            try container.encode(decommission, forKey: .deviceDecommission)
        case .ipam(let operation):
            try container.encode(Kind.ipam, forKey: .kind)
            try container.encode(operation, forKey: .ipam)
        case let .device(resourceKey, description):
            try container.encode(Kind.device, forKey: .kind)
            try container.encode(resourceKey, forKey: .resourceKey)
            try container.encode(description, forKey: .description)
        case let .template(kind, target, sourceTemplateID, migrations):
            try container.encode(Kind.template, forKey: .kind)
            try container.encode(kind, forKey: .templateKind)
            try container.encode(target, forKey: .target)
            try container.encodeIfPresent(sourceTemplateID, forKey: .sourceTemplateID)
            try container.encode(migrations, forKey: .migrations)
        case let .moduleTemplate(kind, target, sourceTemplateID):
            try container.encode(Kind.moduleTemplate, forKey: .kind)
            try container.encode(kind, forKey: .templateKind)
            try container.encode(target, forKey: .moduleTarget)
            try container.encodeIfPresent(sourceTemplateID, forKey: .sourceTemplateID)
        case .floorPlan(let operation):
            try container.encode(Kind.floorPlan, forKey: .kind)
            try container.encode(operation, forKey: .floorPlan)
        case .hierarchy(let operation):
            try container.encode(Kind.hierarchy, forKey: .kind)
            try container.encode(operation, forKey: .hierarchy)
        }
    }
}
