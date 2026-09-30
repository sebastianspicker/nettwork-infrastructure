import FeatureContracts
import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

@MainActor
@Observable
final class WorkspaceAdministrationViewModel {
    private(set) var status: WorkspaceParticipantStatusPresentation?
    private(set) var lastInvitation: WorkspaceInviteReceipt?
    private(set) var isPerformingAction = false
    private(set) var errorMessage: String?

    private let service: any WorkspaceAdministrationService

    init(service: any WorkspaceAdministrationService) {
        self.service = service
    }

    func refresh() async {
        do {
            status = try await service.participantStatus()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func invite(_ request: WorkspaceInviteRequest) async -> WorkspaceInviteReceipt? {
        guard !request.participantCloudKitUserRecordName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "A participant CloudKit record name is required."
            return nil
        }
        lastInvitation = nil
        return await perform { [service] in
            try await service.inviteParticipant(request)
        } receive: { [weak self] receipt in
            self?.lastInvitation = receipt
        }
    }

    func acceptShare(metadata: Data?) async -> WorkspaceAcceptedShare? {
        guard let metadata, !metadata.isEmpty else {
            errorMessage = "A valid share invitation is required."
            return nil
        }
        return await perform { [service] in
            try await service.acceptShare(metadata: metadata)
        } receive: { [weak self] accepted in
            self?.status = accepted.presentation
        }
    }

    func revokeCurrentShare() async {
        _ = await perform { [service] in
            try await service.revokeCurrentShare()
        } receive: { [weak self] (_: Void) in
            self?.status = nil
            self?.lastInvitation = nil
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func perform<Value>(
        operation: () async throws -> Value,
        receive: (Value) -> Void
    ) async -> Value? {
        guard !isPerformingAction else { return nil }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let value = try await operation()
            receive(value)
            errorMessage = nil
            return value
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

/// A distinct workspace/share administration surface. Operations keeps audit,
/// reports, and synchronization presentation separate from privileged sharing.
struct AdministrationScreen: View {
    @State private var model: WorkspaceAdministrationViewModel
    @State private var participantRecordName = ""
    @State private var permission: WorkspaceSharePermission = .readWrite
    @State private var isPresentingRevocationConfirmation = false

    /// The application integration layer supplies metadata received from the
    /// system share-acceptance handoff. No untrusted URL or CloudKit object is
    /// constructed in this screen.
    let shareMetadata: (() -> Data?)?
    /// Receives opaque invitation metadata for the platform share handoff.
    /// The screen itself does not deliver, decode, or persist this metadata.
    let onInvitationPrepared: ((WorkspaceInviteReceipt) -> Void)?

    init(
        model: WorkspaceAdministrationViewModel,
        shareMetadata: (() -> Data?)? = nil,
        onInvitationPrepared: ((WorkspaceInviteReceipt) -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        self.shareMetadata = shareMetadata
        self.onInvitationPrepared = onInvitationPrepared
    }

    var body: some View {
        Form {
            Section {
                NettworkPageHeader(
                    "Administration",
                    subtitle: "Review the current workspace member, prepare invitations, and manage the active share through verified services.",
                    systemImage: "person.2.badge.key"
                )
            }
            participantSection
            inviteSection
            acceptSection
            revocationSection
        }
        .navigationTitle("Administration")
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .confirmationDialog(
            "Revoke this workspace share?",
            isPresented: $isPresentingRevocationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Revoke share", role: .destructive) {
                Task { await model.revokeCurrentShare() }
            }
        } message: {
            Text("This closes the current workspace session and clears its ephemeral local state.")
        }
        .alert(
            "Workspace administration unavailable",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var participantSection: some View {
        Section("Current participant") {
            if let status = model.status {
                LabeledContent("Workspace", value: status.workspaceName)
                LabeledContent("Account", value: status.participantRecordName)
                LabeledContent("Role", value: status.role?.rawValue ?? "Pending new workspace activation")
                LabeledContent("Permission", value: status.permission.rawValue)
                LabeledContent("Share", value: status.shareRecordName ?? "Owner workspace")
                Label(
                    status.membershipIsVerified ? "Membership verified" : "Membership needs verification",
                    systemImage: status.membershipIsVerified ? "checkmark.shield" : "exclamationmark.shield"
                )
                .foregroundStyle(status.membershipIsVerified ? .green : .orange)
                Text(status.disclosure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                NettworkLoadingState("Loading workspace membership")
            }
        }
    }

    @ViewBuilder private var inviteSection: some View {
        Section("Invite participant") {
            Text("Prepare an invitation for the supplied CloudKit record name. Delivery remains with the app integration layer.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Participant CloudKit record name", text: $participantRecordName)
                .recordNameInputFormatting()
                .accessibilityIdentifier("administration.invite.participant")
            Picker("Permission", selection: $permission) {
                Text("Read only").tag(WorkspaceSharePermission.readOnly)
                Text("Read and write").tag(WorkspaceSharePermission.readWrite)
            }
            Button("Create invitation") {
                Task {
                    let receipt = await model.invite(
                        WorkspaceInviteRequest(
                            participantCloudKitUserRecordName: participantRecordName,
                            permission: permission
                        )
                    )
                    if let receipt { onInvitationPrepared?(receipt) }
                }
            }
            .disabled(model.isPerformingAction)
            .accessibilityIdentifier("administration.invite")
            if let invitation = model.lastInvitation {
                Text("Invitation prepared for \(invitation.participantCloudKitUserRecordName).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("administration.invite.prepared")
            }
        }
    }

    @ViewBuilder private var acceptSection: some View {
        Section("Accept shared workspace") {
            Text("Accept only invitation metadata received through the app's trusted handoff.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Accept received invitation") {
                Task { _ = await model.acceptShare(metadata: shareMetadata?()) }
            }
            .disabled(model.isPerformingAction || shareMetadata == nil)
            .accessibilityIdentifier("administration.accept-share")
            Text("Received invitation metadata is supplied only by the app integration layer.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var revocationSection: some View {
        Section("Revoke current workspace share") {
            Text("Review the active share above before continuing. Revocation closes the current workspace session.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Revoke share", role: .destructive) {
                isPresentingRevocationConfirmation = true
            }
            .disabled(model.isPerformingAction || model.status?.shareRecordName == nil)
            .accessibilityIdentifier("administration.revoke-share")
            Text("Revocation requires the verified workspace owner and administrator session.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private extension View {
    @ViewBuilder
    func recordNameInputFormatting() -> some View {
        #if os(iOS)
            textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
            autocorrectionDisabled()
        #endif
    }
}
