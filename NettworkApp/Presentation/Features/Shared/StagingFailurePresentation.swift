import NetworkModel
import WorkspaceChangeControl

/// Maps a work-order staging failure to presentation state. Only genuine
/// revision or precondition conflicts get the conflict wording; every other
/// failure reports the error's own description so it is not misdiagnosed.
enum StagingFailurePresentation {
    static func state(for error: any Error, conflictMessage: String) -> InventoryPresentationState {
        isConflict(error) ? .conflict(conflictMessage) : .unavailable(error.localizedDescription)
    }

    private static func isConflict(_ error: any Error) -> Bool {
        if case .revisionConflict = error as? IPAMValidationError { return true }
        switch error as? AuthoritativeMutationValidationError {
        case .staleWorkOrderRevision, .preconditionConflict, .resourceAlreadyExists: return true
        default: return false
        }
    }
}
