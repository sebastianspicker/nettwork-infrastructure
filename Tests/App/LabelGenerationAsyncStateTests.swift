import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

@MainActor
final class LabelGenerationAsyncStateTests: XCTestCase {
    func testConfigurationAndEverySelectionActionDiscardPendingPDF() async {
        for change in 0..<4 {
            let source = ControlledLabelSource()
            let generator = ControlledLabelGenerator()
            let model = makeModel(source: source, generator: generator)
            let label = label()
            await load(model, from: source, labels: [label])
            let generation = Task { await model.generate() }
            await generator.requests.waitForRequest(1)
            switch change {
            case 0: model.configuration.rows += 1
            case 1: model.toggleSelection(for: label)
            case 2: model.selectAll()
            default: model.clearSelection()
            }
            await generator.requests.succeed(1, with: document(1))
            await generation.value
            XCTAssertNil(model.document)
            XCTAssertEqual(model.state, .ready)
        }
    }

    func testLatestGenerationRetainsDocumentWhenOldSuccessOrFailureFinishesLast() async {
        for fails in [false, true] {
            let source = ControlledLabelSource()
            let generator = ControlledLabelGenerator()
            let model = makeModel(source: source, generator: generator)
            await load(model, from: source, labels: [label()])
            let first = Task { await model.generate() }
            await generator.requests.waitForRequest(1)
            let second = Task { await model.generate() }
            await generator.requests.waitForRequest(2)
            await generator.requests.succeed(2, with: document(2))
            await second.value
            if fails {
                await generator.requests.fail(1)
            } else {
                await generator.requests.succeed(1, with: document(1))
            }
            await first.value
            XCTAssertEqual(model.document?.data, Data([2]))
            XCTAssertEqual(model.state, .ready)
        }
    }

    func testInputChangesDiscardStaleGenerationFailure() async {
        let source = ControlledLabelSource()
        let generator = ControlledLabelGenerator()
        let model = makeModel(source: source, generator: generator)
        await load(model, from: source, labels: [label()])
        let generation = Task { await model.generate() }
        await generator.requests.waitForRequest(1)
        model.configuration.columns += 1
        await generator.requests.fail(1)
        await generation.value
        XCTAssertNil(model.document)
        XCTAssertEqual(model.state, .ready)
    }

    func testReloadInvalidatesPendingPDFAndClearsSourceWhileLoading() async {
        let source = ControlledLabelSource()
        let generator = ControlledLabelGenerator()
        let model = makeModel(source: source, generator: generator)
        await load(model, from: source, labels: [label()])
        let generation = Task { await model.generate() }
        await generator.requests.waitForRequest(1)
        let reload = Task { await model.load() }
        await source.requests.waitForRequest(2)
        XCTAssertTrue(model.labels.isEmpty)
        XCTAssertTrue(model.selectedLabels.isEmpty)
        XCTAssertNil(model.document)
        await generator.requests.succeed(1, with: document(1))
        await generation.value
        XCTAssertNil(model.document)
        XCTAssertEqual(model.state, .loading)
        await source.requests.succeed(2, with: [])
        await reload.value
        XCTAssertEqual(model.state, .empty)
    }

    func testLatestSourceReloadWinsWhenOldSuccessOrFailureFinishesLast() async {
        for fails in [false, true] {
            let source = ControlledLabelSource()
            let model = makeModel(source: source, generator: ControlledLabelGenerator())
            let first = Task { await model.load() }
            await source.requests.waitForRequest(1)
            let second = Task { await model.load() }
            await source.requests.waitForRequest(2)
            let newest = label()
            await source.requests.succeed(2, with: [newest])
            await second.value
            if fails {
                await source.requests.fail(1, with: PrivacySafeLabelValidationError.invalidPayload)
            } else {
                await source.requests.succeed(1, with: [label()])
            }
            await first.value
            XCTAssertEqual(model.labels, [newest])
            XCTAssertEqual(model.selectedObjectIDs, [newest.objectID])
            XCTAssertEqual(model.state, .ready)
        }
    }

    func testCancelledGenerationDiscardsSuccessAndFailure() async {
        for fails in [false, true] {
            let source = ControlledLabelSource()
            let generator = ControlledLabelGenerator()
            let model = makeModel(source: source, generator: generator)
            await load(model, from: source, labels: [label()])
            let generation = Task { await model.generate() }
            await generator.requests.waitForRequest(1)
            generation.cancel()
            if fails {
                await generator.requests.fail(1)
            } else {
                await generator.requests.succeed(1, with: document(1))
            }
            await generation.value
            XCTAssertNil(model.document)
            XCTAssertEqual(model.state, .ready)
        }
    }

    private func load(_ model: LabelSheetModel, from source: ControlledLabelSource, labels: [PrivacySafeLabel]) async {
        let loading = Task { await model.load() }
        await source.requests.waitForRequest(1)
        await source.requests.succeed(1, with: labels)
        await loading.value
    }

    private func makeModel(source: ControlledLabelSource, generator: ControlledLabelGenerator) -> LabelSheetModel {
        LabelSheetModel(
            account: asyncFeatureTestAccount(), source: source, generator: generator,
            exporter: AsyncLabelOutputStub(), printer: AsyncLabelOutputStub()
        )
    }

    private func label() -> PrivacySafeLabel {
        PrivacySafeLabel(objectID: ObjectID(), assetCode: "SW-1", checkText: "A1")
    }

    private func document(_ value: UInt8) -> LabelPDFDocument {
        LabelPDFDocument(data: Data([value]), pageCount: 1)
    }
}

private struct ControlledLabelSource: PrivacySafeLabelSourcing {
    let requests = ControlledFeatureRequest<[PrivacySafeLabel]>()
    func labels(in namespace: PersistenceNamespace, limit: Int) async throws -> [PrivacySafeLabel] { try await requests.perform() }
}

private struct ControlledLabelGenerator: LabelPDFGenerating {
    let requests = ControlledFeatureRequest<LabelPDFDocument>()
    func makePDF(labels: [PrivacySafeLabel], configuration: LabelSheetConfiguration) async throws -> LabelPDFDocument {
        try await requests.perform()
    }
}

private struct AsyncLabelOutputStub: LabelPDFExporting, LabelPrinting {
    func export(_ document: LabelPDFDocument) async throws {}
    func print(_ document: LabelPDFDocument) async throws {}
}
