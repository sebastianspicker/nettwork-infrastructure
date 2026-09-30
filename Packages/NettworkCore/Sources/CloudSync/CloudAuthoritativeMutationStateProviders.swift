import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

public protocol AuthoritativeMutationStateProviding: Sendable {
    func state(for mutation: AuthoritativeMutation) async throws -> AuthoritativeMutationState
    func state(for mutation: AuthoritativeActivationMutation) async throws -> AuthoritativeActivationMutationState
}

public enum AuthoritativeActivationMutationStateProviderError: Error, Hashable, Sendable {
    case unsupported
}

public extension AuthoritativeMutationStateProviding {
    /// Activation requires an explicit state source. Older work-order-only
    /// fakes cannot accidentally authorize a bootstrap or bulk mutation.
    func state(for mutation: AuthoritativeActivationMutation) async throws -> AuthoritativeActivationMutationState {
        throw AuthoritativeActivationMutationStateProviderError.unsupported
    }
}

private func assertionsByKey(_ assertions: [AuthoritativeReadAssertion]) -> [ResourceKey: AuthoritativeReadAssertion] {
    Dictionary(assertions.map { ($0.resourceKey, $0) }, uniquingKeysWith: { first, _ in first })
}

private func stateKeys(_ resourceKeys: Set<ResourceKey>, assertions: [ResourceKey: AuthoritativeReadAssertion], tooLarge: Error) throws -> [ResourceKey] {
    let keys = resourceKeys.union(assertions.keys)
    guard keys.count <= 10_000 else { throw tooLarge }
    return keys.sorted()
}

public enum CloudExactMutationStateError: Error, Hashable, Sendable {
    case workspaceMismatch
    case mutationTooLarge
    case malformedWorkOrderRecord
    case malformedReadAssertionRecord(ResourceKey)
    case returnedSnapshotMismatch(ResourceKey)
}

private func exactSnapshot(
    _ snapshot: CloudExactRecordSnapshot, isValidFor key: ResourceKey, workspaceZone: AuthoritativeWorkspaceZone, assertion: AuthoritativeReadAssertion?
) throws {
    guard snapshot.workspaceZone == workspaceZone, snapshot.resourceKey == key else { throw CloudExactMutationStateError.returnedSnapshotMismatch(key) }
    if let assertion {
        guard snapshot.recordType == assertion.recordType, snapshot.schemaVersion == assertion.schemaVersion,
            snapshot.payload == assertion.encodedRecord, snapshot.exactPrecondition == assertion.precondition
        else {
            throw CloudExactMutationStateError.malformedReadAssertionRecord(key)
        }
    }
}

/// Reconstructs commit preconditions from exact server-returned records. This
/// is the production state provider for authority paths that cannot wait for a
/// foreground mirror refresh, such as the second phase that binds reservation
/// acknowledgement metadata.
public struct CloudExactAuthoritativeMutationStateProvider: AuthoritativeMutationStateProviding {
    private let reader: any CloudExactRecordReading
    private let account: AccountContext

    public init(reader: any CloudExactRecordReading, account: AccountContext) {
        self.reader = reader
        self.account = account
    }

    public func state(for mutation: AuthoritativeMutation) async throws -> AuthoritativeMutationState {
        guard mutation.workspaceZone == account.namespace.workspaceZone else {
            throw CloudExactMutationStateError.workspaceMismatch
        }
        let assertionByKey = assertionsByKey(mutation.readAssertions)
        let stateKeys = try stateKeys(mutation.resourceKeys, assertions: assertionByKey, tooLarge: CloudExactMutationStateError.mutationTooLarge)
        var known = [ResourceKey: ExactRecordPrecondition]()
        var currentWorkOrder: WorkOrder?
        for key in stateKeys.sorted() {
            guard let snapshot = try await reader.exactRecord(for: key, in: mutation.workspaceZone) else {
                continue
            }
            try exactSnapshot(snapshot, isValidFor: key, workspaceZone: mutation.workspaceZone, assertion: assertionByKey[key])
            known[key] = snapshot.exactPrecondition
            if key == .object(mutation.workOrder.id) {
                guard snapshot.recordType == CloudRecordNaming.workOrderRecordType,
                    snapshot.schemaVersion == CloudRecordNaming.schemaVersion,
                    let decoded = try? CloudDeterministicCoding.decode(WorkOrder.self, from: snapshot.payload),
                    decoded.id == mutation.workOrder.id
                else {
                    throw CloudExactMutationStateError.malformedWorkOrderRecord
                }
                currentWorkOrder = decoded
            }
        }
        return AuthoritativeMutationState(knownRecords: known, currentWorkOrder: currentWorkOrder)
    }

    public func state(for mutation: AuthoritativeActivationMutation) async throws -> AuthoritativeActivationMutationState {
        guard mutation.workspaceZone == account.namespace.workspaceZone else {
            throw CloudExactMutationStateError.workspaceMismatch
        }
        let assertionByKey = assertionsByKey(mutation.readAssertions)
        let stateKeys = try stateKeys(mutation.resourceKeys, assertions: assertionByKey, tooLarge: CloudExactMutationStateError.mutationTooLarge)
        var known = [ResourceKey: ExactRecordPrecondition]()
        var currentRecords = [ResourceKey: AuthoritativeActivationRecordSnapshot]()
        var currentSentinel: AuthoritativeActivationSentinelSnapshot?
        for key in stateKeys.sorted() {
            guard let snapshot = try await reader.exactRecord(for: key, in: mutation.workspaceZone) else {
                continue
            }
            try exactSnapshot(snapshot, isValidFor: key, workspaceZone: mutation.workspaceZone, assertion: assertionByKey[key])
            if key == mutation.bootstrapSentinelResourceKey {
                guard currentSentinel == nil else {
                    throw CloudExactMutationStateError.returnedSnapshotMismatch(key)
                }
                currentSentinel = AuthoritativeActivationSentinelSnapshot(
                    recordType: snapshot.recordType,
                    schemaVersion: snapshot.schemaVersion, encodedRecord: snapshot.payload)
            }
            currentRecords[key] = AuthoritativeActivationRecordSnapshot(
                recordType: snapshot.recordType,
                schemaVersion: snapshot.schemaVersion, encodedRecord: snapshot.payload,
                precondition: snapshot.exactPrecondition)
            guard known.updateValue(snapshot.exactPrecondition, forKey: key) == nil else {
                throw CloudExactMutationStateError.returnedSnapshotMismatch(key)
            }
        }
        return AuthoritativeActivationMutationState(
            knownRecords: known, currentRecords: currentRecords,
            currentSentinel: currentSentinel)
    }
}
