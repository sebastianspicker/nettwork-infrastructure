import Foundation

/// Planner failures are shown to users as semantic validation issues, so each
/// case reads as a sentence and never exposes record keys.
extension ProductionMutationPlannerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .namespaceMismatch: "The draft belongs to a different workspace than the active account."
        case .malformedMirrorRecord: "A record in the local mirror could not be read."
        case .missingTopologyObject: "A device, port or cable in this draft is not in the local mirror."
        case .missingHierarchyObject: "A location or rack in this draft is not in the local mirror."
        case .missingIPAMObject: "A VRF, prefix or interface in this draft is not in the local mirror."
        default: relationshipDescription
        }
    }

    private var relationshipDescription: String {
        switch self {
        case .staleIPAMRelationshipSet: "The IP address or VLAN assignments changed since this draft was prepared."
        case .invalidIPAMRelationshipSet: "The IP address or VLAN assignments in this draft are not valid."
        case .ipamRecordAlreadyExists: "A VRF, IP address, VLAN or VLAN group with the same identity or name already exists."
        case .invalidIPAMCreation: "The new VRF, IP address or VLAN in this draft is not valid or its scope is missing."
        case .missingFloorPlanAnchor: "A floor-plan anchor in this draft is not in the local mirror."
        case .staleDeviceDecommission: "The device or its dependencies changed since the removal was prepared."
        case .legacyIntentRequiresReconciliation: "This draft uses a legacy format and must be reconciled before it can be applied."
        default: operationDescription
        }
    }

    private var operationDescription: String {
        switch self {
        case .invalidHierarchyOperation: "The location or rack change in this draft is not valid."
        case .unsupportedGenericDeviceOperation: "Generic device changes cannot be applied; use a typed topology command."
        case .duplicateMutation: "This draft changes the same object more than once."
        case .missingMirrorPrecondition: "The local mirror has no verified version of an object this draft changes."
        default: "The planned change failed validation against the current mirror."
        }
    }
}
