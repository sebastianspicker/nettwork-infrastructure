import Foundation
import WorkspaceChangeControl

/// Installation identity of the CloudKit runtime. The installation ID is a UUID
/// created once and persisted as `installation.json` in an injected private
/// directory; a damaged file throws and is never regenerated. The session ID is
/// fresh for every value (create one per process), so it changes on every launch.
public struct ProductionInstallationSession: ProductionInstallationSessionProviding {
    public static let fileName = "installation.json"
    static let currentFormatVersion = 1

    struct Record: Codable, Hashable, Sendable {
        let formatVersion: Int
        let installationID: String
    }

    public let installationID: String
    public let launchSessionID: String

    /// Loads the persisted installation ID, creating it only when no file exists.
    public init(directory: URL, launchSessionID: String = UUID().uuidString.lowercased()) throws {
        self.installationID = try Self.loadOrCreateInstallationID(in: directory)
        self.launchSessionID = launchSessionID
    }

    public func sessionID(for actor: ActorContext, account _: AccountContext) async throws -> String {
        guard actor.installationID == installationID else { throw ProductionCloudIdentityError.installationMismatch }
        guard !launchSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProductionCloudIdentityError.invalidInstallationID }
        return launchSessionID
    }

    static func loadOrCreateInstallationID(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return try create(at: url, in: directory)
        } catch {
            throw ProductionCloudIdentityError.installationReadFailed(error.localizedDescription)
        }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: data) } catch { throw ProductionCloudIdentityError.installationCorrupt }
        guard record.formatVersion == currentFormatVersion, isCanonicalUUID(record.installationID) else {
            throw ProductionCloudIdentityError.installationCorrupt
        }
        return record.installationID
    }

    private static func create(at url: URL, in directory: URL) throws -> String {
        let record = Record(formatVersion: currentFormatVersion, installationID: UUID().uuidString.lowercased())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try AtomicLocalFileWriter().writeAtomically(encoder.encode(record), to: url)
        } catch {
            throw ProductionCloudIdentityError.installationWriteFailed(error.localizedDescription)
        }
        return record.installationID
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}
