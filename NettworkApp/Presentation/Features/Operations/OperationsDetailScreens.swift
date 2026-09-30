import FeatureContracts
import NetworkModel
import SwiftUI
import WorkspaceChangeControl

private let officialClientPolicyLimitation =
    "Official-client roles are a UI and client policy, not hostile-client authorization."

struct OperationsReportDetailScreen: View {
    let report: OperationsReport

    var body: some View {
        List {
            Section("Report") {
                LabeledContent("Title", value: report.title)
                LabeledContent("Generated", value: report.generatedAt.formatted())
                LabeledContent("Status", value: report.isFinal ? "Final" : "Draft")
            }
            Section("Summary") { Text(report.summary) }
        }
        .navigationTitle("Report detail")
        .accessibilityIdentifier("operations.report-detail")
    }
}

struct AuditEventDetailScreen: View {
    let presentation: AuditEventPresentation

    var body: some View {
        List {
            AuditPayloadClaimsSection(event: presentation.event)
            AuditServerMetadataSection(event: presentation.event)
            AuditPolicySection(event: presentation.event)
            AuditChangesSection(event: presentation.event)
        }
        .navigationTitle("Audit detail")
    }

    static func opaqueSummary(_ data: Data?) -> String {
        data.map { "Present, \($0.count) bytes" } ?? "Not recorded"
    }
}

private struct AuditPayloadClaimsSection: View {
    let event: AuditEvent

    var body: some View {
        Section("Payload claims") {
            LabeledContent("Event ID", value: event.id.description)
            LabeledContent("Operation ID", value: event.operationID.description)
            LabeledContent("Correlation ID", value: event.correlationID.description)
            LabeledContent("Claimed actor", value: event.actorID)
            LabeledContent("Installation", value: event.installationID ?? "Not recorded")
            LabeledContent("Session", value: event.sessionID ?? "Not recorded")
            LabeledContent("Session generation", value: event.sessionGeneration.map(String.init) ?? "Not recorded")
            LabeledContent("Result", value: String(describing: event.result))
            LabeledContent("Source", value: event.source.rawValue)
            LabeledContent("Client occurred", value: event.occurredAt.formatted())
            LabeledContent("Work order", value: event.workOrderID?.description ?? "None")
            LabeledContent("Ticket", value: event.ticket ?? "None")
            LabeledContent("Error classification", value: event.errorClassification?.rawValue ?? "None")
            LabeledContent("Affected objects", value: event.affectedObjectIDs.map(\.description).joined(separator: ", "))
            ForEach(event.affectedResourceKeys, id: \.self) {
                Text($0.description).font(.footnote.monospaced())
            }
        }
    }
}

private struct AuditServerMetadataSection: View {
    let event: AuditEvent

    var body: some View {
        Section("Verified server metadata") {
            LabeledContent("Server occurred", value: event.serverOccurredAt?.formatted() ?? "Unavailable")
            if event.cloudKitChangeTags.isEmpty {
                Text("CloudKit change tags are unavailable for this event.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(event.cloudKitChangeTags.sorted { $0.key < $1.key }, id: \.key) { key, changeTag in
                    LabeledContent(key.description, value: changeTag).font(.footnote.monospaced())
                }
            }
        }
    }
}

private struct AuditPolicySection: View {
    let event: AuditEvent

    var body: some View {
        Section("Official-client policy") {
            LabeledContent("Policy version", value: event.policyVersion)
            Text(officialClientPolicyLimitation).font(.footnote).foregroundStyle(.secondary)
            Text(
                "Payload actor, installation, session, and client time are recorded claims. "
                    + "Server time and change tags are shown separately when CloudKit supplied them."
            )
            .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct AuditChangesSection: View {
    let event: AuditEvent

    var body: some View {
        Section("Immutable changes") {
            ForEach(Array(event.changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading) {
                    Text(change.resourceKey.description).font(.footnote.monospaced())
                    LabeledContent("Before", value: AuditEventDetailScreen.opaqueSummary(change.before))
                    LabeledContent("After", value: AuditEventDetailScreen.opaqueSummary(change.after))
                    LabeledContent("Patch", value: AuditEventDetailScreen.opaqueSummary(change.patch))
                }
            }
        }
    }
}
