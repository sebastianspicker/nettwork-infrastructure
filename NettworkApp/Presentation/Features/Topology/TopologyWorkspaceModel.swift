import FeatureContracts
import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

@MainActor
@Observable
final class TopologyWorkspaceModel {
    private let browser: any TopologyBrowsing
    private let drafts: any TopologyWorkOrderDrafting
    private let account: AccountContext
    private var loadGeneration: UInt64 = 0
    private(set) var state: InventoryPresentationState = .loading
    private(set) var hierarchy: [TopologyHierarchyNode] = []
    private(set) var hierarchyIndex = TopologyHierarchyIndex()
    private(set) var racks: [RackElevationSnapshot] = []
    var selectedFace = "front"
    var portFilter = ""
    var availabilityFilter: TopologyPortAvailabilityFilter = .all
    var mediumFilter: PortMedium?
    var connectorFilter: Connector?
    var stateFilter: TopologyPortStateFilter = .all
    private(set) var selectedPortIDs: Set<ObjectID> = []
    private(set) var selectedCableID: ObjectID?
    private(set) var focusedObject: InventorySearchResult?
    var proposedAction: TopologyDraftAction?
    private(set) var draftValidationMessage: String?
    private(set) var stagedWorkOrderID: ObjectID?

    init(account: AccountContext, browser: any TopologyBrowsing, drafts: any TopologyWorkOrderDrafting) {
        self.account = account
        self.browser = browser
        self.drafts = drafts
    }

    @discardableResult
    func load() async -> Bool {
        guard !Task.isCancelled else { return false }
        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        do {
            async let hierarchy = browser.hierarchy(in: account.namespace)
            async let racks = browser.racks(in: account.namespace)
            let (loadedHierarchy, loadedRacks) = try await (hierarchy, racks)
            guard generation == loadGeneration, !Task.isCancelled else { return false }
            let loadedHierarchyIndex = TopologyHierarchyIndex(nodes: loadedHierarchy)
            self.hierarchy = loadedHierarchy
            self.hierarchyIndex = loadedHierarchyIndex
            self.racks = loadedRacks
            state = loadedRacks.isEmpty ? .empty : .ready
            return true
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return false }
            state = .offline("Rack and port data is unavailable in the local mirror.")
            return true
        }
    }

    func ports(in rack: RackElevationSnapshot) -> [TopologyPortSnapshot] {
        rack.ports.filter(matches).sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    func toggleSelection(for port: TopologyPortSnapshot) {
        if selectedPortIDs.contains(port.id) { selectedPortIDs.remove(port.id) } else { selectedPortIDs.insert(port.id) }
        proposedAction = nil
        draftValidationMessage = nil
    }

    func selectCable(_ cableID: ObjectID?) {
        selectedCableID = cableID
        proposedAction = nil
        draftValidationMessage = nil
    }

    func focus(on object: InventorySearchResult?) {
        focusedObject = object
        selectedPortIDs = []
        selectedCableID = nil
        guard let object else { return }
        if object.kind == .port, ports.contains(where: { $0.id == object.id }) {
            selectedPortIDs = [object.id]
        } else if object.kind == .cable, cables.contains(where: { $0.id == object.id }) {
            selectedCableID = object.id
        }
    }

    func prepareConnect(assetCode: String, kind: CableKind, color: String, lengthMeters: Double?) {
        guard selectedPorts.count == 2 else {
            invalidateDraft("Select exactly two ports to construct a connection.")
            return
        }
        let endpoints = selectedPorts.sorted { $0.id < $1.id }
        guard endpoints[0].medium == endpoints[1].medium else {
            invalidateDraft("The selected ports use different media, so a typed cable command cannot be created.")
            return
        }
        guard Self.isCompatible(kind: kind, medium: endpoints[0].medium, connectorA: endpoints[0].connector, connectorB: endpoints[1].connector) else {
            invalidateDraft("The selected cable kind or connectors are not valid for the selected port media.")
            return
        }
        guard !AssetCode(assetCode).isEmpty else {
            invalidateDraft("Enter a cable asset code before preparing the draft.")
            return
        }
        guard lengthMeters.map({ $0 > 0 && $0.isFinite }) ?? true else {
            invalidateDraft("Cable length must be a positive number when supplied.")
            return
        }
        let cable = Cable(
            assetCode: AssetCode(assetCode),
            endpointA: endpoints[0].id,
            connectorA: endpoints[0].connector,
            endpointB: endpoints[1].id,
            connectorB: endpoints[1].connector,
            medium: endpoints[0].medium,
            kind: kind,
            status: .planned,
            color: color.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : color,
            lengthMeters: lengthMeters
        )
        proposedAction = .connect(ConnectTopologyCommand(cable: cable))
        draftValidationMessage = nil
    }

    func prepareDisconnect() {
        guard let cableID = selectedCableID, cables.contains(where: { $0.id == cableID }) else {
            invalidateDraft("Select a mirrored cable to construct a disconnect command.")
            return
        }
        proposedAction = .disconnect(DisconnectTopologyCommand(cableID: cableID, deletedAt: .now))
        draftValidationMessage = nil
    }

    func prepareMove() {
        guard let cableID = selectedCableID, cables.contains(where: { $0.id == cableID }) else {
            invalidateDraft("Select a mirrored cable to construct a move command.")
            return
        }
        guard selectedPorts.count == 2 else {
            invalidateDraft("Select exactly two destination ports to construct a move command.")
            return
        }
        let endpoints = selectedPorts.sorted { $0.id < $1.id }
        guard endpoints[0].medium == endpoints[1].medium else {
            invalidateDraft("The selected destination ports use different media.")
            return
        }
        proposedAction = .move(
            MoveTopologyCommand(
                cableID: cableID,
                endpointA: endpoints[0].id,
                connectorA: endpoints[0].connector,
                endpointB: endpoints[1].id,
                connectorB: endpoints[1].connector
            ))
        draftValidationMessage = nil
    }

    func prepareRemoveDevice(deviceID: ObjectID?) async {
        guard let deviceID, hierarchyDevices.contains(where: { $0.id == deviceID }) else {
            invalidateDraft("Select a mirrored device to construct a removal command.")
            return
        }
        guard deviceIsDisconnected(deviceID) else {
            invalidateDraft("Disconnect every mirrored cable from this device before preparing its removal.")
            return
        }
        guard let snapshot = await matchingDecommissionSnapshot(for: deviceID) else { return }
        proposedAction = .deviceDecommission(decommissionPlan(for: snapshot, deviceID: deviceID))
        draftValidationMessage = nil
    }

    func prepareMarkPortUnavailable(portID: ObjectID?, isUnavailable: Bool) {
        guard let portID, ports.contains(where: { $0.id == portID }) else {
            invalidateDraft("Select a mirrored port to construct an availability command.")
            return
        }
        proposedAction = .markUnavailable(MarkPortUnavailableTopologyCommand(portID: portID, isUnavailable: isUnavailable))
        draftValidationMessage = nil
    }

    func prepareHierarchyLocation(
        existingID: ObjectID?,
        name: String,
        kind: LocationKind,
        parentID: ObjectID?,
        remove: Bool
    ) {
        guard remove || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            invalidateDraft("A location name is required.")
            return
        }
        if remove {
            guard let location = hierarchy.first(where: { $0.id == existingID })?.location else {
                invalidateDraft("Select a mirrored location to remove.")
                return
            }
            proposedAction = .hierarchy(.removeLocation(location))
        } else {
            let id = existingID ?? ObjectID()
            let location = Location(id: id, name: name, kind: kind, parentID: parentID)
            proposedAction = .hierarchy(.upsertLocation(location))
        }
        draftValidationMessage = nil
    }

    func prepareHierarchyRack(
        existingID: ObjectID?,
        assetCode: String,
        locationID: ObjectID?,
        heightRU: Int,
        remove: Bool
    ) {
        if remove {
            guard let rack = hierarchy.first(where: { $0.id == existingID })?.rack else {
                invalidateDraft("Select a mirrored rack to remove.")
                return
            }
            proposedAction = .hierarchy(.removeRack(rack))
            draftValidationMessage = nil
            return
        }
        guard let locationID else {
            invalidateDraft("Select a room for the rack.")
            return
        }
        guard !AssetCode(assetCode).isEmpty, heightRU > 0 else {
            invalidateDraft("A rack asset code and positive RU height are required.")
            return
        }
        proposedAction = .hierarchy(
            .upsertRack(
                Rack(
                    id: existingID ?? ObjectID(),
                    assetCode: AssetCode(assetCode),
                    locationID: locationID,
                    heightRU: heightRU
                )))
        draftValidationMessage = nil
    }

    func stage(title: String, ticket: String, notes: String) async {
        guard let action = proposedAction else { return }
        guard let keys = resourceKeys(for: action) else { return }
        do {
            stagedWorkOrderID = try await drafts.stage(
                TopologyWorkOrderRequest(
                    title: title,
                    ticket: ticket,
                    notes: notes,
                    action: action,
                    resourceKeys: keys
                ),
                in: account.namespace
            )
            state = .pending("A topology operation was staged in a work-order draft. No authoritative topology was changed.")
        } catch { state = .conflict("The draft could not reserve its proposed resource set.") }
    }

    private func matches(_ port: TopologyPortSnapshot) -> Bool {
        let needle = portFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty || [port.label, port.deviceName, port.moduleSlot ?? ""].contains(where: { $0.localizedCaseInsensitiveContains(needle) }) else {
            return false
        }
        return matchesAvailability(port) && matchesMedium(port) && matchesConnector(port) && matchesState(port)
    }

    private func matchesAvailability(_ port: TopologyPortSnapshot) -> Bool {
        availabilityFilter == .all || port.availability.rawValue == availabilityFilter.rawValue
    }

    private func matchesMedium(_ port: TopologyPortSnapshot) -> Bool {
        mediumFilter == nil || port.medium == mediumFilter
    }

    private func matchesConnector(_ port: TopologyPortSnapshot) -> Bool {
        connectorFilter == nil || port.connector == connectorFilter
    }

    private func matchesState(_ port: TopologyPortSnapshot) -> Bool {
        stateFilter == .all || port.state.rawValue == stateFilter.rawValue
    }

    private func invalidateDraft(_ message: String) {
        proposedAction = nil
        draftValidationMessage = message
    }

    private func portResourceKeys(_ port: TopologyPortSnapshot) -> Set<ResourceKey> {
        var keys: Set<ResourceKey> = [.object(port.id), .object(port.deviceID)]
        if let moduleID = port.moduleID { keys.insert(.object(moduleID)) }
        return keys
    }

    private func resourceKeys(for action: TopologyDraftAction) -> Set<ResourceKey>? {
        switch action {
        case let .connect(command): return [.object(command.cable.id), .object(command.cable.endpointA), .object(command.cable.endpointB)]
        case let .disconnect(command):
            let endpoints = cables.first(where: { $0.id == command.cableID }).map { [$0.endpointA, $0.endpointB] } ?? []
            return Set([.object(command.cableID)] + endpoints.map(ResourceKey.object))
        case let .move(command): return [.object(command.cableID), .object(command.endpointA), .object(command.endpointB)]
        case .remove:
            invalidateDraft("Device removal requires a complete decommission snapshot.")
            return nil
        case let .deviceDecommission(decommission): return decommission.resourceKeys
        case let .markUnavailable(command):
            guard let port = ports.first(where: { $0.id == command.portID }) else {
                invalidateDraft("The selected port is no longer present in the local mirror.")
                return nil
            }
            return portResourceKeys(port)
        case let .hierarchy(operation): return operation.resourceKeys
        }
    }

    private func deviceIsDisconnected(_ deviceID: ObjectID) -> Bool {
        let devicePortIDs = Set(ports.lazy.filter { $0.deviceID == deviceID }.map(\.id))
        return !cables.contains { devicePortIDs.contains($0.endpointA) || devicePortIDs.contains($0.endpointB) }
    }

    private func matchingDecommissionSnapshot(for deviceID: ObjectID) async -> DeviceDecommissionSnapshot? {
        do {
            let snapshot = try await browser.deviceDecommissionSnapshot(for: deviceID, in: account.namespace)
            guard snapshot.device.id == deviceID else {
                invalidateDraft("The selected device no longer matches the local mirror.")
                return nil
            }
            return snapshot
        } catch {
            invalidateDraft("The device dependencies are unavailable in the local mirror.")
            return nil
        }
    }

    private func decommissionPlan(for snapshot: DeviceDecommissionSnapshot, deviceID: ObjectID) -> PlannedDeviceDecommission {
        PlannedDeviceDecommission(
            removal: RemoveTopologyCommand(deviceID: deviceID, deletedAt: .now),
            device: snapshot.device,
            modules: snapshot.modules,
            ports: snapshot.ports,
            rackPlacements: snapshot.rackPlacements,
            floorPlanAnchors: snapshot.floorPlanAnchors,
            interfaces: snapshot.interfaces,
            addressAssignments: snapshot.addressAssignments,
            vlanMemberships: snapshot.vlanMemberships,
            addresses: snapshot.addresses
        )
    }
}
