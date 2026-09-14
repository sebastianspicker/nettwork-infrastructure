import NetworkModel

enum MutationPreconditionValidationPolicy {
    static func mismatchedKey(
        preconditions: [ResourceKey: MutationPrecondition],
        conditionalKeys: Set<ResourceKey>
    ) -> ResourceKey? {
        guard Set(preconditions.keys) != conditionalKeys else { return nil }
        guard
            let key = conditionalKeys.subtracting(preconditions.keys).first
                ?? preconditions.keys.first
        else {
            preconditionFailure("Unequal precondition key sets must identify a key.")
        }
        return key
    }

    static func firstReadAssertionMismatch(
        _ assertions: [AuthoritativeReadAssertion],
        preconditions: [ResourceKey: MutationPrecondition]
    ) -> ResourceKey? {
        assertions.first { assertion in
            guard let precondition = preconditions[assertion.resourceKey],
                case let .exactSystemFields(_, exact) = precondition
            else {
                return true
            }
            return exact != assertion.precondition
        }?.resourceKey
    }
}
