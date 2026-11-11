import AppKit

let size = NSSize(width: 660, height: 400)
let context = CGContext(data: nil, width: 1320, height: 800, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let scale = NSAffineTransform()
scale.scale(by: 2)
scale.concat()
NSColor(srgbRed: 118.0 / 255, green: 118.0 / 255, blue: 118.0 / 255, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
NSColor.white.setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 282, y: 230))
arrow.line(to: NSPoint(x: 378, y: 230))
arrow.move(to: NSPoint(x: 364, y: 244))
arrow.line(to: NSPoint(x: 378, y: 230))
arrow.line(to: NSPoint(x: 364, y: 216))
arrow.stroke()
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
("Drag NoteBank onto Applications" as NSString).draw(
    in: NSRect(x: 0, y: 85, width: size.width, height: 30),
    withAttributes: [.font: NSFont.systemFont(ofSize: 19, weight: .medium),
                     .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
bitmap.size = size
let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("background.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
