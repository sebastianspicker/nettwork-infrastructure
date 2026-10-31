import CloudSync
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Typed failures of the persisted local identity. A missing or damaged
/// identity is never regenerated implicitly outside `loadOrCreate`'s first run.
public enum LocalWorkspaceIdentityError: Error, Equatable, Sendable {
    case missing
    case corrupt
    case readFailed(String)
    case writeFailed(String)
}

extension LocalWorkspaceIdentityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missing: "The local workspace identity does not exist."
        case .corrupt: "The local workspace identity file is corrupt and was left untouched."
        case .readFailed(let reason): "The local workspace identity could not be read: \(reason)"
        case .writeFailed(let reason): "The local workspace identity could not be written: \(reason)"
        }
    }
}

/// The one local user and workspace of an installation, persisted as `identity.json`.
public struct LocalWorkspaceIdentity: Codable, Hashable, Sendable {
    /// Reserved container-identifier prefix of local namespaces. Composition validation relies on it.
    public static let containerPrefix = "local."
    public static let containerIdentifier = containerPrefix + "nettwork"
    public static let fileName = "identity.json"

    public let userID: String
    public let workspaceID: ObjectID
    public let createdAt: Date

    public init(userID: String = "local-user-" + UUID().uuidString.lowercased(), workspaceID: ObjectID = ObjectID(), createdAt: Date = Date()) {
        self.userID = userID
        self.workspaceID = workspaceID
        self.createdAt = createdAt
    }

    /// The only namespace this identity may activate, for the given session generation.
    public func namespace(sessionGeneration: UInt64) -> PersistenceNamespace {
        PersistenceNamespace(
            containerIdentifier: Self.containerIdentifier, cloudKitAccountRecordName: userID, workspaceID: workspaceID,
            zoneName: CloudRecordNaming.zoneName(for: workspaceID), zoneOwnerRecordName: userID, sessionGeneration: sessionGeneration)
    }

    public func ownerContext(sessionGeneration: UInt64, verifiedAt: Date) -> AccountContext {
        AccountContext(
            namespace: namespace(sessionGeneration: sessionGeneration), databaseScope: .ownerPrivate, sharePermission: .owner, verifiedAt: verifiedAt)
    }

    /// Reads the identity; throws `.missing` or `.corrupt` rather than creating one.
    public static func load(from directory: URL) throws -> LocalWorkspaceIdentity {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(in: directory))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw LocalWorkspaceIdentityError.missing
        } catch {
            throw LocalWorkspaceIdentityError.readFailed(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let identity: LocalWorkspaceIdentity
        do { identity = try decoder.decode(LocalWorkspaceIdentity.self, from: data) } catch { throw LocalWorkspaceIdentityError.corrupt }
        guard !identity.userID.isEmpty else { throw LocalWorkspaceIdentityError.corrupt }
        return identity
    }

    /// Returns the persisted identity, creating and persisting a new one only when none exists.
    /// A corrupt file throws and is never overwritten.
    public static func loadOrCreate(in directory: URL, now: Date = Date()) throws -> LocalWorkspaceIdentity {
        do {
            return try load(from: directory)
        } catch LocalWorkspaceIdentityError.missing {
            return try create(in: directory, now: now)
        }
    }

    private static func create(in directory: URL, now: Date) throws -> LocalWorkspaceIdentity {
        let identity = LocalWorkspaceIdentity(createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try AtomicLocalFileWriter().writeAtomically(encoder.encode(identity), to: fileURL(in: directory))
        } catch {
            throw LocalWorkspaceIdentityError.writeFailed(error.localizedDescription)
        }
        return identity
    }

    private static func fileURL(in directory: URL) -> URL { directory.appendingPathComponent(fileName, isDirectory: false) }
}
