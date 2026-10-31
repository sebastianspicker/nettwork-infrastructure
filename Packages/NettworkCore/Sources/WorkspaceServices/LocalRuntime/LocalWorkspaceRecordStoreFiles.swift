import Foundation
import WorkspaceChangeControl

/// The single file-write step of the store, injectable so tests can simulate a
/// failed write. Implementations must replace `url` atomically or leave it untouched.
public protocol LocalWorkspaceRecordStoreFileWriting: Sendable {
    func writeAtomically(_ data: Data, to url: URL) throws
}

/// Writes to a temporary file in the destination directory, then atomically replaces the destination.
public struct AtomicLocalFileWriter: LocalWorkspaceRecordStoreFileWriting {
    public init() {}

    public func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            // Best-effort removal of this call's own temporary file; the write error below is what matters.
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

/// On-disk layout: `<directory>/store.plist` and `<directory>/assets/<sha256>`.
struct LocalWorkspaceRecordStoreFiles: Sendable {
    static let maximumSnapshotByteCount = 64 * 1_024 * 1_024
    static let snapshotFileName = "store.plist"
    static let assetDirectoryName = "assets"

    let directory: URL
    let writer: any LocalWorkspaceRecordStoreFileWriting

    private var snapshotURL: URL { directory.appendingPathComponent(Self.snapshotFileName, isDirectory: false) }
    private var assetDirectory: URL { directory.appendingPathComponent(Self.assetDirectoryName, isDirectory: true) }

    /// Returns nil only when no snapshot file exists; every other problem throws.
    func loadSnapshot() throws -> LocalWorkspaceRecordSnapshot? {
        let data: Data
        do {
            let size = try snapshotURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumSnapshotByteCount else { throw LocalWorkspaceRecordStoreError.snapshotTooLarge(byteCount: size) }
            data = try Data(contentsOf: snapshotURL)
        } catch let error as LocalWorkspaceRecordStoreError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw LocalWorkspaceRecordStoreError.readFailed(error.localizedDescription)
        }
        return try Self.decode(data)
    }

    func persist(_ snapshot: LocalWorkspaceRecordSnapshot) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do { data = try encoder.encode(snapshot) } catch { throw LocalWorkspaceRecordStoreError.writeFailed(error.localizedDescription) }
        guard data.count <= Self.maximumSnapshotByteCount else { throw LocalWorkspaceRecordStoreError.snapshotTooLarge(byteCount: data.count) }
        try write(data, to: snapshotURL)
    }

    /// Content-addressed, so rewriting is idempotent; the bytes are read back to verify their digest.
    func storeAsset(_ bytes: Data, sha256: String) throws {
        guard let url = assetURL(sha256: sha256) else { throw LocalWorkspaceRecordStoreError.assetIntegrityFailure(sha256: sha256) }
        do {
            try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        } catch { throw LocalWorkspaceRecordStoreError.writeFailed(error.localizedDescription) }
        try write(bytes, to: url)
        _ = try readAsset(sha256: sha256, byteCount: bytes.count)
    }

    func assetExists(sha256: String, byteCount: Int) throws -> Bool {
        guard let url = assetURL(sha256: sha256) else { throw LocalWorkspaceRecordStoreError.corruptSnapshot }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        do {
            return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == byteCount
        } catch { throw LocalWorkspaceRecordStoreError.readFailed(error.localizedDescription) }
    }

    func readAsset(sha256: String, byteCount: Int) throws -> Data {
        guard let url = assetURL(sha256: sha256) else { throw LocalWorkspaceRecordStoreError.assetIntegrityFailure(sha256: sha256) }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw LocalWorkspaceRecordStoreError.assetMissing(sha256: sha256)
        } catch {
            throw LocalWorkspaceRecordStoreError.readFailed(error.localizedDescription)
        }
        guard bytes.count == byteCount, CloudRecordAssetDescriptor.sha256(for: bytes) == sha256 else {
            throw LocalWorkspaceRecordStoreError.assetIntegrityFailure(sha256: sha256)
        }
        return bytes
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writer.writeAtomically(data, to: url)
        } catch let error as LocalWorkspaceRecordStoreError {
            throw error
        } catch {
            throw LocalWorkspaceRecordStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Digests become file names, so anything but 64 lowercase hex digits is rejected.
    private func assetURL(sha256: String) -> URL? {
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        return assetDirectory.appendingPathComponent(sha256, isDirectory: false)
    }

    private struct VersionHeader: Decodable { let formatVersion: Int }

    private static func decode(_ data: Data) throws -> LocalWorkspaceRecordSnapshot {
        let decoder = PropertyListDecoder()
        let header: VersionHeader
        do { header = try decoder.decode(VersionHeader.self, from: data) } catch { throw LocalWorkspaceRecordStoreError.corruptSnapshot }
        guard header.formatVersion == LocalWorkspaceRecordSnapshot.currentFormatVersion else {
            throw LocalWorkspaceRecordStoreError.unsupportedFormatVersion(header.formatVersion)
        }
        do { return try decoder.decode(LocalWorkspaceRecordSnapshot.self, from: data) } catch { throw LocalWorkspaceRecordStoreError.corruptSnapshot }
    }
}
