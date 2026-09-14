import XCTest

@testable import NetworkModel
@testable import WorkspaceChangeControl

final class AuthoritativeMutationReadAssertionCompatibilityTests: XCTestCase {
    func testReadAssertionsAreConditionalOnlyAndRequireExactState() throws {
        let base = try makeMutation()
        let assertionKey = ResourceKey.object(ObjectID())
        let exact = ExactRecordPrecondition(systemFields: Data([7, 8]), changeTag: "read-v4")
        let assertion = AuthoritativeReadAssertion(
            resourceKey: assertionKey,
            recordType: "NettworkPort",
            schemaVersion: 1,
            encodedRecord: Data("{\"name\":\"unchanged\"}".utf8),
            precondition: exact
        )
        let preparedMutation = try mutation(
            from: base, readAssertions: [assertion], preconditions: base.preconditions + [.exactSystemFields(assertionKey, exact)])
        var state = validationState(for: preparedMutation)
        state.knownRecords[assertionKey] = exact

        try AuthoritativeMutationValidator.validate(preparedMutation, against: state)
        XCTAssertFalse(preparedMutation.resourceKeys.contains(assertionKey))
        XCTAssertFalse(preparedMutation.auditEvent.affectedResourceKeys.contains(assertionKey))
        XCTAssertFalse(preparedMutation.auditEvent.changes.contains { $0.resourceKey == assertionKey })

        XCTAssertThrowsError(
            try AuthoritativeMutationValidator.validate(
                try mutation(from: base, readAssertions: [assertion], preconditions: base.preconditions),
                against: state
            )
        ) { error in
            XCTAssertEqual(error as? AuthoritativeMutationValidationError, .missingPrecondition(assertionKey))
        }

        XCTAssertThrowsError(try AuthoritativeMutationValidator.validate(preparedMutation, against: validationState(for: base))) { error in
            XCTAssertEqual(error as? AuthoritativeMutationValidationError, .missingRecord(assertionKey))
        }
    }

    func testReadAssertionsRejectMalformedAndOverlappingDependencies() throws {
        let base = try makeMutation()
        let exact = ExactRecordPrecondition(systemFields: Data([7]), changeTag: "read-v1")
        let malformed = AuthoritativeReadAssertion(
            resourceKey: .object(ObjectID()),
            recordType: "NettworkPort",
            schemaVersion: 1,
            encodedRecord: Data(),
            precondition: exact
        )
        XCTAssertThrowsError(
            try AuthoritativeMutationValidator.validate(
                try mutation(from: base, readAssertions: [malformed], preconditions: base.preconditions + [.exactSystemFields(malformed.resourceKey, exact)]),
                against: validationState(for: base)
            )
        ) { error in
            XCTAssertEqual(error as? AuthoritativeMutationValidationError, .invalidReadAssertion(malformed.resourceKey))
        }

        let overlapping = AuthoritativeReadAssertion(
            resourceKey: base.saves[0].resourceKey,
            recordType: "NettworkPort",
            schemaVersion: 1,
            encodedRecord: Data("{}".utf8),
            precondition: exact
        )
        XCTAssertThrowsError(
            try AuthoritativeMutationValidator.validate(
                try mutation(
                    from: base, readAssertions: [overlapping], preconditions: base.preconditions + [.exactSystemFields(overlapping.resourceKey, exact)]),
                against: validationState(for: base)
            )
        ) { error in
            XCTAssertEqual(error as? AuthoritativeMutationValidationError, .readAssertionOverlapsMutation(overlapping.resourceKey))
        }
    }

    func testLegacyMutationEnvelopeDecodesWithoutReadAssertions() throws {
        let mutation = try makeMutation()
        let encoded = try JSONEncoder().encode(mutation)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "readAssertions")
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertTrue(try JSONDecoder().decode(AuthoritativeMutation.self, from: legacy).readAssertions.isEmpty)
    }

    func testLegacyWorkOrderWithoutIntentSchemaVersionDecodesAsV1Evidence() throws {
        let workOrder = WorkOrder(kind: .ipam, title: "Legacy reserved intent")
        let encoded = try JSONEncoder().encode(workOrder)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "intentSchemaVersion")
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertNil(try JSONDecoder().decode(WorkOrder.self, from: legacy).intentSchemaVersion)
    }
}
