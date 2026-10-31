import Foundation
import NetworkModel

/// Typed failures of the durable Favorites and Recents file. A failed load
/// never aborts the app: the affected scope starts empty and the failure is
/// reported through `PersistentInventoryHistoryStore.lastFailure()`.
public enum InventoryHistoryStoreError: Error, Equatable, Sendable {
    case corruptHistory
    case unsupportedFormatVersion(Int)
    case historyTooLarge(byteCount: Int)
    case readFailed(String)
    case writeFailed(String)
    case favoriteLimitReached(Int)
}

/// Versioned JSON content of one history file: object IDs only.
struct InventoryHistoryDocument: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let recents: [ObjectID]
    let favorites: [ObjectID]
}

/// File access of one scope's history. Reads are bounded and strictly
/// validated; writes replace the file atomically through the injected writer.
struct InventoryHistoryFile: Sendable {
    static let maximumByteCount = 256 * 1_024
    static let quarantineExtension = "corrupt"

    let url: URL
    let writer: any LocalWorkspaceRecordStoreFileWriting

    /// Returns nil only when no file exists; every other problem throws.
    func load() throws -> InventoryHistoryDocument? {
        let data: Data
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumByteCount else { throw InventoryHistoryStoreError.historyTooLarge(byteCount: size) }
            data = try Data(contentsOf: url)
        } catch let error as InventoryHistoryStoreError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw InventoryHistoryStoreError.readFailed(error.localizedDescription)
        }
        return try Self.decode(data)
    }

    /// With `quarantining`, an existing (unreadable) file is first moved to
    /// `<name>.corrupt` so the new content never silently overwrites it.
    func persist(_ document: InventoryHistoryDocument, quarantining: Bool) throws {
        do {
            let data = try JSONEncoder().encode(document)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
            if quarantining { try moveAsideExistingFile() }
            try writer.writeAtomically(data, to: url)
        } catch {
            throw InventoryHistoryStoreError.writeFailed(error.localizedDescription)
        }
    }

    private func moveAsideExistingFile() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        let quarantine = url.appendingPathExtension(Self.quarantineExtension)
        if manager.fileExists(atPath: quarantine.path) { try manager.removeItem(at: quarantine) }
        try manager.moveItem(at: url, to: quarantine)
    }

    private struct VersionHeader: Decodable { let formatVersion: Int }

    private static func decode(_ data: Data) throws -> InventoryHistoryDocument {
        let decoder = JSONDecoder()
        let header: VersionHeader
        do { header = try decoder.decode(VersionHeader.self, from: data) } catch { throw InventoryHistoryStoreError.corruptHistory }
        guard header.formatVersion == InventoryHistoryDocument.currentFormatVersion else {
            throw InventoryHistoryStoreError.unsupportedFormatVersion(header.formatVersion)
        }
        do { return try decoder.decode(InventoryHistoryDocument.self, from: data) } catch { throw InventoryHistoryStoreError.corruptHistory }
    }
}
