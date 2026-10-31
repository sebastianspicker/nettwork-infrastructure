import CryptoKit
import Foundation
import WorkspaceChangeControl

/// Durable, per-account list of the workspace contexts this installation has
/// verified. It holds no secrets: only namespaces, scopes, permissions and
/// share record names. A damaged or foreign file throws and is left untouched.
struct CloudKitWorkspaceContextFile: Sendable {
    static let currentFormatVersion = 1
    static let maximumByteCount = 1_024 * 1_024

    struct Snapshot: Codable, Hashable, Sendable {
        let formatVersion: Int
        let accountRecordName: String
        let contexts: [AccountContext]
    }

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// One file per account; the name is a digest, so record names never become paths.
    func fileURL(accountRecordName: String) -> URL {
        let digest = SHA256.hash(data: Data(accountRecordName.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("workspace-contexts-\(digest).json", isDirectory: false)
    }

    /// Returns an empty list only when no file exists for the account.
    func contexts(accountRecordName: String) throws -> [AccountContext] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(accountRecordName: accountRecordName))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            throw CloudKitWorkspaceError.contextStoreReadFailed(error.localizedDescription)
        }
        guard data.count <= Self.maximumByteCount else { throw CloudKitWorkspaceError.contextStoreCorrupt }
        let snapshot: Snapshot
        do { snapshot = try JSONDecoder().decode(Snapshot.self, from: data) } catch { throw CloudKitWorkspaceError.contextStoreCorrupt }
        try validate(snapshot, accountRecordName: accountRecordName)
        return snapshot.contexts
    }

    func persist(_ contexts: [AccountContext], accountRecordName: String) throws {
        let snapshot = Snapshot(formatVersion: Self.currentFormatVersion, accountRecordName: accountRecordName, contexts: contexts)
        try validate(snapshot, accountRecordName: accountRecordName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try replace(fileURL(accountRecordName: accountRecordName), with: encoder.encode(snapshot))
        } catch {
            throw CloudKitWorkspaceError.contextStoreWriteFailed(error.localizedDescription)
        }
    }

    /// Writes a sibling temporary file and renames it over `url`, so readers see
    /// either the old or the new list. The temporary file never outlives the call.
    private func replace(_ url: URL, with data: Data) throws {
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).contexts.tmp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: [.withoutOverwriting])
        guard rename(staging.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// The file must name its account, contain only that account's contexts, and
    /// hold at most one context per namespace and scope.
    private func validate(_ snapshot: Snapshot, accountRecordName: String) throws {
        guard snapshot.formatVersion == Self.currentFormatVersion, snapshot.accountRecordName == accountRecordName else {
            throw CloudKitWorkspaceError.contextStoreCorrupt
        }
        var seen = Set<CloudKitWorkspaceContextKey>()
        for context in snapshot.contexts {
            guard context.namespace.cloudKitAccountRecordName == accountRecordName, seen.insert(CloudKitWorkspaceContextKey(context)).inserted else {
                throw CloudKitWorkspaceError.contextStoreCorrupt
            }
        }
    }
}

/// Identity of a persisted context: the namespace and database scope. Permission
/// and share record name are the values a refresh may change.
struct CloudKitWorkspaceContextKey: Hashable, Sendable {
    let namespace: PersistenceNamespace
    let databaseScope: CloudDatabaseScope

    init(_ context: AccountContext) {
        self.namespace = context.namespace
        self.databaseScope = context.databaseScope
    }
}
