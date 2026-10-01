import CloudSync
import ContentSafety
import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    import ImageIO

    /// Pins the successful evidence pipeline of ARCHITECTURE.md "Attachments and
    /// transfer" end to end through public services: content safety verifies,
    /// sanitizes, hashes and privately stages a JPEG; binding claims the staged
    /// bytes, reserves quota and activates one conditional binding for a work
    /// order whose reviewed intent already names that evidence hash. The server
    /// enforces every precondition.
    @MainActor
    final class ProductionAttachmentEvidenceCommitCharacterizationTests: XCTestCase {
        func testSanitizedEvidenceIsBoundToItsWorkOrderInOneConditionalActivation() async throws {
            let harness = try await MutationAuthorityHarness.make()
            await harness.server.enforcePreconditions()
            let context = harness.session.operationContext(.createAttachment)
            let service = try await evidenceService(harness, context: context)
            let source = InMemoryContentSource(bytes: try Self.jpeg(width: 16, height: 12))

            let prepared = try await service.prepareEvidence(source: source, authorization: context)
            var draft = harness.connectDraft()
            draft.evidence = [prepared.evidence]
            _ = try await harness.reserve(draft)
            let result = try await service.bindPreparedEvidence(prepared, to: draft.id, authorization: context)

            let descriptor = prepared.descriptor
            XCTAssertEqual(descriptor.purpose, .evidence)
            XCTAssertEqual(descriptor.contentType, .jpeg)
            XCTAssertEqual(prepared.evidence.id, descriptor.id)
            XCTAssertEqual(prepared.evidence.digest.hexadecimalString, descriptor.domainSeparatedSHA256)
            let intent = try AttachmentEvidenceBindingIntent(
                owner: AttachmentEvidenceOwner(workOrderID: draft.id, namespace: harness.namespace), attachmentID: descriptor.id,
                evidence: prepared.evidence, authorization: context)
            XCTAssertEqual(result, AttachmentEvidenceBindingResult(evidence: prepared.evidence, receipt: intent.expectedReceipt))
            let activations = await harness.server.activations
            let committed = await harness.server.committed
            XCTAssertEqual(activations.count, 1, "Binding must be one activation.")
            XCTAssertEqual(committed.count, 2, "Binding must not revise the work order.")
            let activation = try XCTUnwrap(activations.first)
            let bindingKey = ResourceKey.attachmentEvidenceBinding(for: descriptor.id)
            XCTAssertTrue(activation.preconditions.contains(.mustNotExist(bindingKey)))
            XCTAssertTrue(activation.preconditions.contains(.exactSystemFields(.object(draft.id), ServiceFixture.exact("server-2"))))
            try assertSanitizedAsset(in: activation, key: bindingKey, matches: descriptor)
            let binding = try CloudDeterministicCoding.decode(
                AttachmentEvidenceBindingRecord.self, from: try await harness.server.requiredSnapshot(for: bindingKey).payload)
            XCTAssertEqual(binding.workOrderID, draft.id)
            XCTAssertEqual(binding.evidence, prepared.evidence)
            XCTAssertEqual(binding.operationID, context.operationID)
            XCTAssertEqual(binding.assetMetadata.byteCount, descriptor.byteCount)
            XCTAssertEqual(binding.auditEventID, AuditEvent.deterministicID(for: context.operationID))
            let ledger = try CloudDeterministicCoding.decode(
                AttachmentEvidenceQuotaLedger.self,
                from: try await harness.server.requiredSnapshot(for: .attachmentEvidenceQuotaLedger(for: draft.id)).payload)
            XCTAssertEqual(ledger.attachmentCount, 1)
            XCTAssertEqual(ledger.totalBytes, descriptor.byteCount)
        }

        // MARK: Helpers

        private func evidenceService(
            _ harness: MutationAuthorityHarness, context: AuthorizedOperationContext
        ) async throws -> ProductionAttachmentEvidenceFeatureService {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("evidence-\(UUID().uuidString)")
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let store = try ServiceFixture.makeStore()
            _ = await store.activateLease(for: harness.namespace)
            let staging = try FileBackedPrivateAttachmentStaging(root: root)
            let current = CurrentContext(context: context)
            // Pins only this authority's side of binding. The clock is pinned to
            // whole seconds because a sub-second reservation expiry fails local
            // read-back (ISO 8601 payload vs. full-precision column). Attachment
            // evidence is inconsistent across components and deliberately left
            // unrepaired: completion and the remote binding validator expect the
            // work order's intent digest and a completed work order, while
            // activation validation requires the binding's own digest during
            // execution (CompositeCloudRemoteReferenceAttachments.swift,
            // AttachmentEvidenceActivationValidation.swift).
            let authority = ProductionAttachmentEvidenceAuthority(
                sessionAuthorizer: harness.session.authorizer, exactRecords: harness.server, mutations: harness.server, persistence: store,
                policy: try ProductionAttachmentEvidencePolicy(
                    quota: AttachmentEvidenceQuotaPolicy(maximumAttachmentCount: 4, maximumTotalBytes: 4 * 1_024 * 1_024, reservationLifetime: 600),
                    policyVersion: "evidence-test-policy"),
                now: { ServiceFixture.wholeSeconds(fromNow: 0) })
            return ProductionAttachmentEvidenceFeatureService(
                account: harness.session.account,
                contentSafety: ContentSafetyService(decoder: PlatformContentSanitizingDecoder(), staging: staging, currentContext: current),
                bindingService: AuthorizedAttachmentEvidenceBindingService(authority: authority, staging: staging, currentContext: current),
                operationBoundary: try ServiceFixture.operationBoundary())
        }

        /// The binding carries the sanitized bytes whose hashes the staged
        /// descriptor reported, so CloudKit stores them in the same operation.
        private func assertSanitizedAsset(
            in activation: AuthoritativeActivationMutation, key: ResourceKey, matches descriptor: SanitizedContentDescriptor,
            file: StaticString = #filePath, line: UInt = #line
        ) throws {
            let save = try XCTUnwrap(activation.saves.first { $0.resourceKey == key }, file: file, line: line)
            guard case let .inline(bytes) = try XCTUnwrap(save.recordAsset, file: file, line: line).storage else {
                return XCTFail("The sanitized asset must travel inline on the binding save.", file: file, line: line)
            }
            XCTAssertEqual(bytes.count, descriptor.byteCount, file: file, line: line)
            XCTAssertEqual(CloudRecordAssetDescriptor.sha256(for: bytes), descriptor.contentSHA256, file: file, line: line)
            XCTAssertEqual(ContentSafetyService.digest(for: bytes, purpose: .evidence), descriptor.domainSeparatedSHA256, file: file, line: line)
            XCTAssertEqual(Array(bytes.prefix(2)), [0xFF, 0xD8], "The sanitized output is a JPEG.", file: file, line: line)
        }

        private static func jpeg(width: Int, height: Int) throws -> Data {
            let output = NSMutableData()
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw ServiceTestError(reason: "no bitmap context") }
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
                throw ServiceTestError(reason: "no JPEG encoder")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ServiceTestError(reason: "JPEG encoding failed") }
            return output as Data
        }
    }

    /// Accepts only the one operation context the test issued.
    private struct CurrentContext: CurrentAuthorizationContextProviding {
        let context: AuthorizedOperationContext

        func validateCurrent(_ candidate: AuthorizedOperationContext) async -> Bool { candidate == context }
    }

    private struct InMemoryContentSource: OpaqueContentSource {
        let bytes: Data
        let sourceID = "in-memory-evidence"

        func metadata() throws -> UntrustedContentMetadata { UntrustedContentMetadata(byteCount: bytes.count, declaredType: .jpeg) }
        func makeReader() throws -> any OpaqueContentByteReader { InMemoryContentReader(remaining: bytes) }
    }

    private struct InMemoryContentReader: OpaqueContentByteReader {
        var remaining: Data

        mutating func nextChunk(maximumBytes: Int) throws -> Data? {
            guard !remaining.isEmpty else { return nil }
            let chunk = Data(remaining.prefix(maximumBytes))
            remaining = Data(remaining.dropFirst(chunk.count))
            return chunk
        }
    }
#endif
