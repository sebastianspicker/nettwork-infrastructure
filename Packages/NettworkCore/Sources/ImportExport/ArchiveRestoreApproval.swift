import ContentSafety
import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

public struct ArchiveRestoreApproval: Hashable, Sendable {
    private let bindingSHA256: String

    private init(bindingSHA256: String) {
        self.bindingSHA256 = bindingSHA256
    }

    static func issue(
        for archive: VerifiedArchive, authorization: AuthorizedOperationContext
    ) throws -> ArchiveRestoreApproval {
        try issue(
            manifest: archive.manifest, rootSHA256: archive.rootSHA256,
            authorization: authorization)
    }

    static func issue(
        for archive: FileBackedVerifiedArchive, authorization: AuthorizedOperationContext
    ) throws -> ArchiveRestoreApproval {
        try issue(
            manifest: archive.manifest, rootSHA256: archive.rootSHA256,
            authorization: authorization)
    }

    private static func issue(
        manifest: ArchiveManifest, rootSHA256: String,
        authorization: AuthorizedOperationContext
    ) throws -> ArchiveRestoreApproval {
        guard authorization.action == .restoreArchive else {
            throw ImportAuthorizationError.actionMismatch
        }
        let manifestCommitment = try ArchiveManifestCommitment.digest(for: manifest)
        let provenance = manifest.provenance
        let intent = try CanonicalActivationReceipt.intent(
            domain: "nettwork.archive-restore-approval.v1",
            namespace: authorization.account.namespace, operationID: authorization.operationID,
            fields: [
                authorization.action.rawValue, authorization.actor.cloudKitUserRecordName,
                authorization.actor.role.rawValue, authorization.actor.installationID,
                String(authorization.actor.sessionGeneration),
                String(authorization.capturedSessionGeneration), rootSHA256, manifestCommitment,
                provenance.workspaceID.description, provenance.containerIdentifier, provenance.zoneName,
                provenance.zoneOwnerRecordName,
            ])
        return ArchiveRestoreApproval(bindingSHA256: intent.hexadecimalString)
    }

    func matches(archive: VerifiedArchive, authorization: AuthorizedOperationContext) throws -> Bool {
        self == (try Self.issue(for: archive, authorization: authorization))
    }

    func matches(archive: FileBackedVerifiedArchive, authorization: AuthorizedOperationContext) throws -> Bool {
        self == (try Self.issue(for: archive, authorization: authorization))
    }
}

/// The reviewed archive and its unforgeable restore approval travel together
/// through UI and adapter layers. Callers can inspect the archive but cannot
/// mint or alter the approval.
public struct ArchiveRestorePreview: Sendable {
    public let archive: VerifiedArchive
    public let approval: ArchiveRestoreApproval

    init(archive: VerifiedArchive, approval: ArchiveRestoreApproval) {
        self.archive = archive
        self.approval = approval
    }
}

public struct FileBackedArchiveRestorePreview: Sendable {
    public let archive: FileBackedVerifiedArchive
    public let approval: ArchiveRestoreApproval

    init(archive: FileBackedVerifiedArchive, approval: ArchiveRestoreApproval) {
        self.archive = archive
        self.approval = approval
    }

    public func discardIfUnadopted() { archive.discardIfUnadopted() }
}

public enum ArchiveManifestRecordCounts {
    public static let knownKeys = Set(WorkspaceTransferRecordType.allCases.map(\.rawValue))

    public static func total(_ recordCounts: [String: Int]) throws -> Int {
        var total = 0
        for (key, count) in recordCounts {
            guard knownKeys.contains(key), count >= 0, count <= WorkspaceTransferLimits.maximumRows else {
                throw ArchiveValidationError.manifestMismatch
            }
            let (nextTotal, overflow) = total.addingReportingOverflow(count)
            guard !overflow, nextTotal <= WorkspaceTransferLimits.maximumRows else {
                throw ArchiveValidationError.manifestMismatch
            }
            total = nextTotal
        }
        return total
    }
}

public struct ArchiveExportInput: Sendable {
    public let recordCounts: [String: Int]
    public let recordsJSONL: Data
    public let auditJSONL: Data
    public let auditHeadSHA256: String
    /// Typed payload descriptors retain the original record asset identity.
    public let assets: [ArchiveAssetPayload]

    public init(recordCounts: [String: Int], recordsJSONL: Data, auditJSONL: Data, auditHeadSHA256: String, assets: [ArchiveAssetPayload] = []) {
        self.recordCounts = recordCounts
        self.recordsJSONL = recordsJSONL
        self.auditJSONL = auditJSONL
        self.auditHeadSHA256 = auditHeadSHA256
        self.assets = assets
    }
}

/// A document is handed to the platform archive writer one entry at a time.
/// This core module never asks an archive library to extract or write a tree.
public struct ArchiveExportDocument: Sendable {
    public let manifest: ArchiveManifest
    public let completionMarker: ArchiveCompletionMarker
    public let entries: [String: Data]
}

public protocol ArchiveExportSource: Sendable {
    func currentAccount() async throws -> AccountContext
    func snapshot(for namespace: PersistenceNamespace) async throws -> ArchiveExportInput
}
