import ContentSafety
import FeatureContracts
import Foundation
import NetworkModel
import Observation
import WorkspaceChangeControl

@MainActor
extension OperationsFeatureViewModel {
    func registerStagedDraft(id: ObjectID) async {
        do {
            let staged = try await service.stagedDraft(id: id)
            if let index = stagedDrafts.firstIndex(where: { $0.id == staged.id }) {
                stagedDrafts[index] = staged
            } else {
                stagedDrafts.append(staged)
                stagedDrafts.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }
            if isPristineDraft, reservation == nil, evidenceItems.isEmpty {
                selectStagedDraft(staged.id)
            }
            lastError = nil
        } catch {
            fail(error)
        }
    }

    func selectStagedDraft(_ id: ObjectID) {
        guard let staged = stagedDrafts.first(where: { $0.id == id }) else { return }
        guard canSelectStagedDraft else {
            fail("Finish or cancel the current reserved/evidence workflow before selecting another staged draft.")
            return
        }
        draft = staged
        validation = .unvalidated
        phase = .editing
        phaseBeforeFailure = nil
        lastError = nil
    }

    func validate(using authorization: OperationsAuthorization) async {
        guard let operation = beginLifecycleOperation() else { return }
        defer { finishLifecycleOperation(operation) }
        let snapshot = draft
        validationGeneration &+= 1
        let generation = validationGeneration
        phase = .validating
        do {
            let result = try await service.validateDraft(snapshot, authorization: authorization)
            guard generation == validationGeneration, draft == snapshot else {
                validation = .unvalidated
                validatedDraft = nil
                phase = .editing
                return
            }
            validation = result
            validatedDraft = result.isValid ? snapshot : nil
            phase = validation.isValid ? .readyToReserve : .editing
            lastError = nil
        } catch {
            guard generation == validationGeneration, draft == snapshot else { return }
            fail(error)
        }
    }

    func synchronizeForeground(using authorization: OperationsAuthorization) async {
        guard let operation = beginLifecycleOperation() else { return }
        defer { finishLifecycleOperation(operation) }
        let receipt = await service.synchronizeForeground()
        syncReceipt = receipt
        if !receipt.failures.isEmpty || receipt.lastSuccessfulServerContact == nil {
            fail(receipt.failures.first?.message ?? "Foreground synchronization did not confirm server contact.")
        } else {
            do {
                if let reservation {
                    let refreshed = try await service.refreshReservation(
                        reservation,
                        authorization: authorization
                    )
                    self.reservation = refreshed
                    phase = phase(for: refreshed)
                } else {
                    phase = .editing
                }
                lastError = nil
            } catch {
                fail(error)
            }
        }
    }

    func reserve(
        using authorization: OperationsAuthorization,
        evidenceAuthorization: (() -> AuthorizedOperationContext?)? = nil
    ) async {
        guard authorization.permitsPrivilegedAction else {
            fail("A fresh technician or administrator authorization is required.")
            return
        }
        guard canReserve else {
            fail("The draft must have a valid exact intent digest.")
            return
        }
        guard let operation = beginLifecycleOperation() else { return }
        defer { finishLifecycleOperation(operation) }
        let snapshot = draft
        let expectedDigest = validation.exactIntentDigest
        phase = .reserving
        do {
            let result = try await service.reserve(snapshot, authorization: authorization)
            reservation = result
            phase = phase(for: result)
            guard result.exactIntentDigest == expectedDigest else {
                fail("The reservation digest does not match the validated intent.")
                return
            }
            lastError = nil
            if result.isConfirmedAndFresh {
                await bindPreparedEvidenceAlreadyLocked(using: evidenceAuthorization)
            }
        } catch {
            fail(error)
        }
    }

    func refreshReservation(
        using authorization: OperationsAuthorization,
        evidenceAuthorization: (() -> AuthorizedOperationContext?)? = nil
    ) async {
        guard let operation = beginLifecycleOperation() else { return }
        defer { finishLifecycleOperation(operation) }
        guard let reservation else { return }
        guard authorization.permitsPrivilegedAction else {
            fail("A fresh technician or administrator authorization is required.")
            return
        }
        do {
            let refreshed = try await service.refreshReservation(reservation, authorization: authorization)
            guard refreshed.id == reservation.id,
                refreshed.exactIntentDigest == validation.exactIntentDigest
            else {
                fail("The refreshed reservation does not match the validated intent.")
                return
            }
            self.reservation = refreshed
            phase = phase(for: refreshed)
            if refreshed.isConfirmedAndFresh {
                await bindPreparedEvidenceAlreadyLocked(using: evidenceAuthorization)
            }
        } catch {
            fail(error)
        }
    }

    func requestApproval(using authorization: OperationsAuthorization) async {
        guard authorization.permitsPrivilegedAction else {
            fail("A fresh approver authorization is required.")
            return
        }
        guard canRequestApproval else {
            fail("Approval can only be requested for a fresh, confirmed reservation.")
            return
        }
        guard let operation = beginLifecycleOperation() else { return }
        defer { finishLifecycleOperation(operation) }
        phase = .requestingApproval
        do {
            try await service.requestApproval(for: draft.id, authorization: authorization)
            phase = .approved
            lastError = nil
        } catch { fail(error) }
    }

    func beginExecution(using authorization: OperationsAuthorization) async {
        guard canExecute, authorization.permitsPrivilegedAction, let reservation,
            let digest = validation.exactIntentDigest, digest == reservation.exactIntentDigest
        else {
            fail("Execution requires an approved, fresh reservation with the exact validated digest.")
            return
        }
        guard let operation = beginLifecycleOperation() else { return }
        defer { finishLifecycleOperation(operation) }
        phase = .beginningExecution
        do {
            try await service.beginExecution(
                workOrderID: draft.id,
                reservationID: reservation.id,
                intentDigest: digest,
                authorization: authorization
            )
            phase = .executing
            lastError = nil
        } catch { fail(error) }
    }

    func complete(using authorization: OperationsAuthorization) async {
        guard authorization.permitsPrivilegedAction else {
            fail("A fresh technician or administrator authorization is required.")
            return
        }
        guard canComplete else {
            fail("Only executing work with bound evidence can be completed.")
            return
        }
        guard let operation = beginLifecycleOperation() else { return }
        defer { finishLifecycleOperation(operation) }
        phase = .completing
        do {
            try await service.complete(
                workOrderID: draft.id,
                evidence: draft.evidence,
                authorization: authorization
            )
            phase = .completed
            lastError = nil
        } catch { fail(error) }
    }

    func requestCancellation(reason: String, physicalStatus: CancellationPhysicalStatus, using authorization: OperationsAuthorization) async {
        guard authorization.permitsPrivilegedAction,
            !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            fail("A fresh authorization and cancellation reason are required.")
            return
        }
        guard canRequestCancellation else {
            fail("Cancellation can only be requested for reserved, approved, or executing work.")
            return
        }
        guard let operation = beginLifecycleOperation() else { return }
        defer { finishLifecycleOperation(operation) }
        do {
            let refreshed = try await service.requestCancellation(
                workOrderID: draft.id,
                reason: reason,
                physicalStatus: physicalStatus,
                authorization: authorization
            )
            guard refreshed.workOrderID == draft.id,
                refreshed.workOrderStatus == .cancellationRequested,
                refreshed.cancellationRequestID != nil
            else {
                throw OperationsFeatureModelError.invalidAuthoritativePresentation
            }
            reservation = refreshed
            phase = .cancellationRequested
            lastError = nil
        } catch { fail(error) }
    }

    func resolveCancellation(
        reason: String,
        physicalAttestation: String,
        releaseAuthorization: CancellationReleaseAuthorization?,
        using authorization: OperationsAuthorization
    ) async {
        guard canResolveCancellation else {
            fail("Only a cancellation request can be resolved.")
            return
        }
        guard let operation = beginLifecycleOperation() else { return }
        defer { finishLifecycleOperation(operation) }
        guard authorization.permitsPrivilegedAction,
            !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let releaseAuthorization
        else {
            fail("A current cancellation release authorization and resolution reason are required.")
            return
        }
        if case let .attestation(_, statement) = releaseAuthorization,
            statement != physicalAttestation
        {
            fail("The physical attestation must exactly match the authorized release attestation.")
            return
        }
        phase = .resolvingCancellation
        do {
            try await service.resolveCancellation(
                workOrderID: draft.id,
                reason: reason,
                releaseAuthorization: releaseAuthorization,
                authorization: authorization
            )
            phase = .completed
            lastError = nil
        } catch {
            fail(error)
        }
    }

    func cancellationReleaseRequest(
        physicalAttestation: String
    ) -> CancellationReleaseRequest? {
        guard let reservation,
            let cancellationRequestID = reservation.cancellationRequestID,
            phase == .cancellationRequested
        else { return nil }
        return CancellationReleaseRequest(
            workOrderID: draft.id,
            reservationID: reservation.id,
            cancellationRequestID: cancellationRequestID,
            physicalAttestation: physicalAttestation
        )
    }
}
