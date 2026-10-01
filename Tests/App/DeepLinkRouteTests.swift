import Foundation
import XCTest

@testable import Nettwork

/// External contract: `nettwork://object/<UUID>` names one opaque object and
/// every other shape is rejected without changing navigation state.
final class DeepLinkRouteTests: XCTestCase {
    private let identifier = UUID(uuidString: "A4B0E37E-2D92-4F93-9374-ABBD3C2CB84A")

    func testObjectRouteAcceptsSchemeAndHostCaseInsensitivelyAndLowercaseUUID() throws {
        let identifier = try XCTUnwrap(identifier)
        let lowercased = identifier.uuidString.lowercased()

        XCTAssertEqual(AppRoute(url: try url("NETTWORK://OBJECT/\(identifier.uuidString)")), .object(identifier))
        XCTAssertEqual(AppRoute(url: try url("nettwork://object/\(lowercased)")), .object(identifier))
        XCTAssertEqual(AppRoute(url: try url("nettwork://object/\(identifier.uuidString)/")), .object(identifier))
    }

    func testMalformedObjectRoutesAreRejected() throws {
        let uuid = try XCTUnwrap(identifier).uuidString
        let malformed = [
            "https://object/\(uuid)",
            "nettwork://device/\(uuid)",
            "nettwork://object",
            "nettwork://object/",
            "nettwork://object/\(uuid)/extra",
            "nettwork://object/not-a-uuid",
            "nettwork:object/\(uuid)",
        ]

        for string in malformed {
            XCTAssertNil(AppRoute(url: try url(string)), string)
        }
    }

    @MainActor
    func testRouterIgnoresMalformedURLWithoutChangingNavigation() throws {
        let router = AppRouter()
        router.selectedSection = .ipam

        router.handle(url: try url("nettwork://object/SW-CORE-01"))

        XCTAssertEqual(router.selectedSection, .ipam)
        XCTAssertNil(router.deepLinkRequest)
    }

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string), string)
    }
}
