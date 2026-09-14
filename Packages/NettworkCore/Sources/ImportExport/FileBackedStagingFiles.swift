import Foundation
import NetworkModel
import WorkspaceChangeControl

enum FileBackedStagingFiles {
    static func ensureNewPrivateDirectory(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw FileBackedStagingError.invalidRoot }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try applyPrivateAttributes(to: url)
    }

    static func ensurePrivateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try validateDirectory(url)
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try applyPrivateAttributes(to: url)
    }

    static func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw FileBackedStagingError.invalidRoot }
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try applyPrivateAttributes(to: url, permissions: 0o600)
    }

    static func readPrivate(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else { throw FileBackedStagingError.invalidArchiveEntry }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
            size >= 0, size <= maximumBytes
        else {
            throw FileBackedStagingError.invalidArchiveEntry
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == size, data.count <= maximumBytes else {
            throw FileBackedStagingError.invalidArchiveEntry
        }
        return data
    }

    static func readCanonicalSidecar<T: Codable>(
        _ url: URL, as type: T.Type
    ) throws -> (value: T, data: Data) {
        let data = try readPrivate(url, maximumBytes: 1_048_576)
        do {
            return (try WorkspaceTransferCoding.decode(type, from: data), data)
        } catch {
            throw FileBackedStagingError.stagedPayloadMismatch
        }
    }

    static func loadCanonicalSidecar<T: Codable>(
        root: URL, handle: ImportStagingHandle, as type: T.Type
    ) throws -> (directory: URL, value: T, data: Data) {
        let directory = root.appendingPathComponent(handle.id.description, isDirectory: true)
        try validateDirectory(directory)
        let loaded = try readCanonicalSidecar(
            directory.appendingPathComponent("staging.json", isDirectory: false), as: type)
        return (directory, loaded.value, loaded.data)
    }

    private static func applyPrivateAttributes(to url: URL, permissions: Int = 0o700) throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }
}
