import FeatureContracts
import NetworkModel
import SwiftUI

struct ScanIntakeScreen: View {
    @Bindable var model: ScanIntakeModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isManualEntryFocused: Bool

    var body: some View {
        Form {
            Section {
                NettworkPageHeader(
                    "Scan",
                    subtitle: "Capture or paste an opaque label, then resolve it against the current scoped mirror.",
                    systemImage: "qrcode.viewfinder"
                )
            }
            ScanCameraSection(
                availability: model.captureAvailability,
                lifecycle: model.captureLifecycle,
                begin: begin,
                suspend: suspend,
                resume: resume,
                cancel: cancel
            )
            ScanManualEntrySection(
                entry: $model.manualEntry,
                isFocused: $isManualEntryFocused,
                submit: submitKeyboardWedge,
                resolve: resolveManualEntry
            )
            if let objectID = resolvedObjectID {
                Section("Resolved object") {
                    NettworkNotice(
                        "Label resolved",
                        message: "Review the matched object before making any change.",
                        style: .success
                    )
                    NavigationLink("Open object details", value: AppRoute.object(objectID.rawValue))
                        .accessibilityIdentifier("scan.open-object")
                }
            }
            resolutionStatus
        }
        .navigationTitle("Scan")
        .task { await model.refreshCaptureAvailability() }
        .onChange(of: scenePhase) { _, phase in
            Task { await model.updateScenePhase(phase) }
        }
    }

    private var resolvedObjectID: ObjectID? {
        guard case let .objectDetails(objectID)? = model.destination else { return nil }
        return objectID
    }

    private var resolutionDescription: String? {
        switch model.resolutionState {
        case .idle:
            nil
        case .resolving:
            "Resolving the label against the current scoped mirror."
        case .invalid(let reason), .unavailable(let reason):
            reason
        case .resolved:
            "Label resolved."
        }
    }

    @ViewBuilder private var resolutionStatus: some View {
        if let resolutionDescription {
            switch model.resolutionState {
            case .resolving:
                NettworkLoadingState("Resolving label")
                    .accessibilityIdentifier("scan.resolution-status")
            case .invalid, .unavailable:
                NettworkNotice("Label unavailable", message: resolutionDescription, style: .critical)
                    .accessibilityIdentifier("scan.resolution-status")
            case .resolved:
                NettworkNotice("Label resolved", message: resolutionDescription, style: .success)
                    .accessibilityIdentifier("scan.resolution-status")
            case .idle:
                EmptyView()
            }
        }
    }

    private func begin() { Task { await model.begin() } }
    private func suspend() { Task { await model.suspend() } }
    private func resume() { Task { await model.resume() } }
    private func cancel() { Task { await model.cancel() } }
    private func resolveManualEntry() { Task { await model.submitManual() } }

    private func submitKeyboardWedge() {
        let wedgeSubmission = model.manualEntry
        model.manualEntry = ""
        Task { await model.receiveKeyboardWedge(wedgeSubmission, isTerminator: true) }
    }
}

private struct ScanCameraSection: View {
    let availability: ScanCaptureAvailability
    let lifecycle: ScanCaptureLifecycle
    let begin: () -> Void
    let suspend: () -> Void
    let resume: () -> Void
    let cancel: () -> Void

    var body: some View {
        Section("Camera") {
            Text("Use the device camera when available. You can suspend scanning when attention moves elsewhere.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Start scanner", action: begin)
                .disabled(!availability.canStart || isEngaged)
                .accessibilityIdentifier("scan.start")
            if lifecycle == .ready {
                Button("Suspend scanner", action: suspend).accessibilityIdentifier("scan.suspend")
            }
            if lifecycle == .suspended {
                Button("Resume scanner", action: resume).accessibilityIdentifier("scan.resume")
            }
            if isEngaged {
                Button("Cancel scanner", role: .cancel, action: cancel).accessibilityIdentifier("scan.cancel")
            }
            Text(description).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var isEngaged: Bool {
        [.ready, .suspended, .requestingPermission].contains(lifecycle)
    }

    private var description: String {
        if let reason = availability.reason { return reason }
        switch lifecycle {
        case .ready:
            return "Scanner ready. Labels resolve only against the current scoped mirror."
        case .requestingPermission:
            return "Requesting camera access."
        case .suspended:
            return "Scanner paused while this scene is inactive."
        case .inactive, .cancelled:
            return "Camera scanning is not active."
        }
    }
}

private struct ScanManualEntrySection: View {
    @Binding var entry: String
    let isFocused: FocusState<Bool>.Binding
    let submit: () -> Void
    let resolve: () -> Void

    var body: some View {
        Section("Type, paste, or Bluetooth scanner") {
            Text("Enter the opaque Nettwork object link exactly as received. The value is resolved against the active workspace scope.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Opaque Nettwork object link", text: $entry)
                .scanInputFormatting()
                .focused(isFocused)
                .onSubmit(submit)
                .accessibilityIdentifier("scan.manual")
            Button("Resolve label", action: resolve).accessibilityIdentifier("scan.resolve")
        }
    }
}

private extension View {
    @ViewBuilder
    func scanInputFormatting() -> some View {
        #if os(iOS)
            textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
        #else
            autocorrectionDisabled()
        #endif
    }
}
