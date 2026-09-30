import FeatureContracts
import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

@MainActor
@Observable
final class TraceInspectionModel {
    private let service: any TraceInspecting
    private let account: AccountContext
    private let identifierCopier: (any TraceIdentifierCopying)?
    private let drafts: (any TopologyWorkOrderDrafting)?
    private let onStagedWorkOrder: ((ObjectID) async -> Void)?
    private var loadGeneration: UInt64 = 0
    var direction: TraceDirection = .forward
    private(set) var state: InventoryPresentationState = .empty
    private(set) var inspection: TraceInspectionSnapshot?
    private(set) var selectedNodeID: ObjectID?
    private(set) var copiedIdentifier: String?
    private(set) var stagedWorkOrderID: ObjectID?
    var draftTitle = ""
    var draftTicket = ""
    var draftNotes = ""

    init(
        account: AccountContext,
        service: any TraceInspecting,
        identifierCopier: (any TraceIdentifierCopying)? = nil,
        drafts: (any TopologyWorkOrderDrafting)? = nil,
        onStagedWorkOrder: ((ObjectID) async -> Void)? = nil
    ) {
        self.account = account
        self.service = service
        self.identifierCopier = identifierCopier
        self.drafts = drafts
        self.onStagedWorkOrder = onStagedWorkOrder
    }
    func load(startPortID: ObjectID) async {
        guard !Task.isCancelled else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        let requestedDirection = direction
        state = .loading
        do {
            let result = try await service.inspect(
                startingAt: startPortID,
                direction: requestedDirection,
                in: account.namespace
            )
            guard generation == loadGeneration, !Task.isCancelled else { return }
            inspection = result
            if result.hasConflict {
                state = .conflict("Trace has a conflict; authoritative state remains unchanged.")
            } else if result.hasPendingWork {
                state = .pending("Trace includes planned work-order overlays.")
            } else if result.isStale {
                state = .offline("Trace may be stale while offline.")
            } else {
                state = .ready
            }
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            state = .offline("The trace is unavailable from the scoped local mirror.")
        }
    }

    func select(_ node: TraceNodeSnapshot) {
        selectedNodeID = node.id
    }

    func copyIdentifier(_ identifier: String) async {
        guard let identifierCopier else {
            state = .unavailable("Copying is unavailable until this platform injects a copy service.")
            return
        }
        await identifierCopier.copy(identifier: identifier)
        copiedIdentifier = identifier
    }

    func stageWork(from segment: TraceSegmentSnapshot) async {
        guard let seed = segment.workOrderRequest else {
            state = .unavailable("This segment has no complete typed work-order command, so no change can be staged.")
            return
        }
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let ticket = draftTicket.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = draftNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ticket.isEmpty else {
            state = .unavailable("Enter a ticket or change reference before staging this trace segment.")
            return
        }
        guard let drafts else {
            state = .unavailable("Work-order staging is unavailable for this trace.")
            return
        }
        do {
            let request = TopologyWorkOrderRequest(
                title: title.isEmpty ? seed.title : title,
                ticket: ticket,
                notes: notes.isEmpty ? seed.notes : notes,
                action: seed.action,
                resourceKeys: seed.resourceKeys
            )
            let workOrderID = try await drafts.stage(request, in: account.namespace)
            stagedWorkOrderID = workOrderID
            await onStagedWorkOrder?(workOrderID)
            state = .pending("A trace segment change was staged in work order \(workOrderID.description).")
        } catch {
            state = .conflict("The trace segment draft could not reserve its complete resource set.")
        }
    }
}

struct TraceInspectionScreen: View {
    @Bindable var model: TraceInspectionModel
    let startPortID: ObjectID

    let onOpenObject: ((ObjectID) -> Void)?
    let statusAnnouncer: any AccessibilityStatusAnnouncing

    init(
        model: TraceInspectionModel,
        startPortID: ObjectID,
        onOpenObject: ((ObjectID) -> Void)? = nil,
        statusAnnouncer: any AccessibilityStatusAnnouncing = AccessibilityStatusAnnouncer()
    ) {
        self.model = model
        self.startPortID = startPortID
        self.onOpenObject = onOpenObject
        self.statusAnnouncer = statusAnnouncer
    }

    var body: some View {
        List {
            Picker("Direction", selection: $model.direction) { ForEach(TraceDirection.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                .pickerStyle(.segmented).accessibilityIdentifier("trace.direction")
            if let inspection = model.inspection {
                Section("Trace status") {
                    Text(statusDescription)
                        .accessibilityIdentifier("trace.status")
                    if model.copiedIdentifier != nil {
                        Label("Identifier copied", systemImage: NettworkStatusRole.ready.symbolName)
                            .foregroundStyle(NettworkStatusRole.ready.color)
                    }
                }
                Section("Trace work-order draft") {
                    TextField("Title", text: $model.draftTitle)
                    TextField("Ticket or change reference", text: $model.draftTicket)
                    TextField("Notes", text: $model.draftNotes, axis: .vertical)
                    Text("A segment action is staged only after a ticket is supplied; execution remains in Work Orders.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    actionFeedback
                }
                if !inspection.globalWarnings.isEmpty { Section("Warnings") { ForEach(inspection.globalWarnings, id: \.self) { Text($0) } } }
                ForEach(inspection.branches) { branch in
                    Section("Branch · \(branch.termination)") {
                        TraceDiagram(
                            branch: branch,
                            selectedNodeID: model.selectedNodeID,
                            onSelectNode: model.select,
                            onCopyIdentifier: model.copyIdentifier,
                            onOpenObject: onOpenObject,
                            onStageWork: model.stageWork
                        )
                        ForEach(branch.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No trace loaded",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Select a starting port to inspect its connection path.")
                )
            }
        }
        .navigationTitle("Trace")
        .task(id: model.direction) { await model.load(startPortID: startPortID) }
        .onChange(of: model.state) { _, _ in
            statusAnnouncer.announce(statusDescription)
        }
        .onChange(of: model.copiedIdentifier) { _, identifier in
            if identifier != nil { statusAnnouncer.announce("Identifier copied.") }
        }
    }

    @ViewBuilder
    private var actionFeedback: some View {
        switch model.state {
        case .pending(let message):
            Label(message, systemImage: NettworkStatusRole.pending.symbolName)
                .foregroundStyle(NettworkStatusRole.pending.color)
        case .conflict(let message), .unavailable(let message):
            Label(message, systemImage: NettworkStatusRole.conflict.symbolName)
                .foregroundStyle(NettworkStatusRole.conflict.color)
        default:
            EmptyView()
        }
    }

    private var statusDescription: String {
        switch model.state {
        case .loading: "Loading the scoped local trace."
        case .ready: "Trace is ready."
        case .empty: "No trace has been loaded."
        case .offline(let message), .pending(let message), .conflict(let message),
            .quarantined(let message), .permissionDenied(let message), .unavailable(let message):
            message
        }
    }
}

private struct TraceDiagram: View {
    let branch: TraceBranchSnapshot
    let selectedNodeID: ObjectID?

    let onSelectNode: (TraceNodeSnapshot) -> Void
    let onCopyIdentifier: (String) async -> Void
    let onOpenObject: ((ObjectID) -> Void)?
    let onStageWork: (TraceSegmentSnapshot) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(branch.nodes.enumerated()), id: \.element.id) { index, node in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        onSelectNode(node)
                    } label: {
                        Label(
                            "\(node.deviceName) · \(node.portLabel) · \(node.faceName) · \(node.roomRack)",
                            systemImage: node.id == selectedNodeID ? "checkmark.circle.fill" : "circle.inset.filled"
                        )
                    }
                    HStack {
                        Button("Copy identifier") { Task { await onCopyIdentifier(node.id.description) } }
                        if let onOpenObject {
                            Button("Open details") { onOpenObject(node.id) }
                        } else {
                            NavigationLink("Open details", value: AppRoute.object(node.id.rawValue))
                        }
                    }
                    .font(.footnote)
                    if !node.logicalContext.isEmpty {
                        Text(node.logicalContext.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Logical context: \(node.logicalContext.joined(separator: ", "))")
                    }
                }
                .accessibilityIdentifier("trace.node.\(node.id.description)")
                .accessibilityHint("Select to expose this node for details or a work-order draft.")
                if index < branch.segments.count {
                    TraceSegmentRow(segment: branch.segments[index], onStageWork: onStageWork)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ordered text alternative for this trace branch")
    }
}

private struct TraceSegmentRow: View {
    let segment: TraceSegmentSnapshot
    let onStageWork: (TraceSegmentSnapshot) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(segment.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(segment.kind.rawValue) connection: \(segment.label)")
            if let detail = segment.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if segment.workOrderRequest != nil {
                Button("Stage work from segment") { Task { await onStageWork(segment) } }
                    .font(.footnote)
                    .accessibilityIdentifier("trace.segment.\(segment.id).stage")
            } else {
                Text("No complete work-order command is available for this segment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("trace.segment.\(segment.id).unavailable")
            }
        }
    }
}
