import Foundation
import ImportExport
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

#if os(iOS)
    import UIKit
#endif

final class ProductionPlatformAdaptersTests: XCTestCase {
    func testScanPayloadGateAcceptsOnlyOneStrictOpaqueObjectIDPerSession() {
        let objectID = ObjectID(UUID(uuidString: "B56A8B77-CCDC-463A-8987-36C9E01D65C3")!)
        let route = ObjectLink.url(for: objectID).absoluteString
        var gate = PlatformScanPayloadGate()

        XCTAssertEqual(gate.accept(route), objectID)
        XCTAssertNil(gate.accept(route), "Repeated camera frames must not resolve twice.")
        XCTAssertNil(gate.accept("https://example.invalid/object/\(objectID)"))
        XCTAssertNil(gate.accept("nettwork://object/not-a-uuid"))
    }

    func testScanPayloadGateResetsOnlyAtANewCaptureSession() {
        let objectID = ObjectID(UUID(uuidString: "A5C063B1-E55C-447E-BD24-D2C9EF78C87D")!)
        let route = ObjectLink.url(for: objectID).absoluteString
        var gate = PlatformScanPayloadGate()

        XCTAssertNotNil(gate.accept(route))
        gate.reset()
        XCTAssertEqual(gate.accept(route), objectID)
    }

    func testLabelLayoutRejectsOutOfPageDimensions() {
        var configuration = LabelSheetConfiguration()
        configuration.columns = 5
        configuration.labelWidthMillimeters = 100

        XCTAssertThrowsError(try PlatformLabelPDFLayout(configuration: configuration))
    }

    func testLabelLayoutKeepsPageLocalRectsInsideA4AndAdvancesAtCapacity() throws {
        var configuration = LabelSheetConfiguration()
        configuration.columns = 2
        configuration.rows = 2
        let layout = try PlatformLabelPDFLayout(configuration: configuration)

        let first = layout.placement(forLabelAt: 0)
        let lastOnFirstPage = layout.placement(forLabelAt: layout.labelsPerPage - 1)
        let firstOnSecondPage = layout.placement(forLabelAt: layout.labelsPerPage)

        XCTAssertEqual(first.pageIndex, 0)
        XCTAssertEqual(lastOnFirstPage.pageIndex, 0)
        XCTAssertEqual(firstOnSecondPage.pageIndex, 1)
        XCTAssertEqual(first.rect, firstOnSecondPage.rect)
        XCTAssertGreaterThanOrEqual(lastOnFirstPage.rect.minX, layout.margin)
        XCTAssertGreaterThanOrEqual(lastOnFirstPage.rect.minY, layout.margin)
        XCTAssertLessThanOrEqual(lastOnFirstPage.rect.maxX, PlatformLabelPDFLayout.pageSize.width - layout.margin)
        XCTAssertLessThanOrEqual(lastOnFirstPage.rect.maxY, PlatformLabelPDFLayout.pageSize.height - layout.margin)
    }

    func testLabelPDFContainsOnlyValidatedOpaqueRoutes() async throws {
        let objectID = ObjectID(UUID(uuidString: "C7E7C64F-EBF9-40B3-9B68-B94BEE931C51")!)
        let label = PrivacySafeLabel(objectID: objectID, assetCode: "SW-CORE-01", checkText: "A7")
        let document = try await ProductionLabelPDFGenerator().makePDF(
            labels: [label],
            configuration: LabelSheetConfiguration()
        )

        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.data.starts(with: Data("%PDF".utf8)))
        XCTAssertTrue(document.data.contains(Data("%%EOF".utf8)))
    }

    func testLabelPDFUsesAPageForEachCapacityBoundary() async throws {
        var configuration = LabelSheetConfiguration()
        configuration.columns = 2
        configuration.rows = 2
        let labels = (1...5).map { index in
            PrivacySafeLabel(
                objectID: ObjectID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!),
                assetCode: AssetCode("SW-\(index)"),
                checkText: "A\(index)"
            )
        }

        let document = try await ProductionLabelPDFGenerator().makePDF(labels: labels, configuration: configuration)

        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.data.starts(with: Data("%PDF".utf8)))
        XCTAssertTrue(document.data.contains(Data("%%EOF".utf8)))
    }

    func testQRCodePayloadIsOnlyTheValidatedCanonicalObjectRoute() throws {
        let label = PrivacySafeLabel(objectID: ObjectID(), assetCode: "SW-CORE-01", checkText: "A7")
        let payload = try ProductionLabelPDFGenerator().qrPayload(for: label)

        XCTAssertEqual(payload, Data(label.opaqueRoute.absoluteString.utf8))
        XCTAssertFalse(payload.contains(Data(label.assetCode.value.utf8)))
        XCTAssertFalse(payload.contains(Data(label.checkText.utf8)))
    }

    func testCSVDirectorySourceRejectsReplacementAndExplicitClose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("devices.csv")
        let template = CSVSchemaV2.templates[.devices]!
        let bytes = CSVExport.encode(rows: [template.columns])
        try bytes.write(to: file)
        let source = try ProductionCSVDirectoryPackageSource.source(at: directory)
        let metadata = try XCTUnwrap(source.fileMetadata().first)

        try FileManager.default.removeItem(at: file)
        try bytes.write(to: file)
        XCTAssertThrowsError(try source.openFile(metadata))
        source.close()
        XCTAssertThrowsError(try source.fileMetadata())
    }

    func testLabelPDFRejectsUnsafeCheckText() async {
        let label = PrivacySafeLabel(objectID: ObjectID(), assetCode: "SW-CORE-01", checkText: "A7\n10.0.0.1")

        await XCTAssertThrowsErrorAsync {
            _ = try await ProductionLabelPDFGenerator().makePDF(
                labels: [label],
                configuration: LabelSheetConfiguration()
            )
        }
    }

    @MainActor
    func testSystemCapabilityFactoryConstructsNativeAdapters() {
        let capabilities: ProductionRuntimeAssembly.OrganizationInput.PlatformCapabilities
        #if os(iOS)
            capabilities = .system(presentationContext: IOSPresentationContext())
        #else
            capabilities = .system()
        #endif

        XCTAssertTrue(capabilities.scanCapture { _ in } is ProductionScanCaptureAdapter)
        XCTAssertTrue(capabilities.labelGenerator() is ProductionLabelPDFGenerator)
        XCTAssertTrue(capabilities.labelExporter() is PlatformLabelPDFExporter)
        XCTAssertTrue(capabilities.labelPrinter() is PlatformLabelPDFPrinter)
    }

    @MainActor
    func testOrganizationCapabilityOverrideWinsAsACompleteSet() {
        let custom = ProductionRuntimeAssembly.OrganizationInput.PlatformCapabilities(
            scanCapture: { _ in CustomScanCapture() },
            labelGenerator: { CustomLabelGenerator() },
            labelExporter: { CustomLabelExporter() },
            labelPrinter: { CustomLabelPrinter() }
        )
        let system: ProductionRuntimeAssembly.OrganizationInput.PlatformCapabilities
        #if os(iOS)
            system = .system(presentationContext: IOSPresentationContext())
        #else
            system = .system()
        #endif

        let resolved = ProductionRuntimeAssembly.resolvedPlatformCapabilities(
            organizationOverride: custom,
            system: system
        )

        XCTAssertTrue(resolved.scanCapture { _ in } is CustomScanCapture)
        XCTAssertTrue(resolved.labelGenerator() is CustomLabelGenerator)
        XCTAssertTrue(resolved.labelExporter() is CustomLabelExporter)
        XCTAssertTrue(resolved.labelPrinter() is CustomLabelPrinter)
    }

    #if os(iOS)
        @MainActor
        func testPresentationContextDoesNotRetainItsSceneAnchor() {
            let context = IOSPresentationContext()
            weak var weakAnchor: UIViewController?

            autoreleasepool {
                let anchor = UIViewController()
                weakAnchor = anchor
                context.bind(anchor: anchor)
            }

            XCTAssertNil(weakAnchor)
            XCTAssertNil(context.presentingViewController)
        }
    #endif
}

private struct CustomScanCapture: ScanCapturing {
    func availability() async -> ScanCaptureAvailability { .available }
    func requestPermission() async -> ScanCaptureAvailability { .available }
    func start() async throws {}
    func stop() async {}
}

private struct CustomLabelGenerator: LabelPDFGenerating {
    func makePDF(labels _: [PrivacySafeLabel], configuration _: LabelSheetConfiguration) async throws -> LabelPDFDocument {
        fatalError("Type-only fixture")
    }
}

private struct CustomLabelExporter: LabelPDFExporting {
    func export(_: LabelPDFDocument) async throws {}
}

private struct CustomLabelPrinter: LabelPrinting {
    func print(_: LabelPDFDocument) async throws {}
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: @escaping () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected an error.", file: file, line: line)
        } catch {}
    }
}
