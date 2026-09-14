import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Stores a verified archive in an opaque local directory, re-verifies that
/// directory before activation, then delegates the final CAS to the injected
/// authoritative target store.
public actor FileBackedArchiveRestoreStore: ArchiveRestoreStore {
    private struct Entry: Sendable {
        let handle: ImportStagingHandle
        let source: ArchiveSourceProvenance
        let operationID: ObjectID
        let directory: URL
        var rootSHA256: String?
    }

    /// A canonical, private restart record for a staged archive. The archive
    /// itself is still independently re-verified before authority activation.
    private struct Sidecar: Codable, Sendable {
        static let currentSchemaVersion = 1
        let schemaVersion: Int
        let handle: ImportStagingHandle
        let source: ArchiveSourceProvenance
        let operationID: ObjectID
        let rootSHA256: String?
    }

    private struct ActivationRequest {
        let source: ArchiveSourceProvenance
        let target: PersistenceNamespace
        let expectedRoot: String
        let operationID: ObjectID
        let expectedReceipt: OperationReceipt
    }

    private let root: URL
    private let authority: any ArchiveRestoreActivationAuthority
    private var nextGeneration: UInt64
    private var entries: [ObjectID: Entry] = [:]

    public init(root: URL, authority: any ArchiveRestoreActivationAuthority, firstGeneration: UInt64 = 1) {
        self.root = root.standardizedFileURL
        self.authority = authority
        nextGeneration = max(1, firstGeneration)
    }

    public func currentAccount() async throws -> AccountContext {
        try await authority.currentAccount()
    }

    public func isFreshAuthenticatedTarget(in namespace: PersistenceNamespace) async throws -> Bool {
        try await authority.isFreshAuthenticatedTarget(in: namespace)
    }

    public func dryRun(_ archive: VerifiedArchive, for target: PersistenceNamespace) async throws {
        try await authority.dryRun(archive, for: target)
    }

    public func dryRun(_ archive: FileBackedVerifiedArchive, for target: PersistenceNamespace) async throws {
        guard let authority = authority as? any FileBackedArchiveRestoreActivationAuthority else {
            throw ArchiveValidationError.archiveDecodeFailed("file-backed restore unsupported")
        }
        try await authority.dryRun(archive, for: target)
    }

    public func createRestoreStaging(
        source: ArchiveSourceProvenance, target: PersistenceNamespace,
        operationID: ObjectID
    ) async throws -> ImportStagingHandle {
        try FileBackedStagingFiles.ensurePrivateDirectory(root)
        let generation = nextGeneration
        guard generation > 0 else { throw FileBackedStagingError.invalidStagingHandle }
        let handle = ImportStagingHandle(
            id: operationID, transferID: operationID, namespace: target,
            generation: generation)
        let directory = root.appendingPathComponent(handle.id.description, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            let data = try FileBackedStagingFiles.readPrivate(
                sidecarURL(in: directory),
                maximumBytes: 1_048_576)
            let sidecar = try WorkspaceTransferCoding.decode(Sidecar.self, from: data)
            return try reopenRestoreStaging(
                sidecar.handle, source: source, target: target,
                operationID: operationID)
        }
        nextGeneration &+= 1
        try FileBackedStagingFiles.ensureNewPrivateDirectory(directory)
        let entry = Entry(
            handle: handle, source: source, operationID: operationID,
            directory: directory, rootSHA256: nil)
        try writeSidecar(for: entry)
        entries[handle.id] = entry
        return handle
    }

    /// Rehydrates a restore transfer only when its durable sidecar still binds
    /// the exact target namespace, source provenance, and operation identity.
    public func reopenRestoreStaging(
        _ staging: ImportStagingHandle, source: ArchiveSourceProvenance,
        target: PersistenceNamespace, operationID: ObjectID
    ) throws -> ImportStagingHandle {
        let entry = try entry(for: staging)
        guard entry.handle.namespace == target, entry.source == source, entry.operationID == operationID,
            staging.transferID == operationID
        else {
            throw FileBackedStagingError.invalidStagingHandle
        }
        return entry.handle
    }

    public func stage(_ archive: VerifiedArchive, in staging: ImportStagingHandle) async throws {
        var entry = try entry(for: staging)
        guard entry.source == archive.manifest.provenance else {
            throw FileBackedStagingError.restoreSourceMismatch
        }
        let archiveDirectory = entry.directory.appendingPathComponent("archive", isDirectory: true)
        if let stagedRoot = entry.rootSHA256 {
            let verified = try ArchiveVerifier().verify(source: FileBackedArchiveEntrySource(root: archiveDirectory))
            guard stagedRoot == archive.rootSHA256, verified.rootSHA256 == archive.rootSHA256,
                verified.manifest == archive.manifest
            else {
                throw FileBackedStagingError.stagedPayloadMismatch
            }
            return
        }
        try FileBackedStagingFiles.ensureNewPrivateDirectory(archiveDirectory)
        do {
            try write(archive, to: archiveDirectory)
            let verified = try ArchiveVerifier().verify(source: FileBackedArchiveEntrySource(root: archiveDirectory))
            guard verified.rootSHA256 == archive.rootSHA256 else { throw FileBackedStagingError.stagedPayloadMismatch }
            entry.rootSHA256 = verified.rootSHA256
            try writeSidecar(for: entry)
            entries[staging.id] = entry
        } catch {
            try? FileManager.default.removeItem(at: archiveDirectory)
            throw error
        }
    }

    public func stage(
        _ archive: FileBackedVerifiedArchive, in staging: ImportStagingHandle
    ) async throws {
        defer { archive.discardIfUnadopted() }
        guard authority is any FileBackedArchiveRestoreActivationAuthority else {
            throw ArchiveValidationError.archiveDecodeFailed("file-backed restore unsupported")
        }
        var entry = try entry(for: staging)
        guard entry.source == archive.manifest.provenance else {
            throw FileBackedStagingError.restoreSourceMismatch
        }
        let archiveDirectory = entry.directory.appendingPathComponent("archive", isDirectory: true)
        if let stagedRoot = entry.rootSHA256 {
            try validateExistingStage(
                archive, entry: entry, stagedRoot: stagedRoot)
            return
        }
        try adopt(archive, into: archiveDirectory, entry: &entry, staging: staging)
    }

    private func validateExistingStage(
        _ archive: FileBackedVerifiedArchive, entry: Entry,
        stagedRoot: String
    ) throws {
        let verified = try verifyStagedArchive(in: entry)
        defer { verified.discardIfUnadopted() }
        guard stagedRoot == archive.rootSHA256,
            verified.rootSHA256 == archive.rootSHA256,
            verified.manifest == archive.manifest
        else { throw FileBackedStagingError.stagedPayloadMismatch }
    }

    private func adopt(
        _ archive: FileBackedVerifiedArchive, into archiveDirectory: URL,
        entry: inout Entry, staging: ImportStagingHandle
    ) throws {
        do {
            try archive.adoptPayload(into: archiveDirectory)
            let verified = try verifyStagedArchive(in: entry)
            defer { verified.discardIfUnadopted() }
            guard verified.rootSHA256 == archive.rootSHA256,
                verified.manifest == archive.manifest
            else { throw FileBackedStagingError.stagedPayloadMismatch }
            entry.rootSHA256 = verified.rootSHA256
            try writeSidecar(for: entry)
            entries[staging.id] = entry
        } catch {
            try? FileManager.default.removeItem(at: archiveDirectory)
            throw error
        }
    }

    public func activateRestore(
        _ staging: ImportStagingHandle, expectedFreshTarget: PersistenceNamespace,
        operationID: ObjectID, expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt {
        let entry = try entry(for: staging)
        guard entry.handle.namespace == expectedFreshTarget, entry.operationID == operationID,
            let expectedRoot = entry.rootSHA256
        else {
            throw FileBackedStagingError.stagingNotReady
        }
        let archiveDirectory = entry.directory.appendingPathComponent("archive", isDirectory: true)
        let receipt =
            if let fileAuthority = authority as? any FileBackedArchiveRestoreActivationAuthority {
                try await activateFileBacked(
                    entry: entry, expectedRoot: expectedRoot, target: expectedFreshTarget,
                    operationID: operationID, expectedReceipt: expectedReceipt,
                    authority: fileAuthority)
            } else {
                try await activateLegacy(
                    archiveDirectory: archiveDirectory, entry: entry,
                    expectedRoot: expectedRoot, target: expectedFreshTarget,
                    operationID: operationID, expectedReceipt: expectedReceipt)
            }
        guard receipt == expectedReceipt else {
            throw FileBackedStagingError.activationReceiptMismatch
        }
        entries.removeValue(forKey: staging.id)
        try? FileManager.default.removeItem(at: entry.directory)
        return receipt
    }

    private func activateFileBacked(
        entry: Entry, expectedRoot: String, target: PersistenceNamespace,
        operationID: ObjectID, expectedReceipt: OperationReceipt,
        authority: any FileBackedArchiveRestoreActivationAuthority
    ) async throws -> OperationReceipt {
        let verified = try verifyStagedArchive(in: entry)
        defer { verified.discardIfUnadopted() }
        let request = ActivationRequest(
            source: entry.source, target: target, expectedRoot: expectedRoot,
            operationID: operationID, expectedReceipt: expectedReceipt)
        try validateActivation(
            manifest: verified.manifest, rootSHA256: verified.rootSHA256,
            request: request)
        return try await dispatch(verified, request: request, authority: authority)
    }

    private func activateLegacy(
        archiveDirectory: URL, entry: Entry, expectedRoot: String,
        target: PersistenceNamespace, operationID: ObjectID,
        expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt {
        let verified = try ArchiveVerifier().verify(
            source: FileBackedArchiveEntrySource(root: archiveDirectory))
        let request = ActivationRequest(
            source: entry.source, target: target, expectedRoot: expectedRoot,
            operationID: operationID, expectedReceipt: expectedReceipt)
        try validateActivation(
            manifest: verified.manifest, rootSHA256: verified.rootSHA256,
            request: request)
        return try await dispatch(verified, request: request)
    }

    private func dispatch(
        _ archive: FileBackedVerifiedArchive, request: ActivationRequest,
        authority: any FileBackedArchiveRestoreActivationAuthority
    ) async throws -> OperationReceipt {
        try await authority.activateStagedArchive(
            archive: archive, source: request.source, target: request.target,
            expectedRootSHA256: request.expectedRoot,
            operationID: request.operationID, expectedReceipt: request.expectedReceipt)
    }

    private func dispatch(
        _ archive: VerifiedArchive, request: ActivationRequest
    ) async throws -> OperationReceipt {
        try await authority.activateStagedArchive(
            archive: archive, source: request.source, target: request.target,
            expectedRootSHA256: request.expectedRoot,
            operationID: request.operationID, expectedReceipt: request.expectedReceipt)
    }

    public func discardRestore(_ staging: ImportStagingHandle) async {
        guard let entry = try? entry(for: staging) else { return }
        entries.removeValue(forKey: staging.id)
        try? FileManager.default.removeItem(at: entry.directory)
    }

    public func cleanupRestore(_ staging: ImportStagingHandle, disposition: StagedTransferCleanupDisposition) async {
        guard disposition.discardsStaging else { return }
        await discardRestore(staging)
    }

    private func entry(for handle: ImportStagingHandle) throws -> Entry {
        if let entry = try cachedEntry(for: handle) { return entry }
        let loaded = try FileBackedStagingFiles.loadCanonicalSidecar(
            root: root, handle: handle,
            as: Sidecar.self)
        let sidecar = loaded.value
        guard sidecar.schemaVersion == Sidecar.currentSchemaVersion,
            try WorkspaceTransferCoding.encode(sidecar) == loaded.data, sidecar.handle == handle,
            handle.transferID == sidecar.operationID
        else {
            throw FileBackedStagingError.stagedPayloadMismatch
        }
        let entry = Entry(
            handle: handle, source: sidecar.source, operationID: sidecar.operationID,
            directory: loaded.directory, rootSHA256: sidecar.rootSHA256)
        entries[handle.id] = entry
        return entry
    }

    private func cachedEntry(for handle: ImportStagingHandle) throws -> Entry? {
        guard let entry = entries[handle.id] else { return nil }
        guard entry.handle == handle else { throw FileBackedStagingError.invalidStagingHandle }
        return entry
    }

    private func verifyStagedArchive(in entry: Entry) throws -> FileBackedVerifiedArchive {
        let archiveDirectory = entry.directory.appendingPathComponent("archive", isDirectory: true)
        return try ArchiveVerifier().verifyFileBacked(
            source: FileBackedArchiveEntrySource(root: archiveDirectory),
            stagingRoot: entry.directory.appendingPathComponent("verification", isDirectory: true))
    }

    private func validateActivation(
        manifest: ArchiveManifest, rootSHA256: String,
        request: ActivationRequest
    ) throws {
        guard rootSHA256 == request.expectedRoot,
            manifest.provenance == request.source
        else {
            throw FileBackedStagingError.stagedPayloadMismatch
        }
        let receipt = try ArchiveRestoreActivationReceipt.expected(
            manifest: manifest, rootSHA256: rootSHA256,
            target: request.target, operationID: request.operationID)
        guard request.expectedReceipt == receipt else {
            throw FileBackedStagingError.activationReceiptMismatch
        }
    }

    private func writeSidecar(for entry: Entry) throws {
        let sidecar = Sidecar(
            schemaVersion: Sidecar.currentSchemaVersion, handle: entry.handle, source: entry.source, operationID: entry.operationID,
            rootSHA256: entry.rootSHA256)
        try FileBackedStagingFiles.writePrivate(WorkspaceTransferCoding.encode(sidecar), to: sidecarURL(in: entry.directory))
    }

    private func sidecarURL(in directory: URL) -> URL {
        directory.appendingPathComponent("staging.json", isDirectory: false)
    }

    private func write(_ archive: VerifiedArchive, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileBackedStagingFiles.writePrivate(encoder.encode(archive.manifest), to: directory.appendingPathComponent(ArchiveLayout.manifestPath))
        try FileBackedStagingFiles.writePrivate(archive.recordsJSONL, to: directory.appendingPathComponent(ArchiveLayout.recordsPath))
        try FileBackedStagingFiles.writePrivate(archive.auditJSONL, to: directory.appendingPathComponent(ArchiveLayout.auditPath))
        let marker = ArchiveCompletionMarker(
            rootSHA256: archive.rootSHA256,
            manifestCommitmentSHA256: try ArchiveManifestCommitment.digest(for: archive.manifest),
            completedAt: archive.manifest.createdAt)
        try FileBackedStagingFiles.writePrivate(encoder.encode(marker), to: directory.appendingPathComponent(ArchiveLayout.completionPath))
        for (rawPath, bytes) in archive.assets {
            let path = try ArchivePathPolicy.normalized(rawPath)
            guard path.hasPrefix(ArchiveLayout.assetsDirectory + "/") else {
                throw FileBackedStagingError.invalidArchiveEntry
            }
            let components = path.split(separator: "/").map(String.init)
            let parent = components.dropLast().reduce(directory) { $0.appendingPathComponent($1, isDirectory: true) }
            try FileBackedStagingFiles.ensurePrivateDirectory(parent)
            try FileBackedStagingFiles.writePrivate(bytes, to: parent.appendingPathComponent(components.last ?? ""))
        }
    }
}
