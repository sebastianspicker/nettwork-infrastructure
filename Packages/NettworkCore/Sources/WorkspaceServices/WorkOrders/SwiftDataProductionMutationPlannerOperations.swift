import NetworkModel
import WorkspaceChangeControl

extension SwiftDataProductionMutationPlanner {
    func apply(
        _ operation: PlannedWorkOperation, operationIndex: Int, workOrderID: ObjectID, snapshot: inout Snapshot, changes: inout ChangeAccumulator
    ) throws {
        switch operation {
        case .topology(let command):
            try applyTopology(command, snapshot: &snapshot, changes: &changes)
        case .deviceDecommission(let decommission):
            try applyDeviceDecommission(decommission, snapshot: &snapshot, changes: &changes)
        case let .template(kind, target, sourceTemplateID, migrations):
            try applyDeviceTemplate(
                kind: kind, target: target, sourceTemplateID: sourceTemplateID, migrations: migrations, snapshot: &snapshot, changes: &changes
            )
        case let .moduleTemplate(kind, target, sourceTemplateID):
            try applyModuleTemplate(kind: kind, target: target, sourceTemplateID: sourceTemplateID, snapshot: &snapshot, changes: &changes)
        case .ipam(let operation):
            try applyIPAM(operation, workOrderID: workOrderID, operationIndex: operationIndex, snapshot: &snapshot, changes: &changes)
        case .floorPlan(let operation):
            try applyFloorPlan(operation, snapshot: &snapshot, changes: &changes)
        case .hierarchy(let operation):
            try applyHierarchy(operation, snapshot: &snapshot, changes: &changes)
        case .device:
            throw ProductionMutationPlannerError.unsupportedGenericDeviceOperation
        }
    }

    private func applyTopology(_ command: TopologyCommand, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        if case .remove = command {
            throw ProductionMutationPlannerError.unsupportedGenericDeviceOperation
        }
        if case let .install(installation) = command,
            installation.device.templateSnapshot != nil || !installation.modules.isEmpty
        {
            guard let template = snapshot.deviceTypes[installation.device.typeID] else {
                throw ProductionMutationPlannerError.missingTopologyObject(.object(installation.device.typeID))
            }
            try TemplateInstantiator.validate(
                DeviceInstantiation(device: installation.device, modules: installation.modules, ports: installation.ports),
                against: template,
                moduleTemplates: Array(snapshot.moduleTemplates.values)
            )
        }
        let before = snapshot.topology
        _ = try snapshot.topology.apply(command)
        try changes.captureTopologyDifference(before: before, after: snapshot.topology)
    }

    private func applyDeviceTemplate(
        kind: PlannedTemplateChangeKind, target: DeviceType, sourceTemplateID: ObjectID?, migrations: [DeviceTemplateMigrationPlan],
        snapshot: inout Snapshot, changes: inout ChangeAccumulator
    ) throws {
        try TemplateCatalog.validate(
            deviceTemplate: target,
            moduleTemplates: Array(snapshot.moduleTemplates.values)
        )
        guard
            target.moduleSlots.allSatisfy({ slot in
                slot.allowedModuleTemplateIDs.allSatisfy { snapshot.moduleTemplates[$0] != nil }
            })
        else {
            throw ProductionMutationPlannerError.missingTopologyObject(.object(target.id))
        }
        try validateDeviceTemplateChange(kind: kind, target: target, sourceTemplateID: sourceTemplateID, migrations: migrations, snapshot: snapshot)
        snapshot.deviceTypes[target.id] = target
        replaceDeviceType(target, in: &snapshot.topology)
        try changes.save(target, recordType: WorkspaceRecordType.Legacy.deviceType)
        for migration in migrations {
            try applyMigration(migration, target: target, snapshot: &snapshot, changes: &changes)
        }
    }

    private func validateDeviceTemplateChange(
        kind: PlannedTemplateChangeKind, target: DeviceType, sourceTemplateID: ObjectID?, migrations: [DeviceTemplateMigrationPlan], snapshot: Snapshot
    ) throws {
        switch kind {
        case .create:
            guard snapshot.deviceTypes[target.id] == nil else {
                throw ProductionMutationPlannerError.duplicateMutation(.object(target.id))
            }
        case .clone:
            guard let sourceTemplateID,
                snapshot.deviceTypes[sourceTemplateID] != nil,
                sourceTemplateID != target.id
            else {
                throw ProductionMutationPlannerError.missingTopologyObject(.object(sourceTemplateID ?? target.id))
            }
        case .newVersion:
            guard let sourceTemplateID,
                let source = snapshot.deviceTypes[sourceTemplateID],
                sourceTemplateID == target.id,
                target.version > source.version
            else {
                throw ProductionMutationPlannerError.missingTopologyObject(.object(sourceTemplateID ?? target.id))
            }
        case .migration:
            guard !migrations.isEmpty else {
                throw ProductionMutationPlannerError.missingTopologyObject(.object(target.id))
            }
        }
    }

    private func replaceDeviceType(_ target: DeviceType, in topology: inout PhysicalTopology) {
        if let index = topology.deviceTypes.firstIndex(where: { $0.id == target.id }) {
            topology.deviceTypes[index] = target
        } else {
            topology.deviceTypes.append(target)
        }
    }

    private func applyMigration(
        _ migration: DeviceTemplateMigrationPlan, target: DeviceType, snapshot: inout Snapshot, changes: inout ChangeAccumulator
    ) throws {
        guard var device = snapshot.devices[migration.deviceID],
            migration.targetSnapshot == DeviceTemplateSnapshot(template: target)
        else {
            throw ProductionMutationPlannerError.missingTopologyObject(.object(migration.deviceID))
        }
        try applyTemplateMigration(migration, device: device, snapshot: &snapshot, changes: &changes)
        try TemplateMigration.apply(migration, to: &device)
        snapshot.devices[device.id] = device
        if let index = snapshot.topology.devices.firstIndex(where: { $0.id == device.id }) {
            snapshot.topology.devices[index] = device
        }
        try changes.save(device, recordType: WorkspaceRecordType.Legacy.device)
    }

    private func applyModuleTemplate(
        kind: PlannedTemplateChangeKind, target: ModuleTemplate, sourceTemplateID: ObjectID?, snapshot: inout Snapshot, changes: inout ChangeAccumulator
    ) throws {
        try TemplateCatalog.validate(moduleTemplate: target)
        try validateModuleTemplateChange(kind: kind, target: target, sourceTemplateID: sourceTemplateID, snapshot: snapshot)
        snapshot.moduleTemplates[target.id] = target
        try changes.save(target, recordType: WorkspaceRecordType.Legacy.moduleTemplate)
    }

    private func validateModuleTemplateChange(
        kind: PlannedTemplateChangeKind, target: ModuleTemplate, sourceTemplateID: ObjectID?, snapshot: Snapshot
    ) throws {
        switch kind {
        case .create:
            guard snapshot.moduleTemplates[target.id] == nil else {
                throw ProductionMutationPlannerError.duplicateMutation(.object(target.id))
            }
        case .clone:
            guard let sourceTemplateID,
                snapshot.moduleTemplates[sourceTemplateID] != nil,
                sourceTemplateID != target.id
            else {
                throw ProductionMutationPlannerError.missingTopologyObject(.object(sourceTemplateID ?? target.id))
            }
        case .newVersion:
            guard let sourceTemplateID,
                let source = snapshot.moduleTemplates[sourceTemplateID],
                sourceTemplateID == target.id,
                target.version > source.version
            else {
                throw ProductionMutationPlannerError.missingTopologyObject(.object(sourceTemplateID ?? target.id))
            }
        case .migration:
            throw ProductionMutationPlannerError.unsupportedGenericDeviceOperation
        }
    }

    func validate(_ snapshot: Snapshot) throws {
        try DefaultTopologyEngine.validate(snapshot.topology)
        try DefaultIPAMValidationService.validate(
            prefixes: Array(snapshot.prefixes.values),
            addresses: Array(snapshot.addresses.values),
            vlans: Array(snapshot.vlans.values),
            interfaces: Array(snapshot.interfaces.values),
            assignments: Array(snapshot.assignments.values),
            memberships: Array(snapshot.memberships.values)
        )
        try TemplatePlacementState(
            hierarchy: snapshot.hierarchy, topology: snapshot.topology, placements: snapshot.placements,
            rackReservations: snapshot.rackReservations, anchors: snapshot.anchors
        ).validate()
    }
}
