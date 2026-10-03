import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

extension TransferScreen {
    func beginDryRun() {
        guard let document = importDocument?(), let context = importAuthorization?() else { return }
        Task { await model.dryRunCSV(source: document, authorization: context) }
    }

    func activateImport(_ plan: ImportPlan) {
        Task { await model.activateCSV(expectedPlan: plan) }
    }

    var pendingCSVActivationDialog: Binding<Bool> {
        Binding(
            get: { pendingCSVActivation != nil },
            set: { if !$0 { pendingCSVActivation = nil } }
        )
    }

    var pendingArchiveRestoreDialog: Binding<Bool> {
        Binding(
            get: { pendingArchiveRestore != nil },
            set: { if !$0 { pendingArchiveRestore = nil } }
        )
    }

    func beginCSVExport() {
        guard let context = csvExportAuthorization?() else { return }
        csvExportHandoffMessage = nil
        Task { await model.exportCSV(authorization: context) }
    }

    func beginCSVExportHandoff(to destination: any CSVWorkspaceExportDestination) {
        Task {
            do {
                try await model.handoffCSVExport(to: destination)
                csvExportHandoffMessage = "CSV files were handed to the configured export destination."
            } catch {
                csvExportHandoffMessage = error.localizedDescription
            }
        }
    }

    func beginDefaultCSVExportHandoff() {
        Task {
            do {
                let document = try await model.prepareCSVExportHandoff()
                csvWorkspaceExportDocument = try NettworkCSVWorkspaceDocument(exportDocument: document)
                isCSVWorkspaceExporterPresented = true
            } catch {
                csvExportHandoffMessage = error.localizedDescription
            }
        }
    }

    var csvWorkspaceExportFilename: String { "nettwork-workspace-csv" }

    func completeCSVWorkspaceExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            Task {
                do {
                    try await model.validateCSVExportHandoff()
                    csvExportHandoffMessage = "CSV workspace saved to the selected location."
                } catch {
                    csvExportHandoffMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            csvExportHandoffMessage = error.localizedDescription
        }
    }

    func beginExport() {
        guard let context = exportAuthorization?() else { return }
        archiveSaveMessage = nil
        Task { await model.exportArchive(authorization: context) }
    }

    func beginVerifyRestore() {
        guard restoreAuthorization != nil, model.canBeginArchiveVerification else { return }
        if let source = restoreSource?() {
            verifyRestore(source: source)
        } else {
            isArchiveImporterPresented = true
        }
    }

    func restoreArchive(_ pending: PendingArchiveRestore) {
        Task {
            await model.restoreArchive(
                expectedApproval: pending.approval,
                presentation: pending.presentation
            )
        }
    }

    var archiveFilename: String {
        guard case .exported(let document) = model.archiveState else { return "nettworkarchive" }
        return "nettwork-\(document.manifest.workspaceID).nettworkarchive"
    }

    func presentArchiveExporter(for _: ArchiveExportDocument) {
        Task {
            do {
                try await model.validateArchiveExportHandoff()
                archiveDocument = NettworkArchiveDocument()
                isArchiveExporterPresented = true
            } catch {
                archiveSaveMessage = error.localizedDescription
            }
        }
    }

    func completeArchiveExport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                do {
                    let document = try await model.prepareArchiveExportHandoff()
                    try NettworkArchiveDocument.publish(document, to: url)
                    archiveSaveMessage = "Archive saved to the selected location."
                } catch {
                    archiveSaveMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            archiveSaveMessage = error.localizedDescription
        }
    }

    func selectArchiveForRestore(_ result: Result<[URL], Error>) {
        guard let context = restoreAuthorization?() else { return }
        do {
            let urls = try result.get()
            guard let url = urls.first, let archivePackageSource else {
                throw TransferDocumentError.invalidPackage
            }
            verifyRestore(source: try archivePackageSource(url), authorization: context)
        } catch {
            model.reportArchiveSelectionFailure(error)
        }
    }

    func verifyRestore(source: any ArchiveEntrySource, authorization: AuthorizedOperationContext? = nil) {
        guard let context = authorization ?? restoreAuthorization?() else {
            (source as? any ArchiveEntrySourceAccessLifetime)?.close()
            return
        }
        Task { await model.verifyRestore(source: source, authorization: context) }
    }

    func csvStatus(_ state: CSVTransferState) -> String {
        switch state {
        case .idle: "CSV import is idle."
        case .dryRunning: "Validating CSV without changing the workspace."
        case .awaitingActivation(let plan): "CSV import validated for \(plan.totalRecordCount) records and awaiting activation."
        case .activating: "Activating the validated CSV import."
        case .activated: "CSV import activated by the authorized service."
        case .failed(let message): message
        }
    }

    func archiveStatus(_ state: ArchiveTransferState) -> String {
        switch state {
        case .idle: "Archive transfer is idle."
        case .exporting: "Creating the verified archive."
        case .exported: "Verified archive export is ready to save."
        case .verifyingRestore: "Verifying archive before any restore."
        case .readyToRestore: "Verified archive is ready for explicit restore confirmation."
        case .restoring: "Restoring through authorized staging."
        case .restored: "Archive restore completed by the authorized service."
        case .failed(let message): message
        }
    }
}
