import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import ContentSafety

final class ContentSafetyTests: XCTestCase {
    func testRejectsMIMESpoofBeforeDecoderRuns() async {
        let decoder = FixtureDecoder()
        let service = makeService(decoder: decoder)
        let source = FixtureSource(bytes: jpegBytes, metadata: .init(byteCount: jpegBytes.count, declaredType: .png))

        await XCTAssertThrowsErrorAsync(try await service.sanitizeAndStage(source: source, purpose: .evidence, authorization: authorization())) { error in
            XCTAssertEqual(error as? ContentSafetyError, .typeMismatch)
        }
        XCTAssertEqual(decoder.callCount, 0)
    }

    func testRejectsDeclaredRawImageLimitBeforeLoadingPayload() async {
        let source = FixtureSource(bytes: jpegBytes, metadata: .init(byteCount: ContentSafetyService.maximumRawImageBytes + 1, declaredType: .jpeg))
        let service = makeService()

        await XCTAssertThrowsErrorAsync(try await service.sanitizeAndStage(source: source, purpose: .evidence, authorization: authorization())) { error in
            XCTAssertEqual(error as? ContentSafetyError, .sourceSizeExceeded)
        }
    }

    func testRejectsAnimatedAndDecompressionLimits() async {
        let animated = FixtureDecoder(decoded: .init(sourceType: .jpeg, width: 800, height: 600, isAnimated: true))
        await XCTAssertThrowsErrorAsync(
            try await makeService(decoder: animated).sanitizeAndStage(source: jpegSource(), purpose: .evidence, authorization: authorization())
        ) { error in
            XCTAssertEqual(error as? ContentSafetyError, .animatedContent)
        }

        let bomb = FixtureDecoder(decoded: .init(sourceType: .jpeg, width: 16_384, height: 16_384))
        await XCTAssertThrowsErrorAsync(
            try await makeService(decoder: bomb).sanitizeAndStage(source: jpegSource(), purpose: .evidence, authorization: authorization())
        ) { error in
            XCTAssertEqual(error as? ContentSafetyError, .decodedSizeExceeded)
        }
    }

    func testEvidenceOutputAndPDFPurposePolicy() async {
        let oversized = FixtureDecoder(raster: .init(bytes: Data(repeating: 1, count: 1), width: 4_097, height: 1))
        await XCTAssertThrowsErrorAsync(
            try await makeService(decoder: oversized).sanitizeAndStage(source: jpegSource(), purpose: .evidence, authorization: authorization())
        ) { error in
            XCTAssertEqual(error as? ContentSafetyError, .outputDimensionsExceeded)
        }

        let pdf = FixtureSource(bytes: pdfBytes, metadata: .init(byteCount: pdfBytes.count, declaredType: .pdf))
        await XCTAssertThrowsErrorAsync(try await makeService().sanitizeAndStage(source: pdf, purpose: .evidence, authorization: authorization())) { error in
            XCTAssertEqual(error as? ContentSafetyError, .purposeTypeMismatch)
        }
    }

    func testPDFRequiresSelectedPageAndConstrainedBoxes() async {
        let decoder = FixtureDecoder(decoded: .init(sourceType: .pdf, width: 500, height: 700, pageCount: 2, pageBoxesAreFiniteAndBounded: false))
        let source = FixtureSource(bytes: pdfBytes, metadata: .init(byteCount: pdfBytes.count, declaredType: .pdf))
        await XCTAssertThrowsErrorAsync(
            try await makeService(decoder: decoder).sanitizeAndStage(source: source, purpose: .floorPlan, authorization: authorization())
        ) { error in
            XCTAssertEqual(error as? ContentSafetyError, .invalidPDFPageBoxes)
        }

        let valid = FixtureDecoder(decoded: .init(sourceType: .pdf, width: 500, height: 700, pageCount: 2))
        await XCTAssertThrowsErrorAsync(
            try await makeService(decoder: valid).sanitizeAndStage(source: source, purpose: .floorPlan, authorization: authorization())
        ) { error in
            XCTAssertEqual(error as? ContentSafetyError, .missingSelectedPDFPage)
        }
    }

    func testHashIsDomainSeparatedAndCleanupUsesNamespace() async throws {
        let staging = FixtureStaging()
        let service = makeService(staging: staging)
        let descriptor = try await service.sanitizeAndStage(source: jpegSource(), purpose: .evidence, authorization: authorization())
        XCTAssertEqual(descriptor.domainSeparatedSHA256, ContentSafetyService.digest(for: jpegBytes, purpose: .evidence))
        XCTAssertNotEqual(descriptor.domainSeparatedSHA256, ContentSafetyService.digest(for: jpegBytes, purpose: .floorPlan))

        try await service.cleanup(descriptor, authorization: authorization())
        XCTAssertEqual(staging.removedTokens, [descriptor.stagingToken])
        XCTAssertEqual(staging.removedNamespaces, [descriptor.namespace])
    }

    func testAccountAndSessionChangesAreRejectedAtAuthorizationSeam() async {
        let current = FixtureCurrentContext(authorization())
        let service = makeService(current: current)
        current.value = authorization(sessionGeneration: 2)

        await XCTAssertThrowsErrorAsync(try await service.sanitizeAndStage(source: jpegSource(), purpose: .evidence, authorization: authorization())) { error in
            XCTAssertEqual(error as? ContentSafetyError, .unauthorized)
        }
    }

    func testStateMachineIsLinear() throws {
        XCTAssertEqual(try ContentSafetyStateMachine.transition(from: .initialized, to: .authorized), .authorized)
        XCTAssertThrowsError(try ContentSafetyStateMachine.transition(from: .initialized, to: .staged)) { error in
            XCTAssertEqual(error as? ContentSafetyError, .invalidStateTransition)
        }
    }

    /// Descriptors are assertions; the staged bytes are the binding evidence.
    func testBindingRejectsForgedChangedIDOrSameSizeMutatedBytesAndConsumesLeaseOnce() async throws {
        let staging = FixtureStaging()
        let context = FixtureCurrentContext(authorization())
        let descriptor = try await makeService(staging: staging, current: context)
            .sanitizeAndStage(source: jpegSource(), purpose: .evidence, authorization: authorization())
        let authority = RecordingEvidenceAuthority()
        let binding = AuthorizedAttachmentEvidenceBindingService(
            authority: authority,
            staging: staging,
            currentContext: context
        )

        let forged = descriptorByReplacing(byteCount: descriptor.byteCount + 1, in: descriptor)
        await XCTAssertThrowsErrorAsync(try await binding.reserveAndBind(descriptor: forged, workOrderID: ObjectID(), authorization: authorization())) {
            error in
            XCTAssertEqual(error as? AttachmentEvidenceBindingError, .invalidDigest)
        }
        XCTAssertEqual(authority.reserveCount, 0)

        let changedID = descriptorByReplacing(id: ObjectID(), in: descriptor)
        await XCTAssertThrowsErrorAsync(try await binding.reserveAndBind(descriptor: changedID, workOrderID: ObjectID(), authorization: authorization())) {
            error in
            XCTAssertEqual(error as? AttachmentEvidenceBindingError, .invalidDigest)
        }
        XCTAssertEqual(authority.reserveCount, 0)

        staging.replace(bytes: Data([0xFF, 0xD8, 0xFF, 0x00]), for: descriptor.stagingToken)
        await XCTAssertThrowsErrorAsync(try await binding.reserveAndBind(descriptor: descriptor, workOrderID: ObjectID(), authorization: authorization())) {
            error in
            XCTAssertEqual(error as? AttachmentEvidenceBindingError, .invalidDigest)
        }
        XCTAssertEqual(authority.reserveCount, 0)

        staging.replace(bytes: jpegBytes, for: descriptor.stagingToken)
        _ = try await binding.reserveAndBind(descriptor: descriptor, workOrderID: ObjectID(), authorization: authorization())
        XCTAssertEqual(authority.bindCount, 1)
        await XCTAssertThrowsErrorAsync(try await binding.reserveAndBind(descriptor: descriptor, workOrderID: ObjectID(), authorization: authorization()))
        XCTAssertEqual(authority.bindCount, 1)
    }

    private func descriptorByReplacing(
        id: ObjectID? = nil,
        byteCount: Int? = nil,
        in descriptor: SanitizedContentDescriptor
    ) -> SanitizedContentDescriptor {
        SanitizedContentDescriptor(
            id: id ?? descriptor.id, stagingToken: descriptor.stagingToken, stagingExpiresAt: descriptor.stagingExpiresAt,
            namespace: descriptor.namespace, purpose: descriptor.purpose, contentType: descriptor.contentType,
            byteCount: byteCount ?? descriptor.byteCount, pixelWidth: descriptor.pixelWidth, pixelHeight: descriptor.pixelHeight,
            contentSHA256: descriptor.contentSHA256, domainSeparatedSHA256: descriptor.domainSeparatedSHA256)
    }

    /// A receipt is authoritative only when every canonical field matches.
    func testBindingRejectsAnyMismatchedReceipt() async throws {
        let fixture = try await bindingFixture()
        let authorization = fixture.authorization
        let authority = fixture.authority
        let binding = fixture.binding
        let descriptor = fixture.descriptor

        authority.receiptOverride = OperationReceipt(
            workspaceZone: authorization.account.namespace.workspaceZone,
            operationID: ObjectID(),
            intentDigest: try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 1, count: 32)),
            auditEventID: ObjectID()
        )
        await assertInvalidReceipt(binding, descriptor: descriptor, authorization: authorization)

        authority.receiptOverride = OperationReceipt(
            workspaceZone: .init(
                workspaceID: ObjectID(),
                containerIdentifier: authorization.account.namespace.containerIdentifier,
                zoneName: authorization.account.namespace.zoneName,
                zoneOwnerRecordName: authorization.account.namespace.zoneOwnerRecordName
            ),
            operationID: authorization.operationID,
            intentDigest: try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 2, count: 32)),
            auditEventID: ObjectID()
        )
        await assertInvalidReceipt(binding, descriptor: descriptor, authorization: authorization)

        authority.receiptOverride = nil
        let wrongDigest = try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 3, count: 32))
        authority.receiptTransform = { expected in
            OperationReceipt(
                workspaceZone: expected.workspaceZone,
                operationID: expected.operationID,
                intentDigest: wrongDigest,
                auditEventID: expected.auditEventID
            )
        }
        await assertInvalidReceipt(binding, descriptor: descriptor, authorization: authorization)

        authority.receiptTransform = { expected in
            OperationReceipt(
                workspaceZone: expected.workspaceZone,
                operationID: expected.operationID,
                intentDigest: expected.intentDigest,
                auditEventID: ObjectID()
            )
        }
        await assertInvalidReceipt(binding, descriptor: descriptor, authorization: authorization)
        XCTAssertEqual(authority.bindCount, 4)
        XCTAssertEqual(authority.releaseCount, 4)

        authority.receiptTransform = nil
        let result = try await binding.reserveAndBind(descriptor: descriptor, workOrderID: ObjectID(), authorization: authorization)
        XCTAssertEqual(result.evidence.id, descriptor.id)
        XCTAssertEqual(result.receipt.operationID, authorization.operationID)
        XCTAssertEqual(result.receipt.workspaceZone, authorization.account.namespace.workspaceZone)
        XCTAssertEqual(result.receipt.auditEventID, AuditEvent.deterministicID(for: authorization.operationID))
    }

    /// Authority is checked again after reservation and before binding.
    func testBindingRejectsContextThatBecomesStaleDuringReservationAwait() async throws {
        let fixture = try await bindingFixture()
        let authorization = fixture.authorization
        let context = fixture.context
        let descriptor = fixture.descriptor
        let authority = fixture.authority
        let binding = fixture.binding
        let staleAuthorization = self.authorization(sessionGeneration: 2)
        authority.onReserve = { context.value = staleAuthorization }

        await XCTAssertThrowsErrorAsync(try await binding.reserveAndBind(descriptor: descriptor, workOrderID: ObjectID(), authorization: authorization)) {
            error in
            XCTAssertEqual(error as? AttachmentEvidenceBindingError, .unauthorized)
        }
        XCTAssertEqual(authority.reserveCount, 1)
        XCTAssertEqual(authority.bindCount, 0)
        XCTAssertEqual(authority.releaseCount, 1)

        context.value = authorization
        authority.onReserve = nil
        _ = try await binding.reserveAndBind(descriptor: descriptor, workOrderID: ObjectID(), authorization: authorization)
        XCTAssertEqual(authority.bindCount, 1)
    }

    func testCommittedReceiptSurvivesStagingCleanupFailure() async throws {
        let authorization = self.authorization()
        let staging = FixtureStaging()
        let context = FixtureCurrentContext(authorization)
        let descriptor = try await makeService(staging: staging, current: context)
            .sanitizeAndStage(
                source: jpegSource(),
                purpose: .evidence,
                authorization: authorization
            )
        let authority = RecordingEvidenceAuthority()
        let binding = AuthorizedAttachmentEvidenceBindingService(
            authority: authority,
            staging: staging,
            currentContext: context
        )
        staging.failNextComplete = true

        let result = try await binding.reserveAndBind(
            descriptor: descriptor,
            workOrderID: ObjectID(),
            authorization: authorization
        )

        XCTAssertEqual(result.receipt.operationID, authorization.operationID)
        XCTAssertEqual(authority.bindCount, 1)
        XCTAssertEqual(staging.removedTokens, [descriptor.stagingToken])
    }

    private func makeService(
        decoder: FixtureDecoder = .init(),
        staging: FixtureStaging = .init(),
        current: FixtureCurrentContext? = nil
    ) -> ContentSafetyService {
        ContentSafetyService(decoder: decoder, staging: staging, currentContext: current ?? FixtureCurrentContext(authorization()))
    }

    private func bindingFixture() async throws -> BindingFixture {
        let authorization = authorization()
        let staging = FixtureStaging()
        let context = FixtureCurrentContext(authorization)
        let descriptor = try await makeService(staging: staging, current: context).sanitizeAndStage(
            source: jpegSource(), purpose: .evidence, authorization: authorization)
        let authority = RecordingEvidenceAuthority()
        return BindingFixture(
            authorization: authorization, context: context, descriptor: descriptor, authority: authority,
            binding: .init(authority: authority, staging: staging, currentContext: context))
    }

    private func assertInvalidReceipt(
        _ binding: AuthorizedAttachmentEvidenceBindingService, descriptor: SanitizedContentDescriptor, authorization: AuthorizedOperationContext
    ) async {
        await XCTAssertThrowsErrorAsync(try await binding.reserveAndBind(descriptor: descriptor, workOrderID: ObjectID(), authorization: authorization)) {
            XCTAssertEqual($0 as? AttachmentEvidenceBindingError, .invalidReceipt)
        }
    }

    private func authorization(sessionGeneration: UInt64 = 1) -> AuthorizedOperationContext {
        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork", cloudKitAccountRecordName: "account-a",
            workspaceID: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), zoneName: "zone-a", zoneOwnerRecordName: "owner-a",
            sessionGeneration: sessionGeneration)
        let account = AccountContext(namespace: namespace, databaseScope: .ownerPrivate, sharePermission: .owner, verifiedAt: .distantPast)
        let actor = ActorContext(cloudKitUserRecordName: "account-a", role: .technician, installationID: "ipad-a", sessionGeneration: sessionGeneration)
        return AuthorizedOperationContext(
            operationID: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!), account: account, actor: actor, action: .createAttachment)
    }

    private func jpegSource() -> FixtureSource {
        FixtureSource(bytes: jpegBytes, metadata: .init(byteCount: jpegBytes.count, declaredType: .jpeg))
    }

    private var jpegBytes: Data { Data([0xFF, 0xD8, 0xFF, 0xD9]) }
    private var pdfBytes: Data { Data("%PDF-1.7".utf8) }
}

private struct BindingFixture {
    let authorization: AuthorizedOperationContext
    let context: FixtureCurrentContext
    let descriptor: SanitizedContentDescriptor
    let authority: RecordingEvidenceAuthority
    let binding: AuthorizedAttachmentEvidenceBindingService
}

private struct FixtureSource: OpaqueContentSource {
    let bytes: Data
    let value: UntrustedContentMetadata
    var sourceID: String { "fixture" }

    init(bytes: Data, metadata: UntrustedContentMetadata) {
        self.bytes = bytes
        value = metadata
    }

    func metadata() throws -> UntrustedContentMetadata { value }
    func makeReader() throws -> any OpaqueContentByteReader { FixtureReader(bytes: bytes) }
}

private struct FixtureReader: OpaqueContentByteReader {
    let bytes: Data
    var offset = 0

    mutating func nextChunk(maximumBytes: Int) throws -> Data? {
        guard offset < bytes.count else { return nil }
        let end = min(bytes.count, offset + maximumBytes)
        defer { offset = end }
        return bytes.subdata(in: offset..<end)
    }
}

private final class FixtureDecoder: ContentSanitizingDecoder, @unchecked Sendable {
    private(set) var callCount = 0
    private let decodedValue: DecodedContent?
    private let rasterValue: SanitizedRaster?

    init(decoded: DecodedContent? = nil, raster: SanitizedRaster? = nil) {
        decodedValue = decoded
        rasterValue = raster
    }

    func decodeAndSanitize(_ bytes: Data, sourceType: ContentType, purpose: ContentPurpose, selectedPDFPage: Int?, outputEdgeLimit: Int, outputByteLimit: Int)
        throws -> (decoded: DecodedContent, raster: SanitizedRaster)
    {
        callCount += 1
        return (
            decodedValue ?? .init(sourceType: sourceType, width: 800, height: 600, pageCount: sourceType == .pdf ? 1 : 0),
            rasterValue ?? .init(bytes: Data([0xFF, 0xD8, 0xFF, 0xD9]), width: 800, height: 600)
        )
    }
}

private final class FixtureStaging: PrivateAttachmentStaging, @unchecked Sendable {
    private struct Entry {
        var bytes: Data
        let metadata: SanitizedAttachmentStagingMetadata
        let namespace: AttachmentNamespace
        let expiresAt: Date
        var claimID: UUID?
    }

    private(set) var removedTokens = [AttachmentStagingToken]()
    private(set) var removedNamespaces = [AttachmentNamespace]()
    private var entries = [AttachmentStagingToken: Entry]()
    var failNextComplete = false

    func stage(_ sanitizedBytes: Data, metadata: SanitizedAttachmentStagingMetadata, namespace: AttachmentNamespace) async throws -> StagedAttachmentLease {
        let token = AttachmentStagingToken(id: UUID())
        let registryMetadata = metadata.assigningRegistryAttachmentID(ObjectID())
        entries[token] = Entry(bytes: sanitizedBytes, metadata: registryMetadata, namespace: namespace, expiresAt: .distantFuture, claimID: nil)
        return .init(token: token, attachmentID: registryMetadata.attachmentID, expiresAt: .distantFuture)
    }

    func claim(_ token: AttachmentStagingToken, namespace: AttachmentNamespace) async throws -> ClaimedStagedAttachment {
        guard var entry = entries[token], entry.namespace == namespace, entry.claimID == nil else {
            throw FileAttachmentStagingError.unknownLease
        }
        let claimID = UUID()
        entry.claimID = claimID
        entries[token] = entry
        return ClaimedStagedAttachment(
            sanitizedBytes: entry.bytes, metadata: entry.metadata, attachmentID: entry.metadata.attachmentID, token: token, namespace: namespace,
            expiresAt: entry.expiresAt, claimID: claimID)
    }

    func complete(_ claim: ClaimedStagedAttachment) async throws {
        guard let entry = entries[claim.token], entry.claimID == claim.claimID else {
            throw FileAttachmentStagingError.unknownLease
        }
        if failNextComplete {
            failNextComplete = false
            throw FileAttachmentStagingError.invalidClaim
        }
        entries.removeValue(forKey: claim.token)
    }

    func release(_ claim: ClaimedStagedAttachment) async {
        guard var entry = entries[claim.token], entry.claimID == claim.claimID else { return }
        entry.claimID = nil
        entries[claim.token] = entry
    }

    func remove(_ token: AttachmentStagingToken, namespace: AttachmentNamespace) async throws {
        removedTokens.append(token)
        removedNamespaces.append(namespace)
        entries.removeValue(forKey: token)
    }

    func replace(bytes: Data, for token: AttachmentStagingToken) {
        guard var entry = entries[token] else { return }
        entry.bytes = bytes
        entries[token] = entry
    }
}

private final class RecordingEvidenceAuthority: AttachmentEvidenceReservationAuthority, @unchecked Sendable {
    private(set) var reserveCount = 0
    private(set) var bindCount = 0
    private(set) var releaseCount = 0
    var receiptOverride: OperationReceipt?
    var receiptTransform: ((OperationReceipt) -> OperationReceipt)?
    var onReserve: (() -> Void)?

    func reserveAttachment(owner: AttachmentEvidenceOwner, attachment: VerifiedSanitizedAttachment) async throws -> AttachmentQuotaReservation {
        reserveCount += 1
        onReserve?()
        return AttachmentQuotaReservation(
            owner: owner, attachmentID: attachment.attachmentID, reservedCount: 1, reservedBytes: attachment.byteCount, expiresAt: .distantFuture)
    }

    func bindReservedAttachment(
        _ reservation: AttachmentQuotaReservation,
        attachment _: VerifiedSanitizedAttachment,
        intent: AttachmentEvidenceBindingIntent,
        authorization _: AuthorizedOperationContext
    ) async throws -> OperationReceipt {
        bindCount += 1
        guard reservation.reservedCount == 1 else { throw AttachmentEvidenceBindingError.bindingConflict }
        let expected = intent.expectedReceipt
        return receiptTransform?(expected) ?? receiptOverride ?? expected
    }

    func releaseAttachmentReservation(_: AttachmentQuotaReservation) async {
        releaseCount += 1
    }
}

private final class FixtureCurrentContext: CurrentAuthorizationContextProviding, @unchecked Sendable {
    var value: AuthorizedOperationContext?
    init(_ value: AuthorizedOperationContext?) { self.value = value }
    func validateCurrent(_ context: AuthorizedOperationContext) async -> Bool { value == context }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch {
        handler(error)
    }
}
