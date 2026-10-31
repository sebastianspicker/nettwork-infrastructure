import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Durable Favorites and Recents, one small versioned JSON file per account
/// and workspace inside the workspace's private history directory.
///
/// - The key is account record name plus workspace ID; the session generation
///   is deliberately excluded so a renewed session keeps the user's history,
///   while another account or workspace never sees it.
/// - Only object IDs are stored (at most 50 recents and 500 favorites), so no
///   customer data leaves the mirror.
/// - Fail closed on a damaged file: the scope starts empty and the file is
///   left untouched. The first later write explicitly moves it aside to
///   `<name>.corrupt` before writing the new content.
/// - Write failures keep the in-memory state for the session and are reported
///   through `lastFailure()`; the next change retries the full write.
public actor PersistentInventoryHistoryStore: InventoryHistoryStoring {
    public static let maximumRecents = 50
    public static let maximumFavorites = 500

    private struct Key: Hashable {
        let accountRecordName: String
        let workspaceID: ObjectID

        init(_ scope: InventoryAccountScope) {
            accountRecordName = scope.accountRecordName
            workspaceID = scope.workspaceID
        }
    }

    private struct State {
        var recents: [ObjectID]
        var favorites: Set<ObjectID>
        var needsQuarantine: Bool
    }

    private let directory: URL
    private let writer: any LocalWorkspaceRecordStoreFileWriting
    private var states: [Key: State] = [:]
    private var failure: InventoryHistoryStoreError?

    public init(directory: URL, writer: any LocalWorkspaceRecordStoreFileWriting = AtomicLocalFileWriter()) {
        self.directory = directory
        self.writer = writer
    }

    /// The most recent load or write problem; nil after a successful write.
    public func lastFailure() -> InventoryHistoryStoreError? { failure }

    public nonisolated func historyFileURL(for scope: InventoryAccountScope) -> URL {
        let key = Key(scope)
        let digest = CloudRecordAssetDescriptor.sha256(for: Data("\(key.accountRecordName)\n\(key.workspaceID.description)".utf8))
        return directory.appendingPathComponent("inventory-history-\(digest).json", isDirectory: false)
    }

    public func recent(in scope: InventoryAccountScope) async -> [ObjectID] {
        state(for: scope).recents
    }

    public func favorites(in scope: InventoryAccountScope) async -> Set<ObjectID> {
        state(for: scope).favorites
    }

    public func recordRecent(_ id: ObjectID, in scope: InventoryAccountScope) async {
        var current = state(for: scope)
        current.recents.removeAll { $0 == id }
        current.recents.insert(id, at: 0)
        current.recents = Array(current.recents.prefix(Self.maximumRecents))
        save(current, for: scope)
    }

    public func toggleFavorite(_ id: ObjectID, in scope: InventoryAccountScope) async -> Set<ObjectID> {
        var current = state(for: scope)
        if current.favorites.contains(id) {
            current.favorites.remove(id)
        } else if current.favorites.count < Self.maximumFavorites {
            current.favorites.insert(id)
        } else {
            failure = .favoriteLimitReached(Self.maximumFavorites)
            return current.favorites
        }
        save(current, for: scope)
        return current.favorites
    }

    private func file(for scope: InventoryAccountScope) -> InventoryHistoryFile {
        InventoryHistoryFile(url: historyFileURL(for: scope), writer: writer)
    }

    private func state(for scope: InventoryAccountScope) -> State {
        let key = Key(scope)
        if let cached = states[key] { return cached }
        let loaded: State
        do {
            if let document = try file(for: scope).load() {
                loaded = Self.normalized(document)
            } else {
                loaded = State(recents: [], favorites: [], needsQuarantine: false)
            }
        } catch {
            failure = error as? InventoryHistoryStoreError ?? .readFailed(error.localizedDescription)
            loaded = State(recents: [], favorites: [], needsQuarantine: true)
        }
        states[key] = loaded
        return loaded
    }

    private func save(_ updated: State, for scope: InventoryAccountScope) {
        var pending = updated
        states[Key(scope)] = pending
        let document = InventoryHistoryDocument(
            formatVersion: InventoryHistoryDocument.currentFormatVersion, recents: pending.recents, favorites: pending.favorites.sorted())
        do {
            try file(for: scope).persist(document, quarantining: pending.needsQuarantine)
            pending.needsQuarantine = false
            states[Key(scope)] = pending
            failure = nil
        } catch {
            failure = error as? InventoryHistoryStoreError ?? .writeFailed(error.localizedDescription)
        }
    }

    /// Bounds and dedupes whatever a file contains (first occurrence wins).
    private static func normalized(_ document: InventoryHistoryDocument) -> State {
        var seen = Set<ObjectID>()
        let recents = document.recents.filter { seen.insert($0).inserted }.prefix(maximumRecents)
        let favorites = document.favorites.sorted().prefix(maximumFavorites)
        return State(recents: Array(recents), favorites: Set(favorites), needsQuarantine: false)
    }
}
