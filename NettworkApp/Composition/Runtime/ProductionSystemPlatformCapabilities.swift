/// Production defaults select only source-verified system capabilities. The
/// organization input can still use `PlatformCapabilities.init` to provide a
/// narrower custom implementation for its own policy or hardware requirements.
extension ProductionRuntimeAssembly.OrganizationInput.PlatformCapabilities {
    #if os(iOS)
        @MainActor
        static func system(presentationContext: IOSPresentationContext) -> Self {
            Self(
                scanCapture: { handler in
                    ProductionScanCaptureAdapter(presentationContext: presentationContext, onValidatedScan: handler)
                },
                labelGenerator: { ProductionLabelPDFGenerator() },
                labelExporter: { PlatformLabelPDFExporter(presentationContext: presentationContext) },
                labelPrinter: { PlatformLabelPDFPrinter(presentationContext: presentationContext) }
            )
        }
    #elseif os(macOS)
        @MainActor
        static func system() -> Self {
            Self(
                scanCapture: { _ in ProductionScanCaptureAdapter() },
                labelGenerator: { ProductionLabelPDFGenerator() },
                labelExporter: { PlatformLabelPDFExporter() },
                labelPrinter: { PlatformLabelPDFPrinter() }
            )
        }
    #endif
}
