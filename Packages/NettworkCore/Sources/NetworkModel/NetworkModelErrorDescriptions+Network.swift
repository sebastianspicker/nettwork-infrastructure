import Foundation

extension IPAMValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPrefix, .duplicatePrefix, .partialPrefixOverlap, .crossVRFPrefixMutation:
            "The address range is invalid or overlaps another range. Enter a range that does not overlap existing ones."
        case .invalidReservedRange, .overlappingReservedRange, .addressReserved:
            "The reserved address range is invalid or already in use. Choose a different range or address."
        case .invalidVLAN, .duplicateVLAN, .missingVLANMembership, .duplicateVLANMembership, .invalidNativeVLAN, .invalidInterfaceVLANMode:
            "The VLAN settings are not valid or are already in use. Review the VLAN numbers and modes."
        case .duplicateAddress, .addressOutsidePrefixes, .duplicateAddressAssignment:
            "The IP address is already used or lies outside the available ranges. Enter an unused address in a defined range."
        case .revisionConflict, .revisionOverflow:
            "The address data was changed elsewhere. Refresh and try your change again."
        case .missingAddressAssignment, .missingInterfaceAssignment, .inconsistentAddressAssignment, .invalidPrimaryAddress:
            "The address is not assigned correctly to an interface. Review the interface address settings."
        case .duplicateInterface, .invalidInterface:
            "The interface is duplicated or invalid. Review the interface list."
        }
    }
}

extension TopologyValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateObjectID, .duplicateDeviceType, .duplicateDevice, .duplicateModule, .duplicatePort, .duplicateCable,
            .duplicateInternalLinkID, .duplicateReservation, .duplicatePlannedWork, .duplicateTombstone, .duplicateInternalLink:
            "The same item appears more than once. Remove the duplicate and try again."
        case .missingDeviceType, .missingDevice, .missingModule, .missingPort, .missingCable, .tombstonedReference,
            .tombstoneConflictsWithLiveObject:
            "An item refers to something that no longer exists. Restore it or remove the reference."
        case .invalidModuleOwner, .invalidInstalledModuleOwner, .invalidInstalledPortOwner, .invalidRackPlacement:
            "A module, port or device is attached to the wrong parent. Check where it is installed."
        case .selfConnection, .incompatibleEndpoints, .incompatibleCableKind, .invalidFiberMode, .invalidPowerTermination,
            .invalidPassThrough:
            "The cable cannot connect those ports. Choose compatible ports and cable type."
        case .invalidCableLength:
            "The cable length is not valid. Enter a positive length."
        case .duplicateCableOccupancy:
            "One of the ports already has a cable. Disconnect it first."
        case .deviceHasCableOccupancy, .deviceHasInternalLinks:
            "The device still has cables or links. Disconnect them first."
        case .revisionOverflow:
            "The record has been changed too many times to be updated further."
        }
    }
}
