import ContentSafety
import CryptoKit
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import WorkspaceChangeControl

protocol ImportStagingGenerationProviding: Sendable {
    func generation(for operationID: ObjectID, in namespace: PersistenceNamespace) async throws -> UInt64
}

/// Stable for one authorized operation and namespace, including the active
/// session generation. A process restart therefore reopens the same private
/// staging sidecar, while an account/session switch derives a different value.
struct DeterministicImportStagingGenerationProvider: ImportStagingGenerationProviding {
    func generation(for operationID: ObjectID, in namespace: PersistenceNamespace) async throws -> UInt64 {
        let material = [
            "nettwork.import-staging-generation.v1",
            operationID.description,
            namespace.containerIdentifier,
            namespace.cloudKitAccountRecordName,
            namespace.workspaceID.description,
            namespace.zoneName,
            namespace.zoneOwnerRecordName,
            String(namespace.sessionGeneration),
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
        let value = digest.prefix(MemoryLayout<UInt64>.size).reduce(UInt64.zero) {
            ($0 << 8) | UInt64($1)
        }
        return max(1, value)
    }
}

protocol TransferCurrentAccountProviding: Sendable {
    func currentAccount() async throws -> AccountContext
}

/// Composes the authorized core services used by the transfer UI. Every
/// activation re-decodes the original typed document, so the approved plan
/// remains bound to the exact canonical records that are eventually staged.
@MainActor
struct ProductionTransferFeatureService: TransferFeatureService {
    private let stagingGeneration: any ImportStagingGenerationProviding
    private let currentAccount: any TransferCurrentAccountProviding
    private let csvImport: AuthorizedCSVImportService
    private let archiveExport: AuthorizedArchiveExportService
    private let archiveRestore: AuthorizedArchiveRestoreService
    private let archiveVerifier: ArchiveVerifier
    private let archiveVerificationStagingRoot: URL
    private let operationBoundary: ProductionOperationBoundary

    init(
        stagingGeneration: any ImportStagingGenerationProviding,
        currentAccount: any TransferCurrentAccountProviding,
        csvImport: AuthorizedCSVImportService,
        archiveExport: AuthorizedArchiveExportService,
        archiveRestore: AuthorizedArchiveRestoreService,
        archiveVerifier: ArchiveVerifier = .init(),
        archiveVerificationStagingRoot: URL,
        operationBoundary: ProductionOperationBoundary
    ) {
        self.stagingGeneration = stagingGeneration
        self.currentAccount = currentAccount
        self.csvImport = csvImport
        self.archiveExport = archiveExport
        self.archiveRestore = archiveRestore
        self.archiveVerifier = archiveVerifier
        self.archiveVerificationStagingRoot = archiveVerificationStagingRoot
        self.operationBoundary = operationBoundary
    }

    func dryRunCSV(_ source: any CSVImportSource, authorization: AuthorizedOperationContext) async throws -> ImportPlan {
        let stagingGeneration = stagingGeneration
        let csvImport = csvImport
        return try await operationBoundary.perform(.workspaceImport) {
            let records = try await Self.decodeRecords(from: source)
            let generation = try await stagingGeneration.generation(for: authorization.operationID, in: authorization.account.namespace)
            return try await csvImport.makePlan(records: records, context: authorization, stagingGeneration: generation)
        }
    }

    func activateCSV(_ plan: ImportPlan, source: any CSVImportSource, authorization: AuthorizedOperationContext) async throws {
        let csvImport = csvImport
        _ = try await operationBoundary.perform(.workspaceImport) {
            let records = try await Self.decodeRecords(from: source)
            return try await csvImport.execute(plan: plan, records: records, context: authorization)
        }
    }

    func exportArchive(authorization: AuthorizedOperationContext) async throws -> ArchiveExportDocument {
        let archiveExport = archiveExport
        return try await operationBoundary.perform(.workspaceExport) {
            try await archiveExport.makeDocument(context: authorization)
        }
    }

    func verifyArchive(
        _ source: any ArchiveEntrySource, authorization: AuthorizedOperationContext
    ) async throws -> FileBackedArchiveRestorePreview {
        let currentAccount = currentAccount
        let archiveVerifier = archiveVerifier
        let stagingRoot = archiveVerificationStagingRoot
        return try await operationBoundary.perform(.workspaceImport) {
            try await Self.authorizeArchiveRestorePreflight(authorization, currentAccount: currentAccount)
            let preview = try await Task.detached(priority: .userInitiated) {
                try archiveVerifier.verifyFileBackedForRestore(
                    source: source, stagingRoot: stagingRoot,
                    authorization: authorization)
            }.value
            do {
                try await Self.authorizeArchiveRestorePreflight(
                    authorization, currentAccount: currentAccount)
                return preview
            } catch {
                preview.discardIfUnadopted()
                throw error
            }
        }
    }

    func restoreArchive(
        _ archive: FileBackedVerifiedArchive, approval: ArchiveRestoreApproval,
        authorization: AuthorizedOperationContext
    ) async throws {
        let archiveRestore = archiveRestore
        _ = try await operationBoundary.perform(.workspaceImport) {
            try await archiveRestore.restore(
                archive: archive, approval: approval, context: authorization)
        }
    }

    nonisolated private static func authorizeArchiveRestorePreflight(
        _ authorization: AuthorizedOperationContext, currentAccount: any TransferCurrentAccountProviding
    ) async throws {
        guard authorization.action == .restoreArchive else {
            throw ImportAuthorizationError.actionMismatch
        }
        guard authorization.actor.role == .administrator else {
            throw ImportAuthorizationError.administratorRequired
        }
        guard authorization.account.sharePermission == .owner || authorization.account.sharePermission == .readWrite else {
            throw ImportAuthorizationError.writePermissionRequired
        }
        guard authorization.validateCurrent(account: try await currentAccount.currentAccount()) else {
            throw ImportAuthorizationError.staleContext
        }
    }

    nonisolated private static func decodeRecords(from source: any CSVImportSource) async throws -> [ImportRecord] {
        return try await Task.detached(priority: .userInitiated) {
            try CSVImportBatchDecoder.records(source: source)
        }.value
    }
}
