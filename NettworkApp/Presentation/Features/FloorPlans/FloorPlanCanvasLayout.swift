import CoreGraphics

/// Anchors are normalized to the plan image, which is drawn aspect-fit (centred,
/// letterboxed) inside the canvas, so markers and drags map through this rect.
enum FloorPlanCanvasLayout {
    static func imageRect(imageSize: CGSize?, in canvas: CGSize) -> CGRect {
        guard let imageSize, imageSize.width > 0, imageSize.height > 0, canvas.width > 0, canvas.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }
        let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
    }
}
