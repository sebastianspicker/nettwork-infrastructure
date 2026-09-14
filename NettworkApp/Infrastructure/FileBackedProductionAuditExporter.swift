import CloudSync
import CryptoKit
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

enum ProductionAuditExportError: Error, Equatable, Sendable {
    case namespaceMismatch
    case invalidStagingRoot
    case unknownCapability
    case destinationExists
    case invalidDestination
    case malformedAuditRecord(ResourceKey)
}

/// Supplies a policy-approved, user- or organization-selected destination.
/// The exporter never invents a public path and never overwrites an existing
/// file. Sandboxed platforms can implement this with a security-scoped URL or
/// an organization-managed export directory.
protocol ProductionAuditExportDestinationProviding: Sendable {
    func destination(for operationID: ObjectID, namespace: PersistenceNamespace) async throws -> URL
}

struct ProductionAuditExportDocument: Codable, Hashable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let workspaceZone: AuthoritativeWorkspaceZone
    let operationID: ObjectID
    let eventCount: Int
    let auditHeadSHA256: String
    let auditJSONL: Data
    let documentSHA256: String

    init(workspaceZone: AuthoritativeWorkspaceZone, operationID: ObjectID, auditJSONL: Data, eventCount: Int, auditHeadSHA256: String) {
        version = Self.schemaVersion
        self.workspaceZone = workspaceZone
        self.operationID = operationID
        self.eventCount = eventCount
        self.auditHeadSHA256 = auditHeadSHA256
        self.auditJSONL = auditJSONL
        var material = Data("nettwork.audit-export-document.v1\0".utf8)
        material.append(Data(workspaceZone.workspaceID.description.utf8))
        material.append(0)
        material.append(Data(workspaceZone.zoneName.utf8))
        material.append(0)
        material.append(Data(workspaceZone.zoneOwnerRecordName.utf8))
        material.append(0)
        material.append(Data(operationID.description.utf8))
        material.append(0)
        material.append(Data(auditHeadSHA256.utf8))
        material.append(0)
        material.append(auditJSONL)
        documentSHA256 = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Private prepare/publish/abort implementation used by the workflow authority.
/// A capability is namespace-bound and single-use; prepared bytes are never
/// returned to presentation code before the final live-session revalidation.
actor FileBackedProductionAuditExporter: ProductionImmutableAuditExporting {
    private struct Entry: Sendable {
        let capability: ProductionStagedAuditExport
        let operationID: ObjectID
        let namespace: PersistenceNamespace
        let privateURL: URL
    }

    private let account: AccountContext
    private let persistence: SwiftDataPersistenceStore
    private let root: URL
    private let destination: any ProductionAuditExportDestinationProviding
    private var entries: [ObjectID: Entry] = [:]

    init(account: AccountContext, persistence: SwiftDataPersistenceStore, privateRoot: URL, destination: any ProductionAuditExportDestinationProviding) {
        self.account = account
        self.persistence = persistence
        root = privateRoot.standardizedFileURL
        self.destination = destination
    }

    func prepareAudit(operationID: ObjectID, in namespace: PersistenceNamespace) async throws -> ProductionStagedAuditExport {
        try requireNamespace(namespace)
        try preparePrivateRoot()
        let records = try await persistence.mirroredRecords(in: namespace)
        let events =
            try records
            .filter {
                !$0.isTombstone && ($0.recordType == CloudRecordNaming.auditRecordType || $0.recordType == LocalRecordKind.auditEvent)
            }
            .map { record -> AuditEvent in
                guard let payload = record.payload,
                    let event = try? CloudDeterministicCoding.decode(AuditEvent.self, from: payload)
                else {
                    throw ProductionAuditExportError.malformedAuditRecord(record.resourceKey)
                }
                return event
            }
            .sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                return $0.id < $1.id
            }
        let chain = try ArchiveAuditChain.encode(
            events: try events.map { try CloudDeterministicCoding.encode($0) }
        )
        let document = ProductionAuditExportDocument(
            workspaceZone: namespace.workspaceZone, operationID: operationID, auditJSONL: chain.jsonl, eventCount: events.count,
            auditHeadSHA256: chain.headSHA256
        )
        let bytes = try CloudDeterministicCoding.encode(document)
        let capability = ProductionStagedAuditExport(capabilityID: ObjectID())
        let url = root.appendingPathComponent(capability.capabilityID.description, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ProductionAuditExportError.invalidStagingRoot
        }
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
        entries[capability.capabilityID] = Entry(capability: capability, operationID: operationID, namespace: namespace, privateURL: url)
        return capability
    }

    func publishAudit(_ staged: ProductionStagedAuditExport, in namespace: PersistenceNamespace) async throws -> URL {
        try requireNamespace(namespace)
        guard let entry = entries[staged.capabilityID],
            entry.capability.capabilityID == staged.capabilityID,
            entry.namespace == namespace
        else {
            throw ProductionAuditExportError.unknownCapability
        }
        let selectedDestination = try await destination.destination(for: entry.operationID, namespace: namespace)
        let finalURL = selectedDestination.standardizedFileURL
        let parent = finalURL.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true,
            parentValues.isSymbolicLink != true,
            finalURL.lastPathComponent != ".",
            finalURL.lastPathComponent != ".."
        else {
            throw ProductionAuditExportError.invalidDestination
        }
        guard !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw ProductionAuditExportError.destinationExists
        }
        let temporaryURL = parent.appendingPathComponent(
            ".nettwork-audit-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try FileManager.default.copyItem(at: entry.privateURL, to: temporaryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporaryURL.path
            )
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            entries.removeValue(forKey: staged.capabilityID)
            try? FileManager.default.removeItem(at: entry.privateURL)
            return finalURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func abortAudit(_ staged: ProductionStagedAuditExport, in namespace: PersistenceNamespace) async {
        guard let entry = entries[staged.capabilityID], entry.namespace == namespace else { return }
        entries.removeValue(forKey: staged.capabilityID)
        try? FileManager.default.removeItem(at: entry.privateURL)
    }

    private func requireNamespace(_ namespace: PersistenceNamespace) throws {
        guard namespace == account.namespace else {
            throw ProductionAuditExportError.namespaceMismatch
        }
    }

    private func preparePrivateRoot() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ProductionAuditExportError.invalidStagingRoot
            }
        } else {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: root.path
        )
    }
}
