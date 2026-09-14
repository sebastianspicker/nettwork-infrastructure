#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation

    extension CloudKitRecordTransport {
        func fetchDeletionPreconditionRecords(
            _ recordIDs: [CKRecord.ID],
            in database: CKDatabase
        ) async throws -> [CKRecord.ID: CKRecord] {
            try await CloudKitRecordFetchBatch.fetch(recordIDs) { operation in
                database.add(operation)
            }
        }
    }

    typealias CloudKitRecordFetchSubmission = @Sendable (CKFetchRecordsOperation) -> Void

    enum CloudKitRecordFetchBatch {
        static func fetch(
            _ recordIDs: [CKRecord.ID],
            submit: CloudKitRecordFetchSubmission
        ) async throws -> [CKRecord.ID: CKRecord] {
            guard !recordIDs.isEmpty else { return [:] }
            return try await withCheckedThrowingContinuation { continuation in
                let accumulator = CloudKitRecordFetchAccumulator(expected: recordIDs)
                let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
                operation.perRecordResultBlock = { recordID, result in
                    accumulator.consume(recordID: recordID, result: result)
                }
                operation.fetchRecordsResultBlock = { result in
                    switch result {
                    case .success: continuation.resume(with: accumulator.result())
                    case .failure(let error): continuation.resume(with: accumulator.result(overallError: error))
                    }
                }
                submit(operation)
            }
        }
    }

    enum CloudKitDeletionPreconditionValidator {
        static func validate(
            _ records: [CKRecord.ID: CKRecord],
            expectedChangeTags: [CKRecord.ID: String]
        ) throws {
            guard records.count == expectedChangeTags.count else { throw CKError(.unknownItem) }
            for recordID in expectedChangeTags.keys.sorted(by: recordIDLess) {
                guard let record = records[recordID] else { throw CKError(.unknownItem) }
                guard record.recordID == recordID,
                    record.recordChangeTag == expectedChangeTags[recordID]
                else { throw CKError(.serverRecordChanged) }
            }
        }

        private static func recordIDLess(_ lhs: CKRecord.ID, _ rhs: CKRecord.ID) -> Bool {
            if lhs.zoneID.ownerName != rhs.zoneID.ownerName {
                return lhs.zoneID.ownerName < rhs.zoneID.ownerName
            }
            if lhs.zoneID.zoneName != rhs.zoneID.zoneName {
                return lhs.zoneID.zoneName < rhs.zoneID.zoneName
            }
            return lhs.recordName < rhs.recordName
        }
    }

    final class CloudKitRecordFetchAccumulator: @unchecked Sendable {
        private let expected: [CKRecord.ID]
        private let lock = NSLock()
        private var records: [CKRecord.ID: CKRecord] = [:]
        private var errors: [CKRecord.ID: Error] = [:]

        init(expected: [CKRecord.ID]) { self.expected = expected }

        func consume(recordID: CKRecord.ID, result: Result<CKRecord, Error>) {
            lock.lock()
            defer { lock.unlock() }
            switch result {
            case .success(let record): records[recordID] = record
            case .failure(let error): errors[recordID] = error
            }
        }

        func result(overallError: Error? = nil) -> Result<[CKRecord.ID: CKRecord], Error> {
            lock.lock()
            defer { lock.unlock() }
            for recordID in expected {
                if let error = errors[recordID] { return .failure(error) }
            }
            if let overallError, (overallError as? CKError)?.code != .partialFailure {
                return .failure(overallError)
            }
            for recordID in expected {
                guard records[recordID] != nil else {
                    return .failure(CKError(.unknownItem))
                }
            }
            if let overallError { return .failure(overallError) }
            return .success(records)
        }
    }
#endif
