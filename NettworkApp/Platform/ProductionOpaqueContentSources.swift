import ContentSafety
import Foundation
import UniformTypeIdentifiers

enum ProductionContentSourceError: LocalizedError {
    case notRegularFile
    case unsupportedType
    case changedWhileReading
    case invalidChunkBound

    var errorDescription: String? {
        switch self {
        case .notRegularFile: "Choose a regular file, not a folder or link."
        case .unsupportedType: "Only JPEG, PNG, HEIC, HEIF, or PDF files can be used here."
        case .changedWhileReading: "The selected file changed or became unavailable while it was being read."
        case .invalidChunkBound: "The content reader was asked for an invalid chunk size."
        }
    }
}

extension ContentType {
    /// Maps a platform type to the content-safety allowlist; anything else is nil.
    init?(utType: UTType) {
        let allowlist: [(UTType, ContentType)] = [
            (.jpeg, .jpeg), (.png, .png), (.heic, .heic), (.heif, .heif), (.pdf, .pdf),
        ]
        guard let match = allowlist.first(where: { utType.conforms(to: $0.0) }) else { return nil }
        self = match.1
    }
}

/// An opaque source over one user-picked regular file. The URL never leaves
/// this type: callers see only a random identifier, the declared size and type.
final class ProductionFileContentSource: OpaqueContentSource, @unchecked Sendable {
    let sourceID = UUID().uuidString
    private let url: URL
    private let declared: UntrustedContentMetadata
    private let lifetime: SecurityScopedPackageAccess
    private let chunkSize: Int

    init(url: URL, chunkSize: Int = 64 * 1_024) throws {
        guard url.isFileURL, (1...64 * 1_024).contains(chunkSize) else {
            throw ProductionContentSourceError.notRegularFile
        }
        let didStartAccess = url.startAccessingSecurityScopedResource()
        do {
            let values = try Self.regularFileValues(url)
            guard let type = values.contentType ?? UTType(filenameExtension: url.pathExtension),
                let contentType = ContentType(utType: type)
            else { throw ProductionContentSourceError.unsupportedType }
            declared = UntrustedContentMetadata(byteCount: values.fileSize ?? 0, declaredType: contentType)
            self.url = url.standardizedFileURL
            self.chunkSize = chunkSize
            lifetime = SecurityScopedPackageAccess(url: url, didStartAccess: didStartAccess)
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    deinit { lifetime.close() }

    func close() { lifetime.close() }

    func metadata() throws -> UntrustedContentMetadata {
        try lifetime.requireOpen()
        return declared
    }

    func makeReader() throws -> any OpaqueContentByteReader {
        try lifetime.requireOpen()
        let values = try Self.regularFileValues(url)
        guard values.fileSize == declared.byteCount else { throw ProductionContentSourceError.changedWhileReading }
        let reader = try ProductionArchivePackageEntryReader(
            url: url, expectedSize: declared.byteCount, chunkSize: chunkSize)
        return ProductionFileContentReader(reader: reader, lifetime: lifetime)
    }

    private static func regularFileValues(_ url: URL) throws -> URLResourceValues {
        // URLs cache resource values; re-reading must observe the file as it is now.
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize != nil else {
            throw ProductionContentSourceError.notRegularFile
        }
        return values
    }
}

/// Streams the opened file in bounded chunks and fails if it yields more or
/// fewer bytes than were declared.
private struct ProductionFileContentReader: OpaqueContentByteReader {
    let reader: ProductionArchivePackageEntryReader
    let lifetime: SecurityScopedPackageAccess

    mutating func nextChunk(maximumBytes: Int) throws -> Data? {
        guard maximumBytes > 0 else { throw ProductionContentSourceError.invalidChunkBound }
        do {
            try lifetime.requireOpen()
            return try reader.nextChunk(maximumBytes: maximumBytes)
        } catch is ProductionArchiveDocumentAdapterError {
            throw ProductionContentSourceError.changedWhileReading
        }
    }
}

/// An opaque source over bytes the app already loaded, such as a picked photo.
struct ProductionDataContentSource: OpaqueContentSource {
    let sourceID = UUID().uuidString
    private let data: Data
    private let declaredType: ContentType

    init(data: Data, declaredType: ContentType) {
        self.data = data
        self.declaredType = declaredType
    }

    func metadata() throws -> UntrustedContentMetadata {
        UntrustedContentMetadata(byteCount: data.count, declaredType: declaredType)
    }

    func makeReader() throws -> any OpaqueContentByteReader {
        ProductionDataContentReader(data: data)
    }
}

private struct ProductionDataContentReader: OpaqueContentByteReader {
    let data: Data
    private var offset = 0

    init(data: Data) { self.data = data }

    mutating func nextChunk(maximumBytes: Int) throws -> Data? {
        guard maximumBytes > 0 else { throw ProductionContentSourceError.invalidChunkBound }
        guard offset < data.count else { return nil }
        let end = min(data.count, offset + maximumBytes)
        defer { offset = end }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))
    }
}
