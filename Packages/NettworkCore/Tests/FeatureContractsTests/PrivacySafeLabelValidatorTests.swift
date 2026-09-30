import FeatureContracts
import Foundation
import NetworkModel
import XCTest

final class PrivacySafeLabelValidatorTests: XCTestCase {
    func testAcceptsCanonicalRouteNormalizedAssetCodeAndBoundedCheckText() throws {
        let label = PrivacySafeLabel(objectID: ObjectID(), assetCode: "SW-CORE-01", checkText: "A7")

        XCTAssertNoThrow(try PrivacySafeLabelValidator.validate(label))
        XCTAssertEqual(ObjectLink.objectID(from: label.opaqueRoute), label.objectID)
        XCTAssertEqual(try PrivacySafeLabelValidator.validated([label]), [label])
    }

    func testRejectsCheckTextCarryingTopologyOrExceedingTheBound() {
        let objectID = ObjectID()
        let atLimit = String(repeating: "A", count: PrivacySafeLabelValidator.maximumCheckTextLength)
        let overLimit = String(repeating: "A", count: PrivacySafeLabelValidator.maximumCheckTextLength + 1)

        XCTAssertNoThrow(try PrivacySafeLabelValidator.validate(PrivacySafeLabel(objectID: objectID, assetCode: "SW-1", checkText: atLimit)))
        assertValidationError(.invalidPayload) {
            try PrivacySafeLabelValidator.validate(PrivacySafeLabel(objectID: objectID, assetCode: "SW-1", checkText: overLimit))
        }
        assertValidationError(.invalidPayload) {
            try PrivacySafeLabelValidator.validate(PrivacySafeLabel(objectID: objectID, assetCode: "SW-1", checkText: "A7\n10.0.0.1"))
        }
    }

    func testRejectsBatchesAboveTheSheetMaximum() {
        let labels = (0...PrivacySafeLabelValidator.maximumLabels).map { index in
            PrivacySafeLabel(objectID: ObjectID(), assetCode: AssetCode("SW-\(index)"), checkText: "A1")
        }

        XCTAssertEqual(labels.count, 101)
        assertValidationError(.tooManyLabels) { _ = try PrivacySafeLabelValidator.validated(labels) }
        XCTAssertNoThrow(try PrivacySafeLabelValidator.validated(Array(labels.prefix(PrivacySafeLabelValidator.maximumLabels))))
    }

    func testRejectsTheSameObjectReturnedTwice() {
        let objectID = ObjectID()
        let first = PrivacySafeLabel(objectID: objectID, assetCode: "SW-1", checkText: "A1")
        let second = PrivacySafeLabel(objectID: objectID, assetCode: "SW-2", checkText: "B2")

        assertValidationError(.duplicateObjectID) { _ = try PrivacySafeLabelValidator.validated([first, second]) }
    }

    private func assertValidationError(
        _ expected: PrivacySafeLabelValidationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? PrivacySafeLabelValidationError, expected, file: file, line: line)
        }
    }
}
