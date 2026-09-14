#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import XCTest

    @testable import CloudSync

    final class CloudKitDeletionPreconditionFetchTests: XCTestCase {
        func testBoundedFetchSubmitsOneOperationAndReturnsEveryRecord() async throws {
            let count = CloudStagedTransferGarbageCollector.maximumDeleteMembersPerPage
            let recordIDs = (0..<count).map { recordID("record-\($0)") }
            let submissions = FetchSubmissionRecorder()

            let records = try await CloudKitRecordFetchBatch.fetch(recordIDs) { operation in
                submissions.record(operation)
                for recordID in recordIDs {
                    operation.perRecordResultBlock?(
                        recordID, .success(CKRecord(recordType: "Device", recordID: recordID)))
                }
                operation.fetchRecordsResultBlock?(.success(()))
            }

            XCTAssertEqual(submissions.count, 1)
            XCTAssertEqual(submissions.recordIDs, recordIDs)
            XCTAssertEqual(Set(records.keys), Set(recordIDs))
        }

        func testEmptyFetchSubmitsNoOperation() async throws {
            let submissions = FetchSubmissionRecorder()

            let records = try await CloudKitRecordFetchBatch.fetch([]) { operation in
                submissions.record(operation)
            }

            XCTAssertEqual(submissions.count, 0)
            XCTAssertTrue(records.isEmpty)
        }

        func testSubmittedPerRecordErrorBlocksLaterStage() async {
            let recordID = recordID("denied")
            let stage = LaterStageProbe()

            do {
                _ = try await CloudKitRecordFetchBatch.fetch([recordID]) { operation in
                    operation.perRecordResultBlock?(
                        recordID, .failure(CKError(.permissionFailure)))
                    operation.fetchRecordsResultBlock?(.failure(CKError(.partialFailure)))
                }
                stage.advance()
                XCTFail("Expected per-record failure")
            } catch let error as CKError {
                XCTAssertEqual(error.code, .permissionFailure)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(stage.didAdvance)
        }

        func testSubmittedMissingResultBlocksLaterStage() async {
            let stage = LaterStageProbe()

            do {
                _ = try await CloudKitRecordFetchBatch.fetch([recordID("missing")]) { operation in
                    operation.fetchRecordsResultBlock?(.success(()))
                }
                stage.advance()
                XCTFail("Expected missing-result failure")
            } catch let error as CKError {
                XCTAssertEqual(error.code, .unknownItem)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(stage.didAdvance)
        }

        func testChangedTagMapsToServerRecordChanged() {
            let recordID = recordID("changed")
            let record = CKRecord(recordType: "Device", recordID: recordID)

            XCTAssertThrowsError(
                try CloudKitDeletionPreconditionValidator.validate(
                    [recordID: record], expectedChangeTags: [recordID: "expected-change-tag"])
            ) { error in
                XCTAssertEqual((error as? CKError)?.code, .serverRecordChanged)
            }
        }

        func testPerRecordFailureWinsOverOverallPartialFailure() {
            let first = recordID("first")
            let second = recordID("second")
            let accumulator = CloudKitRecordFetchAccumulator(expected: [first, second])
            accumulator.consume(
                recordID: first,
                result: .failure(CKError(.permissionFailure)))
            accumulator.consume(
                recordID: second,
                result: .success(CKRecord(recordType: "Device", recordID: second)))

            assertCKError(
                accumulator.result(overallError: CKError(.partialFailure)),
                code: .permissionFailure)
        }

        func testSuccessfulOperationWithMissingResultMapsToUnknownItem() {
            let missing = recordID("missing")
            let accumulator = CloudKitRecordFetchAccumulator(expected: [missing])

            assertCKError(accumulator.result(), code: .unknownItem)
        }

        func testEarlierMissingResultCannotHideLaterPerRecordFailure() {
            let missing = recordID("missing")
            let denied = recordID("denied")
            let accumulator = CloudKitRecordFetchAccumulator(expected: [missing, denied])
            accumulator.consume(recordID: denied, result: .failure(CKError(.permissionFailure)))

            assertCKError(
                accumulator.result(overallError: CKError(.partialFailure)),
                code: .permissionFailure)
        }

        func testPartialFailureWithoutRecordResultMapsToUnknownItem() {
            let accumulator = CloudKitRecordFetchAccumulator(expected: [recordID("missing")])

            assertCKError(accumulator.result(overallError: CKError(.partialFailure)), code: .unknownItem)
        }

        func testTransportFailureWithoutCallbacksRemainsRetryable() {
            let accumulator = CloudKitRecordFetchAccumulator(expected: [recordID("unfetched")])

            assertCKError(accumulator.result(overallError: CKError(.networkFailure)), code: .networkFailure)
        }

        func testOverallErrorIsPreservedAfterAllPerRecordSuccesses() {
            let recordID = recordID("present")
            let accumulator = CloudKitRecordFetchAccumulator(expected: [recordID])
            accumulator.consume(
                recordID: recordID,
                result: .success(CKRecord(recordType: "Device", recordID: recordID)))

            assertCKError(
                accumulator.result(overallError: CKError(.serviceUnavailable)),
                code: .serviceUnavailable)
        }

        private func recordID(_ name: String) -> CKRecord.ID {
            CKRecord.ID(
                recordName: name,
                zoneID: CKRecordZone.ID(zoneName: "zone", ownerName: "owner"))
        }

        private func assertCKError<Value>(
            _ result: Result<Value, Error>, code: CKError.Code,
            file: StaticString = #filePath, line: UInt = #line
        ) {
            switch result {
            case .success:
                XCTFail("Expected CloudKit error", file: file, line: line)
            case .failure(let error):
                XCTAssertEqual((error as? CKError)?.code, code, file: file, line: line)
            }
        }
    }

    private final class FetchSubmissionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var operations: [CKFetchRecordsOperation] = []

        var count: Int { locked { operations.count } }
        var recordIDs: [CKRecord.ID] { locked { operations.flatMap { $0.recordIDs ?? [] } } }

        func record(_ operation: CKFetchRecordsOperation) {
            locked { operations.append(operation) }
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private final class LaterStageProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var advanced = false

        var didAdvance: Bool { locked { advanced } }

        func advance() {
            locked { advanced = true }
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }
#endif
