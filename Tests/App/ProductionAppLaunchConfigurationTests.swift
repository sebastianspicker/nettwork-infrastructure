import Foundation
import XCTest

@testable import Nettwork

@MainActor
final class ProductionAppLaunchConfigurationTests: XCTestCase {
    func testAbsentConfigurationKeepsProductionProviderUnconfigured() throws {
        XCTAssertNil(try ProductionAppLaunchConfiguration.providerName(from: nil))
    }

    func testEmptyConfigurationIsRejected() {
        XCTAssertThrowsError(try ProductionAppLaunchConfiguration.providerName(from: "  \n")) { error in
            XCTAssertEqual(
                (error as? ProductionAppLaunchError)?.errorDescription,
                ProductionAppLaunchError.invalidProviderName.errorDescription)
        }
    }

    func testNonStringConfigurationIsRejected() {
        XCTAssertThrowsError(try ProductionAppLaunchConfiguration.providerName(from: 42)) { error in
            XCTAssertEqual(
                (error as? ProductionAppLaunchError)?.errorDescription,
                ProductionAppLaunchError.invalidProviderName.errorDescription)
        }
    }

    func testUnavailableProviderClassIsRejected() {
        XCTAssertThrowsError(
            try ProductionAppLaunchConfiguration.providerType(
                named: "MissingOrganizationProvider",
                classLookup: { _ in nil }
            )
        ) { error in
            XCTAssertEqual(
                (error as? ProductionAppLaunchError)?.errorDescription,
                ProductionAppLaunchError.providerClassUnavailable("MissingOrganizationProvider").errorDescription
            )
        }
    }

    func testNSObjectBackedProviderTypeResolvesWithoutBuildingOrganizationInput() throws {
        let providerType = try ProductionAppLaunchConfiguration.providerType(
            named: "TestOrganizationProvider",
            classLookup: { name in name == "TestOrganizationProvider" ? TestOrganizationProvider.self : nil }
        )

        XCTAssertTrue(providerType == TestOrganizationProvider.self)
    }
}

@MainActor
private final class TestOrganizationProvider: NSObject, ProductionRuntimeOrganizationInputProviding {
    override init() {
        super.init()
    }

    func makeOrganizationInput() throws -> ProductionRuntimeAssembly.OrganizationInput {
        fatalError("Configuration resolution must not build an organization input.")
    }
}
