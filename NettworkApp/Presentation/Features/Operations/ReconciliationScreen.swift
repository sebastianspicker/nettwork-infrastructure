import FeatureContracts
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

@MainActor
@Observable
final class ReconciliationViewModel {
    private(set) var comparisons: [ReconciliationComparison] = []
    private(set) var createdCorrectiveWorkOrderID: ObjectID?
    private(set) var errorMessage: String?
    private let service: any ReconciliationFeatureService
    private let onStagedWorkOrder: @MainActor (ObjectID) async -> Void

    init(
        service: any ReconciliationFeatureService,
        onStagedWorkOrder: @escaping @MainActor (ObjectID) async -> Void = { _ in }
    ) {
        self.service = service
        self.onStagedWorkOrder = onStagedWorkOrder
    }

    func refresh() async {
        do {
            comparisons = try await service.unresolvedComparisons()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func createCorrectiveWorkOrder(for comparison: ReconciliationComparison, authorization: OperationsAuthorization) async {
        guard authorization.permitsPrivilegedAction else {
            errorMessage = "A fresh technician or administrator authorization is required."
            return
        }
        do {
            let id = try await service.createCorrectiveWorkOrder(
                for: comparison.id,
                authorization: authorization
            )
            createdCorrectiveWorkOrderID = id
            await onStagedWorkOrder(id)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ReconciliationScreen: View {
    @State private var model: ReconciliationViewModel
    let authorization: OperationsAuthorization

    init(model: ReconciliationViewModel, authorization: OperationsAuthorization) {
        _model = State(initialValue: model)
        self.authorization = authorization
    }

    var body: some View {
        List {
            Section {
                NettworkPageHeader(
                    "Reconciliation",
                    subtitle: "Compare intended and current workspace state, then stage a corrective work order for review.",
                    systemImage: "arrow.triangle.merge"
                )
            }
            .listRowInsets(EdgeInsets())

            if model.comparisons.isEmpty {
                Section {
                    NettworkEmptyState(
                        "No unresolved comparisons",
                        systemImage: "arrow.triangle.merge",
                        message: "Refresh to check the current workspace for unresolved comparisons."
                    )
                }
            } else {
                ForEach(model.comparisons) { comparison in
                    Section {
                        Text("Review the difference below before staging a corrective work order.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        LabeledContent("Base", value: comparison.baseSummary)
                        LabeledContent("Intended", value: comparison.intendedSummary)
                        LabeledContent("Current", value: comparison.currentSummary)
                        if comparison.isSecurityEvent {
                            NettworkNotice(
                                "Security-sensitive reconciliation",
                                message: "Review this comparison carefully before staging corrective work.",
                                style: .critical
                            )
                        }
                        Button("Create corrective work order") {
                            Task { await model.createCorrectiveWorkOrder(for: comparison, authorization: authorization) }
                        }
                        .disabled(!authorization.permitsPrivilegedAction)
                        .accessibilityIdentifier("reconciliation.corrective-work-order.\(comparison.id)")
                    } header: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(comparison.title)
                            Text(comparison.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Reconciliation")
        .task { await model.refresh() }
        .safeAreaInset(edge: .bottom) {
            if let id = model.createdCorrectiveWorkOrderID {
                Label("Corrective work order \(id.description) created", systemImage: "checkmark.seal")
                    .font(.footnote)
                    .padding()
                    .background(.thinMaterial, in: Capsule())
            }
        }
    }
}
