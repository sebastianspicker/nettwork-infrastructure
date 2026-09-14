import ContentSafety
import NetworkModel
import SwiftUI
import WorkspaceChangeControl

struct FloorPlanAttachmentStatusView: View {
    @Bindable var model: FloorPlanViewModel
    let permitsPrivilegedAction: Bool
    let hasAttachmentAuthorization: Bool
    let hasPreviewAuthorization: Bool
    let sanitizeSelectedPage: () -> Void
    let cleanup: () -> Void
    let retryPreview: () -> Void
    let stageWorkOrder: () -> Void
    let bindAsset: () -> Void

    var body: some View {
        attachmentStateView
        if let receipt = model.assetBindingReceipt {
            Text("Floor plan binding accepted: \(receipt.operationID.description)")
                .font(.footnote)
                .accessibilityIdentifier("floor-plan.asset-binding-receipt")
        }
    }

    @ViewBuilder private var attachmentStateView: some View {
        switch model.attachmentState {
        case .idle: EmptyView()
        case .inspectingPDF: ProgressView("Inspecting PDF pages safely").accessibilityIdentifier("floor-plan.inspecting-pdf")
        case .awaitingPDFPageSelection(let inspection): FloorPlanPDFPageSelection(model: model, inspection: inspection, sanitize: sanitizeSelectedPage)
        case .sanitizing: ProgressView("Sanitizing untrusted attachment").accessibilityIdentifier("floor-plan.sanitizing")
        case .staged(let descriptor):
            FloorPlanStagedAttachmentStatus(
                model: model,
                descriptor: descriptor,
                permitsPrivilegedAction: permitsPrivilegedAction,
                hasAttachmentAuthorization: hasAttachmentAuthorization,
                hasPreviewAuthorization: hasPreviewAuthorization,
                cleanup: cleanup,
                retryPreview: retryPreview,
                stageWorkOrder: stageWorkOrder,
                bindAsset: bindAsset
            )
        case .cleaningUp: ProgressView("Cleaning up staged attachment")
        case .failed(let message):
            Label(message, systemImage: NettworkStatusRole.conflict.symbolName)
                .foregroundStyle(NettworkStatusRole.conflict.color)
                .font(.footnote)
        }
    }
}

private struct FloorPlanPDFPageSelection: View {
    @Bindable var model: FloorPlanViewModel
    let inspection: FloorPlanPDFInspection
    let sanitize: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        adaptiveLayout {
            Stepper(
                "PDF page \(model.selectedPDFPage + 1) of \(inspection.pageCount)",
                value: Binding(
                    get: { model.selectedPDFPage },
                    set: { model.selectPDFPage($0, inspection: inspection) }
                ),
                in: 0...max(inspection.pageCount - 1, 0)
            )
            .accessibilityIdentifier("floor-plan.pdf-page")
            Button("Sanitize selected PDF page", action: sanitize)
                .buttonStyle(.borderedProminent)
                .disabled(model.isAttachmentOperationInFlight)
                .accessibilityIdentifier("floor-plan.sanitize-selected-pdf-page")
        }
        .font(.footnote)
        .padding(.horizontal)
    }

    private var adaptiveLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize || horizontalSizeClass == .compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NettworkSpacing.small))
            : AnyLayout(HStackLayout(spacing: NettworkSpacing.small))
    }
}

private struct FloorPlanStagedAttachmentStatus: View {
    @Bindable var model: FloorPlanViewModel
    let descriptor: SanitizedContentDescriptor
    let permitsPrivilegedAction: Bool
    let hasAttachmentAuthorization: Bool
    let hasPreviewAuthorization: Bool
    let cleanup: () -> Void
    let retryPreview: () -> Void
    let stageWorkOrder: () -> Void
    let bindAsset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FloorPlanAttachmentCleanupRow(
                descriptor: descriptor,
                isDisabled: !hasAttachmentAuthorization || model.isAttachmentOperationInFlight,
                cleanup: cleanup
            )
            if model.canRetryAttachmentPreview {
                Button("Retry sanitized preview", action: retryPreview)
                    .buttonStyle(.bordered)
                    .disabled(!hasPreviewAuthorization || model.isAttachmentOperationInFlight)
                    .accessibilityIdentifier("floor-plan.retry-preview")
            }
            FloorPlanAssetBindingAction(
                model: model,
                hasAttachmentAuthorization: hasAttachmentAuthorization,
                permitsPrivilegedAction: permitsPrivilegedAction,
                stageWorkOrder: stageWorkOrder,
                bindAsset: bindAsset
            )
            if let error = model.assetActionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(NettworkStatusRole.conflict.color)
                    .accessibilityStatus(error, identifier: "floor-plan.asset-action-error")
            }
        }
        .font(.footnote)
        .padding(.horizontal)
    }
}

private struct FloorPlanAttachmentCleanupRow: View {
    let descriptor: SanitizedContentDescriptor
    let isDisabled: Bool
    let cleanup: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        adaptiveLayout {
            Label("Sanitized \(descriptor.contentType.rawValue) staged", systemImage: "checkmark.shield")
            Button("Clean up", action: cleanup)
                .buttonStyle(.bordered)
                .disabled(isDisabled)
                .accessibilityIdentifier("floor-plan.cleanup")
        }
    }

    private var adaptiveLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize || horizontalSizeClass == .compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NettworkSpacing.small))
            : AnyLayout(HStackLayout(spacing: NettworkSpacing.small))
    }
}

private struct FloorPlanAssetBindingAction: View {
    @Bindable var model: FloorPlanViewModel
    let hasAttachmentAuthorization: Bool
    let permitsPrivilegedAction: Bool
    let stageWorkOrder: () -> Void
    let bindAsset: () -> Void
    var body: some View {
        if let workOrderID = model.assetWorkOrderID {
            Text("Replacement work order \(workOrderID.description) is staged. Complete it in Work Orders, then bind these exact sanitized bytes.")
                .textSelection(.enabled)
            Button("Bind completed work order", action: bindAsset)
                .buttonStyle(.borderedProminent)
                .disabled(!hasAttachmentAuthorization || model.isAttachmentOperationInFlight)
                .accessibilityIdentifier("floor-plan.bind-asset")
        } else {
            Button("Create replacement work order", action: stageWorkOrder)
                .buttonStyle(.borderedProminent)
                .disabled(!permitsPrivilegedAction || model.isAttachmentOperationInFlight)
                .accessibilityIdentifier("floor-plan.stage-asset-work-order")
        }
    }
}
