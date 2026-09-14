import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

struct TransferScreen: View {
    @State var model: TransferFeatureViewModel
    @State var archiveDocument: NettworkArchiveDocument?
    @State var csvWorkspaceExportDocument: NettworkCSVWorkspaceDocument?
    @State var isArchiveExporterPresented = false
    @State var isCSVWorkspaceExporterPresented = false
    @State var isArchiveImporterPresented = false
    @State var archiveSaveMessage: String?
    @State var csvExportHandoffMessage: String?
    @State var pendingCSVActivation: PendingCSVActivation?
    @State var pendingArchiveRestore: PendingArchiveRestore?
    let importDocument: (() -> CSVImportDocument?)?
    let importAuthorization: (() -> AuthorizedOperationContext?)?
    let csvExportAuthorization: (() -> AuthorizedOperationContext?)?
    let csvExportDestination: (any CSVWorkspaceExportDestination)?
    let exportAuthorization: (() -> AuthorizedOperationContext?)?
    let restoreSource: (() -> (any ArchiveEntrySource)?)?
    let restoreAuthorization: (() -> AuthorizedOperationContext?)?
    let statusAnnouncer: any AccessibilityStatusAnnouncing

    @MainActor init(
        model: TransferFeatureViewModel,
        importDocument: (() -> CSVImportDocument?)? = nil,
        importAuthorization: (() -> AuthorizedOperationContext?)? = nil,
        csvExportAuthorization: (() -> AuthorizedOperationContext?)? = nil,
        csvExportDestination: (any CSVWorkspaceExportDestination)? = nil,
        exportAuthorization: (() -> AuthorizedOperationContext?)? = nil,
        restoreSource: (() -> (any ArchiveEntrySource)?)? = nil,
        restoreAuthorization: (() -> AuthorizedOperationContext?)? = nil,
        statusAnnouncer: any AccessibilityStatusAnnouncing = AccessibilityStatusAnnouncer()
    ) {
        _model = State(initialValue: model)
        self.importDocument = importDocument
        self.importAuthorization = importAuthorization
        self.csvExportAuthorization = csvExportAuthorization
        self.csvExportDestination = csvExportDestination
        self.exportAuthorization = exportAuthorization
        self.restoreSource = restoreSource
        self.restoreAuthorization = restoreAuthorization
        self.statusAnnouncer = statusAnnouncer
    }

    var body: some View {
        addingStatusAnnouncements(to: addingConfirmationDialogs(to: addingDocumentPresenters(to: transferList)))
    }

    private var transferList: some View {
        List {
            Section {
                NettworkPageHeader(
                    "Import and Export",
                    subtitle: "Review imported data and backups before adding them to your workspace.",
                    systemImage: "arrow.left.arrow.right"
                )
            }
            .listRowInsets(EdgeInsets())

            csvSection
            csvExportSection
            archiveSection
        }
        .navigationTitle("Import and Export")
        .onDisappear { model.cancelVerifiedRestore() }
    }

    private func addingDocumentPresenters<Content: View>(to content: Content) -> some View {
        content
            .fileExporter(
                isPresented: $isArchiveExporterPresented,
                document: archiveDocument,
                contentType: .nettworkArchive,
                defaultFilename: archiveFilename,
                onCompletion: completeArchiveExport
            )
            .fileExporter(
                isPresented: $isCSVWorkspaceExporterPresented,
                document: csvWorkspaceExportDocument,
                contentType: .nettworkCSVWorkspace,
                defaultFilename: csvWorkspaceExportFilename,
                onCompletion: completeCSVWorkspaceExport
            )
            .fileImporter(
                isPresented: $isArchiveImporterPresented,
                allowedContentTypes: [.nettworkArchive],
                allowsMultipleSelection: false,
                onCompletion: selectArchiveForRestore
            )
    }

    private func addingConfirmationDialogs<Content: View>(to content: Content) -> some View {
        content
            .confirmationDialog(
                "Activate validated CSV import?",
                isPresented: pendingCSVActivationDialog,
                titleVisibility: .visible,
                presenting: pendingCSVActivation
            ) { pending in
                Button("Activate validated import", role: .destructive) {
                    activateImport(pending.plan)
                }
                .accessibilityIdentifier("transfer.csv.activate.confirm")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("transfer.csv.activate.cancel")
            } message: { pending in
                Text("Activate exactly \(pending.plan.totalRecordCount) validated records with canonical digest \(pending.plan.canonicalSHA256)?")
            }
            .confirmationDialog(
                "Restore verified archive?",
                isPresented: pendingArchiveRestoreDialog,
                titleVisibility: .visible,
                presenting: pendingArchiveRestore
            ) { pending in
                Button("Restore verified archive", role: .destructive) {
                    restoreArchive(pending)
                }
                .accessibilityIdentifier("transfer.archive.restore.confirm")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("transfer.archive.restore.cancel")
            } message: { pending in
                Text(
                    "Restore the verified archive from \(pending.presentation.sourceWorkspaceID.description) "
                        + "into \(pending.presentation.targetWorkspaceID.description)?"
                )
            }
    }

    private func addingStatusAnnouncements<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: csvStatus(model.csvState)) { _, status in
                statusAnnouncer.announce(status)
            }
            .onChange(of: archiveStatus(model.archiveState)) { _, status in
                statusAnnouncer.announce(status)
            }
    }

    fileprivate var csvSection: some View {
        Section("1. Validate CSV import") {
            Text("A dry import checks the selected file without changing the workspace. Activation stays unavailable until that review succeeds.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Review CSV import") { beginDryRun() }
                .buttonStyle(.bordered)
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(importDocument == nil || importAuthorization == nil || !model.canBeginCSVDryRun)
                .accessibilityIdentifier("transfer.csv.dry-run")
            switch model.csvState {
            case .idle: Text("Review the files first. Apply the validated import when you are ready.").foregroundStyle(.secondary)
            case .dryRunning: ProgressView("Validating CSV without changing the workspace")
            case .awaitingActivation(let plan):
                LabeledContent("Validated records", value: "\(plan.totalRecordCount)")
                LabeledContent("Canonical digest", value: String(plan.canonicalSHA256.prefix(16)) + "…")
                Button("Activate validated import", role: .destructive) {
                    pendingCSVActivation = PendingCSVActivation(plan: plan)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canActivateCSV)
                .accessibilityIdentifier("transfer.csv.activate")
                Button("Cancel staged import", role: .cancel) {
                    model.cancelCSVImport()
                }
                .accessibilityIdentifier("transfer.csv.cancel")
            case .activating: ProgressView("Activating staged import")
            case .activated:
                Label("CSV import complete", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
                    .accessibilityValue("Import complete")
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .accessibilityValue(message)
            }
        }
    }

    fileprivate var archiveSection: some View {
        Section("Archive backup and restore") {
            Text("Exports are verified before saving. Restores are verified first and require a separate explicit confirmation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Export verified archive") { beginExport() }
                .disabled(exportAuthorization == nil || !model.canBeginArchiveExport)
                .accessibilityIdentifier("transfer.archive.export")
            Button("Verify archive for restore") { beginVerifyRestore() }
                .disabled(restoreAuthorization == nil || !model.canBeginArchiveVerification)
                .accessibilityIdentifier("transfer.archive.verify")
            TransferArchiveStateContent(
                model: model, archiveSaveMessage: archiveSaveMessage,
                saveArchive: presentArchiveExporter,
                queueRestore: { pendingArchiveRestore = $0 }
            )
        }
    }

    fileprivate var csvExportSection: some View {
        Section("CSV export") {
            Text("Create a complete workspace export, then choose where to save the prepared files.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Export complete CSV workspace") { beginCSVExport() }
                .buttonStyle(.bordered)
                .disabled(csvExportAuthorization == nil || !model.canBeginCSVWorkspaceExport)
                .accessibilityIdentifier("transfer.csv.export")
            switch model.csvWorkspaceExportState {
            case .idle:
                Text("Exports contain every CSV schema table from the active local workspace.")
                    .foregroundStyle(.secondary)
            case .exporting:
                ProgressView("Encoding complete CSV workspace")
            case .exported(let document):
                LabeledContent("CSV files", value: "\(document.files.count)")
                Button("Save CSV workspace") { beginDefaultCSVExportHandoff() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("transfer.csv.save")
                if let destination = csvExportDestination {
                    Button("Choose CSV export destination") { beginCSVExportHandoff(to: destination) }
                        .accessibilityIdentifier("transfer.csv.handoff")
                }
                if let csvExportHandoffMessage {
                    Text(csvExportHandoffMessage).font(.footnote).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        }
    }
}

private struct TransferArchiveStateContent: View {
    @Bindable var model: TransferFeatureViewModel
    let archiveSaveMessage: String?
    let saveArchive: (ArchiveExportDocument) -> Void
    let queueRestore: (PendingArchiveRestore) -> Void

    var body: some View {
        switch model.archiveState {
        case .idle: TransferArchiveIdleState(isCancelling: model.isArchiveOperationInFlight)
        case .exporting: NettworkLoadingState("Creating complete archive")
        case .exported(let document): TransferArchiveExportedState(document: document, message: archiveSaveMessage, save: saveArchive)
        case .verifyingRestore: TransferArchiveVerifyingState(model: model)
        case .readyToRestore(let preview): TransferArchiveReadyState(model: model, preview: preview, queueRestore: queueRestore)
        case .restoring: NettworkLoadingState("Restoring workspace")
        case .restored:
            Label("Workspace restored", systemImage: "checkmark.seal")
                .foregroundStyle(.green)
                .accessibilityValue("Workspace restored")
        case .failed(let message): Label(message, systemImage: "xmark.octagon").foregroundStyle(.red).accessibilityValue(message)
        }
    }
}

private struct TransferArchiveIdleState: View {
    let isCancelling: Bool

    var body: some View {
        Text(
            isCancelling
                ? "Cancelling archive verification and releasing the selected source."
                : ArchiveIntegrityDisclosure.checksumsAreNotAuthenticityProof
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

private struct TransferArchiveExportedState: View {
    let document: ArchiveExportDocument
    let message: String?
    let save: (ArchiveExportDocument) -> Void
    var body: some View {
        NettworkNotice(
            "Verified archive is ready",
            message: "Save the prepared archive to complete the export.",
            style: .success
        )
        LabeledContent("Archive root digest", value: String(document.manifest.rootSHA256.prefix(16)) + "…")
        Text("Completion marker created \(document.completionMarker.completedAt.formatted())").font(.footnote).foregroundStyle(.secondary)
        Button("Save Archive") { save(document) }.accessibilityIdentifier("transfer.archive.save")
        if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
    }
}

private struct TransferArchiveVerifyingState: View {
    @Bindable var model: TransferFeatureViewModel
    var body: some View {
        NettworkLoadingState("Verifying archive before any restore")
        Button("Cancel archive verification", role: .cancel) { model.cancelVerifiedRestore() }.accessibilityIdentifier("transfer.archive.cancel-verification")
    }
}

private struct TransferArchiveReadyState: View {
    @Bindable var model: TransferFeatureViewModel
    let preview: FileBackedArchiveRestorePreview
    let queueRestore: (PendingArchiveRestore) -> Void

    var body: some View {
        NettworkNotice(
            "Review verified restore",
            message: "Check the source, target, and record counts below. Restore stays pending until you confirm it.",
            style: .warning
        )
        TransferArchiveApprovalDetails(approval: model.archiveRestoreApprovalPresentation)
        Text(ArchiveIntegrityDisclosure.checksumsAreNotAuthenticityProof).font(.footnote).foregroundStyle(.secondary)
        Button("Restore verified archive", role: .destructive, action: queueVerifiedRestore)
            .disabled(model.isArchiveOperationInFlight || model.archiveRestoreApprovalPresentation == nil)
            .accessibilityIdentifier("transfer.archive.restore")
        Button("Cancel verified restore", role: .cancel) { model.cancelVerifiedRestore() }.accessibilityIdentifier("transfer.archive.cancel-restore")
    }

    private func queueVerifiedRestore() {
        guard let approval = model.archiveRestoreApprovalPresentation else { return }
        queueRestore(PendingArchiveRestore(approval: preview.approval, presentation: approval))
    }
}

private struct TransferArchiveApprovalDetails: View {
    let approval: ArchiveRestoreApprovalPresentation?
    var body: some View {
        if let approval {
            LabeledContent("Records", value: "\(approval.recordCount)")
            LabeledContent("Assets", value: "\(approval.assetCount) (\(approval.assetByteCount) bytes)")
            LabeledContent("Compatibility", value: approval.compatibility)
            DisclosureGroup("Verified restore details") {
                LabeledContent("Source workspace", value: approval.sourceWorkspaceID.description)
                LabeledContent("Source zone", value: approval.sourceZone)
                LabeledContent("Source owner", value: approval.sourceZoneOwner)
                LabeledContent("Target workspace", value: approval.targetWorkspaceID.description)
                LabeledContent("Target zone", value: approval.targetZone)
                LabeledContent("Target owner", value: approval.targetZoneOwner)
                LabeledContent("Restore operation", value: approval.operationID.description)
                LabeledContent("Created", value: approval.createdAt.formatted())
                LabeledContent("Audit records", value: "\(approval.auditRecordCount)")
                LabeledContent("Audit head", value: String(approval.auditHeadSHA256.prefix(16)) + "…")
                LabeledContent("Root digest", value: String(approval.rootSHA256.prefix(16)) + "…")
            }
        } else {
            Label("The verified approval presentation is unavailable.", systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}
