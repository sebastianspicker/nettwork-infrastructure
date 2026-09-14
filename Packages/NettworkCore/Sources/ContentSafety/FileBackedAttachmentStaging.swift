import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Applies platform data-protection policy after each private staging write.
/// Composition must supply an implementation appropriate for the app's storage
/// location and managed-device policy.
public protocol AttachmentStagingFileProtection: Sendable {
    func applyFileProtection(to url: URL) throws
    func applyDirectoryProtection(to url: URL) throws
}

/// The default Foundation implementation keeps directories private and requests
/// protection while the device is locked on platforms that support it.
public struct FoundationAttachmentStagingFileProtection: AttachmentStagingFileProtection {
    public init() {}

    public func applyFileProtection(to url: URL) throws {
        try apply(to: url, permissions: 0o600)
    }

    public func applyDirectoryProtection(to url: URL) throws {
        try apply(to: url, permissions: 0o700)
    }

    private func apply(to url: URL, permissions: Int) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: permissions)]
        #if os(iOS) || os(tvOS) || os(watchOS)
            attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
}

public enum FileAttachmentStagingError: Error, Equatable, Sendable {
    case invalidRoot
    case unexpectedRootItem
    case unknownLease
    case namespaceMismatch
    case invalidLifetime
    case leaseAlreadyClaimed
    case invalidClaim
    case stagedMetadataMismatch
}

/// A private, process-local attachment staging implementation. The supplied
/// root must be an app-owned directory, never a user-selected URL. Files are
/// stored below an opaque namespace digest and are reachable only through the
/// in-memory lease map; callers never receive their paths.
public actor FileBackedPrivateAttachmentStaging: PrivateAttachmentStaging {
    private struct Entry: Sendable {
        let namespace: AttachmentNamespace
        let url: URL
        let expiresAt: Date
        let metadata: SanitizedAttachmentStagingMetadata
        var claimID: UUID?
    }

    private let root: URL
    private let lifetime: TimeInterval
    private let protection: any AttachmentStagingFileProtection
    private let now: @Sendable () -> Date
    private var entries: [AttachmentStagingToken: Entry] = [:]

    public init(
        root: URL, lifetime: TimeInterval = 15 * 60,
        protection: any AttachmentStagingFileProtection = FoundationAttachmentStagingFileProtection(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard lifetime > 0 else { throw FileAttachmentStagingError.invalidLifetime }
        self.root = root.standardizedFileURL
        self.lifetime = lifetime
        self.protection = protection
        self.now = now
    }

    public func stage(
        _ sanitizedBytes: Data, metadata: SanitizedAttachmentStagingMetadata,
        namespace: AttachmentNamespace
    ) async throws -> StagedAttachmentLease {
        try removeExpiredEntries()
        guard sanitizedBytes.count == metadata.byteCount,
            try ContentSignature.detect(in: sanitizedBytes) == metadata.contentType,
            metadata.contentType == .jpeg,
            ContentSafetyService.digest(for: sanitizedBytes, purpose: metadata.purpose) == metadata.domainSeparatedSHA256
        else {
            throw FileAttachmentStagingError.stagedMetadataMismatch
        }
        let directory = try privateDirectory(for: namespace)
        let token = AttachmentStagingToken()
        let registryMetadata = metadata.assigningRegistryAttachmentID(ObjectID())
        let url = directory.appendingPathComponent(token.id.uuidString, isDirectory: false)
        let expiry = now().addingTimeInterval(lifetime)

        do {
            try sanitizedBytes.write(to: url, options: .atomic)
            try protection.applyFileProtection(to: url)
            entries[token] = Entry(namespace: namespace, url: url, expiresAt: expiry, metadata: registryMetadata, claimID: nil)
            return StagedAttachmentLease(
                token: token, attachmentID: registryMetadata.attachmentID,
                expiresAt: expiry)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    public func remove(_ token: AttachmentStagingToken, namespace: AttachmentNamespace) async throws {
        try removeExpiredEntries()
        guard let entry = entries[token] else { throw FileAttachmentStagingError.unknownLease }
        guard entry.namespace == namespace else { throw FileAttachmentStagingError.namespaceMismatch }
        guard entry.claimID == nil else { throw FileAttachmentStagingError.leaseAlreadyClaimed }
        try FileManager.default.removeItem(at: entry.url)
        entries.removeValue(forKey: token)
    }

    public func claim(
        _ token: AttachmentStagingToken, namespace: AttachmentNamespace
    ) async throws -> ClaimedStagedAttachment {
        try removeExpiredEntries()
        guard var entry = entries[token] else { throw FileAttachmentStagingError.unknownLease }
        guard entry.namespace == namespace else { throw FileAttachmentStagingError.namespaceMismatch }
        guard entry.claimID == nil else { throw FileAttachmentStagingError.leaseAlreadyClaimed }
        let bytes = try Data(contentsOf: entry.url)
        let claimID = UUID()
        entry.claimID = claimID
        entries[token] = entry
        return ClaimedStagedAttachment(
            sanitizedBytes: bytes, metadata: entry.metadata,
            attachmentID: entry.metadata.attachmentID, token: token, namespace: namespace,
            expiresAt: entry.expiresAt, claimID: claimID)
    }

    public func complete(_ claim: ClaimedStagedAttachment) async throws {
        try removeExpiredEntries()
        guard let entry = entries[claim.token] else { throw FileAttachmentStagingError.unknownLease }
        guard entry.namespace == claim.namespace, entry.expiresAt == claim.expiresAt,
            entry.claimID == claim.claimID
        else {
            throw FileAttachmentStagingError.invalidClaim
        }
        try FileManager.default.removeItem(at: entry.url)
        entries.removeValue(forKey: claim.token)
    }

    public func release(_ claim: ClaimedStagedAttachment) async {
        guard var entry = entries[claim.token], entry.namespace == claim.namespace,
            entry.expiresAt == claim.expiresAt, entry.claimID == claim.claimID
        else {
            return
        }
        entry.claimID = nil
        entries[claim.token] = entry
    }

    /// Removes in-process leases whose deadline has elapsed. Call this on
    /// foreground transitions as well as before handing a lease to a platform
    /// asset uploader.
    @discardableResult
    public func purgeExpired() throws -> Int {
        let before = entries.count
        try removeExpiredEntries()
        return before - entries.count
    }

    /// An explicit launch-time recovery hook for an exclusively owned staging
    /// root. It never follows links and does not touch files outside `root`.
    public func discardAllStagedFiles() throws {
        try ensurePrivateDirectory(root)
        let manager = FileManager.default
        for item in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw FileAttachmentStagingError.unexpectedRootItem
            }
            try manager.removeItem(at: item)
        }
        entries.removeAll(keepingCapacity: false)
    }

    private func removeExpiredEntries() throws {
        let deadline = now()
        let expired = entries.filter { $0.value.expiresAt <= deadline }
        for (token, entry) in expired {
            if FileManager.default.fileExists(atPath: entry.url.path) {
                try FileManager.default.removeItem(at: entry.url)
            }
            entries.removeValue(forKey: token)
        }
    }

    private func privateDirectory(for namespace: AttachmentNamespace) throws -> URL {
        try ensurePrivateDirectory(root)
        let directory = root.appendingPathComponent(namespaceKey(for: namespace), isDirectory: true)
        try ensurePrivateDirectory(directory)
        return directory
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
                throw FileAttachmentStagingError.invalidRoot
            }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try protection.applyDirectoryProtection(to: url)
    }

    private func namespaceKey(for namespace: AttachmentNamespace) -> String {
        let material = [
            "netzwerkdoku.private-attachment-staging.v1", namespace.containerIdentifier,
            namespace.accountRecordName, namespace.workspaceID.description, namespace.zoneName,
            namespace.zoneOwnerRecordName, String(namespace.sessionGeneration),
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
