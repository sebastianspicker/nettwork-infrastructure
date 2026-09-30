import FeatureContracts
import SwiftUI

struct OperationsScreenSections: View {
    let mode: OperationsScreenMode
    let reports: [OperationsReport]
    let reportsPhase: OperationsLoadPhase
    let syncHealth: SyncHealthPresentation?
    let syncHealthErrorMessage: String?
    let auditEvents: [AuditEventPresentation]
    let auditPhase: OperationsLoadPhase
    let access: WorkspaceAccessPresentation?
    let workspaceAccessErrorMessage: String?
    let exportLocation: URL?
    let canExportAudit: Bool
    let exportUnavailableReason: String
    @Binding var selectedAudit: AuditEventPresentation?
    @Binding var selectedReport: OperationsReport?
    let exportAudit: () -> Void
    let refreshReports: () -> Void
    let refreshAudit: () -> Void

    var body: some View {
        switch mode {
        case .reports:
            SyncHealthSection(health: syncHealth, phase: reportsPhase, errorMessage: syncHealthErrorMessage)
            ReportsSection(reports: reports, phase: reportsPhase, selectedReport: $selectedReport, retry: refreshReports)
        case .audit:
            WorkspaceAccessSection(access: access, phase: auditPhase, errorMessage: workspaceAccessErrorMessage)
            ImmutableAuditSection(
                events: auditEvents,
                phase: auditPhase,
                exportLocation: exportLocation,
                canExportAudit: canExportAudit,
                exportUnavailableReason: exportUnavailableReason,
                selectedAudit: $selectedAudit,
                exportAudit: exportAudit,
                retry: refreshAudit
            )
        }
    }
}

private struct SyncHealthSection: View {
    let health: SyncHealthPresentation?
    let phase: OperationsLoadPhase
    let errorMessage: String?

    var body: some View {
        Section("Sync health") {
            Text("This reflects the most recent workspace refresh. Resolve conflicts or refresh account context before relying on stale operational data.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let health {
                LabeledContent("Pending queue", value: health.queueDescription)
                LabeledContent("Quarantine", value: health.quarantineDescription)
                LabeledContent("Conflicts", value: "\(health.mirror.conflictCount)")
                LabeledContent("Last server contact", value: health.mirror.lastSuccessfulServerContact?.formatted() ?? "Not confirmed")
                LabeledContent("Backup", value: health.backupDescription)
                Label(
                    health.accountFresh ? "Account context is fresh" : "Account context needs refresh",
                    systemImage: health.accountFresh ? "checkmark.shield" : "exclamationmark.shield"
                )
                .foregroundStyle(health.accountFresh ? .green : .orange)
                if let errorMessage {
                    Text("Latest refresh failed: \(errorMessage)").font(.footnote).foregroundStyle(.red)
                }
            } else if case .loading = phase {
                ProgressView("Loading sync health")
            } else if let errorMessage {
                Text("Sync health unavailable: \(errorMessage)").foregroundStyle(.red)
            } else {
                Text("Sync health has not been loaded.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ReportsSection: View {
    let reports: [OperationsReport]
    let phase: OperationsLoadPhase
    @Binding var selectedReport: OperationsReport?
    let retry: () -> Void

    var body: some View {
        Section("Reports") {
            switch phase {
            case .idle where reports.isEmpty, .loading where reports.isEmpty:
                ProgressView("Loading reports")
            case .empty:
                ContentUnavailableView(
                    "No reports", systemImage: "chart.bar.doc.horizontal", description: Text("No local report has been generated for this workspace."))
            case .failed(let message) where reports.isEmpty:
                OperationsErrorState(title: "Reports unavailable", message: message, retry: retry)
            default:
                ForEach(reports) { report in
                    Button {
                        selectedReport = report
                    } label: {
                        VStack(alignment: .leading) {
                            Text(report.title)
                            Text(report.summary).font(.footnote).foregroundStyle(.secondary)
                            Text(report.generatedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                            Label(report.isFinal ? "Final" : "Draft", systemImage: report.isFinal ? "checkmark.seal" : "doc.badge.clock").font(.caption)
                        }
                    }
                    .accessibilityIdentifier("operations.report.\(report.id)")
                }
                if case .failed(let message) = phase {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }
}

private struct WorkspaceAccessSection: View {
    let access: WorkspaceAccessPresentation?
    let phase: OperationsLoadPhase
    let errorMessage: String?

    var body: some View {
        Section("Workspace, share, and policy") {
            if let access {
                LabeledContent("Workspace", value: access.workspaceName)
                LabeledContent("Account", value: access.accountRecordName)
                LabeledContent("Role", value: access.role.rawValue)
                LabeledContent("Share permission", value: access.permission.rawValue)
                LabeledContent("Policy version", value: access.policyVersion)
                Text(access.disclosure).font(.footnote).foregroundStyle(.secondary)
                if let errorMessage {
                    Text("Latest workspace refresh failed: \(errorMessage)").font(.footnote).foregroundStyle(.red)
                }
            } else if case .loading = phase {
                ProgressView("Loading workspace scope")
            } else if let errorMessage {
                Text("Workspace scope unavailable: \(errorMessage)").foregroundStyle(.red)
            } else {
                Text("Workspace scope has not been loaded.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ImmutableAuditSection: View {
    let events: [AuditEventPresentation]
    let phase: OperationsLoadPhase
    let exportLocation: URL?
    let canExportAudit: Bool
    let exportUnavailableReason: String
    @Binding var selectedAudit: AuditEventPresentation?
    let exportAudit: () -> Void
    let retry: () -> Void

    var body: some View {
        Section("Immutable audit") {
            Text("Audit records are immutable. Export creates a prepared file only when the current organization authorization permits it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Export immutable audit", action: exportAudit)
                .disabled(!canExportAudit)
                .accessibilityIdentifier("operations.export-audit")
            if !canExportAudit {
                Text(exportUnavailableReason).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("operations.export-audit-reason")
            }
            if let exportLocation {
                Text("Prepared at \(exportLocation.lastPathComponent)").font(.footnote).foregroundStyle(.secondary)
            }
            switch phase {
            case .idle where events.isEmpty, .loading where events.isEmpty:
                ProgressView("Loading immutable audit")
            case .empty:
                ContentUnavailableView(
                    "No audit events", systemImage: "clock.arrow.circlepath", description: Text("No immutable events match this workspace and search."))
            case .failed(let message) where events.isEmpty:
                OperationsErrorState(title: "Audit unavailable", message: message, retry: retry)
            default:
                ForEach(events) { presentation in
                    Button {
                        selectedAudit = presentation
                    } label: {
                        VStack(alignment: .leading) {
                            Text(presentation.summary)
                            Text(presentation.event.occurredAt.formatted()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("operations.audit.\(presentation.id)")
                }
                if case .failed(let message) = phase {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }
}

private struct OperationsErrorState: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: retry)
        }
    }
}
