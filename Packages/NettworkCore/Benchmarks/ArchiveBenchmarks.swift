import CryptoKit
import Foundation
import ImportExport

extension NettworkBenchmarks {
    static func prepareArchive(directory: URL, assetMiB: Int) throws {
        guard assetMiB <= 64 else { throw BenchmarkError.invalidInput }
        let assetsDirectory = directory.appendingPathComponent(ArchiveLayout.assetsDirectory)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x61, count: assetMiB * 1_024 * 1_024)
        let payloadDigest = digest(payload)
        let emptyDigest = digest(Data())
        var digests = [ArchiveLayout.recordsPath: emptyDigest, ArchiveLayout.auditPath: emptyDigest]
        var assets: [ArchiveAsset] = []
        for index in 0..<4 {
            let path = "\(ArchiveLayout.assetsDirectory)/asset-\(index).bin"
            try payload.write(to: directory.appendingPathComponent(path))
            digests[path] = payloadDigest
            assets.append(ArchiveAsset(relativePath: path, sha256: payloadDigest.sha256, size: payload.count))
        }
        try Data().write(to: directory.appendingPathComponent(ArchiveLayout.recordsPath))
        try Data().write(to: directory.appendingPathComponent(ArchiveLayout.auditPath))
        let root = ArchiveVerifier.rootDigest(for: digests)
        let manifest = ArchiveManifest(
            workspaceID: try fixedID(1), createdAt: Date(timeIntervalSince1970: 0), recordCounts: [:], assets: assets,
            auditRecordCount: 0, recordsSHA256: emptyDigest.sha256, auditSHA256: emptyDigest.sha256,
            auditHeadSHA256: ArchiveAuditChain.emptyHeadSHA256, rootSHA256: root)
        let marker = ArchiveCompletionMarker(
            rootSHA256: root, manifestCommitmentSHA256: try ArchiveManifestCommitment.digest(for: manifest), completedAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(ArchiveLayout.manifestPath))
        try encoder.encode(marker).write(to: directory.appendingPathComponent(ArchiveLayout.completionPath))
    }

    static func archiveMemory(directory: URL, assetMiB: Int) throws {
        try measure(workload: "archive-memory", size: assetMiB * 4 * 1_024 * 1_024, repetitions: 1, warmup: false) {
            let source = try FileBackedArchiveEntrySource(root: directory)
            let archive = try ArchiveVerifier().verify(source: source)
            guard archive.assets.count == 4 else { throw BenchmarkError.incorrectResult }
            return archive.assets.values.reduce(0) { $0 + $1.count }
        }
    }

    #if !NETTWORK_BASELINE
        static func archiveFile(directory: URL, assetMiB: Int) throws {
            try measure(workload: "archive-file", size: assetMiB * 4 * 1_024 * 1_024, repetitions: 1, warmup: false) {
                let source = try FileBackedArchiveEntrySource(root: directory)
                let archive = try ArchiveVerifier().verifyFileBacked(
                    source: source, stagingRoot: directory.deletingLastPathComponent().appendingPathComponent("private-staging"))
                defer { archive.discardIfUnadopted() }
                guard archive.manifest.assets.count == 4 else { throw BenchmarkError.incorrectResult }
                return archive.manifest.assets.reduce(0) { $0 + $1.byteCount }
            }
        }
    #endif

    private static func digest(_ data: Data) -> ArchiveDigest {
        ArchiveDigest(size: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
