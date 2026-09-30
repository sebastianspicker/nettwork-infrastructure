import CloudSync
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

/// Pins the private prepare/publish/abort audit export: the document binds
/// the workspace zone, operation and hash-chained audit events in occurrence
/// order; a capability is namespace-bound and single-use; publication never
/// overwrites an existing file.
final class FileBackedProductionAuditExporterCharacterizationTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audit-export-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPublishedDocumentChainsTheNamespaceAuditEventsInOccurrenceOrder() async throws {
        let fixture = try await AuditExportFixture.make(directory: directory)
        let operationID = ObjectID()

        let staged = try await fixture.exporter.prepareAudit(operationID: operationID, in: fixture.namespace)
        let url = try await fixture.exporter.publishAudit(staged, in: fixture.namespace)

        XCTAssertEqual(url, fixture.destination.url.standardizedFileURL)
        let document = try CloudDeterministicCoding.decode(ProductionAuditExportDocument.self, from: try Data(contentsOf: url))
        let chain = try ArchiveAuditChain.encode(events: try [fixture.first, fixture.second].map { try CloudDeterministicCoding.encode($0) })
        let expected = ProductionAuditExportDocument(
            workspaceZone: fixture.namespace.workspaceZone, operationID: operationID, auditJSONL: chain.jsonl, eventCount: 2,
            auditHeadSHA256: chain.headSHA256)
        XCTAssertEqual(document, expected)
        XCTAssertEqual(document.version, ProductionAuditExportDocument.schemaVersion)
    }

    func testCapabilityIsSingleUseAndBoundToItsNamespace() async throws {
        let fixture = try await AuditExportFixture.make(directory: directory)
        let staged = try await fixture.exporter.prepareAudit(operationID: ObjectID(), in: fixture.namespace)

        await assertThrows(ProductionAuditExportError.namespaceMismatch) {
            try await fixture.exporter.publishAudit(staged, in: ServiceFixture.namespace())
        }
        _ = try await fixture.exporter.publishAudit(staged, in: fixture.namespace)
        try FileManager.default.removeItem(at: fixture.destination.url)
        await assertThrows(ProductionAuditExportError.unknownCapability) {
            try await fixture.exporter.publishAudit(staged, in: fixture.namespace)
        }
    }

    func testAbortDiscardsTheStagedExport() async throws {
        let fixture = try await AuditExportFixture.make(directory: directory)
        let staged = try await fixture.exporter.prepareAudit(operationID: ObjectID(), in: fixture.namespace)

        await fixture.exporter.abortAudit(staged, in: fixture.namespace)

        await assertThrows(ProductionAuditExportError.unknownCapability) {
            try await fixture.exporter.publishAudit(staged, in: fixture.namespace)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.url.path))
        let staging = try FileManager.default.contentsOfDirectory(atPath: fixture.privateRoot.path)
        XCTAssertEqual(staging, [], "Aborting removes the private staged bytes.")
    }

    func testPublicationNeverOverwritesAnExistingFile() async throws {
        let fixture = try await AuditExportFixture.make(directory: directory)
        try Data("existing".utf8).write(to: fixture.destination.url)
        let staged = try await fixture.exporter.prepareAudit(operationID: ObjectID(), in: fixture.namespace)

        await assertThrows(ProductionAuditExportError.destinationExists) {
            try await fixture.exporter.publishAudit(staged, in: fixture.namespace)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.destination.url), Data("existing".utf8))
    }

    func testPreparingForAnotherNamespaceIsRejected() async throws {
        let fixture = try await AuditExportFixture.make(directory: directory)

        await assertThrows(ProductionAuditExportError.namespaceMismatch) {
            try await fixture.exporter.prepareAudit(operationID: ObjectID(), in: ServiceFixture.namespace())
        }
    }
}

struct FixedAuditDestination: ProductionAuditExportDestinationProviding {
    let url: URL

    func destination(for _: ObjectID, namespace _: PersistenceNamespace) async throws -> URL { url }
}

/// Two audit events stored out of order, plus one work order that must not be
/// exported as an audit event.
struct AuditExportFixture {
    let namespace: PersistenceNamespace
    let first: AuditEvent
    let second: AuditEvent
    let privateRoot: URL
    let destination: FixedAuditDestination
    let exporter: FileBackedProductionAuditExporter

    static func make(directory: URL) async throws -> AuditExportFixture {
        let namespace = ServiceFixture.namespace()
        let store = try ServiceFixture.makeStore()
        let first = ServiceFixture.auditEvent(ticket: "CHG-1", at: 10)
        let second = ServiceFixture.auditEvent(ticket: "CHG-2", at: 20)
        let workOrder = WorkOrder(kind: .connect, title: "Not an audit event", creatorID: "owner")
        try await ServiceFixture.seed(
            store, namespace: namespace,
            records: [
                try ServiceFixture.auditRecord(second, namespace), try ServiceFixture.auditRecord(first, namespace),
                try ServiceFixture.mirror(workOrder, type: CloudRecordNaming.workOrderRecordType, namespace: namespace),
            ])
        let privateRoot = directory.appendingPathComponent("private", isDirectory: true)
        let destination = FixedAuditDestination(url: directory.appendingPathComponent("audit-export.json"))
        let exporter = FileBackedProductionAuditExporter(
            account: ServiceFixture.account(namespace), persistence: store, privateRoot: privateRoot, destination: destination)
        return AuditExportFixture(
            namespace: namespace, first: first, second: second, privateRoot: privateRoot, destination: destination, exporter: exporter)
    }
}
