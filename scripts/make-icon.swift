import Cocoa
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments[1]
// Input-source menu icons are 16 pt template images, like Apple's: a rounded badge with the letter cut out.
// Emit 1x (72 dpi) before 2x (144 dpi) in one TIFF; the menu bar reads them in that order.
let side: CGFloat = 16

func badge(scale: Int) -> CGImage {
    let pixels = Int(side) * scale
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.setFillColor(.black)
    context.addPath(CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1),
                           cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
    context.fillPath()
    let font = NSFont(name: "Apple-Chancery", size: 14) ?? NSFont.systemFont(ofSize: 14, weight: .semibold)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "L", attributes: [.font: font]))
    // Center and size the glyph's ink, not its line box.
    let ink = CTLineGetImageBounds(line, context)
    let fit = 11.5 / max(ink.width, ink.height)
    context.setBlendMode(.clear)
    context.translateBy(x: (side - ink.width * fit) / 2 - ink.minX * fit,
                        y: (side - ink.height * fit) / 2 - ink.minY * fit)
    context.scaleBy(x: fit, y: fit)
    // Stroking the outline as well as filling it keeps the calligraphic hairlines visible at 16 px.
    context.setTextDrawingMode(.fillStroke)
    context.setLineWidth(0.9)
    context.setLineJoin(.round)
    context.textPosition = .zero
    CTLineDraw(line, context)
    return context.makeImage()!
}

let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                  UTType.tiff.identifier as CFString, 2, nil)!
for scale in [1, 2] {
    let dpi = 72 * scale
    CGImageDestinationAddImage(destination, badge(scale: scale), [
        kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
    ] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(output)") }
