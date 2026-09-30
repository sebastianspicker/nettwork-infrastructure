import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

#if os(iOS)
    @preconcurrency import AVFoundation
    import UIKit
    #if canImport(VisionKit)
        import VisionKit
    #endif
#endif

/// Applies the same strict, opaque-route policy to every camera implementation.
/// A valid code is still only a lookup candidate: its scoped-mirror resolution
/// and every subsequent write authorization remain outside this adapter.
struct PlatformScanPayloadGate {
    private var deliveredIDs = Set<ObjectID>()

    mutating func accept(_ rawValue: String) -> ObjectID? {
        guard rawValue.utf8.count <= 512,
            rawValue.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            let objectID = OpaqueScanParser.parse(rawValue)?.objectID,
            deliveredIDs.insert(objectID).inserted
        else {
            return nil
        }
        return objectID
    }

    mutating func reset() {
        deliveredIDs.removeAll(keepingCapacity: true)
    }
}

enum PlatformScanCaptureError: LocalizedError {
    case unavailable
    case noCamera
    case unauthorized
    case presentationUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: "Camera scanning is unavailable on this device."
        case .noCamera: "No QR-capable camera is available."
        case .unauthorized: "Camera access is not authorized for Nettwork."
        case .presentationUnavailable: "The scanner cannot be presented from the current screen."
        }
    }
}

#if os(iOS)
    /// iOS production scanner with VisionKit preference and an AVFoundation QR-only
    /// fallback. It intentionally delivers an `ObjectID`, never scanner metadata or
    /// mutable label fields, to its caller.
    @MainActor
    final class ProductionScanCaptureAdapter: NSObject, ScanCapturing {
        typealias ScanHandler = @MainActor (ObjectID) -> Void

        private let presentationContext: IOSPresentationContext
        private let onValidatedScan: ScanHandler
        private var payloadGate = PlatformScanPayloadGate()
        private var isRunning = false

        #if canImport(VisionKit)
            @available(iOS 16.0, *)
            private var visionScanner: DataScannerViewController?
        #endif
        private var captureSession: AVCaptureSession?
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private let captureQueue = DispatchQueue(label: "com.nettwork.scan.capture")

        init(presentationContext: IOSPresentationContext, onValidatedScan: @escaping ScanHandler) {
            self.presentationContext = presentationContext
            self.onValidatedScan = onValidatedScan
            super.init()
            observeApplicationLifecycle()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func availability() async -> ScanCaptureAvailability {
            guard AVCaptureDevice.default(for: .video) != nil else {
                return .unavailable("No QR-capable camera is available on this device. Use typed, paste, or Bluetooth scanner input.")
            }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized, .notDetermined:
                return .available
            case .denied, .restricted:
                return .unauthorized("Camera access is not authorized. Allow camera access in Settings, or use typed, paste, or Bluetooth scanner input.")
            @unknown default:
                return .unavailable("Camera availability could not be determined. Use typed, paste, or Bluetooth scanner input.")
            }
        }

        func requestPermission() async -> ScanCaptureAvailability {
            guard case .available = await availability() else { return await availability() }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
                return await availability()
            }
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted
                ? await availability()
                : .unauthorized("Camera access was not granted. Allow camera access in Settings, or use typed, paste, or Bluetooth scanner input.")
        }

        private func presentationController() -> UIViewController? {
            presentationContext.presentingViewController
        }

        private func requirePresentationController() throws -> UIViewController {
            guard let presentation = presentationController() else {
                throw PlatformScanCaptureError.presentationUnavailable
            }
            return presentation
        }

        func start() async throws {
            guard !isRunning else { return }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                throw PlatformScanCaptureError.unauthorized
            }
            let presentation = try requirePresentationController()

            payloadGate.reset()
            #if canImport(VisionKit)
                if #available(iOS 16.0, *), DataScannerViewController.isSupported {
                    try await startVisionScanner(from: presentation)
                    isRunning = true
                    return
                }
            #endif
            try await startAVFoundationScanner(from: presentation)
            isRunning = true
        }

        func stop() async {
            guard isRunning || captureSession != nil else { return }
            isRunning = false

            #if canImport(VisionKit)
                if #available(iOS 16.0, *), let visionScanner {
                    visionScanner.stopScanning()
                    if visionScanner.presentingViewController != nil {
                        await dismiss(visionScanner)
                    }
                    self.visionScanner = nil
                }
            #endif

            if let captureSession {
                await stop(captureSession)
                self.captureSession = nil
            }
            previewLayer?.removeFromSuperlayer()
            previewLayer = nil
        }

        private func observeApplicationLifecycle() {
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(applicationBecameInactive), name: UIApplication.willResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(applicationBecameInactive), name: UIApplication.didEnterBackgroundNotification, object: nil)
        }

        @objc private func applicationBecameInactive() {
            Task { await stop() }
        }

        #if canImport(VisionKit)
            @available(iOS 16.0, *)
            private func startVisionScanner(from presentation: UIViewController) async throws {
                let scanner = DataScannerViewController(
                    recognizedDataTypes: [.barcode(symbologies: [.qr])],
                    qualityLevel: .balanced,
                    recognizesMultipleItems: false,
                    isHighFrameRateTrackingEnabled: false,
                    isPinchToZoomEnabled: false
                )
                scanner.delegate = self
                await present(scanner, from: presentation)
                do {
                    try scanner.startScanning()
                    visionScanner = scanner
                } catch {
                    await dismiss(scanner)
                    throw error
                }
            }
        #endif

        private func startAVFoundationScanner(from presentation: UIViewController) async throws {
            guard let camera = AVCaptureDevice.default(for: .video) else {
                throw PlatformScanCaptureError.noCamera
            }
            let input = try AVCaptureDeviceInput(device: camera)
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .high
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw PlatformScanCaptureError.unavailable
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw PlatformScanCaptureError.unavailable
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.frame = presentation.view.bounds
            layer.videoGravity = .resizeAspectFill
            presentation.view.layer.insertSublayer(layer, at: 0)
            previewLayer = layer
            captureSession = session
            await start(session)
        }

        private func acceptUntrustedPayload(_ payload: String?) {
            guard let payload, let objectID = payloadGate.accept(payload) else { return }
            onValidatedScan(objectID)
        }

        private func present(_ scanner: UIViewController, from presentation: UIViewController) async {
            await withCheckedContinuation { continuation in
                presentation.present(scanner, animated: true) {
                    continuation.resume()
                }
            }
        }

        private func dismiss(_ scanner: UIViewController) async {
            await withCheckedContinuation { continuation in
                scanner.dismiss(animated: true) {
                    continuation.resume()
                }
            }
        }

        private func start(_ session: AVCaptureSession) async {
            await withCheckedContinuation { continuation in
                captureQueue.async {
                    session.startRunning()
                    continuation.resume()
                }
            }
        }

        private func stop(_ session: AVCaptureSession) async {
            await withCheckedContinuation { continuation in
                captureQueue.async {
                    session.stopRunning()
                    continuation.resume()
                }
            }
        }
    }

    #if canImport(VisionKit)
        @available(iOS 16.0, *)
        extension ProductionScanCaptureAdapter: DataScannerViewControllerDelegate {
            func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
                for case let .barcode(barcode) in addedItems {
                    acceptUntrustedPayload(barcode.payloadStringValue)
                }
            }
        }
    #endif

    extension ProductionScanCaptureAdapter: AVCaptureMetadataOutputObjectsDelegate {
        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection)
        {
            let payload = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
            Task { @MainActor in
                acceptUntrustedPayload(payload)
            }
        }
    }
#else
    /// macOS currently retains typed and keyboard-wedge entry rather than claiming a
    /// camera path that is not source-verified for this app's sandbox configuration.
    @MainActor
    final class ProductionScanCaptureAdapter: ScanCapturing {
        init() {}

        func availability() async -> ScanCaptureAvailability {
            .unavailable("Camera scanning is not available on macOS. Use typed, paste, or Bluetooth scanner input.")
        }
        func requestPermission() async -> ScanCaptureAvailability { await availability() }
        func start() async throws { throw PlatformScanCaptureError.unavailable }
        func stop() async {}
    }
#endif
