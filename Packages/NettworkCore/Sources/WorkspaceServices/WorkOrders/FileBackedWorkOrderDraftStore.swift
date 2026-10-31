import CryptoKit
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Typed, fail-closed failures of the durable draft store. None of them is
/// ever mapped to an empty draft list, and an unreadable file is never removed.
public enum FileBackedWorkOrderDraftStoreError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case corruptDraftFile
    case draftFileTooLarge(byteCount: Int)
    case namespaceMismatch
    case readFailed(String)
    case writeFailed(String)
}

/// Staged work-order drafts that survive relaunch. Each namespace owns one
/// versioned JSON file below `directory`, replaced atomically on every store.
public actor FileBackedWorkOrderDraftStore: ProductionStagedWorkOrderDraftStoring {
    static let currentFormatVersion = 1
    static let maximumFileByteCount = 16 * 1_024 * 1_024

    private let directory: URL
    private let writer: any LocalWorkspaceRecordStoreFileWriting
    private var loaded: [PersistenceNamespace: [ObjectID: WorkOrderDraft]] = [:]

    public init(directory: URL, writer: any LocalWorkspaceRecordStoreFileWriting = AtomicLocalFileWriter()) {
        self.directory = directory
        self.writer = writer
    }

    public func store(_ draft: WorkOrderDraft, in namespace: PersistenceNamespace) throws {
        var drafts = try currentDrafts(in: namespace)
        drafts[draft.id] = draft
        try persist(drafts, in: namespace)
        loaded[namespace] = drafts
    }

    public func draft(id: ObjectID, in namespace: PersistenceNamespace) throws -> WorkOrderDraft? {
        try currentDrafts(in: namespace)[id]
    }

    public func drafts(in namespace: PersistenceNamespace) throws -> [WorkOrderDraft] {
        try currentDrafts(in: namespace).values.sorted { ($0.title, $0.id.description) < ($1.title, $1.id.description) }
    }

    private func currentDrafts(in namespace: PersistenceNamespace) throws -> [ObjectID: WorkOrderDraft] {
        if let drafts = loaded[namespace] { return drafts }
        let drafts = try load(namespace)
        loaded[namespace] = drafts
        return drafts
    }

    /// Returns an empty set only when no file exists; every other problem throws.
    private func load(_ namespace: PersistenceNamespace) throws -> [ObjectID: WorkOrderDraft] {
        guard let data = try Self.contents(of: fileURL(for: namespace)) else { return [:] }
        let file = try Self.decode(data)
        guard file.namespace == namespace else { throw FileBackedWorkOrderDraftStoreError.namespaceMismatch }
        var drafts: [ObjectID: WorkOrderDraft] = [:]
        for persisted in file.drafts {
            guard drafts.updateValue(persisted.draft, forKey: persisted.id) == nil else {
                throw FileBackedWorkOrderDraftStoreError.corruptDraftFile
            }
        }
        return drafts
    }

    private func persist(_ drafts: [ObjectID: WorkOrderDraft], in namespace: PersistenceNamespace) throws {
        let file = DraftFile(
            formatVersion: Self.currentFormatVersion, namespace: namespace,
            drafts: drafts.values.sorted { $0.id.description < $1.id.description }.map(PersistedDraft.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(file) } catch { throw FileBackedWorkOrderDraftStoreError.writeFailed(error.localizedDescription) }
        guard data.count <= Self.maximumFileByteCount else { throw FileBackedWorkOrderDraftStoreError.draftFileTooLarge(byteCount: data.count) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writer.writeAtomically(data, to: fileURL(for: namespace))
        } catch {
            throw FileBackedWorkOrderDraftStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// One file per namespace; the name is a digest so no namespace field
    /// reaches the file system, and the file repeats the namespace it belongs to.
    private func fileURL(for namespace: PersistenceNamespace) -> URL {
        let identity = [
            namespace.containerIdentifier, namespace.cloudKitAccountRecordName, namespace.workspaceID.description,
            namespace.zoneName, namespace.zoneOwnerRecordName, String(namespace.sessionGeneration),
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("drafts-\(digest).json", isDirectory: false)
    }

    /// Nil only when the file does not exist.
    private static func contents(of url: URL) throws -> Data? {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumFileByteCount else { throw FileBackedWorkOrderDraftStoreError.draftFileTooLarge(byteCount: size) }
            return try Data(contentsOf: url)
        } catch let error as FileBackedWorkOrderDraftStoreError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw FileBackedWorkOrderDraftStoreError.readFailed(error.localizedDescription)
        }
    }

    private struct VersionHeader: Decodable { let formatVersion: Int }

    private static func decode(_ data: Data) throws -> DraftFile {
        let decoder = JSONDecoder()
        let header: VersionHeader
        do { header = try decoder.decode(VersionHeader.self, from: data) } catch { throw FileBackedWorkOrderDraftStoreError.corruptDraftFile }
        guard header.formatVersion == currentFormatVersion else {
            throw FileBackedWorkOrderDraftStoreError.unsupportedFormatVersion(header.formatVersion)
        }
        do { return try decoder.decode(DraftFile.self, from: data) } catch { throw FileBackedWorkOrderDraftStoreError.corruptDraftFile }
    }
}

private struct DraftFile: Codable {
    let formatVersion: Int
    let namespace: PersistenceNamespace
    let drafts: [PersistedDraft]
}

/// The on-disk shape of one draft, kept separate from the feature contract so
/// the file format changes only with `formatVersion`.
private struct PersistedDraft: Codable {
    let id: ObjectID
    let title: String
    let kind: WorkOrderKind
    let ticket: String
    let notes: String
    let resourceKeys: [ResourceKey]
    let operations: [PlannedWorkOperation]
    let evidence: [EvidenceHash]

    init(_ draft: WorkOrderDraft) {
        id = draft.id
        title = draft.title
        kind = draft.kind
        ticket = draft.ticket
        notes = draft.notes
        resourceKeys = draft.resourceKeys.sorted()
        operations = draft.operations
        evidence = draft.evidence
    }

    var draft: WorkOrderDraft {
        WorkOrderDraft(
            id: id, title: title, kind: kind, ticket: ticket, notes: notes, resourceKeys: Set(resourceKeys), operations: operations, evidence: evidence)
    }
}
