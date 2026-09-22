#!/usr/bin/env swift
// Draws ClaudeSwap.app's icon and writes the host target's AppIcon set.
//
//   swift widget/make-app-icon.swift [output directory]
//
// Default output is App/Assets.xcassets/AppIcon.appiconset, PNGs plus the
// Contents.json that lists them -- one file describes both, so the slot list
// below cannot drift from the catalog. The PNGs are committed; this script is
// how they are regenerated, not a build step.
//
// The artwork is the widget's own language: charcoal ground, a terracotta
// usage ring, and the header's swap mark in off-white. Everything is laid out
// on a 1024pt canvas and scaled, so every size is the same drawing.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Canvas

/// Apple's macOS icon grid: the artwork is a 824pt rounded square centred in a
/// 1024pt canvas. Filling the canvas edge to edge would render the icon
/// visibly larger than every system icon beside it.
let canvas: CGFloat = 1024
let artwork: CGFloat = 824
let center = CGPoint(x: canvas / 2, y: canvas / 2)

/// The macOS icon shape is a continuous-corner square, not a rounded
/// rectangle; a superellipse of degree 5 is the usual close approximation.
func squirclePath(side: CGFloat, center: CGPoint) -> CGPath {
    let radius = side / 2
    let exponent: CGFloat = 2.0 / 5.0
    let path = CGMutablePath()
    let steps = 720
    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle), sine = sin(angle)
        let point = CGPoint(
            x: center.x + radius * copysign(pow(abs(cosine), exponent), cosine),
            y: center.y + radius * copysign(pow(abs(sine), exponent), sine))
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Palette

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

let charcoal = color(0x141413)
let terracotta = color(0xD97757)
let offWhite = color(0xFAF9F5)
let ringTrack = color(0xFAF9F5, alpha: 0.10)

// MARK: - Drawing

// Ring and mark are deliberately heavy: at 16pt a stroke this wide is still
// about a pixel, and anything finer disappears in the gallery sidebar.
let ringRadius: CGFloat = 285
let ringWidth: CGFloat = 72
/// A usage gauge: clockwise from 12 o'clock, stopping short of a full circle.
let ringSweep: CGFloat = 280

let markReach: CGFloat = 140   // half the length of each arrow shaft
let markOffset: CGFloat = 100   // each shaft's distance from the centre line
let markHead: CGFloat = 66     // arrowhead depth along the shaft
let markWidth: CGFloat = 58

func draw(into context: CGContext) {
    context.setFillColor(charcoal)
    context.addPath(squirclePath(side: artwork, center: center))
    context.fillPath()

    context.setLineCap(.round)
    context.setLineJoin(.round)

    context.setStrokeColor(ringTrack)
    context.setLineWidth(ringWidth)
    context.addArc(
        center: center, radius: ringRadius,
        startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    context.strokePath()

    context.setStrokeColor(terracotta)
    let start: CGFloat = .pi / 2                                 // 12 o'clock
    context.addArc(
        center: center, radius: ringRadius,
        startAngle: start, endAngle: start - ringSweep * .pi / 180, clockwise: true)
    context.strokePath()

    // The header's swap mark: upper arrow to the right, lower to the left.
    context.setStrokeColor(offWhite)
    context.setLineWidth(markWidth)
    for direction in [CGFloat(1), CGFloat(-1)] {
        let shaft = center.y + markOffset * direction
        let tip = center.x + markReach * direction
        let tail = center.x - markReach * direction
        context.move(to: CGPoint(x: tail, y: shaft))
        context.addLine(to: CGPoint(x: tip, y: shaft))
        context.strokePath()

        let notch = tip - markHead * direction
        context.move(to: CGPoint(x: notch, y: shaft + markHead))
        context.addLine(to: CGPoint(x: tip, y: shaft))
        context.addLine(to: CGPoint(x: notch, y: shaft - markHead))
        context.strokePath()
    }
}

func render(pixels: Int) -> CGImage {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not create a \(pixels)x\(pixels) bitmap") }
    let scale = CGFloat(pixels) / canvas
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    draw(into: context)
    guard let image = context.makeImage() else { fatalError("could not render \(pixels)x\(pixels)") }
    return image
}

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("could not write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
}

// MARK: - Asset catalog

/// Every slot a macOS AppIcon set has: point size, then scale.
let slots: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)
]

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// One image per distinct pixel size; 16@2x and 32@1x are the same 32px file.
var images: [Int: String] = [:]
var entries: [String] = []
for slot in slots {
    let pixels = slot.points * slot.scale
    let name = images[pixels] ?? "icon_\(pixels).png"
    if images[pixels] == nil {
        images[pixels] = name
        write(render(pixels: pixels), to: output.appendingPathComponent(name))
    }
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.points)x\(slot.points)"
        }
    """)
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(images.count) PNGs and Contents.json to \(output.path)")
