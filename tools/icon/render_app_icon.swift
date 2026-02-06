import AppKit

@main
enum RenderAppIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: render_app_icon <output.png>\n".utf8))
            exit(2)
        }

        let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

        let canvasSize = CGSize(width: 1024, height: 1024)
        let backgroundInset: CGFloat = 32
        let backgroundRadius: CGFloat = 180
        let symbolInset: CGFloat = 165

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSize.width),
            pixelsHigh: Int(canvasSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "RenderAppIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmap"])
        }
        rep.size = canvasSize

        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) else {
            throw NSError(domain: "RenderAppIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create graphics context"])
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        let backgroundRect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: backgroundInset, dy: backgroundInset)
        let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: backgroundRadius, yRadius: backgroundRadius)

        NSColor(calibratedWhite: 0.98, alpha: 1.0).setFill()
        backgroundPath.fill()

        NSColor(calibratedWhite: 0.90, alpha: 1.0).setStroke()
        backgroundPath.lineWidth = 3
        backgroundPath.stroke()

        guard var symbol = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Ticker") else {
            throw NSError(domain: "RenderAppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing SF Symbol: text.quote"])
        }

        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 700, weight: .regular)
        let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: .black)
        let config = sizeConfig.applying(colorConfig)
        symbol = symbol.withSymbolConfiguration(config) ?? symbol

        let symbolRect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: symbolInset, dy: symbolInset)
        symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RenderAppIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        try png.write(to: outputURL, options: [.atomic])
    }
}
