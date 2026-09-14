import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum FileBackedStagingError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidStagingHandle
    case stagingNotReady
    case stagedPayloadMismatch
    case restoreSourceMismatch
    case invalidArchiveEntry
    case activationReceiptMismatch
}

/// The authority supplies the live account, semantic dry run, and the one
/// authoritative compare-and-swap. This adapter owns only private local files.
public protocol CSVImportActivationAuthority: Sendable {
    func currentAccount() async throws -> AccountContext
    func workspaceIsEmpty(in namespace: PersistenceNamespace) async throws -> Bool
    func dryRun(_ records: [ImportRecord], in namespace: PersistenceNamespace) async throws -> ImportDryRunReport
    func activateStagedCSV(
        records: [ImportRecord], plan: ImportPlan, requiringEmptyWorkspace: Bool,
        expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt
}

/// A local staging store that serializes reviewed records into a private file.
/// It re-decodes and re-digests the file immediately before the injected final
/// CAS so a stale or altered local payload cannot be activated.
public actor FileBackedCSVImportStagingStore: ImportStagingStore {
    private struct Entry: Sendable {
        let handle: ImportStagingHandle
        let directory: URL
        let plan: ImportPlan
        var isStaged: Bool
    }

    /// Stored beside, but separately from, the opaque records payload. This
    /// canonical sidecar is the durable source of truth after actor restart.
    private struct Sidecar: Codable, Sendable {
        static let currentSchemaVersion = 1
        let schemaVersion: Int
        let handle: ImportStagingHandle
        let plan: ImportPlan
        let isStaged: Bool
    }

    private let root: URL
    private let authority: any CSVImportActivationAuthority
    private var entries: [ObjectID: Entry] = [:]

    public init(root: URL, authority: any CSVImportActivationAuthority) {
        self.root = root.standardizedFileURL
        self.authority = authority
    }

    public func currentAccount() async throws -> AccountContext {
        try await authority.currentAccount()
    }

    public func workspaceIsEmpty(in namespace: PersistenceNamespace) async throws -> Bool {
        try await authority.workspaceIsEmpty(in: namespace)
    }

    public func dryRun(
        _ records: [ImportRecord], in namespace: PersistenceNamespace
    ) async throws -> ImportDryRunReport {
        try await authority.dryRun(records, in: namespace)
    }

    public func createStaging(for plan: ImportPlan) async throws -> ImportStagingHandle {
        guard plan.stagingGeneration > 0 else { throw FileBackedStagingError.invalidStagingHandle }
        try FileBackedStagingFiles.ensurePrivateDirectory(root)
        let handle = ImportStagingHandle(
            id: plan.transferID, transferID: plan.transferID,
            namespace: plan.namespace, generation: plan.stagingGeneration)
        let directory = root.appendingPathComponent(handle.id.description, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            return try reopenStaging(handle, for: plan)
        }
        try FileBackedStagingFiles.ensureNewPrivateDirectory(directory)
        let entry = Entry(handle: handle, directory: directory, plan: plan, isStaged: false)
        try writeSidecar(for: entry)
        entries[handle.id] = entry
        return handle
    }

    /// Rehydrates a staged transfer after a process restart without allocating
    /// a new transfer identity or accepting a substituted operation plan.
    public func reopenStaging(_ staging: ImportStagingHandle, for plan: ImportPlan) throws -> ImportStagingHandle {
        let entry = try entry(for: staging)
        guard entry.plan == plan, plan.transferID == staging.transferID else {
            throw FileBackedStagingError.invalidStagingHandle
        }
        return entry.handle
    }

    public func stage(_ records: [ImportRecord], in staging: ImportStagingHandle) async throws {
        var entry = try entry(for: staging)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(records)
        guard data.count <= CSVImportLimits.maximumImportBytes else { throw CSVImportError.importTooLarge }
        if entry.isStaged {
            let existing = try readRecords(at: entry.directory.appendingPathComponent("records.json"))
            guard existing == records else { throw FileBackedStagingError.stagedPayloadMismatch }
            return
        }
        try FileBackedStagingFiles.writePrivate(data, to: entry.directory.appendingPathComponent("records.json"))
        entry.isStaged = true
        try writeSidecar(for: entry)
        entries[staging.id] = entry
    }

    public func activate(
        _ staging: ImportStagingHandle, plan: ImportPlan, requiringEmptyWorkspace: Bool,
        expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt {
        let entry = try entry(for: staging)
        guard entry.isStaged, plan.namespace == staging.namespace,
            plan.stagingGeneration == staging.generation, plan.transferID == staging.transferID,
            plan == entry.plan
        else {
            throw FileBackedStagingError.stagingNotReady
        }
        let url = entry.directory.appendingPathComponent("records.json")
        let records = try readRecords(at: url)
        guard records.count == plan.totalRecordCount,
            CanonicalImportDigest.digest(records: records) == plan.canonicalSHA256
        else {
            throw FileBackedStagingError.stagedPayloadMismatch
        }
        guard expectedReceipt == (try CSVImportActivationReceipt.expected(for: plan)) else {
            throw FileBackedStagingError.activationReceiptMismatch
        }
        let receipt = try await authority.activateStagedCSV(
            records: records, plan: plan,
            requiringEmptyWorkspace: requiringEmptyWorkspace, expectedReceipt: expectedReceipt)
        guard receipt == expectedReceipt else {
            throw FileBackedStagingError.activationReceiptMismatch
        }
        entries.removeValue(forKey: staging.id)
        try? FileManager.default.removeItem(at: entry.directory)
        return receipt
    }

    public func discard(_ staging: ImportStagingHandle) async {
        guard let entry = try? entry(for: staging) else { return }
        entries.removeValue(forKey: staging.id)
        try? FileManager.default.removeItem(at: entry.directory)
    }

    public func cleanup(_ staging: ImportStagingHandle, disposition: StagedTransferCleanupDisposition) async {
        guard disposition.discardsStaging else { return }
        await discard(staging)
    }

    private func entry(for handle: ImportStagingHandle) throws -> Entry {
        if let entry = entries[handle.id] {
            guard entry.handle == handle else { throw FileBackedStagingError.invalidStagingHandle }
            return entry
        }
        let loaded = try FileBackedStagingFiles.loadCanonicalSidecar(
            root: root, handle: handle,
            as: Sidecar.self)
        let sidecar = loaded.value
        guard sidecar.schemaVersion == Sidecar.currentSchemaVersion,
            try WorkspaceTransferCoding.encode(sidecar) == loaded.data, sidecar.handle == handle,
            sidecar.plan.transferID == handle.transferID
        else {
            throw FileBackedStagingError.stagedPayloadMismatch
        }
        let entry = Entry(handle: handle, directory: loaded.directory, plan: sidecar.plan, isStaged: sidecar.isStaged)
        entries[handle.id] = entry
        return entry
    }

    private func writeSidecar(for entry: Entry) throws {
        let sidecar = Sidecar(schemaVersion: Sidecar.currentSchemaVersion, handle: entry.handle, plan: entry.plan, isStaged: entry.isStaged)
        try FileBackedStagingFiles.writePrivate(WorkspaceTransferCoding.encode(sidecar), to: sidecarURL(in: entry.directory))
    }

    private func sidecarURL(in directory: URL) -> URL {
        directory.appendingPathComponent("staging.json", isDirectory: false)
    }

    private func readRecords(at url: URL) throws -> [ImportRecord] {
        let data = try FileBackedStagingFiles.readPrivate(
            url,
            maximumBytes: CSVImportLimits.maximumImportBytes)
        do {
            return try JSONDecoder().decode([ImportRecord].self, from: data)
        } catch {
            throw FileBackedStagingError.stagedPayloadMismatch
        }
    }
}

/// Reads a verified archive tree without handing an archive library an
/// extract-all destination. The verifier still owns path, size, and digest
/// policy; this type only exposes regular files and directories as entries.
