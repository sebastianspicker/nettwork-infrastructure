import FeatureContracts
import SwiftUI
import WorkspaceChangeControl

/// Authoritative work orders, so reserved, approved or executing work can be
/// continued after a relaunch. Opening one re-reads it through the service.
struct WorkOrderExistingSection: View {
    @Bindable var model: OperationsFeatureViewModel
    let authorization: OperationsAuthorization

    var body: some View {
        Section("Existing work orders") {
            Button("Refresh work orders") {
                Task { await model.loadWorkOrders() }
            }
            .accessibilityIdentifier("work-order.refresh-list")
            if let message = model.workOrderListError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(NettworkStatusRole.conflict.color)
                    .accessibilityIdentifier("work-order.list-error")
            }
            if model.workOrderRows.isEmpty {
                Text("No work orders have been reserved in this workspace yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.workOrderRows) { row in
                Button {
                    Task { await model.reopenWorkOrder(row.id, using: authorization) }
                } label: {
                    WorkOrderRowLabel(row: row, isOpen: row.id == model.draft.id)
                }
                .disabled(!model.canReopenWorkOrder || !authorization.permitsPrivilegedAction)
                .accessibilityIdentifier("work-order.reopen")
            }
        }
        .task { await model.loadWorkOrders() }
    }
}

/// Explains an expired, unconfirmed or released reservation and offers the
/// renewal step; release itself is the Safety section's cancellation path.
struct WorkOrderReservationRecoverySection: View {
    @Bindable var model: OperationsFeatureViewModel

    var body: some View {
        if let text = model.reservationRecoveryText {
            Section("Reservation recovery") {
                Label(text, systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(NettworkStatusRole.pending.color)
                    .accessibilityIdentifier("work-order.reservation-recovery")
                if model.canReserveFreshCopy {
                    Button("Reserve a fresh copy") { model.prepareFreshCopyOfReleasedWorkOrder() }
                        .accessibilityIdentifier("work-order.reserve-fresh-copy")
                }
            }
        }
    }
}

private struct WorkOrderRowLabel: View {
    let row: OperationsWorkOrderRow
    let isOpen: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(row.title)
                Text([row.status.displayName, row.ticket].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let expiry = row.reservationExpiresAt, row.pendingOverlay || row.confirmedOverlay {
                    Text(row.confirmedOverlay ? "Reserved until \(expiry.formatted())" : "Reservation expired \(expiry.formatted())")
                        .font(.caption)
                        .foregroundStyle(row.confirmedOverlay ? NettworkStatusRole.reserved.color : NettworkStatusRole.conflict.color)
                } else if row.pendingOverlay {
                    Text("Reservation not confirmed").font(.caption).foregroundStyle(NettworkStatusRole.pending.color)
                }
                Text("Updated \(row.updatedAt.formatted())").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isOpen { Image(systemName: "checkmark.circle.fill") }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension WorkOrderStatus {
    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .reserved: "Reserved"
        case .approved: "Approved"
        case .executing: "Executing"
        case .completed: "Completed"
        case .cancellationRequested: "Cancellation requested"
        case .cancelled: "Cancelled"
        case .reconciliation: "Reconciliation"
        }
    }
}
