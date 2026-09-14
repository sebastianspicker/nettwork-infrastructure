import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

@MainActor
@Observable
final class IPAMWorkspaceModel {
    private let browser: any IPAMBrowsing
    private var loadGeneration: UInt64 = 0
    let drafts: any IPAMWorkOrderDrafting
    let account: AccountContext
    let onStagedWorkOrder: (@MainActor (ObjectID) async -> Void)?

    var state: InventoryPresentationState = .loading
    private(set) var vrfs: [VRFSnapshot] = []
    private(set) var prefixes: [IPAMPrefixSnapshot] = []
    private(set) var addresses: [IPAMAddressSnapshot] = []
    private(set) var vlans: [VLANSnapshot] = []
    private(set) var interfaces: [LogicalInterfaceSnapshot] = []
    private(set) var selectedVRFID: ObjectID?
    private(set) var selectedPrefixID: ObjectID?
    var stagedWorkOrderID: ObjectID?
    private(set) var validationExplanation: String?
    private(set) var prefixEditorID: ObjectID?

    var searchText = ""
    var draftTitle = "IPAM change"
    var ticketID = ""
    var draftNotes = ""
    var prefixCIDR = ""
    var prefixName = ""
    var reservedRanges = ""

    init(
        account: AccountContext,
        browser: any IPAMBrowsing,
        drafts: any IPAMWorkOrderDrafting,
        onStagedWorkOrder: (@MainActor (ObjectID) async -> Void)? = nil
    ) {
        self.account = account
        self.browser = browser
        self.drafts = drafts
        self.onStagedWorkOrder = onStagedWorkOrder
    }
    @discardableResult
    func load() async -> Bool {
        guard !Task.isCancelled else { return false }
        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        do {
            async let vrfs = browser.vrfs(in: account.namespace)
            async let prefixes = browser.prefixes(in: account.namespace)
            async let vlans = browser.vlans(in: account.namespace)
            async let interfaces = browser.interfaces(in: account.namespace)
            let loaded = try await (vrfs, prefixes, vlans, interfaces)
            guard generation == loadGeneration, !Task.isCancelled else { return false }
            self.vrfs = loaded.0
            self.prefixes = loaded.1
            self.vlans = loaded.2
            self.interfaces = loaded.3
            selectedVRFID = selectedVRFID ?? self.vrfs.first?.id
            state = self.vrfs.isEmpty && self.prefixes.isEmpty ? .empty : .ready
            return true
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return false }
            state = .offline("IPAM is unavailable from the scoped local mirror.")
            return true
        }
    }

    func selectVRF(_ id: ObjectID) {
        selectedVRFID = id
        selectedPrefixID = nil
        addresses = []
        validationExplanation = nil
        resetPrefixEditor()
    }

    func selectPrefix(_ id: ObjectID) async {
        guard let prefix = prefixes.first(where: { $0.id == id }) else { return }
        selectedVRFID = prefix.vrfID
        selectedPrefixID = id
        validationExplanation = nil
        prefixEditorID = prefix.id
        prefixCIDR = prefix.cidr
        prefixName = prefix.name
        reservedRanges = prefix.value.reservedRanges.map {
            "\($0.lowerBound)-\($0.upperBound)"
        }.joined(separator: ", ")
        do {
            addresses = try await browser.addresses(prefixID: id, in: account.namespace)
        } catch {
            state = .offline("Addresses are unavailable while offline.")
        }
    }

    func beginNewPrefix() {
        guard selectedVRF != nil else {
            state = .unavailable("Select a VRF before creating a prefix layout.")
            return
        }
        prefixEditorID = ObjectID()
        selectedPrefixID = nil
        prefixCIDR = ""
        prefixName = ""
        reservedRanges = ""
        validationExplanation = "Enter a canonical IPv4 or IPv6 CIDR. Reserved ranges use start-end pairs separated by commas."
    }

    func stagePrefixLayout(removing: Bool = false) async {
        guard let vrfSnapshot = selectedVRF else {
            state = .unavailable("Select a VRF before staging a prefix layout.")
            return
        }
        let current = prefixes.filter { $0.vrfID == vrfSnapshot.id }.map(\.value)
        let desired: [Prefix]
        if removing {
            guard let prefixEditorID,
                current.contains(where: { $0.id == prefixEditorID })
            else {
                state = .unavailable("Select an existing prefix before staging its removal.")
                return
            }
            desired = current.filter { $0.id != prefixEditorID }
        } else {
            let cidr = prefixCIDR.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let editorID = prefixEditorID,
                let ranges = parseReservedRanges(reservedRanges),
                let proposed = Prefix(
                    id: editorID,
                    vrfID: vrfSnapshot.id,
                    cidr: cidr,
                    name: prefixName.trimmingCharacters(in: .whitespacesAndNewlines),
                    reservedRanges: ranges
                ), proposed.cidr == cidr
            else {
                validationExplanation = "Use a canonical network CIDR and comma-separated start-end ranges contained by it."
                state = .unavailable("Correct the prefix layout before staging it.")
                return
            }
            desired = current.filter { $0.id != editorID } + [proposed]
        }
        do {
            _ = try PrefixLayoutMutation.apply(
                prefixes: desired,
                to: vrfSnapshot.value,
                expectedRevision: vrfSnapshot.revision
            )
            validationExplanation = "The complete desired prefix layout is valid against VRF revision \(vrfSnapshot.revision)."
            await stage(
                IPAMWorkOrderRequest(
                    title: draftTitle,
                    ticketID: ticketID,
                    notes: draftNotes,
                    perVRFRevisionKey: .object(vrfSnapshot.id),
                    operation: .prefixLayout(
                        PrefixLayoutWorkOrderRequest(
                            vrf: vrfSnapshot.value,
                            currentPrefixes: current.sorted { $0.id < $1.id },
                            desiredPrefixes: desired.sorted { $0.id < $1.id }
                        ))
                ))
        } catch {
            validationExplanation = "The complete layout overlaps, crosses VRFs, exceeds its network, or no longer matches the selected revision."
            state = .conflict("The prefix layout failed deterministic validation.")
        }
    }

    /// Confirms that the immutable prefix shown in the dialog is still the
    /// selected, current snapshot before applying the existing removal gate.
    func stagePrefixRemoval(_ prefix: IPAMPrefixSnapshot) async {
        guard selectedVRFID == prefix.vrfID,
            selectedPrefixID == prefix.id,
            prefixEditorID == prefix.id,
            prefixes.contains(prefix)
        else {
            state = .unavailable("The selected prefix changed. Review the current prefix layout before staging removal.")
            return
        }
        await stagePrefixLayout(removing: true)
    }

    private func resetPrefixEditor() {
        prefixEditorID = nil
        prefixCIDR = ""
        prefixName = ""
        reservedRanges = ""
    }

    private func parseReservedRanges(_ source: String) -> [ReservedAddressRange]? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [ReservedAddressRange] = []
        for rawRange in trimmed.split(separator: ",") {
            let bounds = rawRange.split(separator: "-", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard bounds.count == 2,
                let lower = IPAddress(parsing: bounds[0]),
                let upper = IPAddress(parsing: bounds[1]),
                let range = ReservedAddressRange(lowerBound: lower, upperBound: upper)
            else {
                return nil
            }
            result.append(range)
        }
        return result
    }

    func validateAddress(_ address: IPAMAddressSnapshot) {
        guard let parsed = IPAddress(parsing: address.address) else {
            validationExplanation = "Invalid IP address. Use canonical dotted-decimal IPv4 or RFC 4291 IPv6 notation without whitespace or a zone identifier."
            return
        }
        switch parsed {
        case .v4:
            validationExplanation = "IPv4 validated: four decimal octets, each from 0 through 255, with no leading zeroes."
        case .v6:
            validationExplanation = "IPv6 validated: RFC 4291 notation with at most one :: compression and no zone identifier."
        }
    }

    func stageAddressAssignment(
        address: IPAMAddressSnapshot,
        interface: LogicalInterfaceSnapshot,
        action: AddressAssignmentStagingAction,
        primaryAddressID: String?
    ) async {
        guard let context = addressAssignmentContext(address: address, interface: interface),
            let desired = desiredAddressAssignments(
                address: address,
                interface: interface,
                action: action,
                primaryAddressID: primaryAddressID,
                current: context.current,
                addressID: context.addressID
            )
        else { return }
        await stage(
            IPAMWorkOrderRequest(
                title: draftTitle,
                ticketID: ticketID,
                notes: draftNotes,
                perVRFRevisionKey: .object(context.vrf.id),
                operation: .addressAssignment(
                    InterfaceAddressAssignmentSet(
                        revisionVRF: context.vrf.value,
                        interfaceID: interface.id,
                        currentAssignments: context.current,
                        desiredAssignments: desired.assignments,
                        primaryAddressID: desired.primaryAddressID
                    ))
            )
        )
    }

    private func addressAssignmentContext(
        address: IPAMAddressSnapshot,
        interface: LogicalInterfaceSnapshot
    ) -> (vrf: VRFSnapshot, addressID: String, current: [IPAddressAssignment])? {
        guard let vrf = selectedVRF else {
            state = .unavailable("Select a VRF before staging an address assignment.")
            return nil
        }
        guard !address.isConflicted else {
            state = .conflict("This address has unresolved conflicts. Resolve them before staging a new assignment.")
            return nil
        }
        guard IPAddress(parsing: address.address) != nil else {
            validateAddress(address)
            state = .conflict("The address failed validation and cannot be staged.")
            return nil
        }
        guard case let .string(addressID) = address.resourceKey else {
            state = .conflict("The selected address does not have its authoritative record name.")
            return nil
        }
        let current = interface.addressAssignments
        guard current.allSatisfy({ $0.isActive && $0.interfaceID == interface.id }) else {
            state = .conflict("The interface assignment snapshot is incomplete. Refresh before staging this change.")
            return nil
        }
        return (vrf, addressID, current)
    }

    private func desiredAddressAssignments(
        address: IPAMAddressSnapshot,
        interface: LogicalInterfaceSnapshot,
        action: AddressAssignmentStagingAction,
        primaryAddressID: String?,
        current: [IPAddressAssignment],
        addressID: String
    ) -> (assignments: [IPAddressAssignment], primaryAddressID: String?)? {
        switch action {
        case .addSecondary:
            return addSecondaryAddressAssignment(
                current: current,
                address: address,
                interface: interface,
                addressID: addressID,
                primaryAddressID: primaryAddressID
            )
        case .makePrimary:
            return makePrimaryAddressAssignment(current: current, address: address, interface: interface, addressID: addressID)
        case .unassign:
            return unassignAddressAssignment(current: current, addressID: addressID, primaryAddressID: primaryAddressID)
        }
    }

    private func addSecondaryAddressAssignment(
        current: [IPAddressAssignment],
        address: IPAMAddressSnapshot,
        interface: LogicalInterfaceSnapshot,
        addressID: String,
        primaryAddressID: String?
    ) -> (assignments: [IPAddressAssignment], primaryAddressID: String?)? {
        guard !current.contains(where: { $0.addressID == addressID }), address.assignments.isEmpty, let primaryAddressID else {
            state = .unavailable("Choose an unassigned address and the existing primary address before adding a secondary assignment.")
            return nil
        }
        return normalizedAssignments(current + [IPAddressAssignment(addressID: addressID, interfaceID: interface.id)], primaryAddressID: primaryAddressID)
    }

    private func makePrimaryAddressAssignment(
        current: [IPAddressAssignment],
        address: IPAMAddressSnapshot,
        interface: LogicalInterfaceSnapshot,
        addressID: String
    ) -> (assignments: [IPAddressAssignment], primaryAddressID: String?)? {
        guard address.assignments.isEmpty || current.contains(where: { $0.addressID == addressID }) else {
            state = .unavailable("An address assigned to another interface cannot be added to this relationship set.")
            return nil
        }
        let desired =
            current.contains(where: { $0.addressID == addressID })
            ? current : current + [IPAddressAssignment(addressID: addressID, interfaceID: interface.id)]
        return normalizedAssignments(desired, primaryAddressID: addressID)
    }

    private func unassignAddressAssignment(
        current: [IPAddressAssignment],
        addressID: String,
        primaryAddressID: String?
    ) -> (assignments: [IPAddressAssignment], primaryAddressID: String?)? {
        guard current.contains(where: { $0.addressID == addressID }) else {
            state = .unavailable("The selected address is not assigned to this interface.")
            return nil
        }
        return normalizedAssignments(current.filter { $0.addressID != addressID }, primaryAddressID: primaryAddressID)
    }

    private func normalizedAssignments(
        _ assignments: [IPAddressAssignment],
        primaryAddressID: String?
    ) -> (assignments: [IPAddressAssignment], primaryAddressID: String?)? {
        guard (assignments.isEmpty && primaryAddressID == nil) || assignments.contains(where: { $0.addressID == primaryAddressID }) else {
            state = .unavailable("Choose exactly one primary address for the complete desired assignment set.")
            return nil
        }
        return (
            assignments.map { assignment in
                var value = assignment
                value.isPrimary = value.addressID == primaryAddressID
                return value
            }, primaryAddressID
        )
    }
}
