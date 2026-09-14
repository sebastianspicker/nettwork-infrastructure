import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

public enum CloudAuthoritativeCommitError: Error, Hashable, Sendable {
    case returnedReceiptMismatch
    case reconciliationRequired(ReconciliationCase)
    case retryable(SyncFailure)
    case permanent(SyncFailure)
}

/// Online implementation of the domain's only privileged write boundary. It
/// validates against a freshly supplied candidate state, encodes one atomic
/// conditional same-zone mutation, and returns only CloudKit's verified receipt.
/// Offline execution remains a separate durable ExecutionEnvelope/outbox path.
public actor CloudAuthoritativeMutationRepository: AuthoritativeMutationRepository {
    private let transport: any CloudRecordTransport
    private let stateProvider: any AuthoritativeMutationStateProviding
    private let receiptLookup: (any CloudReceiptLookupTransport)?
    private let exactRecordReader: (any CloudExactRecordReading)?

    public init(
        transport: any CloudRecordTransport, stateProvider: any AuthoritativeMutationStateProviding,
        receiptLookup: (any CloudReceiptLookupTransport)? = nil,
        exactRecordReader: (any CloudExactRecordReading)? = nil
    ) {
        self.transport = transport
        self.stateProvider = stateProvider
        self.receiptLookup = receiptLookup ?? (transport as? any CloudReceiptLookupTransport)
        self.exactRecordReader = exactRecordReader ?? (transport as? any CloudExactRecordReading)
    }

    public func commit(_ mutation: AuthoritativeMutation) async throws -> OperationReceipt {
        try await commit(
            expected: mutation.receipt, operationID: mutation.operationID,
            workspaceZone: mutation.workspaceZone, resourceKeys: mutation.resourceKeys,
            readAssertionKeys: mutation.readAssertions.map(\.resourceKey),
            conflictMessage: "CloudKit returned a conflict outside the submitted mutation scope."
        ) {
            let state = try await self.stateProvider.state(for: mutation)
            try AuthoritativeMutationValidator.validate(mutation, against: state)
            return try CloudMutationEncoder.encode(mutation, against: state)
        }
    }

    public func commit(_ mutation: AuthoritativeActivationMutation) async throws -> OperationReceipt {
        try await commit(
            expected: mutation.receipt, operationID: mutation.operationID,
            workspaceZone: mutation.workspaceZone, resourceKeys: mutation.resourceKeys,
            readAssertionKeys: mutation.readAssertions.map(\.resourceKey),
            conflictMessage: "CloudKit returned a conflict outside the submitted activation scope."
        ) {
            let state = try await self.stateProvider.state(for: mutation)
            try AuthoritativeActivationMutationValidator.validate(mutation, against: state)
            try CloudStagedTransferFinalActivationContract.validate(mutation)
            return try CloudActivationMutationEncoder.encode(mutation, against: state)
        }
    }

    private func commit(
        expected: OperationReceipt, operationID: ObjectID, workspaceZone: AuthoritativeWorkspaceZone, resourceKeys: Set<ResourceKey>,
        readAssertionKeys: [ResourceKey], conflictMessage: String,
        prepare: () async throws -> AtomicCloudMutation
    ) async throws -> OperationReceipt {
        if let receipt = try await recoveredReceipt(expected: expected, operationID: operationID, workspaceZone: workspaceZone) { return receipt }
        let result = try await savePrepared(prepare, expected: expected, operationID: operationID, workspaceZone: workspaceZone)
        return try await resolved(
            result, expected: expected, operationID: operationID, workspaceZone: workspaceZone, resourceKeys: resourceKeys,
            readAssertionKeys: readAssertionKeys, conflictMessage: conflictMessage)
    }

    private func savePrepared(
        _ prepare: () async throws -> AtomicCloudMutation, expected: OperationReceipt, operationID: ObjectID, workspaceZone: AuthoritativeWorkspaceZone
    ) async throws -> CloudSaveResult {
        do { return try await transport.saveAtomically(try await prepare()) } catch let failure as CloudTransportFailure where failure.possiblyCommitted {
            if let receipt = try await recoveredReceipt(expected: expected, operationID: operationID, workspaceZone: workspaceZone) {
                return .accepted(receipt: receipt)
            }
            throw failure
        }
    }

    private func resolved(
        _ result: CloudSaveResult, expected: OperationReceipt, operationID: ObjectID, workspaceZone: AuthoritativeWorkspaceZone, resourceKeys: Set<ResourceKey>,
        readAssertionKeys: [ResourceKey],
        conflictMessage: String
    ) async throws -> OperationReceipt {
        switch result {
        case let .accepted(receipt):
            guard receipt == expected else { throw CloudAuthoritativeCommitError.returnedReceiptMismatch }
            return receipt
        case let .conflict(reconciliation):
            if let receipt = try await recoveredReceipt(expected: expected, operationID: operationID, workspaceZone: workspaceZone) { return receipt }
            try validate(
                reconciliation, operationID: operationID, workspaceZone: workspaceZone, resourceKeys: resourceKeys, readAssertionKeys: readAssertionKeys,
                message: conflictMessage)
            throw CloudAuthoritativeCommitError.reconciliationRequired(reconciliation)
        case let .retryableFailure(failure):
            if let receipt = try await recoveredReceipt(expected: expected, operationID: operationID, workspaceZone: workspaceZone) { return receipt }
            throw CloudAuthoritativeCommitError.retryable(failure)
        case let .permanentFailure(failure): throw CloudAuthoritativeCommitError.permanent(failure)
        }
    }

    private func validate(
        _ reconciliation: ReconciliationCase, operationID: ObjectID, workspaceZone: AuthoritativeWorkspaceZone, resourceKeys: Set<ResourceKey>,
        readAssertionKeys: [ResourceKey], message: String
    ) throws {
        guard reconciliation.operationID == operationID, reconciliation.namespace.workspaceZone == workspaceZone,
            reconciliation.resourceKeys == resourceKeys.union(readAssertionKeys)
        else {
            throw CloudAuthoritativeCommitError.permanent(SyncFailure(category: .security, message: message, resourceKeys: resourceKeys))
        }
    }

    /// A deterministic operation receipt is the only durable proof that a
    /// lost response committed the whole atomic mutation. Check it before a
    /// retry and after an indeterminate response; a different receipt fails
    /// closed rather than authorizing a second activation attempt.
    private func recoveredReceipt(
        expected: OperationReceipt, operationID: ObjectID,
        workspaceZone: AuthoritativeWorkspaceZone
    ) async throws -> OperationReceipt? {
        if let receiptLookup {
            let observed = try await receiptLookup.receipt(operationID: operationID, in: workspaceZone)
            if let receipt = try resolvedReceipt(expected: expected, observed: observed) { return receipt }
        }
        return try await recoveredExactReceipt(expected: expected, workspaceZone: workspaceZone)
    }

    private func resolvedReceipt(expected: OperationReceipt, observed: OperationReceipt?) throws -> OperationReceipt? {
        switch LostReceiptRecovery.resolve(expected: expected, observed: observed) {
        case let .accepted(receipt): return receipt
        case .retry: return nil
        case .securityMismatch: throw CloudAuthoritativeCommitError.returnedReceiptMismatch
        }
    }

    private func recoveredExactReceipt(expected: OperationReceipt, workspaceZone: AuthoritativeWorkspaceZone) async throws -> OperationReceipt? {
        guard let exactRecordReader,
            let snapshot = try await exactRecordReader.exactRecord(
                for: expected.id,
                in: workspaceZone)
        else {
            return nil
        }
        guard snapshot.workspaceZone == workspaceZone, snapshot.resourceKey == expected.id,
            snapshot.recordType == CloudRecordNaming.receiptRecordType,
            snapshot.schemaVersion == CloudRecordNaming.schemaVersion,
            let receipt = try? CloudDeterministicCoding.decode(
                OperationReceipt.self,
                from: snapshot.payload)
        else {
            throw CloudAuthoritativeCommitError.returnedReceiptMismatch
        }
        return try resolvedReceipt(expected: expected, observed: receipt)
    }
}
