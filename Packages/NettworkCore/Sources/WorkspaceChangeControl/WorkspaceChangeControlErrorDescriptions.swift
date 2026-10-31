import Foundation

extension WorkOrderTransitionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidTransition:
            "The work order cannot move to that status from its current one. Choose a valid next step."
        case .cancellationReasonRequired:
            "Enter a reason before cancelling the work order."
        case .resourcesRequired:
            "Add at least one resource to the work order before continuing."
        case .cloudKitAcknowledgementRequired, .cloudKitAcknowledgementMismatch, .cloudKitAcknowledgementExpired, .reservationAlreadyAcknowledged:
            "The cloud has not confirmed the reservation for this work order. Sync and try again."
        case .cancellationReleaseAuthorizationRequired, .invalidActor:
            "You are not allowed to make this change to the work order. Ask an administrator."
        case .revisionOverflow:
            "The work order has been changed too many times to be updated further."
        }
    }
}

extension AuthoritativeMutationValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidScope, .invalidActorSnapshot, .reservationOwnerMismatch, .reservationScopeMismatch, .reservationIntentMismatch:
            "The request was not authorized for this workspace. Sync and try again."
        case .missingWorkOrderIntentDigest, .intentDigestMismatch, .invalidWorkOrderPrecondition, .invalidWorkOrderTransition,
            .evidenceMismatch:
            "The work order change could not be verified. Review the work order and try again."
        case .staleWorkOrderRevision, .invalidSubmittedWorkOrderRevision, .preconditionConflict, .resourceAlreadyExists:
            "The data was changed elsewhere in the meantime. Sync and try your change again."
        case .duplicateTouchedResource, .duplicateReadAssertion, .duplicatePrecondition, .readAssertionOverlapsMutation:
            "The change refers to the same item more than once. Review the change and try again."
        case .invalidReadAssertion, .readAssertionPreconditionMismatch, .resourceKeyNotDeclared, .missingPrecondition,
            .invalidExactPrecondition:
            "The change could not be checked against the current data. Sync and try again."
        case .missingRecord, .invalidRecordSave, .invalidTombstone, .reservedActivationInfrastructure, .invalidImmutablePayload:
            "The change refers to data that cannot be modified. Sync and try again."
        case .invalidAuditEvent, .invalidReceipt:
            "The change could not be recorded in the audit history. Sync and try again."
        case .reservationExpired:
            "The reservation for this work order expired. Reserve the resources again."
        }
    }
}

extension AuthoritativeActivationMutationValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidScope, .invalidActorSnapshot:
            "The activation was not authorized for this workspace. Sync and try again."
        case .invalidImmutablePayload, .invalidAuditEvent, .invalidReceipt:
            "The activation data is not valid and was not applied. Start the import again."
        case .missingBootstrapSentinel, .invalidBootstrapSentinelPrecondition, .invalidCurrentBootstrapSentinel, .invalidActivationRecordSet,
            .invalidTransferSessionAssertion:
            "The workspace is not ready for this import. Sync and start the import again."
        case .duplicateTouchedResource, .duplicatePrecondition, .duplicateReadAssertion, .readAssertionOverlapsMutation:
            "The activation refers to the same item more than once. Start the import again."
        case .invalidReadAssertion, .readAssertionPreconditionMismatch, .missingPrecondition, .invalidExactPrecondition:
            "The activation could not be checked against the current data. Sync and try again."
        case .resourceAlreadyExists, .preconditionConflict:
            "The workspace already contains data that conflicts with this import. Import into an empty workspace."
        case .missingRecord, .invalidRecordSave, .invalidTombstone:
            "The activation refers to data that cannot be modified. Start the import again."
        }
    }
}
