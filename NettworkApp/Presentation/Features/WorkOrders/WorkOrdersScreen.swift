import ContentSafety
import NetworkModel
import SwiftUI
import WorkspaceChangeControl

/// A UI-only workflow. Every state-changing action delegates to the supplied
/// authorized service; this screen never writes an authoritative record itself.
struct WorkOrdersScreen: View {
    @State private var model: OperationsFeatureViewModel
    let authorization: OperationsAuthorization
    let evidenceSource: () -> (any OpaqueContentSource)?
    let evidenceAuthorization: () -> AuthorizedOperationContext?
    @State private var cancellationReason = ""
    @State private var showCancellation = false
    @State private var cancellationResolutionReason = ""
    @State private var physicalAttestation = ""
    @State private var showCancellationResolution = false
    @State private var pendingEvidenceDiscard: WorkOrderEvidenceItem?
    /// The composition layer supplies a release that it obtained from the
    /// authorized cancellation path. The screen never creates one itself.
    let cancellationReleaseAuthorization: (CancellationReleaseRequest) -> CancellationReleaseAuthorization?
    let statusAnnouncer: any AccessibilityStatusAnnouncing

    @MainActor init(
        model: OperationsFeatureViewModel,
        authorization: OperationsAuthorization,
        evidenceSource: @escaping () -> (any OpaqueContentSource)?,
        evidenceAuthorization: @escaping () -> AuthorizedOperationContext?,
        cancellationReleaseAuthorization: @escaping (CancellationReleaseRequest) -> CancellationReleaseAuthorization? = { _ in nil },
        statusAnnouncer: any AccessibilityStatusAnnouncing = AccessibilityStatusAnnouncer()
    ) {
        _model = State(initialValue: model)
        self.authorization = authorization
        self.evidenceSource = evidenceSource
        self.evidenceAuthorization = evidenceAuthorization
        self.cancellationReleaseAuthorization = cancellationReleaseAuthorization
        self.statusAnnouncer = statusAnnouncer
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                NettworkPageHeader(
                    "Work Orders",
                    subtitle: "Build a reviewed change, reserve its resources, then complete it with bound evidence.",
                    systemImage: "checklist"
                )
            }
            WorkOrderDraftSelectionSection(model: model)
            WorkOrderDraftFieldsSection(model: model)
            WorkOrderEvidenceSection(
                model: model, prepareEvidence: prepareEvidence,
                evidenceAuthorization: evidenceAuthorization, pendingDiscard: $pendingEvidenceDiscard
            )
            WorkOrderValidationSection(model: model, authorization: authorization, evidenceAuthorization: evidenceAuthorization)
            WorkOrderExecutionSection(model: model, authorization: authorization)
            WorkOrderSafetySection(
                model: model, authorization: authorization,
                showCancellation: $showCancellation,
                showCancellationResolution: $showCancellationResolution
            )
        }
        .navigationTitle("Work Orders")
        .overlay(alignment: .bottom) { phaseOverlay }
        .sheet(isPresented: $showCancellation) { cancellationSheet }
        .sheet(isPresented: $showCancellationResolution) { cancellationResolutionSheet }
        .alert("Work order action unavailable", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.dismissError() } })) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.lastError ?? "")
        }
        .confirmationDialog(
            "Discard staged evidence?",
            isPresented: pendingEvidenceDiscardDialog,
            titleVisibility: .visible,
            presenting: pendingEvidenceDiscard
        ) { item in
            Button("Discard staged evidence", role: .destructive) {
                discardPreparedEvidence(item)
            }
            .accessibilityIdentifier("work-order.cleanup-evidence.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("work-order.cleanup-evidence.cancel")
        } message: { item in
            Text(
                "Discard the prepared evidence with hash \(item.prepared?.evidence.digest.hexadecimalString ?? "unavailable")? "
                    + "This cannot affect a bound work order."
            )
        }
        .onChange(of: model.lastError) { _, error in
            if let error { statusAnnouncer.announce(error) }
        }
        .onChange(of: model.phase) { _, phase in
            statusAnnouncer.announce(workOrderPhaseStatus(phase))
        }
    }

    private func prepareEvidence() {
        guard let source = evidenceSource(), let authorization = evidenceAuthorization() else { return }
        Task { await model.prepareEvidence(source: source, authorization: authorization) }
    }

    private func discardPreparedEvidence(_ item: WorkOrderEvidenceItem) {
        guard model.evidenceItems.first(where: { $0.id == item.id }) == item else {
            statusAnnouncer.announce("The prepared evidence changed. Review the current evidence before discarding it.")
            return
        }
        Task { await model.cleanupPreparedEvidence(itemID: item.id, authorization: evidenceAuthorization()) }
    }

    private var pendingEvidenceDiscardDialog: Binding<Bool> {
        Binding(
            get: { pendingEvidenceDiscard != nil },
            set: { if !$0 { pendingEvidenceDiscard = nil } }
        )
    }

    private func workOrderPhaseStatus(_ phase: OperationsFeatureViewModel.Phase) -> String {
        switch phase {
        case .validating: "Validating the exact work-order intent."
        case .reserving: "Reserving authorized work-order resources."
        case .requestingApproval: "Requesting work-order approval."
        case .beginningExecution: "Beginning confirmed execution."
        case .completing: "Completing the work order with evidence."
        case .resolvingCancellation: "Resolving the authorized cancellation."
        default: "Work-order state updated."
        }
    }

    @ViewBuilder private var phaseOverlay: some View {
        switch model.phase {
        case .validating, .reserving, .requestingApproval, .beginningExecution, .completing, .resolvingCancellation:
            ProgressView("Checking authorized workspace state")
                .padding()
                .background(.regularMaterial, in: Capsule())
                .accessibilityIdentifier("work-order.operation-pending")
        case .awaitingConfirmation:
            Label("Pending confirmation. No physical execution is enabled.", systemImage: "clock.badge.exclamationmark")
                .padding()
                .background(.thinMaterial, in: Capsule())
                .accessibilityIdentifier("work-order.pending-overlay")
        case .reserved, .approved, .executing, .completed:
            Label("Confirmed state", systemImage: "checkmark.circle.fill")
                .padding()
                .background(.thinMaterial, in: Capsule())
                .accessibilityIdentifier("work-order.confirmed-overlay")
        case .cancellationRequested:
            Label("Cancellation requested. Resources stay locked until authorized resolution.", systemImage: "exclamationmark.shield")
                .padding()
                .background(.thinMaterial, in: Capsule())
                .accessibilityIdentifier("work-order.cancellation-requested-overlay")
        default: EmptyView()
        }
    }

    private var cancellationSheet: some View {
        NavigationStack {
            Form {
                Section {
                    NettworkNotice(
                        "Cancellation request",
                        message: "This records the request. Resources remain reserved until an authorized resolution confirms their release.",
                        style: .warning
                    )
                }
                TextField("Reason", text: $cancellationReason, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("work-order.cancellation-reason")
                Text("This records a cancellation request only. An authorized release is required before resources are released.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Request cancellation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCancellation = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Request") {
                        showCancellation = false
                        Task { await model.requestCancellation(reason: cancellationReason, physicalStatus: .unknown, using: authorization) }
                    }
                    .disabled(cancellationReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var cancellationResolutionSheet: some View {
        NavigationStack {
            Form {
                Section {
                    NettworkNotice(
                        "Authorized resolution required",
                        message: "Provide the required reason and physical attestation. The release authorization comes from the authorized cancellation path.",
                        style: .warning
                    )
                }
                TextField("Resolution reason", text: $cancellationResolutionReason, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("work-order.cancellation-resolution-reason")
                TextField("Exact physical attestation", text: $physicalAttestation, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("work-order.cancellation-physical-attestation")
                Text(
                    "Resolution requires an authorized emergency override or an exact physical attestation "
                        + "supplied by the authorized cancellation path. This screen does not create release authorizations."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Resolve cancellation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCancellationResolution = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resolve", role: .destructive) {
                        showCancellationResolution = false
                        Task {
                            let request = model.cancellationReleaseRequest(
                                physicalAttestation: physicalAttestation
                            )
                            await model.resolveCancellation(
                                reason: cancellationResolutionReason,
                                physicalAttestation: physicalAttestation,
                                releaseAuthorization: request.flatMap(cancellationReleaseAuthorization),
                                using: authorization
                            )
                        }
                    }
                    .disabled(cancellationResolutionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
