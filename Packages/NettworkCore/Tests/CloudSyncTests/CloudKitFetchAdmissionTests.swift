#if canImport(CloudKit)
    import CloudKit
    import XCTest

    @testable import CloudSync

    final class CloudKitFetchAdmissionTests: XCTestCase {
        func testAdmissionEnforcesAggregateRecordAndByteLimits() throws {
            var admission = try CloudKitFetchAdmission(maximumRecords: 2, maximumBytes: 10)

            try admission.admit(byteCounts: [2, 3])
            try admission.admit(byteCounts: [5])

            XCTAssertEqual(admission.recordCount, 2)
            XCTAssertEqual(admission.byteCount, 10)
            XCTAssertThrowsError(try admission.admit(byteCounts: [0])) { error in
                XCTAssertEqual(error as? CloudKitSyncEngineBatchSourceError, .batchAdmissionLimitExceeded)
            }
        }

        func testAdmissionRejectsByteOverflowWithoutChangingCounters() throws {
            var admission = try CloudKitFetchAdmission(maximumRecords: 3, maximumBytes: 8)
            try admission.admit(byteCounts: [3])

            XCTAssertThrowsError(try admission.admit(byteCounts: [4, 2])) { error in
                XCTAssertEqual(error as? CloudKitSyncEngineBatchSourceError, .batchAdmissionLimitExceeded)
            }
            XCTAssertEqual(admission.recordCount, 1)
            XCTAssertEqual(admission.byteCount, 3)
        }

        func testAdmissionRejectsInvalidPoliciesAndNegativeCounts() throws {
            XCTAssertThrowsError(try CloudKitFetchAdmission(maximumRecords: 0, maximumBytes: 1))
            XCTAssertThrowsError(try CloudKitFetchAdmission(maximumRecords: 1, maximumBytes: 0))

            var admission = try CloudKitFetchAdmission(maximumRecords: 1, maximumBytes: 1)
            XCTAssertThrowsError(try admission.admit(byteCounts: [-1]))
            XCTAssertEqual(admission.recordCount, 0)
            XCTAssertEqual(admission.byteCount, 0)
        }

        func testProductionDefaultsMatchSupportedWorkspaceEnvelope() {
            XCTAssertEqual(CloudKitSyncEngineBatchSourceAdapter.defaultMaximumBatchRecords, 250_000)
            XCTAssertEqual(CloudKitSyncEngineBatchSourceAdapter.defaultMaximumBatchBytes, 256 * 1_024 * 1_024)
        }
    }
#endif
