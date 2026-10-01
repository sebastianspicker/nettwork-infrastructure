import Foundation
import ImportExport
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

final class ProductionArchiveRestoreInputTests: XCTestCase {
    func testNativeArchiveUsesDurableAssetsWithLegacyReceiptAndEntryEquivalence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceRoot = directory.appendingPathComponent("source")
        let asset = try writeArchive(to: sourceRoot)
        let memory = ProductionArchiveRestoreInput.memory(try ArchiveVerifier().verify(source: FileBackedArchiveEntrySource(root: sourceRoot)))
        let verified = try ArchiveVerifier().verifyFileBacked(
            source: FileBackedArchiveEntrySource(root: sourceRoot), stagingRoot: directory.appendingPathComponent("verification"))
        defer { verified.discardIfUnadopted() }
        let file = ProductionArchiveRestoreInput.file(verified)
        let target = PersistenceNamespace(
            containerIdentifier: "test", cloudKitAccountRecordName: "owner", workspaceID: ObjectID(), zoneName: "target",
            zoneOwnerRecordName: "owner", sessionGeneration: 1)
        let operation = ObjectID()

        XCTAssertEqual(file.manifest, memory.manifest)
        XCTAssertEqual(file.rootSHA256, memory.rootSHA256)
        XCTAssertEqual(try file.expectedReceipt(target: target, operationID: operation), try memory.expectedReceipt(target: target, operationID: operation))
        XCTAssertEqual(try file.readEntry(at: ArchiveLayout.recordsPath), try memory.readEntry(at: ArchiveLayout.recordsPath))
        let filePayload = try file.assetPayload(for: asset)
        XCTAssertEqual(filePayload.bytes, try memory.assetPayload(for: asset).bytes)
        guard case .durableFile(let url) = filePayload.storage else {
            return XCTFail("Native restore must retain a file capability instead of asset bytes in each envelope")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let descriptor = try verified.assetDescriptor(for: asset, fieldName: "workspaceAsset")
        XCTAssertEqual(try descriptor.validatedBytes(), filePayload.bytes)

        try Data("substituted".utf8).write(to: url)
        XCTAssertThrowsError(try file.assetPayload(for: asset))
        XCTAssertThrowsError(try descriptor.validatedBytes())
    }

    private func writeArchive(to directory: URL) throws -> ArchiveAsset {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(ArchiveLayout.assetsDirectory), withIntermediateDirectories: true)
        let bytes = Data("asset payload".utf8)
        let emptyDigest = CloudRecordAssetDescriptor.sha256(for: Data())
        let asset = ArchiveAsset(relativePath: "assets/item.bin", sha256: CloudRecordAssetDescriptor.sha256(for: bytes), size: bytes.count)
        let root = ArchiveVerifier.rootDigest(for: [
            ArchiveLayout.recordsPath: ArchiveDigest(size: 0, sha256: emptyDigest),
            ArchiveLayout.auditPath: ArchiveDigest(size: 0, sha256: emptyDigest),
            asset.relativePath: ArchiveDigest(size: bytes.count, sha256: asset.sha256),
        ])
        let manifest = ArchiveManifest(
            workspaceID: ObjectID(), createdAt: Date(timeIntervalSince1970: 0), recordCounts: [:], assets: [asset], auditRecordCount: 0,
            recordsSHA256: emptyDigest, auditSHA256: emptyDigest, auditHeadSHA256: ArchiveAuditChain.emptyHeadSHA256, rootSHA256: root)
        let marker = ArchiveCompletionMarker(
            rootSHA256: root, manifestCommitmentSHA256: try ArchiveManifestCommitment.digest(for: manifest), completedAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(ArchiveLayout.manifestPath))
        try encoder.encode(marker).write(to: directory.appendingPathComponent(ArchiveLayout.completionPath))
        try Data().write(to: directory.appendingPathComponent(ArchiveLayout.recordsPath))
        try Data().write(to: directory.appendingPathComponent(ArchiveLayout.auditPath))
        try bytes.write(to: directory.appendingPathComponent(asset.relativePath))
        return asset
    }
}
