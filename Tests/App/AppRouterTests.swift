import Foundation
import XCTest

@testable import Nettwork

final class AppRouterTests: XCTestCase {
    func testObjectDeepLinkParsesOpaqueUUID() throws {
        let identifier = try XCTUnwrap(UUID(uuidString: "A4B0E37E-2D92-4F93-9374-ABBD3C2CB84A"))
        let url = try XCTUnwrap(URL(string: "nettwork://object/\(identifier.uuidString)"))

        XCTAssertEqual(AppRoute(url: url), .object(identifier))
    }

    func testObjectDeepLinkRejectsHumanLabel() throws {
        let url = try XCTUnwrap(URL(string: "nettwork://object/SW-CORE-01"))

        XCTAssertNil(AppRoute(url: url))
    }

    @MainActor
    func testObjectDeepLinkReturnsWorkbenchToObjectScope() throws {
        let identifier = try XCTUnwrap(UUID(uuidString: "A4B0E37E-2D92-4F93-9374-ABBD3C2CB84A"))
        let url = try XCTUnwrap(URL(string: "nettwork://object/\(identifier.uuidString)"))
        let router = AppRouter()
        router.selectedSection = .ipam

        router.handle(url: url)

        XCTAssertEqual(router.selectedSection, .explore)
        XCTAssertEqual(router.deepLinkRequest?.route, .object(identifier))
    }

    func testFeatureInventoryCoversEveryRequiredSection() {
        XCTAssertEqual(
            Set(AppSection.allCases.map(\.title)),
            [
                "Explore", "Floor Plans", "Racks", "Trace", "Scan", "Work Orders",
                "IPAM", "Reports", "Import/Export", "Templates", "Audit",
                "Administration", "Reconciliation", "Labels",
            ]
        )
    }

    func testWorkbenchModesCoverObjectCentricDestinations() {
        XCTAssertEqual(
            Set(WorkbenchObjectMode.allCases.compactMap(\.section)),
            [.explore, .racks, .ipam, .trace]
        )
        XCTAssertNil(WorkbenchObjectMode.history.section)
        XCTAssertNil(WorkbenchObjectMode(section: .audit))
    }

    func testCompactMoreGroupsCoverEachOverflowDestinationOnce() {
        let groupedSections = CompactMoreGroup.allCases.flatMap(\.sections)

        XCTAssertEqual(groupedSections.count, Set(groupedSections).count)
        XCTAssertEqual(Set(groupedSections), Set(CompactTab.more.sections))
    }
}
