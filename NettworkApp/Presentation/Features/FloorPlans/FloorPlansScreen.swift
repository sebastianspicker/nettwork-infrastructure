import ContentSafety
import CoreGraphics
import FeatureContracts
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

struct FloorPlansScreen: View {
    @State var model: FloorPlanViewModel
    let authorization: OperationsAuthorization
    /// The app integration owns file importer presentation and supplies only an
    /// already-authorized opaque source here, never a feature-controlled URL.
    let importSource: (() -> (any OpaqueContentSource)?)?
    let attachmentAuthorization: (() -> AuthorizedOperationContext?)?
    /// Must mint a current `.readAttachment` context after sanitization; the
    /// import context is intentionally `.createAttachment` and cannot be reused.
    let previewAuthorization: (() -> AuthorizedOperationContext?)?
    let objectDestination: (@MainActor (ObjectID) -> AnyView)?
    let inventory: InventoryExploreModel?
    let statusAnnouncer: any AccessibilityStatusAnnouncing
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @GestureState private var liveMagnification = 1.0
    @GestureState private var panTranslation = CGSize.zero
    @State private var showAccessibleList = false
    @State var newObjectID = ""
    @State var selectedAnchorObject: InventorySearchResult?
    @State private var showObjectPicker = false
    @State private var pendingAnchorRemoval: FloorPlanAnchor?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @MainActor init(
        model: FloorPlanViewModel,
        authorization: OperationsAuthorization,
        importSource: (() -> (any OpaqueContentSource)?)? = nil,
        attachmentAuthorization: (() -> AuthorizedOperationContext?)? = nil,
        previewAuthorization: (() -> AuthorizedOperationContext?)? = nil,
        objectDestination: (@MainActor (ObjectID) -> AnyView)? = nil,
        inventory: InventoryExploreModel? = nil,
        statusAnnouncer: any AccessibilityStatusAnnouncing = AccessibilityStatusAnnouncer()
    ) {
        _model = State(initialValue: model)
        self.authorization = authorization
        self.importSource = importSource
        self.attachmentAuthorization = attachmentAuthorization
        self.previewAuthorization = previewAuthorization
        self.objectDestination = objectDestination
        self.inventory = inventory
        self.statusAnnouncer = statusAnnouncer
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            NettworkPageHeader(
                "Floor plans",
                subtitle: "Review the sanitized plan, locate infrastructure, and stage anchored changes for approval.",
                systemImage: "map"
            )
            .padding(.horizontal, NettworkSpacing.medium)
            controls(model: $model)
            floorPlanCanvas(model: $model)
        }
        .navigationTitle("Floor Plans")
        .task {
            guard let context = previewAuthorization?() else { return }
            await model.loadPersistedFloorPlan(authorization: context)
        }
        .sheet(isPresented: $showAccessibleList) {
            FloorPlanAnchorList(
                model: model,
                authorization: authorization,
                objectDestination: objectDestination,
                onDone: { showAccessibleList = false }
            )
        }
        .sheet(isPresented: $showObjectPicker) {
            if let inventory {
                FloorPlanObjectPicker(model: inventory) { result in
                    selectedAnchorObject = result
                    showObjectPicker = false
                }
            }
        }
        .floorPlanAnchorRemovalDialog(
            anchor: $pendingAnchorRemoval,
            label: { model.labels[$0.objectID] ?? $0.objectID.description },
            remove: removeAnchor
        )
        .onChange(of: model.attachmentState) { _, state in
            statusAnnouncer.announce(floorPlanAttachmentStatus(state))
        }
        .onChange(of: model.assetActionError) { _, error in
            if let error { statusAnnouncer.announce(error) }
        }
        .onChange(of: model.anchorActionError) { _, error in
            if let error { statusAnnouncer.announce(error) }
        }
    }

    private func floorPlanCanvas(model: Bindable<FloorPlanViewModel>) -> some View {
        GeometryReader { proxy in
            ZStack {
                floorPlanPreview
                    .contentShape(Rectangle())
                    .gesture(canvasPanGesture)
                ForEach(model.wrappedValue.filteredAnchors) { anchor in
                    anchorMarker(anchor, size: proxy.size, model: model)
                }
            }
            .coordinateSpace(name: "floorPlanCanvas")
            .scaleEffect(CGFloat(zoom * liveMagnification))
            .offset(canvasOffset)
            .gesture(canvasMagnificationGesture)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Floor plan canvas")
            .accessibilityHint("Use the accessible anchor list for a text alternative.")
        }
        .padding()
    }

    @ViewBuilder private func controls(model: Bindable<FloorPlanViewModel>) -> some View {
        VStack(spacing: 8) {
            adaptiveControlLayout {
                TextField("Search anchors", text: model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("floor-plan.search")
                Button {
                    showAccessibleList = true
                } label: {
                    Label("Anchor list", systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("l", modifiers: [.command])
                .accessibilityIdentifier("floor-plan.accessible-list")
                Button("Reset view", action: resetCanvas)
                    .buttonStyle(.bordered)
                    .disabled(zoom == 1 && offset == .zero)
                    .accessibilityIdentifier("floor-plan.reset-view")
            }
            .padding([.horizontal, .top])
            layerControls(model: model)
            anchorControls(model: model)
            attachmentStatus
            if let error = model.wrappedValue.anchorActionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(NettworkStatusRole.conflict.color)
                    .padding(.horizontal)
                    .accessibilityStatus(error, identifier: "floor-plan.anchor-action-error")
            }
            if !model.wrappedValue.pendingAnchorWorkOrderIDs.isEmpty {
                Label(
                    "\(model.wrappedValue.pendingAnchorWorkOrderIDs.count) anchor change work order(s) staged. "
                        + "Complete them in Work Orders, then synchronize to update this plan.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.footnote)
                .foregroundStyle(NettworkStatusRole.pending.color)
                .padding(.horizontal)
                .accessibilityStatus(
                    "\(model.wrappedValue.pendingAnchorWorkOrderIDs.count) anchor change work orders staged and pending completion.",
                    identifier: "floor-plan.pending-anchor-work"
                )
            }
        }
    }

    @ViewBuilder
    private func layerControls(model: Bindable<FloorPlanViewModel>) -> some View {
        adaptiveControlLayout {
            ForEach(FloorPlanLayer.allCases) { layer in
                Toggle(
                    layer.rawValue.capitalized,
                    isOn: Binding(
                        get: { model.wrappedValue.visibleLayers.contains(layer) },
                        set: { enabled in
                            if enabled {
                                model.wrappedValue.visibleLayers.insert(layer)
                            } else {
                                model.wrappedValue.visibleLayers.remove(layer)
                            }
                        }
                    )
                )
                .toggleStyle(.button)
            }
            Button {
                requestAttachmentImport()
            } label: {
                Label("Import attachment", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                importSource == nil
                    || attachmentAuthorization == nil
                    || previewAuthorization == nil
                    || !model.wrappedValue.canBeginAttachmentImport
            )
            .accessibilityIdentifier("floor-plan.import")
        }
        .padding(.horizontal)
    }

    private func anchorControls(model: Bindable<FloorPlanViewModel>) -> some View {
        FloorPlanAnchorControls(
            selectedObject: $selectedAnchorObject,
            rawObjectID: $newObjectID,
            canChooseObject: inventory != nil,
            permitsPrivilegedAction: authorization.permitsPrivilegedAction,
            isActionInFlight: model.wrappedValue.isAnchorActionInFlight,
            chooseObject: { showObjectPicker = true },
            addSelected: addSelectedAnchor,
            addByIdentifier: addAnchor
        )
    }

    private var attachmentStatus: some View {
        FloorPlanAttachmentStatusView(
            model: model,
            permitsPrivilegedAction: authorization.permitsPrivilegedAction,
            hasAttachmentAuthorization: attachmentAuthorization != nil,
            hasPreviewAuthorization: previewAuthorization != nil,
            sanitizeSelectedPage: requestSelectedPDFPageSanitization,
            cleanup: requestAttachmentCleanup,
            retryPreview: requestAttachmentPreviewRetry,
            stageWorkOrder: requestAssetWorkOrder,
            bindAsset: requestAssetBinding
        )
    }

    @ViewBuilder private var floorPlanPreview: some View {
        switch model.previewState {
        case .idle:
            previewPlaceholder(
                "Sanitized floor plan",
                systemImage: "map",
                description: "Import an attachment to display its sanitized floor plan preview."
            )
        case .loading:
            previewPlaceholder(
                "Rendering sanitized floor plan",
                systemImage: "photo",
                description: "The sanitized preview is loading."
            )
            .overlay { ProgressView("Rendering sanitized floor plan") }
        case .rendered(let preview):
            Image(decorative: preview.image, scale: 1, orientation: .up)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel(preview.accessibilityDescription)
        case .cancelled:
            previewPlaceholder(
                "Sanitized floor plan rendering cancelled",
                systemImage: "xmark.circle",
                description: "The preview was not retained. Import the attachment again to retry."
            )
        case .failed:
            previewPlaceholder(
                "Unable to render sanitized floor plan",
                systemImage: "exclamationmark.triangle",
                description: "The attachment remains staged until you clean it up. Anchor locations remain available in the Anchor list."
            )
        }
    }

    private func previewPlaceholder(_ title: String, systemImage: String, description: String) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.quaternary)
            .overlay {
                ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
            }
            .accessibilityLabel(description)
    }

    private func anchorMarker(_ anchor: FloorPlanAnchor, size: CGSize, model: Bindable<FloorPlanViewModel>) -> some View {
        let label = model.wrappedValue.labels[anchor.objectID] ?? anchor.objectID.description
        return NavigationLink(value: AppRoute.object(anchor.objectID.rawValue)) {
            Label(label, systemImage: "mappin.circle.fill")
                .labelStyle(.iconOnly)
                .font(.title2)
        }
        .position(x: CGFloat(anchor.x) * size.width, y: CGFloat(anchor.y) * size.height)
        .accessibilityLabel("Anchor \(label), \(Int(anchor.x * 100)) percent across, \(Int(anchor.y * 100)) percent down")
        .accessibilityIdentifier("floor-plan.anchor.\(anchor.id)")
        .gesture(
            DragGesture(coordinateSpace: .named("floorPlanCanvas")).onEnded { value in
                guard !model.wrappedValue.isAnchorActionInFlight else { return }
                Task { await model.wrappedValue.move(anchor: anchor, to: value.location, in: size, authorization: authorization) }
            }
        )
        .contextMenu {
            Button("Remove anchor", role: .destructive) {
                pendingAnchorRemoval = anchor
            }
            .disabled(model.wrappedValue.isAnchorActionInFlight)
            .accessibilityIdentifier("floor-plan.remove-anchor.\(anchor.id)")
        }
    }

    private var adaptiveControlLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize || horizontalSizeClass == .compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NettworkSpacing.small))
            : AnyLayout(HStackLayout(spacing: NettworkSpacing.small))
    }

    private var canvasOffset: CGSize {
        CGSize(width: offset.width + panTranslation.width, height: offset.height + panTranslation.height)
    }

    private func resetCanvas() {
        zoom = 1
        offset = .zero
    }

    private var canvasPanGesture: some Gesture {
        DragGesture()
            .updating($panTranslation) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    private var canvasMagnificationGesture: some Gesture {
        MagnifyGesture()
            .updating($liveMagnification) { value, state, _ in state = Double(value.magnification) }
            .onEnded { value in zoom = min(max(zoom * Double(value.magnification), 1), 4) }
    }
}
