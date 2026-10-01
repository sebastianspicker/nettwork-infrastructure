import Foundation
import XCTest

@testable import NetworkModel
@testable import WorkspaceChangeControl

/// The comparison only forgives the set order of payloads stored before
/// canonical set encoding; every other difference still rejects the payload.
final class CanonicalPayloadComparisonTests: XCTestCase {
    func testAcceptsReversedSetArrays() throws {
        let canonical = try CanonicalJSONCoding.encode(try makeOrder(reservedResourceIDs: Set((0..<4).map { _ in ObjectID() })))
        let legacy = try rewritten(canonical) { json in
            json["reservedResourceIDs"] = try XCTUnwrap(json["reservedResourceIDs"] as? [Any]).reversed() as [Any]
        }

        XCTAssertNotEqual(legacy, canonical)
        XCTAssertTrue(CanonicalPayloadComparison.matches(stored: legacy, reencoded: canonical))
    }

    func testRejectsExtraKey() throws {
        let canonical = try CanonicalJSONCoding.encode(try makeOrder(reservedResourceIDs: [ObjectID(), ObjectID()]))
        let stored = try rewritten(canonical) { json in json["unexpected"] = "value" }

        XCTAssertFalse(CanonicalPayloadComparison.matches(stored: stored, reencoded: try reencoded(stored)))
    }

    func testRejectsDuplicatedSetElement() throws {
        let canonical = try CanonicalJSONCoding.encode(try makeOrder(reservedResourceIDs: [ObjectID(), ObjectID()]))
        let stored = try rewritten(canonical) { json in
            let ids = try XCTUnwrap(json["reservedResourceIDs"] as? [Any])
            json["reservedResourceIDs"] = ids + [ids[0]]
        }

        XCTAssertFalse(CanonicalPayloadComparison.matches(stored: stored, reencoded: try reencoded(stored)))
    }

    func testRejectsAlternateSpellingsOfTheSameTree() {
        let reencoded = Data(#"{"a":[100,"b"]}"#.utf8)

        XCTAssertFalse(CanonicalPayloadComparison.matches(stored: Data(#"{"a":[1e2,"b"]}"#.utf8), reencoded: reencoded))
        XCTAssertFalse(CanonicalPayloadComparison.matches(stored: Data(#"{"a": [100,"b"]}"#.utf8), reencoded: reencoded))
        XCTAssertFalse(CanonicalPayloadComparison.matches(stored: Data(#"{"a":[100,"\u0062"]}"#.utf8), reencoded: reencoded))
        XCTAssertFalse(CanonicalPayloadComparison.matches(stored: Data(#"{"a":[1,"b"],"a":[100,"b"]}"#.utf8), reencoded: reencoded))
        XCTAssertFalse(CanonicalPayloadComparison.matches(stored: Data(#"{"a":["b",100]"#.utf8), reencoded: reencoded))
        XCTAssertTrue(CanonicalPayloadComparison.matches(stored: Data(#"{"a":["b",100]}"#.utf8), reencoded: reencoded))
    }

    func testKeepsBooleansNumbersAndStringsDistinct() {
        XCTAssertFalse(CanonicalPayloadComparison.matches(stored: Data("[1,1]".utf8), reencoded: Data("[1,0]".utf8)))
        XCTAssertFalse(CanonicalPayloadComparison.matches(stored: Data(#"["1",2]"#.utf8), reencoded: Data(#"[1,"2"]"#.utf8)))
        XCTAssertFalse(CanonicalPayloadComparison.matches(stored: Data("[true]".utf8), reencoded: Data("[1000]".utf8)))
    }

    private func reencoded(_ stored: Data) throws -> Data {
        try CanonicalJSONCoding.encode(try CanonicalJSONCoding.decode(WorkOrder.self, from: stored))
    }

    private func rewritten(_ canonical: Data, _ change: (inout [String: Any]) throws -> Void) throws -> Data {
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        try change(&json)
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
