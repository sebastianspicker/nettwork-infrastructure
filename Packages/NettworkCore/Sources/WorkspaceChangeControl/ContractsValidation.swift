import Foundation
import NetworkModel

public enum AuthoritativeMutationValidator {
    public static func validate(
        _ mutation: AuthoritativeMutation, against state: AuthoritativeMutationState
    ) throws {
        try validateMutationMetadata(mutation)
        try validateSubmittedWorkOrder(mutation, state: state)
        try validateReservationAuthority(mutation, state: state)
        try validateExecutingReservation(mutation)
        let context = try validateMutationResources(mutation)
        let assertions = try validateReadAssertions(mutation, context: context)
        let preconditions = try collectMutationPreconditions(mutation)
        let conditionalKeys = context.allTouched.union(assertions.keys)
        try validateMutationPreconditions(
            preconditions, mutation: mutation, state: state,
            assertions: assertions, conditionalKeys: conditionalKeys, workOrderKey: context.workOrderKey)
        try validateAuditEvent(mutation, context: context, assertionKeys: assertions.keys)
        try validateEvidenceAndReceipt(mutation)
    }
}

/// The only privileged write boundary. Implementations validate first, then atomically save all records, tombstones, audit data, and receipt.
public protocol AuthoritativeMutationRepository: Sendable {
    func commit(_ mutation: AuthoritativeMutation) async throws -> OperationReceipt
    func commit(_ mutation: AuthoritativeActivationMutation) async throws -> OperationReceipt
}

public extension AuthoritativeMutationRepository {
    /// Existing narrow fakes and product adapters remain fail-closed until they
    /// explicitly implement the work-order-free activation boundary.
    func commit(_ mutation: AuthoritativeActivationMutation) async throws -> OperationReceipt {
        throw AuthoritativeActivationMutationRepositoryError.unsupported
    }
}
