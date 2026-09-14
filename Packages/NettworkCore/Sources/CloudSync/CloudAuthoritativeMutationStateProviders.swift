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

public enum SwiftDataMutationStateError: Error, Hashable, Sendable {
    case workspaceMismatch
    case duplicateResource(ResourceKey)
    case mutationTooLarge
    case malformedReadAssertionRecord(ResourceKey)
}

private func assertionsByKey(_ assertions: [AuthoritativeReadAssertion]) -> [ResourceKey: AuthoritativeReadAssertion] {
    Dictionary(assertions.map { ($0.resourceKey, $0) }, uniquingKeysWith: { first, _ in first })
}

private func stateKeys(_ resourceKeys: Set<ResourceKey>, assertions: [ResourceKey: AuthoritativeReadAssertion], tooLarge: Error) throws -> [ResourceKey] {
    let keys = resourceKeys.union(assertions.keys)
    guard keys.count <= 10_000 else { throw tooLarge }
    return keys.sorted()
}

private func localRecord(_ record: LocalMirrorRecord, matches assertion: AuthoritativeReadAssertion, key: ResourceKey) throws {
    guard !record.isTombstone, canonicalCloudRecordType(for: record.recordType) == assertion.recordType,
        record.schemaVersion == assertion.schemaVersion, record.payload == assertion.encodedRecord,
        record.exactPrecondition == assertion.precondition
    else { throw SwiftDataMutationStateError.malformedReadAssertionRecord(key) }
}

private struct ActivationStateAccumulator {
    var known = [ResourceKey: ExactRecordPrecondition]()
    var currentRecords = [ResourceKey: AuthoritativeActivationRecordSnapshot]()
    var currentSentinel: AuthoritativeActivationSentinelSnapshot?

    mutating func append(_ record: LocalMirrorRecord, exact: ExactRecordPrecondition, key: ResourceKey, sentinelKey: ResourceKey) throws {
        if key == sentinelKey {
            guard currentSentinel == nil else { throw SwiftDataMutationStateError.duplicateResource(key) }
            currentSentinel = AuthoritativeActivationSentinelSnapshot(
                recordType: canonicalCloudRecordType(for: record.recordType), schemaVersion: record.schemaVersion, encodedRecord: record.payload ?? Data())
        }
        currentRecords[key] = AuthoritativeActivationRecordSnapshot(
            recordType: canonicalCloudRecordType(for: record.recordType), schemaVersion: record.schemaVersion, encodedRecord: record.payload ?? Data(),
            precondition: exact)
        guard known.updateValue(exact, forKey: record.resourceKey) == nil else { throw SwiftDataMutationStateError.duplicateResource(record.resourceKey) }
    }
}

/// Reconstructs exact base preconditions from the active scoped mirror. The
/// final CloudKit conditional save remains authoritative if the mirror changes
/// after this snapshot is read.
public struct SwiftDataAuthoritativeMutationStateProvider: AuthoritativeMutationStateProviding {
    private let persistence: SwiftDataPersistenceStore
    private let account: AccountContext

    public init(persistence: SwiftDataPersistenceStore, account: AccountContext) {
        self.persistence = persistence
        self.account = account
    }

    public func state(for mutation: AuthoritativeMutation) async throws -> AuthoritativeMutationState {
        guard mutation.workspaceZone == account.namespace.workspaceZone else {
            throw SwiftDataMutationStateError.workspaceMismatch
        }
        let assertionByKey = assertionsByKey(mutation.readAssertions)
        let stateKeys = try stateKeys(mutation.resourceKeys, assertions: assertionByKey, tooLarge: SwiftDataMutationStateError.mutationTooLarge)
        var known = [ResourceKey: ExactRecordPrecondition]()
        for resourceKey in stateKeys.sorted() {
            guard let record = try await persistence.storedLocalMirror(for: resourceKey, in: account.namespace) else {
                continue
            }
            if let assertion = assertionByKey[resourceKey] { try localRecord(record, matches: assertion, key: resourceKey) }
            guard let exact = record.exactPrecondition else { continue }
            guard known.updateValue(exact, forKey: record.resourceKey) == nil else {
                throw SwiftDataMutationStateError.duplicateResource(record.resourceKey)
            }
        }
        let current = try await persistence.workOrder(id: mutation.workOrder.id, namespace: account.namespace)
        return AuthoritativeMutationState(knownRecords: known, currentWorkOrder: current)
    }

    public func state(for mutation: AuthoritativeActivationMutation) async throws -> AuthoritativeActivationMutationState {
        guard mutation.workspaceZone == account.namespace.workspaceZone else {
            throw SwiftDataMutationStateError.workspaceMismatch
        }
        let assertionByKey = assertionsByKey(mutation.readAssertions)
        let stateKeys = try stateKeys(mutation.resourceKeys, assertions: assertionByKey, tooLarge: SwiftDataMutationStateError.mutationTooLarge)
        var accumulated = ActivationStateAccumulator()
        for resourceKey in stateKeys.sorted() {
            guard let (record, exact) = try await exactLocalRecord(for: resourceKey) else { continue }
            if let assertion = assertionByKey[resourceKey] { try localRecord(record, matches: assertion, key: resourceKey) }
            try accumulated.append(record, exact: exact, key: resourceKey, sentinelKey: mutation.bootstrapSentinelResourceKey)
        }
        return AuthoritativeActivationMutationState(
            knownRecords: accumulated.known,
            currentRecords: accumulated.currentRecords, currentSentinel: accumulated.currentSentinel)
    }

    private func exactLocalRecord(for resourceKey: ResourceKey) async throws -> (LocalMirrorRecord, ExactRecordPrecondition)? {
        guard let record = try await persistence.storedLocalMirror(for: resourceKey, in: account.namespace),
            let exact = record.exactPrecondition
        else { return nil }
        return (record, exact)
    }
}

private func canonicalCloudRecordType(for persistedType: String) -> String {
    switch persistedType {
    case LocalRecordKind.physicalTopology: "NettworkPhysicalTopology"
    case LocalRecordKind.workOrder: CloudRecordNaming.workOrderRecordType
    case LocalRecordKind.auditEvent: CloudRecordNaming.auditRecordType
    case LocalRecordKind.prefix: "NettworkPrefix"
    default: persistedType
    }
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
