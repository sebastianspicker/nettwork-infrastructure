import Foundation

public enum DefaultIPAMValidationService {
    /// Compatibility validation for the repository protocol. Use the overload below before a complete IPAM commit.
    public static func validate(prefixes: [Prefix], addresses: [IPAddressRecord], vlans: [VLAN]) throws {
        let prefixIndex = try validatePrefixes(prefixes)
        try validateAddresses(addresses, prefixIndex: prefixIndex)
        try validateVLANs(vlans)
    }

    public static func validate(
        prefixes: [Prefix], addresses: [IPAddressRecord], vlans: [VLAN], interfaces: [Interface], assignments: [IPAddressAssignment],
        memberships: [InterfaceVLANMembership]
    ) throws {
        try validate(prefixes: prefixes, addresses: addresses, vlans: vlans)
        try validateInterfaces(interfaces, vlans: vlans)
        try validateAssignments(assignments, addresses: addresses, interfaces: interfaces)
        try validateMemberships(memberships, interfaces: interfaces, vlans: vlans)
    }

    private static func validatePrefixes(_ prefixes: [Prefix]) throws -> IPAMPrefixIndex {
        let active = prefixes.filter(\.isActive)
        for prefix in active { try validate(prefix: prefix) }
        let index = IPAMPrefixIndex(activePrefixes: active)
        if let (prefix, other) = index.earliestDuplicatePair() {
            throw IPAMValidationError.duplicatePrefix(prefix, other)
        }
        return index
    }

    private static func validate(prefix: Prefix) throws {
        guard prefix.network.isWellFormed,
            (0...prefix.network.bitWidth).contains(prefix.prefixLength),
            prefix.network.masked(prefixLength: prefix.prefixLength) == prefix.network
        else {
            throw IPAMValidationError.invalidPrefix(prefix.id)
        }
        try validateReservedRanges(for: prefix)
    }

    private static func validateReservedRanges(for prefix: Prefix) throws {
        for range in prefix.reservedRanges where !prefix.contains(range) {
            _ = range
            throw IPAMValidationError.invalidReservedRange(prefixID: prefix.id)
        }
        let ranges = prefix.reservedRanges.sorted { $0.lowerBound < $1.lowerBound }
        for index in ranges.indices.dropLast() where ranges[index].overlaps(ranges[index + 1]) {
            throw IPAMValidationError.overlappingReservedRange(prefixID: prefix.id)
        }
    }

    private static func validateAddresses(_ addresses: [IPAddressRecord], prefixIndex: IPAMPrefixIndex) throws {
        var names = Set<String>()
        for address in addresses {
            guard names.insert(address.id).inserted, address.address.isWellFormed,
                address.id
                    == IPAddressRecord.deterministicRecordName(
                        vrfID: address.vrfID,
                        address: address.address)
            else { throw IPAMValidationError.duplicateAddress(address.id) }
            let containingPrefixes = prefixIndex.containingPrefixes(for: address.address, vrfID: address.vrfID)
            guard !address.isActive || !containingPrefixes.isEmpty else { throw IPAMValidationError.addressOutsidePrefixes(address.id) }
            guard !address.isActive || !containingPrefixes.contains(where: { $0.isReserved(address.address) }) else {
                throw IPAMValidationError.addressReserved(address.id)
            }
        }
    }

    private static func validateVLANs(_ vlans: [VLAN]) throws {
        var keys = Set<String>()
        for vlan in vlans where vlan.isActive {
            guard (1...4094).contains(vlan.number) else { throw IPAMValidationError.invalidVLAN(vlan.id) }
            let key = "\(vlan.groupID.description):\(vlan.number)"
            guard keys.insert(key).inserted else { throw IPAMValidationError.duplicateVLAN(groupID: vlan.groupID, number: vlan.number) }
        }
    }

    private static func validateInterfaces(_ interfaces: [Interface], vlans: [VLAN]) throws {
        let activeVLANIDs = Set(vlans.lazy.filter(\.isActive).map(\.id))
        for interface in interfaces where interface.isActive {
            switch interface.kind {
            case .physical:
                guard interface.physicalPortID != nil, interface.vlanID == nil else { throw IPAMValidationError.invalidInterface(interface.id) }
            case .loopback:
                guard interface.physicalPortID == nil, interface.vlanID == nil, interface.mode == .routed else {
                    throw IPAMValidationError.invalidInterface(interface.id)
                }
            case .vlan:
                guard interface.physicalPortID == nil, interface.mode == .routed, let vlanID = interface.vlanID, activeVLANIDs.contains(vlanID) else {
                    throw IPAMValidationError.invalidInterface(interface.id)
                }
            }
        }
    }

    private static func validateAssignments(_ assignments: [IPAddressAssignment], addresses: [IPAddressRecord], interfaces: [Interface]) throws {
        let activeAddresses = try activeAddressRecords(addresses)
        let activeInterfaces = try activeInterfaceRecords(interfaces)
        var byAddress: [String: [IPAddressAssignment]] = [:]
        var byInterface: [ObjectID: [IPAddressAssignment]] = [:]
        for assignment in assignments where assignment.isActive {
            try validate(assignment: assignment, addresses: activeAddresses, interfaces: activeInterfaces)
            byAddress[assignment.addressID, default: []].append(assignment)
            byInterface[assignment.interfaceID, default: []].append(assignment)
        }
        for (addressID, matches) in byAddress where matches.count != 1 { throw IPAMValidationError.duplicateAddressAssignment(addressID) }
        try validateAddressAssignments(byAddress, activeAddresses: activeAddresses)
        try validatePrimaryAssignments(byInterface)
    }

    private static func activeAddressRecords(_ addresses: [IPAddressRecord]) throws -> [String: IPAddressRecord] {
        try uniqueRecords(addresses.filter(\.isActive), key: \.id, duplicate: IPAMValidationError.duplicateAddress)
    }

    private static func activeInterfaceRecords(_ interfaces: [Interface]) throws -> [ObjectID: Interface] {
        try uniqueRecords(interfaces.filter(\.isActive), key: \.id, duplicate: IPAMValidationError.duplicateInterface)
    }

    private static func uniqueRecords<Record, Key: Hashable>(_ records: [Record], key: KeyPath<Record, Key>, duplicate: (Key) -> IPAMValidationError) throws
        -> [Key: Record]
    {
        var result = [Key: Record]()
        for record in records {
            let id = record[keyPath: key]
            guard result.updateValue(record, forKey: id) == nil else { throw duplicate(id) }
        }
        return result
    }

    private static func validate(assignment: IPAddressAssignment, addresses: [String: IPAddressRecord], interfaces: [ObjectID: Interface]) throws {
        guard let address = addresses[assignment.addressID] else { throw IPAMValidationError.missingAddressAssignment(assignment.addressID) }
        guard interfaces[assignment.interfaceID] != nil else { throw IPAMValidationError.missingInterfaceAssignment(assignment.interfaceID) }
        guard address.assignedInterfaceID == assignment.interfaceID else { throw IPAMValidationError.inconsistentAddressAssignment(assignment.addressID) }
    }

    private static func validateAddressAssignments(_ byAddress: [String: [IPAddressAssignment]], activeAddresses: [String: IPAddressRecord]) throws {
        for address in activeAddresses.values {
            let count = byAddress[address.id]?.count ?? 0
            if address.assignedInterfaceID == nil, count != 0 { throw IPAMValidationError.inconsistentAddressAssignment(address.id) }
            if address.assignedInterfaceID != nil, count != 1 { throw IPAMValidationError.inconsistentAddressAssignment(address.id) }
        }
    }

    private static func validatePrimaryAssignments(_ byInterface: [ObjectID: [IPAddressAssignment]]) throws {
        for (interfaceID, matches) in byInterface where matches.filter(\.isPrimary).count != 1 {
            throw IPAMValidationError.invalidPrimaryAddress(interfaceID)
        }
    }

    private static func validateMemberships(_ memberships: [InterfaceVLANMembership], interfaces: [Interface], vlans: [VLAN]) throws {
        let activeInterfaces = try activeInterfaceRecords(interfaces)
        let activeVLANIDs = Set(vlans.lazy.filter(\.isActive).map(\.id))
        var byInterface: [ObjectID: [InterfaceVLANMembership]] = [:]
        var pairs = Set<String>()
        for membership in memberships where membership.isActive {
            try validate(membership: membership, interfaces: activeInterfaces, vlanIDs: activeVLANIDs, pairs: &pairs)
            byInterface[membership.interfaceID, default: []].append(membership)
        }
        for interface in activeInterfaces.values { try validateVLANMode(interface, memberships: byInterface[interface.id] ?? []) }
    }

    private static func validate(membership: InterfaceVLANMembership, interfaces: [ObjectID: Interface], vlanIDs: Set<ObjectID>, pairs: inout Set<String>)
        throws
    {
        guard interfaces[membership.interfaceID] != nil, vlanIDs.contains(membership.vlanID) else {
            throw IPAMValidationError.missingVLANMembership(membership.id)
        }
        let key = "\(membership.interfaceID.description):\(membership.vlanID.description)"
        guard pairs.insert(key).inserted else {
            throw IPAMValidationError.duplicateVLANMembership(interfaceID: membership.interfaceID, vlanID: membership.vlanID)
        }
    }

    private static func validateVLANMode(_ interface: Interface, memberships: [InterfaceVLANMembership]) throws {
        switch interface.mode {
        case .access:
            guard interface.kind == .physical, memberships.count == 1, memberships[0].isNative else {
                throw IPAMValidationError.invalidInterfaceVLANMode(interface.id)
            }
        case .trunk:
            guard interface.kind == .physical, !memberships.isEmpty, memberships.filter(\.isNative).count <= 1 else {
                throw IPAMValidationError.invalidNativeVLAN(interface.id)
            }
        case .routed:
            guard memberships.isEmpty else { throw IPAMValidationError.invalidInterfaceVLANMode(interface.id) }
        }
    }
}
