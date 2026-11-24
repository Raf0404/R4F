// Crea l'icona macOS di R4F dal logo quadrato: sagoma con angoli arrotondati (griglia delle icone
// macOS: 824 px di corpo su 1024, raggio 185), ombra leggera, sfondo del colore del logo.
//
//   swiftc -O Scripts/make_icon.swift -o /tmp/make_icon && /tmp/make_icon assets/R4F-logo.jpg assets/R4F-icon-1024.png
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fputs("uso: make_icon <logo> <out.png>\n", stderr); exit(1)
}

// colore dello sfondo preso da un angolo del logo
func cornerColor(_ img: CGImage) -> CGColor {
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // zona vuota sotto le lettere, vicino al bordo del logo disegnato (gli angoli sono più chiari)
    let w = CGFloat(img.width), h = CGFloat(img.height)
    ctx.draw(img.cropping(to: CGRect(x: w * 0.06, y: h * 0.86, width: w * 0.88, height: h * 0.06))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return CGColor(red: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
}

let size: CGFloat = 1024, body: CGFloat = 824, radius: CGFloat = 185
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: (size - body) / 2, y: (size - body) / 2 + 10, width: body, height: body)
let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// ombra
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(cornerColor(logo))
ctx.fillPath()
ctx.restoreGState()

// logo ritagliato nella sagoma
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
// il logo riempie tutta la sagoma: niente fascia di colore intorno (lo sfondo del logo è il suo)
ctx.interpolationQuality = .high
ctx.draw(logo, in: rect)
ctx.restoreGState()

// leggero bordo interno per staccare dallo sfondo scuro del Dock
ctx.addPath(shape)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
ctx.setLineWidth(3)
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("ok: \(args[2])")
