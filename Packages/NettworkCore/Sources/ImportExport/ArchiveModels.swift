import ContentSafety
import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum ArchiveLayout: String, Codable, Sendable {
    case nettworkarchive
    public static let manifestPath = "manifest.json", recordsPath = "records.jsonl", auditPath = "audit.jsonl", assetsDirectory = "assets",
        completionPath = "complete.json"
}

public struct ArchiveCompatibility: Codable, Hashable, Sendable {
    public let archiveFormat: String, minimumReaderVersion: Int, maximumReaderVersion: Int
    public init(archiveFormat: String = ArchiveLayout.nettworkarchive.rawValue, minimumReaderVersion: Int = 4, maximumReaderVersion: Int = 4) {
        self.archiveFormat = archiveFormat
        self.minimumReaderVersion = minimumReaderVersion
        self.maximumReaderVersion = maximumReaderVersion
    }
    public func supports(readerVersion: Int) -> Bool {
        archiveFormat == ArchiveLayout.nettworkarchive.rawValue && minimumReaderVersion <= maximumReaderVersion
            && (minimumReaderVersion...maximumReaderVersion).contains(readerVersion)
    }
}

public struct ArchiveSourceProvenance: Codable, Hashable, Sendable {
    public let workspaceID: ObjectID, containerIdentifier: String, zoneName: String, zoneOwnerRecordName: String
    public init(workspaceID: ObjectID, containerIdentifier: String, zoneName: String, zoneOwnerRecordName: String) {
        self.workspaceID = workspaceID
        self.containerIdentifier = containerIdentifier
        self.zoneName = zoneName
        self.zoneOwnerRecordName = zoneOwnerRecordName
    }
}

public struct ArchiveAsset: Codable, Hashable, Sendable, Identifiable {
    /// `stableID` commits to the normalized archive-relative path. An explicit
    /// `id` retains the authoritative source asset identity.
    public let id: ObjectID
    public let stableID: String
    public let relativePath: String
    public let contentType: String
    public let byteCount: Int
    public let sha256: String
    public var size: Int { byteCount }

    public init(
        id: ObjectID? = nil, relativePath: String, sha256: String, size: Int = 0,
        contentType: String? = nil, stableID: String? = nil
    ) {
        let identity = Self.identity(id: id, stableID: stableID, relativePath: relativePath)
        self.id = identity.id
        self.stableID = identity.stableID
        self.relativePath = relativePath
        self.contentType = contentType ?? Self.contentType(for: relativePath)
        byteCount = size
        self.sha256 = sha256
    }

    private static func identity(id: ObjectID?, stableID: String?, relativePath: String) -> (id: ObjectID, stableID: String) {
        let derivedStableID = stableID ?? Self.stableID(for: relativePath)
        return (id ?? Self.objectID(for: derivedStableID), derivedStableID)
    }

    public init(
        id: ObjectID? = nil, relativePath: String, sha256: String, byteCount: Int,
        contentType: String? = nil, stableID: String? = nil
    ) {
        self.init(id: id, relativePath: relativePath, sha256: sha256, size: byteCount, contentType: contentType, stableID: stableID)
    }

    public static func stableID(for relativePath: String) -> String {
        HexDigest.string(SHA256.hash(data: Data("nettwork.archive-asset-id.v1\\0\(relativePath)".utf8)))
    }

    public static func contentType(for relativePath: String) -> String {
        switch relativePath.split(separator: ".").last?.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    static func objectID(for stableID: String) -> ObjectID {
        let hex = String(stableID.prefix(32))
        let value =
            "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        guard let uuid = UUID(uuidString: value) else {
            preconditionFailure("A stable archive identifier must contain 32 hexadecimal characters.")
        }
        return ObjectID(uuid)
    }
}

/// One verified binary payload and its original authoritative descriptor. The
/// archive writer carries this typed value until it has committed the exact
/// metadata and content digest into the manifest; asset identity is never
/// regenerated from the archive path.
public struct ArchiveAssetPayload: Sendable {
    public let id: ObjectID
    public let stableID: String
    public let relativePath: String
    public let contentType: String
    public let bytes: Data

    public init(id: ObjectID, stableID: String, relativePath: String, contentType: String, bytes: Data) {
        self.id = id
        self.stableID = stableID
        self.relativePath = relativePath
        self.contentType = contentType
        self.bytes = bytes
    }
}

public struct ArchiveManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 4
    public let schemaVersion: Int, workspaceID: ObjectID, createdAt: Date, recordCounts: [String: Int], assets: [ArchiveAsset], auditRecordCount: Int
    public let provenance: ArchiveSourceProvenance, compatibility: ArchiveCompatibility, recordsSHA256: String, auditSHA256: String, auditHeadSHA256: String,
        rootSHA256: String
    public init(
        schemaVersion: Int = currentSchemaVersion, workspaceID: ObjectID, createdAt: Date = .now, recordCounts: [String: Int], assets: [ArchiveAsset] = [],
        auditRecordCount: Int,
        provenance: ArchiveSourceProvenance? = nil, compatibility: ArchiveCompatibility = .init(), recordsSHA256: String = "", auditSHA256: String = "",
        auditHeadSHA256: String = "", rootSHA256: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.workspaceID = workspaceID
        self.createdAt = createdAt
        self.recordCounts = recordCounts
        self.assets = assets
        self.auditRecordCount = auditRecordCount
        self.provenance = provenance ?? ArchiveSourceProvenance(workspaceID: workspaceID, containerIdentifier: "", zoneName: "", zoneOwnerRecordName: "")
        self.compatibility = compatibility
        self.recordsSHA256 = recordsSHA256
        self.auditSHA256 = auditSHA256
        self.auditHeadSHA256 = auditHeadSHA256
        self.rootSHA256 = rootSHA256
    }
}

public struct ArchiveCompletionMarker: Codable, Hashable, Sendable {
    public let schemaVersion: Int, rootSHA256: String, manifestCommitmentSHA256: String, completedAt: Date
    public init(schemaVersion: Int = ArchiveManifest.currentSchemaVersion, rootSHA256: String, manifestCommitmentSHA256: String, completedAt: Date = .now) {
        self.schemaVersion = schemaVersion
        self.rootSHA256 = rootSHA256
        self.manifestCommitmentSHA256 = manifestCommitmentSHA256
        self.completedAt = completedAt
    }
}

/// Commits the complete canonical manifest into the separate completion marker.
/// The marker is deliberately excluded from this material, avoiding a
/// self-referential digest while binding provenance and all manifest metadata.
public enum ArchiveManifestCommitment {
    private static let domain = Data("nettwork.archive-manifest-commitment.v1\\0".utf8)

    public static func digest(for manifest: ArchiveManifest) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return HexDigest.string(SHA256.hash(data: domain + (try encoder.encode(manifest))))
    }
}

public enum ArchiveEntryKind: String, Codable, Hashable, Sendable { case regularFile, directory, symbolicLink, hardLink, special }
public struct ArchiveEntryMetadata: Codable, Hashable, Sendable {
    public let path: String, kind: ArchiveEntryKind, uncompressedSize: Int, compressedSize: Int
    public init(path: String, kind: ArchiveEntryKind, uncompressedSize: Int, compressedSize: Int) {
        self.path = path
        self.kind = kind
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
    }
}

/// Adapters must disclose every entry before payload consumption. No unsafe extract-all API exists here.
public protocol ArchiveEntryReader: Sendable { func nextChunk() throws -> Data? }
public protocol ArchiveEntrySource: Sendable {
    func entries() throws -> [ArchiveEntryMetadata]
    func reader(for entry: ArchiveEntryMetadata) throws -> any ArchiveEntryReader
}

/// Sources backed by a security-scoped selection release that access after the
/// verifier has copied the reviewed bytes into protected staging.
public protocol ArchiveEntrySourceAccessLifetime: AnyObject, Sendable {
    func close()
}

public enum ArchiveSafetyLimits {
    public static let maximumEntries = 100_000, maximumEntryBytes = 64 * 1024 * 1024, maximumExpandedBytes = 256 * 1024 * 1024, maximumExpansionRatio = 100
    public static let maximumPathUTF8Bytes = 1_024, maximumPathComponents = 32
}
public enum ArchiveValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion, incompatibleReader, archiveTooLarge, expansionLimitExceeded, manifestMismatch, completionMarkerMismatch
    case approvalMismatch
    case invalidPath(String)
    case duplicatePath(String)
    case forbiddenEntryKind(String)
    case unknownEntry(String)
    case requiredEntryMissing(String)
    case invalidEntryMetadata(String)
    case hashMismatch(String)
    case sizeMismatch(String)
    case
        archiveDecodeFailed(String)
    case auditChainInvalid
}

public struct ArchiveAuditChainRecord: Codable, Hashable, Sendable {
    public let sequence: Int
    public let previousSHA256: String
    public let eventSHA256: String
    public let event: Data
    public let chainSHA256: String

    public init(sequence: Int, previousSHA256: String, eventSHA256: String, event: Data, chainSHA256: String) {
        self.sequence = sequence
        self.previousSHA256 = previousSHA256
        self.eventSHA256 = eventSHA256
        self.event = event
        self.chainSHA256 = chainSHA256
    }
}

/// Domain-separated audit continuity format used by archive export and restore.
/// Each JSONL row commits to its position, the prior row, and the exact opaque
/// audit event bytes. Semantic AuditEvent validation remains part of restore's
/// complete candidate-graph dry run.
public enum ArchiveAuditChain {
    private static let domain = Data("nettwork.archive-audit-chain.v1".utf8)
    public static let emptyHeadSHA256 = HexDigest.string(SHA256.hash(data: domain))

    public static func encode(events: [Data]) throws -> (jsonl: Data, headSHA256: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var previous = emptyHeadSHA256
        var jsonl = Data()
        for (offset, event) in events.enumerated() {
            let eventDigest = HexDigest.string(SHA256.hash(data: event))
            let chainDigest = digest(sequence: offset + 1, previous: previous, eventSHA256: eventDigest)
            let record = ArchiveAuditChainRecord(
                sequence: offset + 1, previousSHA256: previous,
                eventSHA256: eventDigest, event: event, chainSHA256: chainDigest)
            jsonl.append(try encoder.encode(record))
            jsonl.append(0x0A)
            previous = chainDigest
        }
        return (jsonl, previous)
    }

    public static func verify(_ jsonl: Data) throws -> (count: Int, headSHA256: String) {
        let lines = jsonl.split(separator: 0x0A, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        var previous = emptyHeadSHA256
        for (offset, line) in lines.enumerated() {
            guard let record = try? decoder.decode(ArchiveAuditChainRecord.self, from: Data(line)),
                record.sequence == offset + 1, record.previousSHA256 == previous,
                record.eventSHA256 == HexDigest.string(SHA256.hash(data: record.event)),
                record.chainSHA256 == digest(sequence: record.sequence, previous: previous, eventSHA256: record.eventSHA256)
            else {
                throw ArchiveValidationError.auditChainInvalid
            }
            previous = record.chainSHA256
        }
        return (lines.count, previous)
    }

    private static func digest(sequence: Int, previous: String, eventSHA256: String) -> String {
        var hasher = SHA256()
        hasher.update(data: domain)
        hasher.update(data: Data([0]))
        var position = UInt64(sequence).bigEndian
        withUnsafeBytes(of: &position) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(previous.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(eventSHA256.utf8))
        return HexDigest.string(hasher.finalize())
    }
}

public enum ArchivePathPolicy {
    public static func normalized(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= ArchiveSafetyLimits.maximumPathUTF8Bytes,
            !raw.contains("\\"), !raw.contains("\0"), !raw.hasPrefix("/")
        else {
            throw ArchiveValidationError.invalidPath(raw)
        }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count <= ArchiveSafetyLimits.maximumPathComponents,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw ArchiveValidationError.invalidPath(raw)
        }
        let normalized = components.map(\.precomposedStringWithCanonicalMapping).joined(separator: "/")
        guard normalized.utf8.count <= ArchiveSafetyLimits.maximumPathUTF8Bytes else {
            throw ArchiveValidationError.invalidPath(raw)
        }
        return normalized
    }
    public static func collisionKey(_ normalized: String) -> String {
        normalized.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func isAllowed(_ path: String, kind: ArchiveEntryKind) -> Bool {
        switch path {
        case ArchiveLayout.manifestPath, ArchiveLayout.recordsPath, ArchiveLayout.auditPath, ArchiveLayout.completionPath: return kind == .regularFile
        case ArchiveLayout.assetsDirectory: return kind == .directory
        default: return path.hasPrefix(ArchiveLayout.assetsDirectory + "/") && (kind == .regularFile || kind == .directory)
        }
    }
}

public struct ArchiveDigest: Codable, Hashable, Sendable {
    public let size: Int, sha256: String
    public init(size: Int, sha256: String) {
        self.size = size
        self.sha256 = sha256
    }
}
public struct VerifiedArchive: Sendable {
    public let manifest: ArchiveManifest, recordsJSONL: Data, auditJSONL: Data, assets: [String: Data], rootSHA256: String
}

/// An opaque, immutable authorization for one reviewed archive restore. It is
/// issued only by `ArchiveVerifier.verifyForRestore` and is checked again after
/// the exact source bytes have been reverified, before any staging is created.
