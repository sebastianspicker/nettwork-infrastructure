import NetworkModel
import WorkspaceChangeControl

public protocol ArchiveRestoreActivationAuthority: Sendable {
    func currentAccount() async throws -> AccountContext
    func isFreshAuthenticatedTarget(
        in namespace: PersistenceNamespace
    ) async throws -> Bool
    func dryRun(
        _ archive: VerifiedArchive, for target: PersistenceNamespace
    ) async throws
    func activateStagedArchive(
        archive: VerifiedArchive, source: ArchiveSourceProvenance,
        target: PersistenceNamespace, expectedRootSHA256: String,
        operationID: ObjectID, expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt
}

public protocol FileBackedArchiveRestoreActivationAuthority:
    ArchiveRestoreActivationAuthority
{
    func dryRun(
        _ archive: FileBackedVerifiedArchive,
        for target: PersistenceNamespace
    ) async throws
    func activateStagedArchive(
        archive: FileBackedVerifiedArchive,
        source: ArchiveSourceProvenance, target: PersistenceNamespace,
        expectedRootSHA256: String, operationID: ObjectID,
        expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt
}
