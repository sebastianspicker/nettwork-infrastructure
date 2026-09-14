import Foundation
import ImportExport
import NetworkModel

/// Release-only measurements; correctness and scaling contracts live in tests.
@main
struct NettworkBenchmarks {
    static func main() throws {
        let arguments = CommandLine.arguments
        let workload = arguments.dropFirst().first ?? "ipam"
        let count = integer(arguments, index: 2, fallback: 2_048)
        let repetitions = integer(arguments, index: 3, fallback: 5)
        guard count > 0, repetitions > 0 else { throw BenchmarkError.invalidInput }
        switch workload {
        case "ipam": try ipam(count: count, repetitions: repetitions)
        case "trace": try trace(count: count, repetitions: repetitions)
        default: try fileWorkload(workload, arguments: arguments, count: count)
        }
    }

    static func fileWorkload(_ workload: String, arguments: [String], count: Int) throws {
        let url = try directory(arguments)
        switch workload {
        case "prepare-csv": try prepareCSV(directory: url, rows: count)
        case "csv-memory": try csvMemory(directory: url, rows: count)
        case "prepare-archive": try prepareArchive(directory: url, assetMiB: count)
        case "archive-memory": try archiveMemory(directory: url, assetMiB: count)
        #if !NETTWORK_BASELINE
            case "csv-file": try csvFile(directory: url, rows: count)
            case "archive-file": try archiveFile(directory: url, assetMiB: count)
        #endif
        default: throw BenchmarkError.invalidInput
        }
    }

    static func integer(_ arguments: [String], index: Int, fallback: Int) -> Int {
        guard arguments.count > index else { return fallback }
        return Int(arguments[index]) ?? fallback
    }

    static func fixedID(_ number: Int) throws -> ObjectID {
        guard let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", number)) else {
            throw BenchmarkError.invalidInput
        }
        return ObjectID(uuid)
    }

    static func ipam(count: Int, repetitions: Int) throws {
        guard count <= 65_536 else { throw BenchmarkError.invalidInput }
        let vrf = try fixedID(1)
        let prefixes = try (0..<count).map { index -> Prefix in
            guard let prefix = Prefix(id: try fixedID(index + 2), vrfID: vrf, cidr: "10.\(index / 256).\(index % 256).0/24") else {
                throw BenchmarkError.invalidInput
            }
            return prefix
        }
        let addresses = try (0..<count).map { index -> IPAddressRecord in
            guard let address = IPAddress(parsing: "10.\(index / 256).\(index % 256).10") else { throw BenchmarkError.invalidInput }
            return IPAddressRecord(vrfID: vrf, address: address)
        }
        try measure(workload: "ipam", size: count, repetitions: repetitions) {
            try DefaultIPAMValidationService.validate(prefixes: prefixes, addresses: addresses, vlans: [])
            return prefixes.count + addresses.count
        }
    }

    static func trace(count: Int, repetitions: Int) throws {
        let device = try fixedID(1)
        let ports = try (0...count).map {
            Port(id: try fixedID($0 + 2), deviceID: device, label: "P\($0)", medium: .copper, connector: .rj45)
        }
        let links = try (0..<count).map {
            InternalLink(id: try fixedID(count + $0 + 3), endpointA: ports[$0].id, endpointB: ports[$0 + 1].id)
        }
        let topology = PhysicalTopology(ports: ports, internalLinks: links)
        try measure(workload: "trace", size: count, repetitions: repetitions) {
            #if NETTWORK_BASELINE
                let paths = try DefaultPathTraceService.trace(from: ports[0].id, in: topology)
                return paths.count + (paths.map { $0.segments.count }.max() ?? 0)
            #else
                let summary = try DefaultPathTraceService.summarize(from: ports[0].id, in: topology)
                return summary.exploredPathCount + summary.longestSegmentCount
            #endif
        }
    }

    static let csvTables: [CSVTable] = [.devices, .locations, .moduleTemplates, .vrfs]

    static func directory(_ arguments: [String]) throws -> URL {
        guard arguments.count == 5 else { throw BenchmarkError.invalidInput }
        return URL(fileURLWithPath: arguments[4], isDirectory: true)
    }

    static func prepareCSV(directory: URL, rows: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for table in csvTables {
            guard let template = CSVSchemaV2.templates[table] else { throw BenchmarkError.invalidInput }
            let url = directory.appendingPathComponent(CSVImportDocumentFilenames.filename(for: table))
            try CSVExport.encode(rows: [template.columns]).write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            for index in 0..<rows {
                let row = template.columns.map { column in
                    column == "name" ? "row-\(index)-" + String(repeating: "x", count: 512) : ""
                }
                try handle.write(contentsOf: CSVExport.encode(rows: [row]))
            }
        }
    }

    static func csvMemory(directory: URL, rows: Int) throws {
        try measure(workload: "csv-memory", size: rows * csvTables.count, repetitions: 1, warmup: false) {
            let files = try csvTables.map { table in
                try CSVImportDocument.File(
                    table: table, bytes: Data(contentsOf: directory.appendingPathComponent(CSVImportDocumentFilenames.filename(for: table))))
            }
            let records = try CSVImportDocument(files: files).decodeRecords()
            guard records.count == rows * csvTables.count else { throw BenchmarkError.incorrectResult }
            return records.count
        }
    }

    static func measure(workload: String, size: Int, repetitions: Int, warmup: Bool = true, operation: () throws -> Int) throws {
        if warmup { _ = try operation() }
        var samples: [Double] = []
        var checksum = 0
        for _ in 0..<repetitions {
            let start = ContinuousClock.now
            checksum += try operation()
            let duration = start.duration(to: .now).components
            samples.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
        }
        let output: [String: Any] = ["workload": workload, "size": size, "milliseconds": samples, "checksum": checksum]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

enum BenchmarkError: Error { case invalidInput, incorrectResult }
