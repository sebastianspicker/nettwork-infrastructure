import Foundation
import ImportExport

#if !NETTWORK_BASELINE
    extension NettworkBenchmarks {
        static func csvFile(directory: URL, rows: Int) throws {
            try measure(workload: "csv-file", size: rows * csvTables.count, repetitions: 1, warmup: false) {
                let records = try CSVImportBatchDecoder.records(source: BenchmarkCSVSource(directory: directory))
                guard records.count == rows * csvTables.count else { throw BenchmarkError.incorrectResult }
                return records.count
            }
        }
    }

    private struct BenchmarkCSVSource: CSVImportSource {
        let directory: URL

        func fileMetadata() throws -> [CSVImportFileMetadata] {
            try NettworkBenchmarks.csvTables.map { table in
                let url = directory.appendingPathComponent(CSVImportDocumentFilenames.filename(for: table))
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, let template = CSVSchemaV2.templates[table] else { throw BenchmarkError.invalidInput }
                return CSVImportFileMetadata(template: template, declaredByteCount: size)
            }
        }

        func openFile(_ file: CSVImportFileMetadata) throws -> AnyCSVByteChunkSource {
            let url = directory.appendingPathComponent(CSVImportDocumentFilenames.filename(for: file.table))
            return AnyCSVByteChunkSource(try BenchmarkCSVReader(url: url))
        }
    }

    private final class BenchmarkCSVReader: CSVByteChunkSource, Sendable {
        let handle: FileHandle

        init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
        deinit { try? handle.close() }

        func nextChunk() throws -> Data? {
            let chunk = try handle.read(upToCount: 64 * 1_024)
            return chunk?.isEmpty == false ? chunk : nil
        }
    }
#endif
