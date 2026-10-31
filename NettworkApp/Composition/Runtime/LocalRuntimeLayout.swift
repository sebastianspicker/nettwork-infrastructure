import Foundation
import NetworkModel

/// Typed failures of the local runtime provider and its peripheral seams.
enum LocalRuntimeProviderError: LocalizedError, Equatable {
    case applicationSupportUnavailable(String)
    case directoryUnavailable(String)
    case sharingUnavailable
    case correctiveResolutionUnavailable
    case auditDestinationUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable(let reason):
            "The local runtime cannot locate Application Support: \(reason)"
        case .directoryUnavailable(let reason):
            "The local runtime directory could not be prepared: \(reason)"
        case .sharingUnavailable:
            "Sharing is not available in the local runtime."
        case .correctiveResolutionUnavailable:
            "Corrective resolutions are unavailable in the local runtime."
        case .auditDestinationUnavailable:
            "The local runtime could not reserve a new audit export file."
        }
    }
}

/// Versioned on-disk layout of the local runtime below `root` (Application
/// Support `Nettwork/LocalRuntime/v1/` in production):
/// `identity.json`, `workspaces/<workspaceID>/server/` (authoritative record
/// store), `workspaces/<workspaceID>/mirror.store` (SwiftData mirror),
/// `workspaces/<workspaceID>/history/` (Favorites and Recents),
/// `workspaces/<workspaceID>/drafts/` (staged work-order drafts),
/// `attachments/`, `staging/{attachments,csv,restore}/`, `audit/` (private
/// audit staging) and `exports/audit/` (published audit exports).
struct LocalRuntimeLayout: Hashable, Sendable {
    static let relativeRootPath = "Nettwork/LocalRuntime/v1"

    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    static func applicationSupport(fileManager: FileManager = .default) throws -> LocalRuntimeLayout {
        do {
            let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return LocalRuntimeLayout(root: base.appendingPathComponent(relativeRootPath, isDirectory: true))
        } catch {
            throw LocalRuntimeProviderError.applicationSupportUnavailable(error.localizedDescription)
        }
    }

    /// `identity.json` lives directly in the root.
    var identityDirectory: URL { root }
    var attachmentDirectory: URL { directory("attachments") }
    var attachmentStagingDirectory: URL { directory("staging/attachments") }
    var csvStagingDirectory: URL { directory("staging/csv") }
    var archiveRestoreStagingDirectory: URL { directory("staging/restore") }
    var auditPrivateDirectory: URL { directory("audit") }
    var auditExportDirectory: URL { directory("exports/audit") }

    func workspaceDirectory(for workspaceID: ObjectID) -> URL { directory("workspaces/\(workspaceID.description)") }
    func serverDirectory(for workspaceID: ObjectID) -> URL {
        workspaceDirectory(for: workspaceID).appendingPathComponent("server", isDirectory: true)
    }
    func historyDirectory(for workspaceID: ObjectID) -> URL {
        workspaceDirectory(for: workspaceID).appendingPathComponent("history", isDirectory: true)
    }
    func mirrorStoreURL(for workspaceID: ObjectID) -> URL {
        workspaceDirectory(for: workspaceID).appendingPathComponent("mirror.store", isDirectory: false)
    }
    func draftsDirectory(for workspaceID: ObjectID) -> URL {
        workspaceDirectory(for: workspaceID).appendingPathComponent("drafts", isDirectory: true)
    }

    /// Creates the root before the identity is read or written.
    func prepareRoot() throws {
        try Self.preparePrivateDirectory(root)
    }

    /// Creates every private directory of one workspace's layout.
    func prepareWorkspace(_ workspaceID: ObjectID) throws {
        let directories = [
            workspaceDirectory(for: workspaceID), serverDirectory(for: workspaceID), historyDirectory(for: workspaceID),
            draftsDirectory(for: workspaceID), attachmentDirectory, attachmentStagingDirectory, csvStagingDirectory,
            archiveRestoreStagingDirectory, auditPrivateDirectory, auditExportDirectory,
        ]
        for directory in directories { try Self.preparePrivateDirectory(directory) }
    }

    /// Owner-only directories; on iOS new files inherit
    /// `completeUntilFirstUserAuthentication`, so the store stays readable
    /// after the first unlock while the device is locked again.
    static func preparePrivateDirectory(_ url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: 0o700)]
        #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        } catch {
            throw LocalRuntimeProviderError.directoryUnavailable(error.localizedDescription)
        }
    }

    private func directory(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: true)
    }
}
