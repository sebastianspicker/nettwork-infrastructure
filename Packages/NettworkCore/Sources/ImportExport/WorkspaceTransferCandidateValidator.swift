import Foundation
import NetworkModel
import WorkspaceChangeControl

enum WorkspaceTransferCandidateValidator {
    static func validate(
        hierarchy: WorkspaceHierarchy, topology: PhysicalTopology,
        placement: TemplatePlacementState, moduleTemplates: [ModuleTemplate], vrfs: [VRF], prefixes: [Prefix],
        addresses: [IPAddressRecord], vlanGroups: [VLANGroup], vlans: [VLAN], interfaces: [Interface],
        assignments: [IPAddressAssignment], memberships: [InterfaceVLANMembership],
        standalonePortTemplates: [PortTemplate], workOrders: [WorkOrder],
        reservationLocks: [ResourceReservationLock], releasedReservationLocks: [ResourceReservationLock],
        receipts: [OperationReceipt], quotaLedgers: [AttachmentEvidenceQuotaLedger],
        reservationReleases: [AttachmentEvidenceReservationRelease],
        bindings: [AttachmentEvidenceBindingRecord], floorPlanBindings: [FloorPlanAssetBindingRecord]
    ) throws {
        try validateFoundation(hierarchy: hierarchy, topology: topology, placement: placement)
        try validateTemplates(topology: topology, moduleTemplates: moduleTemplates, standalone: standalonePortTemplates)
        try validateIPAM(
            topology: topology, vrfs: vrfs, prefixes: prefixes, addresses: addresses, vlanGroups: vlanGroups, vlans: vlans, interfaces: interfaces,
            assignments: assignments, memberships: memberships)
        try validateOperational(
            hierarchy: hierarchy, workOrders: workOrders, reservationLocks: reservationLocks, releasedReservationLocks: releasedReservationLocks,
            receipts: receipts, quotaLedgers: quotaLedgers,
            reservationReleases: reservationReleases, bindings: bindings, floorPlanBindings: floorPlanBindings)
    }

    private static func validateFoundation(
        hierarchy: WorkspaceHierarchy, topology: PhysicalTopology,
        placement: TemplatePlacementState
    ) throws {
        do { try hierarchy.validate() } catch { throw WorkspaceTransferValidationError.hierarchyValidationFailed }
        do { try DefaultTopologyEngine.validate(topology) } catch { throw WorkspaceTransferValidationError.topologyValidationFailed }
        do { try placement.validate() } catch { throw WorkspaceTransferValidationError.placementValidationFailed }
    }

    private static func validateTemplates(
        topology: PhysicalTopology, moduleTemplates: [ModuleTemplate],
        standalone: [PortTemplate]
    ) throws {
        do {
            let moduleTemplatesByID = try indexedModuleTemplates(moduleTemplates)
            try validateDeviceTemplates(topology.deviceTypes, moduleTemplates: moduleTemplates, indexed: moduleTemplatesByID)
            try validateModules(topology, moduleTemplates: moduleTemplatesByID)
            try validateTemplatePorts(topology)
            try TemplateCatalog.validate(portTemplates: standalone)
        } catch {
            throw WorkspaceTransferValidationError.templateValidationFailed
        }
    }

    private static func indexedModuleTemplates(_ templates: [ModuleTemplate]) throws -> [ObjectID: ModuleTemplate] {
        var result: [ObjectID: ModuleTemplate] = [:]
        for template in templates {
            guard result.updateValue(template, forKey: template.id) == nil else {
                throw WorkspaceTransferValidationError.templateValidationFailed
            }
        }
        return result
    }

    private static func validateDeviceTemplates(
        _ deviceTemplates: [DeviceType],
        moduleTemplates: [ModuleTemplate], indexed: [ObjectID: ModuleTemplate]
    ) throws {
        for template in deviceTemplates {
            try TemplateCatalog.validate(deviceTemplate: template, moduleTemplates: moduleTemplates)
            for slot in template.moduleSlots {
                guard slot.allowedModuleTemplateIDs.allSatisfy({ indexed[$0] != nil }) else {
                    throw WorkspaceTransferValidationError.templateValidationFailed
                }
            }
        }
    }

    private static func validateModules(
        _ topology: PhysicalTopology,
        moduleTemplates: [ObjectID: ModuleTemplate]
    ) throws {
        let devices = Dictionary(uniqueKeysWithValues: topology.devices.map { ($0.id, $0) })
        let deviceTypes = Dictionary(uniqueKeysWithValues: topology.deviceTypes.map { ($0.id, $0) })
        for module in topology.modules {
            guard moduleTemplates[module.templateID] != nil, let device = devices[module.deviceID],
                let type = deviceTypes[device.typeID],
                let slot = type.moduleSlots.first(where: { $0.key == module.slot }),
                slot.allowedModuleTemplateIDs.contains(module.templateID)
            else {
                throw WorkspaceTransferValidationError.templateValidationFailed
            }
        }
    }

    private static func validateTemplatePorts(_ topology: PhysicalTopology) throws {
        let devices = Dictionary(uniqueKeysWithValues: topology.devices.map { ($0.id, $0) })
        let modules = Dictionary(uniqueKeysWithValues: topology.modules.map { ($0.id, $0) })
        for port in topology.ports {
            guard let templatePortID = port.templatePortID else { continue }
            let definition = templatePortDefinition(
                id: templatePortID, port: port, devices: devices,
                modules: modules)
            guard let definition, port.label == definition.name, port.medium == definition.medium,
                port.connector == definition.connector, port.face == definition.face,
                port.fiberMode == definition.fiberMode,
                try CustomFieldValidator.resolvedValues(values: port.customFields, against: definition.customFieldSchemas) == port.customFields
            else {
                throw WorkspaceTransferValidationError.templateValidationFailed
            }
        }
    }

    private static func templatePortDefinition(
        id: ObjectID, port: NetworkModel.Port,
        devices: [ObjectID: Device], modules: [ObjectID: Module]
    ) -> PortTemplate? {
        if let moduleID = port.moduleID {
            return modules[moduleID]?.templateSnapshot?.ports.first { $0.id == id }
        }
        return devices[port.deviceID]?.templateSnapshot?.portTemplates.first { $0.id == id }
    }

    private static func validateIPAM(
        topology: PhysicalTopology, vrfs: [VRF], prefixes: [Prefix],
        addresses: [IPAddressRecord], vlanGroups: [VLANGroup], vlans: [VLAN], interfaces: [Interface],
        assignments: [IPAddressAssignment], memberships: [InterfaceVLANMembership]
    ) throws {
        try validateIPAMReferences(vrfs: vrfs, prefixes: prefixes, addresses: addresses, vlanGroups: vlanGroups, vlans: vlans)
        try validateInterfaceReferences(topology: topology, interfaces: interfaces)
        do {
            try DefaultIPAMValidationService.validate(
                prefixes: prefixes, addresses: addresses, vlans: vlans, interfaces: interfaces, assignments: assignments, memberships: memberships)
        } catch {
            throw WorkspaceTransferValidationError.ipamValidationFailed
        }
    }

    private static func validateIPAMReferences(
        vrfs: [VRF], prefixes: [Prefix], addresses: [IPAddressRecord],
        vlanGroups: [VLANGroup], vlans: [VLAN]
    ) throws {
        let activeVRFs = Set(vrfs.filter(\.isActive).map(\.id))
        for prefix in prefixes where prefix.isActive && !activeVRFs.contains(prefix.vrfID) {
            throw WorkspaceTransferValidationError.missingReference(kind: "vrf", id: prefix.vrfID.description)
        }
        for address in addresses where address.isActive && !activeVRFs.contains(address.vrfID) {
            throw WorkspaceTransferValidationError.missingReference(kind: "vrf", id: address.vrfID.description)
        }
        let activeGroupIDs = vlanGroups.filter(\.isActive).map(\.id)
        let activeGroups = Set(activeGroupIDs)
        guard activeGroups.count == activeGroupIDs.count else {
            throw WorkspaceTransferValidationError.ipamValidationFailed
        }
        for vlan in vlans where vlan.isActive && !activeGroups.contains(vlan.groupID) {
            throw WorkspaceTransferValidationError.missingReference(kind: "vlan group", id: vlan.groupID.description)
        }
    }

    private static func validateInterfaceReferences(
        topology: PhysicalTopology, interfaces: [Interface]
    ) throws {
        let devices = Set(topology.devices.map(\.id))
        let ports = Dictionary(uniqueKeysWithValues: topology.ports.map { ($0.id, $0) })
        for interface in interfaces where interface.isActive {
            guard devices.contains(interface.deviceID) else {
                throw WorkspaceTransferValidationError.missingReference(kind: "device", id: interface.deviceID.description)
            }
            if let portID = interface.physicalPortID {
                guard let port = ports[portID], port.deviceID == interface.deviceID else {
                    throw WorkspaceTransferValidationError.missingReference(kind: "physical port", id: portID.description)
                }
            }
        }
    }

    private static func validateOperational(
        hierarchy: WorkspaceHierarchy, workOrders: [WorkOrder],
        reservationLocks: [ResourceReservationLock], releasedReservationLocks: [ResourceReservationLock],
        receipts: [OperationReceipt], quotaLedgers: [AttachmentEvidenceQuotaLedger],
        reservationReleases: [AttachmentEvidenceReservationRelease],
        bindings: [AttachmentEvidenceBindingRecord], floorPlanBindings: [FloorPlanAssetBindingRecord]
    ) throws {
        do {
            let index = try OperationalIndex(
                workOrders: workOrders, reservationLocks: reservationLocks, releasedReservationLocks: releasedReservationLocks, receipts: receipts,
                quotaLedgers: quotaLedgers,
                reservationReleases: reservationReleases, bindings: bindings, floorPlanBindings: floorPlanBindings)
            try validateLockSets(index: index, workOrders: workOrders, live: reservationLocks, released: releasedReservationLocks)
            try validateQuotaLedgers(quotaLedgers, index: index)
            try validateFloorPlanBindings(floorPlanBindings, hierarchy: hierarchy, index: index)
            try validateReservationReleases(reservationReleases, index: index)
            try validateBindings(index: index)
        } catch let error as WorkspaceTransferValidationError {
            throw error
        } catch {
            throw WorkspaceTransferValidationError.operationalValidationFailed
        }
    }

    private static func validateLockSets(
        index: OperationalIndex, workOrders: [WorkOrder],
        live: [ResourceReservationLock], released: [ResourceReservationLock]
    ) throws {
        guard Set(index.liveLocks.keys).isDisjoint(with: Set(index.releasedLocks.keys)) else {
            throw WorkspaceTransferValidationError.operationalValidationFailed
        }
        try validateReservationLocks(live, workOrders: index.workOrders, terminal: false)
        try validateReservationLocks(released, workOrders: index.workOrders, terminal: true)
        let liveKeys = Dictionary(grouping: live, by: \.workOrderID).mapValues { Set($0.map(\.id)) }
        let releasedKeys = Dictionary(grouping: released, by: \.workOrderID).mapValues { Set($0.map(\.id)) }
        for workOrder in workOrders {
            try validateLockState(workOrder, live: liveKeys[workOrder.id] ?? [], released: releasedKeys[workOrder.id] ?? [])
        }
    }

    private static func validateLockState(
        _ workOrder: WorkOrder, live: Set<ResourceKey>,
        released: Set<ResourceKey>
    ) throws {
        let expected = Set(workOrder.reservation?.resourceKeys.map(ResourceKey.reservationLock(for:)) ?? [])
        switch workOrder.status {
        case .draft:
            guard expected.isEmpty, live.isEmpty, released.isEmpty else { throw WorkspaceTransferValidationError.operationalValidationFailed }
        case .reserved, .approved, .executing, .cancellationRequested:
            guard !expected.isEmpty, live == expected, released.isEmpty else { throw WorkspaceTransferValidationError.operationalValidationFailed }
        case .completed, .cancelled, .reconciliation:
            try validateTerminalLockState(workOrder, expected: expected, live: live, released: released)
        }
    }

    private static func validateTerminalLockState(
        _ workOrder: WorkOrder, expected: Set<ResourceKey>,
        live: Set<ResourceKey>, released: Set<ResourceKey>
    ) throws {
        guard live.isEmpty else { throw WorkspaceTransferValidationError.operationalValidationFailed }
        if workOrder.reservation == nil {
            guard expected.isEmpty, released.isEmpty else { throw WorkspaceTransferValidationError.operationalValidationFailed }
        } else {
            guard !expected.isEmpty, released == expected else { throw WorkspaceTransferValidationError.operationalValidationFailed }
        }
    }

    private static func validateQuotaLedgers(_ ledgers: [AttachmentEvidenceQuotaLedger], index: OperationalIndex) throws {
        for ledger in ledgers {
            guard index.workOrders[ledger.workOrderID] != nil else {
                throw WorkspaceTransferValidationError.missingReference(kind: "work order", id: ledger.workOrderID.description)
            }
            guard let bindings = index.bindingsByWorkOrder[ledger.workOrderID], !bindings.isEmpty else {
                throw WorkspaceTransferValidationError.operationalValidationFailed
            }
            let totalBytes = try bindings.reduce(into: 0) { total, binding in
                guard total <= Int.max - binding.provenance.byteCount else { throw WorkspaceTransferValidationError.operationalValidationFailed }
                total += binding.provenance.byteCount
            }
            guard ledger.attachmentCount == bindings.count, ledger.totalBytes == totalBytes else {
                throw WorkspaceTransferValidationError.operationalValidationFailed
            }
        }
    }

    private static func validateFloorPlanBindings(
        _ bindings: [FloorPlanAssetBindingRecord],
        hierarchy: WorkspaceHierarchy, index: OperationalIndex
    ) throws {
        for binding in bindings {
            guard let floor = hierarchy.locations.first(where: { $0.id == binding.floorID }),
                floor.kind == .floor, floor.deletedAt == nil,
                let workOrder = index.workOrders[binding.workOrderID], workOrder.kind == .floorPlan,
                workOrder.status == .completed, workOrder.intentDigest == binding.intentDigest,
                hasFloorPlanOperation(workOrder, binding: binding),
                let receipt = index.receipts[binding.operationID],
                receipt.intentDigest == binding.intentDigest,
                receipt.auditEventID == binding.auditEventID
            else {
                throw WorkspaceTransferValidationError.operationalValidationFailed
            }
        }
    }

    private static func hasFloorPlanOperation(_ workOrder: WorkOrder, binding: FloorPlanAssetBindingRecord) -> Bool {
        workOrder.plannedOperations.contains {
            guard case let .floorPlan(.bindAsset(planned)) = $0 else { return false }
            return planned.floorID == binding.floorID && planned.assetMetadata == binding.assetMetadata
        }
    }

    private static func validateReservationReleases(
        _ releases: [AttachmentEvidenceReservationRelease],
        index: OperationalIndex
    ) throws {
        for release in releases {
            guard index.workOrders[release.workOrderID] != nil,
                let binding = index.bindingsByReservation[release.id],
                binding.workOrderID == release.workOrderID, binding.attachmentID == release.attachmentID,
                binding.operationID == release.operationID
            else {
                throw WorkspaceTransferValidationError.missingReference(kind: "attachment evidence binding", id: release.id.description)
            }
        }
    }

    private static func validateBindings(index: OperationalIndex) throws {
        for binding in index.bindingsByAttachment.values {
            guard let workOrder = index.workOrders[binding.workOrderID], workOrder.evidenceHashes.contains(binding.evidence) else {
                throw WorkspaceTransferValidationError.missingReference(kind: "work-order evidence", id: binding.attachmentID.description)
            }
            guard index.quotaLedgers[binding.workOrderID] != nil else {
                throw WorkspaceTransferValidationError.missingReference(kind: "attachment quota ledger", id: binding.workOrderID.description)
            }
            try validateBindingRelease(binding, index: index)
            try validateBindingReceipt(binding, index: index)
        }
    }

    private static func validateBindingRelease(_ binding: AttachmentEvidenceBindingRecord, index: OperationalIndex) throws {
        guard let release = index.releases[binding.reservationID], release.workOrderID == binding.workOrderID,
            release.attachmentID == binding.attachmentID, release.operationID == binding.operationID,
            release.reservedBytes == binding.provenance.byteCount
        else {
            throw WorkspaceTransferValidationError.missingReference(kind: "attachment reservation release", id: binding.reservationID.description)
        }
    }

    private static func validateBindingReceipt(_ binding: AttachmentEvidenceBindingRecord, index: OperationalIndex) throws {
        guard let receipt = index.receipts[binding.operationID], receipt.intentDigest == binding.intentDigest,
            receipt.auditEventID == binding.auditEventID
        else {
            throw WorkspaceTransferValidationError.missingReference(kind: "operation receipt", id: binding.operationID.description)
        }
    }
}
