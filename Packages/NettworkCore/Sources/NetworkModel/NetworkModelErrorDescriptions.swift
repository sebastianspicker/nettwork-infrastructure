import Foundation

extension HierarchyValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateObject, .duplicateTombstone, .tombstoneConflictsWithObject:
            "The workspace contains the same item more than once. Reload the workspace and try again."
        case .missingWorkspace, .multipleWorkspaces:
            "The workspace is incomplete or contains more than one root. Reload the workspace and try again."
        case .missingObject, .deletedObject, .missingParent, .deletedParent:
            "An item refers to a location or parent that no longer exists. Restore the parent or choose another one."
        case .invalidRoot, .invalidParentType, .invalidRackParent:
            "That item cannot be placed there. Choose a location that can contain it."
        case .containmentCycle:
            "An item cannot be placed inside itself. Choose a different parent."
        case .cannotDeleteWithLiveChildren:
            "This item still contains other items. Move or delete them first."
        }
    }
}

extension TemplatePlacementValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicatePlacement, .duplicateRackReservation, .duplicateAnchor, .duplicateAnchoredObject:
            "An item is placed more than once. Remove the duplicate placement and try again."
        case .missingDevice, .missingRack, .deletedRack, .missingFloor, .unknownAnchoredObject:
            "A placement refers to a device, rack or floor that no longer exists. Refresh and try again."
        case .invalidRackHeight, .deviceHeightMismatch, .invalidRackReservation:
            "The device does not fit the rack height or reserved space. Choose a different position."
        case .deviceRackMismatch, .deviceHasPlacement, .deviceHasAnchor, .anchorOwnershipMismatch:
            "The device is already placed somewhere else. Remove the existing placement first."
        case .rackOverlap:
            "Two devices would overlap in the same rack position. Choose a free position."
        case .invalidFloor, .invalidAnchorCoordinate:
            "The position on the floor plan is not valid. Pick a point inside the floor plan."
        }
    }
}

extension TemplateValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidVersion, .incompatibleMigration, .invalidMigrationVersion, .missingSnapshot:
            "The template version cannot be used or upgraded. Choose a current template version."
        case .invalidRackHeight, .invalidFiberTemplate, .invalidConnectorTemplate:
            "The template has an invalid size or connector definition. Correct the template and try again."
        case .duplicatePortTemplate, .duplicatePortOrder, .duplicateSlot, .duplicateAllowedModule:
            "The template lists the same port, slot or module more than once. Remove the duplicates."
        case .emptySlot, .emptyAllowedModules, .missingRequiredSlot:
            "A template slot is empty or has no allowed modules. Complete the slot definition."
        case .unknownSlot, .disallowedModule:
            "That module is not allowed in this slot. Choose a module the slot accepts."
        case .missingInstantiationID, .duplicateInstantiationID:
            "The template could not be applied because of an identifier problem. Try applying it again."
        }
    }
}

extension AssetCodeValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyCode:
            "The asset code is empty. Enter an asset code."
        case .missingParentScope:
            "The asset code cannot be checked because its parent location is missing. Choose a parent location."
        case .duplicateCode:
            "Another item already uses this asset code. Enter a different code."
        }
    }
}

extension CustomFieldValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptySchemaKey, .duplicateSchemaKey, .duplicateValueKey:
            "A custom field has an empty or repeated name. Give each custom field a unique name."
        case .invalidChoices, .invalidChoice:
            "The value is not one of the choices allowed for this custom field. Pick a listed choice."
        case .unknownField:
            "A value refers to a custom field that does not exist. Remove the value or add the field."
        case .invalidDefault, .invalidValueType:
            "A custom field value has the wrong type. Enter a value of the expected type."
        case .missingRequiredField:
            "A required custom field is empty. Fill in all required fields."
        }
    }
}

extension PathTraceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownStartPort:
            "The port to trace from no longer exists. Choose another starting port."
        }
    }
}

extension IPAMLifecycleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tombstonedRecord:
            "This address record was deleted and cannot be changed. Create a new record instead."
        case .recordAlreadyActive:
            "This address record is already active."
        }
    }
}
