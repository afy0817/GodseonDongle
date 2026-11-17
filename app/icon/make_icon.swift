// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT
//
// Draws GodseonDongle's app icon (a USB Wi-Fi dongle sending waves, on a violet
// squircle) with Core Graphics and writes app/Resources/AppIcon.icns.
//   swift app/icon/make_icon.swift
// No SF Symbols: their license does not allow them in app icons.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let design: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// macOS-style continuous squircle: a superellipse |x|^n + |y|^n = r^n.
func squircle(center: CGPoint, radius: CGFloat, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = center.x + radius * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
        let y = center.y + radius * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(in ctx: CGContext) {
    let center = CGPoint(x: 512, y: 512)
    let shape = squircle(center: center, radius: 412)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Body with a soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x5B33E6))
    ctx.fillPath()
    ctx.restoreGState()

    // Violet gradient, lighter at the top.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let fill = CGGradient(colorsSpace: space, colors: [color(0xA98BFF), color(0x7449F5), color(0x4A20C8)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 360, y: 924), end: CGPoint(x: 664, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // A glow behind the waves.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 640), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 640), endRadius: 420, options: [])
    ctx.restoreGState()

    // Glyph: waves, dongle body, plug - white with a quiet shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x1A0663, 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    let waveCenter = CGPoint(x: 512, y: 600)
    ctx.setLineCap(.round)
    ctx.setLineWidth(40)
    for (radius, alpha) in [(CGFloat(96), CGFloat(1)), (166, 0.92), (236, 0.8)] {
        ctx.setStrokeColor(color(0xFFFFFF, alpha))
        ctx.addArc(center: waveCenter, radius: radius, startAngle: .pi / 2 - 0.74,
                   endAngle: .pi / 2 + 0.74, clockwise: false)
        ctx.strokePath()
    }

    // Plug (USB-A) with two contact windows, then the body over its top edge.
    let plug = CGMutablePath()
    plug.addRoundedRect(in: CGRect(x: 448, y: 168, width: 128, height: 130), cornerWidth: 16, cornerHeight: 16)
    plug.addRect(CGRect(x: 470, y: 206, width: 28, height: 30))
    plug.addRect(CGRect(x: 526, y: 206, width: 28, height: 30))
    ctx.addPath(plug)
    ctx.setFillColor(color(0xF1EDFF))
    ctx.fillPath(using: .evenOdd)

    let body = CGPath(roundedRect: CGRect(x: 408, y: 268, width: 208, height: 300), cornerWidth: 56, cornerHeight: 56,
                      transform: nil)
    ctx.addPath(body)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()

    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Status light on the body.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14, color: color(0x3BF0C0, 0.9))
    ctx.addEllipse(in: CGRect(x: 512 - 17, y: 498 - 17, width: 34, height: 34))
    ctx.setFillColor(color(0x3BF0C0))
    ctx.fillPath()
    ctx.restoreGState()
}

func png(size: Int, to url: URL) throws {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(size) / design, y: CGFloat(size) / design)
    drawIcon(in: ctx)
    let image = ctx.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "icon", code: 1) }
}

let script = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let appDir = script.deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let resources = appDir.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try png(size: 1024, to: appDir.appendingPathComponent("icon/AppIcon-1024.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote \(resources.path)/AppIcon.icns" : "iconutil failed")
