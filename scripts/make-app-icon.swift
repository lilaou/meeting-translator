// Generates the placeholder app icon: a solid blue square with a white "译".
// Original artwork, no third-party assets. Replace the PNG whenever you like.
// Usage: swift scripts/make-app-icon.swift <output.png>
import AppKit
import CoreGraphics
import CoreText

let size = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
// noneSkipLast: the PNG has no alpha channel, as App Store icons must be opaque.
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.10, green: 0.36, blue: 0.80, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 640, nil)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "译", attributes: attrs))
let bounds = CTLineGetImageBounds(line, ctx)
ctx.textPosition = CGPoint(x: (CGFloat(size) - bounds.width) / 2 - bounds.minX,
                           y: (CGFloat(size) - bounds.height) / 2 - bounds.minY)
CTLineDraw(line, ctx)
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
