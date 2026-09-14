import ContentSafety
import NetworkModel
import SwiftUI
import WorkspaceChangeControl

struct WorkOrderDraftSelectionSection: View {
    @Bindable var model: OperationsFeatureViewModel

    var body: some View {
        if !model.stagedDrafts.isEmpty {
            Section("Staged feature work") {
                ForEach(model.stagedDrafts) { staged in
                    Button {
                        model.selectStagedDraft(staged.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(staged.title)
                                Text(staged.id.description).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if staged.id == model.draft.id { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                    .disabled(!model.canSelectStagedDraft)
                    .accessibilityIdentifier("work-order.select-staged-draft")
                }
            }
        }
    }
}

struct WorkOrderDraftFieldsSection: View {
    @Bindable var model: OperationsFeatureViewModel

    var body: some View {
        Section("Draft") {
            Text("Describe the planned change and how to reverse it before validating the work order.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Work order title", text: $model.draft.title).accessibilityIdentifier("work-order.title")
            Picker("Change type", selection: $model.draft.kind) {
                Text("Connect").tag(WorkOrderKind.connect)
                Text("Disconnect").tag(WorkOrderKind.disconnect)
                Text("Move").tag(WorkOrderKind.move)
                Text("Device").tag(WorkOrderKind.device)
                Text("Hierarchy").tag(WorkOrderKind.hierarchy)
                Text("IPAM").tag(WorkOrderKind.ipam)
                Text("VLAN").tag(WorkOrderKind.vlan)
                Text("Floor plan").tag(WorkOrderKind.floorPlan)
            }
            TextField("Ticket", text: $model.draft.ticket).accessibilityIdentifier("work-order.ticket")
            TextField("Planned work and rollback notes", text: $model.draft.notes, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("work-order.notes")
            LabeledContent("Affected resources", value: "\(model.draft.resourceKeys.count)")
            LabeledContent("Evidence items", value: "\(model.draft.evidence.count)")
        }
        .disabled(!model.canEditDraft)
    }
}

struct WorkOrderEvidenceSection: View {
    @Bindable var model: OperationsFeatureViewModel
    let prepareEvidence: () -> Void
    let evidenceAuthorization: () -> AuthorizedOperationContext?
    @Binding var pendingDiscard: WorkOrderEvidenceItem?

    var body: some View {
        Section("Evidence") {
            Button("Prepare evidence", action: prepareEvidence).disabled(!model.canPrepareEvidence).accessibilityIdentifier("work-order.prepare-evidence")
            Text("Evidence is checked and prepared before it is attached to this work order.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(model.evidenceItems) { item in
                WorkOrderEvidenceRow(
                    model: model,
                    item: item,
                    evidenceAuthorization: evidenceAuthorization,
                    pendingDiscard: $pendingDiscard
                )
            }
        }
    }
}

private struct WorkOrderEvidenceRow: View {
    @Bindable var model: OperationsFeatureViewModel
    let item: WorkOrderEvidenceItem
    let evidenceAuthorization: () -> AuthorizedOperationContext?
    @Binding var pendingDiscard: WorkOrderEvidenceItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let evidence = item.prepared?.evidence {
                LabeledContent("Evidence hash", value: evidence.digest.hexadecimalString)
                    .font(.footnote.monospaced())
                    .accessibilityLabel("Evidence hash \(evidence.digest.hexadecimalString)")
                    .accessibilityIdentifier("work-order.evidence-hash")
            }
            WorkOrderEvidenceStatus(state: item.state)
            if item.state.allowsEvidenceCleanup, model.reservation == nil, item.prepared != nil {
                Button("Discard staged evidence", role: .destructive) { pendingDiscard = item }.accessibilityIdentifier("work-order.cleanup-evidence")
            }
            if item.state.allowsEvidenceCleanup, model.reservation?.isConfirmedAndFresh == true, item.prepared != nil {
                Button("Retry evidence binding") {
                    Task { await model.bindPreparedEvidenceIfPossible(using: evidenceAuthorization) }
                }
                .accessibilityIdentifier("work-order.retry-evidence-binding")
            }
        }
    }
}

private struct WorkOrderEvidenceStatus: View {
    let state: WorkOrderEvidenceState

    var body: some View {
        Label(state.displayName, systemImage: state.symbolName)
            .foregroundStyle(state.tint)
            .accessibilityLabel("Evidence status: \(state.displayName)")
            .accessibilityIdentifier("work-order.evidence-status")
            .accessibilityValue(state.displayName)
    }
}

struct WorkOrderValidationSection: View {
    @Bindable var model: OperationsFeatureViewModel
    let authorization: OperationsAuthorization
    let evidenceAuthorization: () -> AuthorizedOperationContext?

    var body: some View {
        Section("Validation and reservation") {
            Text(
                "Synchronize first, validate the exact intent, then reserve the affected resources. Approval and execution remain locked until those checks finish."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Button("Synchronize foreground") {
                Task { await model.synchronizeForeground(using: authorization) }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!model.canSynchronize)
            .accessibilityIdentifier("work-order.sync-foreground")
            WorkOrderSyncReceipt(receipt: model.syncReceipt)
            Button("Validate exact intent") {
                Task { await model.validate(using: authorization) }
            }
            .keyboardShortcut("v", modifiers: [.command])
            .disabled(!model.canValidate)
            .accessibilityIdentifier("work-order.validate")
            WorkOrderValidationSummary(validation: model.validation)
            Button("Reserve resources") {
                Task { await model.reserve(using: authorization, evidenceAuthorization: evidenceAuthorization) }
            }
            .disabled(!model.canReserve || !authorization.permitsPrivilegedAction)
            .accessibilityIdentifier("work-order.reserve")
            WorkOrderReservationSummary(reservation: model.reservation)
            if model.reservation?.isConfirmedAndFresh == false {
                Button("Refresh reservation confirmation") {
                    Task { await model.refreshReservation(using: authorization, evidenceAuthorization: evidenceAuthorization) }
                }
                .accessibilityIdentifier("work-order.refresh-reservation")
            }
        }
    }
}

private struct WorkOrderSyncReceipt: View {
    let receipt: SyncReceipt?
    var body: some View {
        if let receipt {
            LabeledContent("Sync queue", value: "\(receipt.queueDepth)")
            if let failure = receipt.failures.first {
                Label("\(failure.category.rawValue): \(failure.message)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(NettworkStatusRole.conflict.color)
            }
        }
    }
}

private struct WorkOrderValidationSummary: View {
    let validation: WorkOrderValidation
    var body: some View {
        if let digest = validation.exactIntentDigest {
            LabeledContent("Exact digest", value: String(digest.hexadecimalString.prefix(16)) + "…")
                .font(.footnote.monospaced())
                .accessibilityLabel("Exact intent digest \(digest.hexadecimalString)")
        }
        ForEach(validation.issues, id: \.self) {
            Label($0, systemImage: validation.isValid ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(
                    validation.isValid ? NettworkStatusRole.ready.color : NettworkStatusRole.conflict.color
                )
        }
    }
}

private struct WorkOrderReservationSummary: View {
    let reservation: WorkOrderReservationPresentation?
    var body: some View {
        if let reservation {
            switch reservation.confirmation {
            case .pending:
                Label("Reservation pending CloudKit confirmation", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(NettworkStatusRole.pending.color)
            case .confirmed:
                Label("Reservation confirmed until \(reservation.expiresAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.seal")
                    .foregroundStyle(NettworkStatusRole.reserved.color)
            case .expired:
                Label("Reservation expired. Refresh before execution.", systemImage: "clock.badge.xmark")
                    .foregroundStyle(NettworkStatusRole.conflict.color)
            case .rejected(let reason):
                Label(reason, systemImage: "xmark.octagon")
                    .foregroundStyle(NettworkStatusRole.conflict.color)
            }
        }
    }
}

struct WorkOrderExecutionSection: View {
    @Bindable var model: OperationsFeatureViewModel
    let authorization: OperationsAuthorization
    var body: some View {
        Section("Approval and execution") {
            Text("Request approval after reservation. Start work only after the confirmed reservation is current, then complete it with bound evidence.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Request approval") {
                Task { await model.requestApproval(using: authorization) }
            }
            .disabled(!model.canRequestApproval || !authorization.permitsPrivilegedAction)
            .accessibilityIdentifier("work-order.request-approval")
            Button("Begin confirmed execution") {
                Task { await model.beginExecution(using: authorization) }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!model.canExecute || !authorization.permitsPrivilegedAction)
            .accessibilityIdentifier("work-order.begin-execution")
            Button("Complete with evidence") {
                Task { await model.complete(using: authorization) }
            }
            .disabled(!model.canComplete || !authorization.permitsPrivilegedAction)
            .accessibilityIdentifier("work-order.complete")
            if model.hasUnboundPreparedEvidence {
                Label("Prepared evidence must bind before completion.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(NettworkStatusRole.pending.color)
                    .accessibilityIdentifier("work-order.evidence-unbound")
            }
        }
    }
}

struct WorkOrderSafetySection: View {
    @Bindable var model: OperationsFeatureViewModel
    let authorization: OperationsAuthorization
    @Binding var showCancellation: Bool
    @Binding var showCancellationResolution: Bool
    var body: some View {
        Section("Safety") {
            Button("Request cancellation", role: .destructive) {
                showCancellation = true
            }
            .disabled(!model.canRequestCancellation || !authorization.permitsPrivilegedAction)
            .accessibilityIdentifier("work-order.request-cancellation")
            if model.canResolveCancellation {
                Button("Resolve cancellation", role: .destructive) {
                    showCancellationResolution = true
                }
                .disabled(!authorization.permitsPrivilegedAction)
                .accessibilityIdentifier("work-order.resolve-cancellation")
            }
            Text("Cancellation releases require separate authorized resolution. Pending work stays visibly pending until the service confirms it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private extension WorkOrderEvidenceState {
    var allowsEvidenceCleanup: Bool { self == .prepared || self == .awaitingAuthorization || failedMessage != nil }
    var failedMessage: String? { if case let .failed(message) = self { message } else { nil } }
    var displayName: String {
        switch self {
        case .preparing: "Sanitizing and staging"
        case .prepared: "Prepared; awaiting authoritative work order"
        case .awaitingAuthorization: "A current evidence authorization is required"
        case .binding: "Binding to the confirmed work order"
        case .bound: "Bound with an authoritative receipt"
        case .cleaningUp: "Removing staged evidence"
        case .cancelled: "Preparation cancelled"
        case .failed(let message): message
        }
    }
    var symbolName: String {
        switch self {
        case .prepared, .awaitingAuthorization: "clock.badge.exclamationmark"
        case .binding, .cleaningUp, .preparing: "progress.indicator"
        case .bound: "checkmark.seal"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
    var tint: Color {
        statusRole?.color ?? .secondary
    }

    var statusRole: NettworkStatusRole? {
        switch self {
        case .bound: .ready
        case .failed: .conflict
        case .cancelled: nil
        default: .pending
        }
    }
}
