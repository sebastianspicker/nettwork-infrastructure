import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

struct AuditEventPresentation: Identifiable, Equatable, Sendable {
    let event: AuditEvent
    let summary: String
    var id: ObjectID { event.id }
}

struct OperationsReport: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let generatedAt: Date
    let summary: String
    let isFinal: Bool
}

struct WorkspaceAccessPresentation: Equatable, Sendable {
    let workspaceName: String
    let accountRecordName: String
    let role: OfficialClientRole
    let permission: WorkspaceSharePermission
    let policyVersion: String
    let disclosure: String
}

struct SyncHealthPresentation: Equatable, Sendable {
    let mirror: SyncMirrorPresentation
    let queueDescription: String
    let quarantineDescription: String
    let backupDescription: String
    let accountFresh: Bool
}

struct SyncMirrorPresentation: Equatable, Sendable {
    let conflictCount: Int
    let lastSuccessfulServerContact: Date?
}

enum OperationsScreenMode: String, CaseIterable, Equatable, Identifiable, Sendable {
    case reports
    case audit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reports: "Reports"
        case .audit: "Audit"
        }
    }
}

enum OperationsLoadPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
}

@MainActor
protocol OperationsReadModel {
    func auditEvents(matching query: String) async throws -> [AuditEventPresentation]
    func reports() async throws -> [OperationsReport]
    func syncHealth() async throws -> SyncHealthPresentation
    func workspaceAccess() async throws -> WorkspaceAccessPresentation
    func exportImmutableAudit(authorization: AuthorizedOperationContext) async throws -> URL
}

@MainActor
@Observable
final class OperationsReadViewModel {
    var auditQuery = ""
    private(set) var auditEvents: [AuditEventPresentation] = []
    private(set) var reports: [OperationsReport] = []
    private(set) var syncHealth: SyncHealthPresentation?
    private(set) var access: WorkspaceAccessPresentation?
    private(set) var exportLocation: URL?
    private(set) var reportsPhase: OperationsLoadPhase = .idle
    private(set) var auditPhase: OperationsLoadPhase = .idle
    private(set) var syncHealthErrorMessage: String?
    private(set) var workspaceAccessErrorMessage: String?
    private(set) var exportErrorMessage: String?
    private let service: any OperationsReadModel
    private var reportsGeneration = 0
    private var auditGeneration = 0

    init(service: any OperationsReadModel) { self.service = service }

    func refresh(_ mode: OperationsScreenMode) async {
        switch mode {
        case .reports: await refreshReports()
        case .audit: await refreshAudit()
        }
    }

    func refreshReports() async {
        reportsGeneration += 1
        let generation = reportsGeneration
        reportsPhase = .loading
        syncHealthErrorMessage = nil
        await loadReports(generation: generation)
        guard generation == reportsGeneration, !Task.isCancelled else { return }
        await loadSyncHealth(generation: generation)
    }

    private func loadReports(generation: Int) async {
        do {
            let loadedReports = try await service.reports()
            guard generation == reportsGeneration else { return }
            reports = loadedReports
            reportsPhase = reports.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            guard generation == reportsGeneration else { return }
            reportsPhase = .idle
        } catch {
            guard generation == reportsGeneration else { return }
            reportsPhase = .failed(error.localizedDescription)
        }
    }

    private func loadSyncHealth(generation: Int) async {
        do {
            let health = try await service.syncHealth()
            guard generation == reportsGeneration else { return }
            syncHealth = health
        } catch is CancellationError {
            return
        } catch {
            guard generation == reportsGeneration else { return }
            syncHealthErrorMessage = error.localizedDescription
        }
    }

    func refreshAudit() async {
        auditGeneration += 1
        let generation = auditGeneration
        auditPhase = .loading
        workspaceAccessErrorMessage = nil
        await loadAuditEvents(generation: generation)
        guard generation == auditGeneration, !Task.isCancelled else { return }
        await loadWorkspaceAccess(generation: generation)
    }

    private func loadAuditEvents(generation: Int) async {
        do {
            let events = try await service.auditEvents(matching: auditQuery)
            guard generation == auditGeneration else { return }
            auditEvents = events
            auditPhase = auditEvents.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            guard generation == auditGeneration else { return }
            auditPhase = .idle
        } catch {
            guard generation == auditGeneration else { return }
            auditPhase = .failed(error.localizedDescription)
        }
    }

    private func loadWorkspaceAccess(generation: Int) async {
        do {
            let workspaceAccess = try await service.workspaceAccess()
            guard generation == auditGeneration else { return }
            access = workspaceAccess
        } catch is CancellationError {
            return
        } catch {
            guard generation == auditGeneration else { return }
            workspaceAccessErrorMessage = error.localizedDescription
        }
    }

    func exportAudit(authorization: AuthorizedOperationContext?) async {
        guard let authorization else {
            exportErrorMessage = "A current authorized export context is required."
            return
        }
        do {
            exportLocation = try await service.exportImmutableAudit(authorization: authorization)
            exportErrorMessage = nil
        } catch { exportErrorMessage = error.localizedDescription }
    }

    func dismissExportError() { exportErrorMessage = nil }
}

struct OperationsScreen: View {
    @State private var model: OperationsReadViewModel
    let mode: OperationsScreenMode
    let exportAuthorization: (() -> AuthorizedOperationContext?)?
    let canExportAudit: Bool
    let exportUnavailableReason: String
    @State private var selectedAudit: AuditEventPresentation?
    @State private var selectedReport: OperationsReport?

    init(
        model: OperationsReadViewModel,
        mode: OperationsScreenMode,
        exportAuthorization: (() -> AuthorizedOperationContext?)? = nil,
        canExportAudit: Bool? = nil,
        exportUnavailableReason: String = "Audit export requires current organization authorization."
    ) {
        _model = State(initialValue: model)
        self.mode = mode
        self.exportAuthorization = exportAuthorization
        self.canExportAudit = canExportAudit ?? (exportAuthorization != nil)
        self.exportUnavailableReason = exportUnavailableReason
    }

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                NettworkPageHeader(
                    mode.title,
                    subtitle: mode == .reports
                        ? "Review local operational reports alongside current sync health."
                        : "Search immutable activity and export it only with current authorization.",
                    systemImage: mode == .reports ? "chart.bar.doc.horizontal" : "clock.arrow.circlepath"
                )
            }
            .listRowInsets(EdgeInsets())
            OperationsScreenSections(
                mode: mode,
                reports: model.reports,
                reportsPhase: model.reportsPhase,
                syncHealth: model.syncHealth,
                syncHealthErrorMessage: model.syncHealthErrorMessage,
                auditEvents: model.auditEvents,
                auditPhase: model.auditPhase,
                access: model.access,
                workspaceAccessErrorMessage: model.workspaceAccessErrorMessage,
                exportLocation: model.exportLocation,
                canExportAudit: canExportAudit,
                exportUnavailableReason: exportUnavailableReason,
                selectedAudit: $selectedAudit,
                selectedReport: $selectedReport,
                exportAudit: exportAudit,
                refreshReports: refreshReports,
                refreshAudit: refreshAudit
            )
        }
        .navigationTitle(mode.title)
        .accessibilityIdentifier("operations.\(mode.rawValue)")
        .modifier(AuditSearchModifier(mode: mode, query: Bindable(model).auditQuery))
        .task(id: mode) { await model.refresh(mode) }
        .task(id: mode == .audit ? model.auditQuery : "") {
            guard mode == .audit else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            await model.refreshAudit()
        }
        .refreshable { await model.refresh(mode) }
        .sheet(item: $selectedAudit) { AuditEventDetailScreen(presentation: $0) }
        .sheet(item: $selectedReport) { OperationsReportDetailScreen(report: $0) }
        .alert(
            "Audit export unavailable",
            isPresented: Binding(
                get: { model.exportErrorMessage != nil },
                set: { if !$0 { model.dismissExportError() } }
            )
        ) {
            Button("OK", role: .cancel) { model.dismissExportError() }
        } message: {
            Text(model.exportErrorMessage ?? "")
        }
    }

    private func exportAudit() {
        Task { await model.exportAudit(authorization: exportAuthorization?()) }
    }

    private func refreshReports() {
        Task { await model.refreshReports() }
    }

    private func refreshAudit() {
        Task { await model.refreshAudit() }
    }
}

private struct AuditSearchModifier: ViewModifier {
    let mode: OperationsScreenMode
    @Binding var query: String

    func body(content: Content) -> some View {
        if mode == .audit {
            content.searchable(text: $query, prompt: "Search immutable audit events")
        } else {
            content
        }
    }
}
