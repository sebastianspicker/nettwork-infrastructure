import Foundation

#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(PDFKit)
    import CoreGraphics
    import ImageIO
    import PDFKit

    /// Apple-platform implementation. It re-encodes to a fresh JPEG and never forwards source metadata.
    public struct PlatformContentSanitizingDecoder: ContentSanitizingDecoder {
        public init() {}

        public func decodeAndSanitize(
            _ bytes: Data, sourceType: ContentType, purpose: ContentPurpose,
            selectedPDFPage: Int?, outputEdgeLimit: Int, outputByteLimit: Int
        ) throws -> (decoded: DecodedContent, raster: SanitizedRaster) {
            switch sourceType {
            case .pdf:
                return try decodePDF(bytes, selectedPage: selectedPDFPage, outputEdgeLimit: outputEdgeLimit, outputByteLimit: outputByteLimit)
            case .jpeg, .png, .heic, .heif:
                return try decodeImage(bytes, sourceType: sourceType, outputEdgeLimit: outputEdgeLimit, outputByteLimit: outputByteLimit)
            }
        }

        private func decodeImage(
            _ bytes: Data, sourceType: ContentType, outputEdgeLimit: Int,
            outputByteLimit: Int
        ) throws -> (decoded: DecodedContent, raster: SanitizedRaster) {
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                platformType(of: source) == sourceType
            else {
                throw ContentSafetyError.decodeFailed
            }
            guard width > 0, height > 0, width <= ContentSafetyService.maximumInputEdge, height <= ContentSafetyService.maximumInputEdge else {
                throw ContentSafetyError.invalidDimensions
            }
            let pixelCount = try checkedProduct(width, height)
            guard pixelCount <= ContentSafetyService.maximumInputPixels,
                try checkedProduct(pixelCount, 4) <= ContentSafetyService.maximumDecodedBytes
            else {
                throw ContentSafetyError.decodedSizeExceeded
            }
            guard CGImageSourceGetCount(source) == 1 else { throw ContentSafetyError.animatedContent }
            let decoded = DecodedContent(sourceType: sourceType, width: width, height: height)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: outputEdgeLimit,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ContentSafetyError.decodeFailed
            }
            return (decoded, try encode(image, outputByteLimit: outputByteLimit))
        }

        private func decodePDF(
            _ bytes: Data, selectedPage: Int?, outputEdgeLimit: Int, outputByteLimit: Int
        ) throws -> (decoded: DecodedContent, raster: SanitizedRaster) {
            guard let document = PDFDocument(data: bytes), document.pageCount > 0 else { throw ContentSafetyError.decodeFailed }
            guard document.pageCount <= ContentSafetyService.maximumPDFPages else { throw ContentSafetyError.pageCountExceeded }
            let validBoxes = allPageBoxesAreValid(in: document)
            guard let selectedPage else { throw ContentSafetyError.missingSelectedPDFPage }
            guard let page = document.page(at: selectedPage) else { throw ContentSafetyError.invalidSelectedPDFPage }
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(CGFloat(outputEdgeLimit) / bounds.width, CGFloat(outputEdgeLimit) / bounds.height, 1)
            let width = max(1, Int((bounds.width * scale).rounded(.down)))
            let height = max(1, Int((bounds.height * scale).rounded(.down)))
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { throw ContentSafetyError.decodeFailed }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage() else { throw ContentSafetyError.decodeFailed }
            let decoded = DecodedContent(
                sourceType: .pdf, width: width, height: height, pageCount: document.pageCount, pageBoxesAreFiniteAndBounded: validBoxes)
            return (decoded, try encode(image, outputByteLimit: outputByteLimit))
        }

        private func allPageBoxesAreValid(in document: PDFDocument) -> Bool {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { return false }
                guard pageBoxesAreValid(on: page) else { return false }
            }
            return true
        }

        private func pageBoxesAreValid(on page: PDFPage) -> Bool {
            for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                let rect = page.bounds(for: box)
                guard rect.origin.x.isFinite else { return false }
                guard rect.origin.y.isFinite else { return false }
                guard validPDFDimension(rect.width) else { return false }
                guard validPDFDimension(rect.height) else { return false }
            }
            return true
        }

        private func validPDFDimension(_ value: CGFloat) -> Bool {
            value.isFinite && value > 0 && value <= CGFloat(ContentSafetyService.maximumPDFBoxPoints)
        }

        private func encode(_ image: CGImage, outputByteLimit: Int) throws -> SanitizedRaster {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
                throw ContentSafetyError.decodeFailed
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ContentSafetyError.decodeFailed }
            guard data.length <= outputByteLimit else { throw ContentSafetyError.outputSizeExceeded }
            return SanitizedRaster(bytes: data as Data, width: image.width, height: image.height)
        }

        private func platformType(of source: CGImageSource) -> ContentType? {
            guard let type = CGImageSourceGetType(source) else { return nil }
            let identifier = (type as String).lowercased()
            if identifier.contains("jpeg") { return .jpeg }
            if identifier.contains("png") { return .png }
            if identifier.contains("heic") { return .heic }
            if identifier.contains("heif") || identifier.contains("hevc") { return .heif }
            return nil
        }

        private func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
            guard !overflow else { throw ContentSafetyError.decodedSizeExceeded }
            return value
        }
    }
#else
    public struct PlatformContentSanitizingDecoder: ContentSanitizingDecoder {
        public init() {}

        public func decodeAndSanitize(
            _ bytes: Data, sourceType: ContentType, purpose: ContentPurpose,
            selectedPDFPage: Int?, outputEdgeLimit: Int, outputByteLimit: Int
        ) throws -> (decoded: DecodedContent, raster: SanitizedRaster) {
            throw ContentSafetyError.decoderUnavailable
        }
    }
#endif
