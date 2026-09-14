import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import ImportExport

final class CSVWorkspaceExporterTests: XCTestCase {
    func testSchemaCompleteExportRoundTripsV2PortTemplateIdentity() throws {
        let deviceID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
        let portID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000102")!)
        let templatePortID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000103")!)
        let export = try CSVWorkspaceExporter.export(
            CSVWorkspaceExportProjection(
                ports: [
                    NetworkModel.Port(
                        id: portID,
                        deviceID: deviceID,
                        templatePortID: templatePortID,
                        label: "Gi0/1",
                        medium: .copper,
                        connector: .rj45
                    )
                ]
            )
        )

        XCTAssertEqual(Set(export.files.map(\.table)), Set(CSVTable.allCases))
        let imports = try export.document.decodeRecords()
        let port = try XCTUnwrap(imports.first(where: { $0.table == CSVTable.ports.rawValue }))
        XCTAssertEqual(port.values["templatePortID"], templatePortID.description)
        let reconstructed = try WorkspaceTransferRecordReconstruction.record(from: port)
        let decoded = try WorkspaceTransferCoding.decode(NetworkModel.Port.self, from: reconstructed.payload)
        XCTAssertEqual(decoded.templatePortID, templatePortID)
    }

    func testExportUsesSharedFormulaSafeRFC4180Encoder() throws {
        let location = Location(name: "\u{0001}=SUM(A1:A2)")
        let export = try CSVWorkspaceExporter.export(CSVWorkspaceExportProjection(locations: [location]))
        let locationFile = try XCTUnwrap(export.files.first(where: { $0.table == .locations }))
        XCTAssertTrue(String(decoding: locationFile.bytes, as: UTF8.self).contains("'\u{0001}=SUM(A1:A2)"))
        XCTAssertTrue(String(decoding: locationFile.bytes, as: UTF8.self).contains("\r\n"))
    }

    func testExportRejectsAnImporterUnsafeCellBeforeEncoding() {
        let oversized = Location(name: String(repeating: "x", count: CSVImportLimits.maximumCellBytes + 1))
        XCTAssertThrowsError(try CSVWorkspaceExporter.export(CSVWorkspaceExportProjection(locations: [oversized]))) { error in
            XCTAssertEqual(error as? CSVImportError, .cellTooLarge)
        }
    }
}
