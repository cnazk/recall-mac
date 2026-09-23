#!/usr/bin/env swift
//
//  Builds Recall's icons.
//
//  The app icon is a ring of cards around a stack: everything you copied, circling the
//  newest item. The artwork is `Resources/AppIcon-source.jpg`, a flat 1024px render on a
//  white background. A JPEG has no alpha, so this script finds the indigo plate, cuts it
//  out along Apple's continuous-corner shape, sets it on the macOS icon grid with a soft
//  shadow, and writes `Resources/AppIcon.icns`.
//
//  The menu bar mark is still drawn geometrically — ⌘, the copy shortcut's key — because
//  a template image has to be a single-colour silhouette, and the card ring is too much
//  detail at 16 points.
//
//  Run with:  swift Scripts/make-icon.swift
//

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Geometry

/// The Command glyph, built from its actual construction: four straight runs that cross
/// at the corners of a square, each ending tangent to a full circle.
///
/// - Parameters:
///   - center: centre of the mark.
///   - width: total width, loop edge to loop edge.
func commandPath(center: CGPoint, width: CGFloat) -> CGPath {
    // The inner square is 40% of the total; each loop is 15%, which puts the loop
    // diameter at 30% — the proportions the glyph is normally drawn at.
    let square = width * 0.40
    let loop = width * 0.15
    let half = square / 2
    let reach = half + loop

    let path = CGMutablePath()

    // The four runs. Each extends one loop-radius past the crossing, ending exactly at
    // the point where its loop is tangent.
    let runs: [(CGPoint, CGPoint)] = [
        (CGPoint(x: -reach, y: half), CGPoint(x: reach, y: half)),     // top
        (CGPoint(x: -reach, y: -half), CGPoint(x: reach, y: -half)),   // bottom
        (CGPoint(x: -half, y: -reach), CGPoint(x: -half, y: reach)),   // left
        (CGPoint(x: half, y: -reach), CGPoint(x: half, y: reach)),     // right
    ]
    for (start, end) in runs {
        path.move(to: CGPoint(x: center.x + start.x, y: center.y + start.y))
        path.addLine(to: CGPoint(x: center.x + end.x, y: center.y + end.y))
    }

    // The four loops, centred diagonally out from each crossing so each is tangent to
    // both runs that meet there.
    for x in [-reach, reach] {
        for y in [-reach, reach] {
            path.addEllipse(in: CGRect(
                x: center.x + x - loop,
                y: center.y + y - loop,
                width: loop * 2,
                height: loop * 2
            ))
        }
    }
    return path
}

/// Apple's icon grid: the art sits in a rounded square inset from the canvas, with
/// continuous corners rather than circular ones.
func squirclePath(in rect: CGRect) -> CGPath {
    RoundedRectangle(cornerRadius: rect.width * 0.2237, style: .continuous).path(in: rect).cgPath
}

// MARK: - Source artwork

func loadImage(at url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("could not read \(url.path)")
    }
    return image
}

/// The plate in the source artwork, in the image's own top-left-origin pixels.
///
/// Found rather than hard-coded, so a regenerated render only has to replace the JPEG.
/// The plate is the only dark thing on the canvas: the cards are pale, and the render's
/// drop shadow never gets below light grey.
func findPlate(in image: CGImage) -> CGRect {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not scan the source artwork") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width, maxX = -1, minY = height, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            let luminance = (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
            guard luminance < 160 else { continue }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    let plate = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    guard maxX >= 0, abs(plate.width - plate.height) <= 4, plate.width > CGFloat(width) / 2 else {
        fatalError("expected one square plate in the source artwork, found \(plate)")
    }
    return plate
}

// MARK: - Drawing

/// The finished 1024px icon: the source plate, cut out and placed on Apple's grid.
func drawIcon(in context: CGContext, artwork: CGImage, plate: CGRect) {
    let size: CGFloat = 1024
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.interpolationQuality = .high

    // Apple's macOS icons leave a margin; 824/1024 is the standard content box.
    let inset = size * 0.0977
    let box = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset)
    // One pixel in from the render's own edge, where JPEG compression has blended the
    // indigo into the white canvas; cutting on it leaves a pale outline.
    let shape = squirclePath(in: box.insetBy(dx: 1, dy: 1))

    // A soft drop shadow so the icon sits on the desktop rather than in it. Kept weak
    // and wide: a tight dark shadow reads as a border, not as depth.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.016),
        blur: size * 0.055,
        color: CGColor(red: 0.07, green: 0.08, blue: 0.16, alpha: 0.28)
    )
    context.addPath(shape)
    context.setFillColor(CGColor(red: 0.137, green: 0.169, blue: 0.325, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // The artwork, scaled so its plate fills the content box exactly.
    guard let cropped = artwork.cropping(to: plate) else { fatalError("could not crop to \(plate)") }
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.draw(cropped, in: box)
    context.restoreGState()
}

/// The menu bar mark: the ⌘ alone. ⌘C is too much detail at 16 points, and the looped
/// square is the distinctive half.
func drawMenuBarIcon(in context: CGContext, size: CGFloat) {
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.setLineWidth(size * 0.085)
    context.setLineCap(.round)
    // Template images are tinted by the system; the colour here only has to be opaque.
    context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.addPath(commandPath(center: CGPoint(x: size / 2, y: size / 2), width: size * 0.82))
    context.strokePath()
}

// MARK: - Output

func makeContext(size: Int) -> CGContext? {
    CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/icon/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let artwork = loadImage(at: root.appendingPathComponent("Resources/AppIcon-source.jpg"))
let plate = findPlate(in: artwork)

guard let masterContext = makeContext(size: 1024) else { fatalError("could not allocate the icon") }
drawIcon(in: masterContext, artwork: artwork, plate: plate)
guard let master = masterContext.makeImage() else { fatalError("could not render the icon") }

// A large preview, for looking at the thing.
writePNG(master, to: root.appendingPathComponent(".build/icon/preview.png"))

// The sizes `iconutil` expects. Each is a downscale of the one master, so the cutout
// and shadow are identical at every size.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let context = makeContext(size: variant.pixels) else { continue }
    context.interpolationQuality = .high
    context.draw(master, in: CGRect(x: 0, y: 0, width: variant.pixels, height: variant.pixels))
    guard let image = context.makeImage() else { continue }
    writePNG(image, to: iconset.appendingPathComponent("\(variant.name).png"))
}

let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

// The menu bar template, as a PDF so it stays sharp at any scale.
let pdfURL = root.appendingPathComponent("Resources/MenuBarIcon.pdf")
var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)
if let pdf = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil) {
    pdf.beginPDFPage(nil)
    drawMenuBarIcon(in: pdf, size: 18)
    pdf.endPDFPage()
    pdf.closePDF()
}

// …and a PNG preview of it at menu bar size, to check it survives 16 points.
if let context = makeContext(size: 36) {
    drawMenuBarIcon(in: context, size: 36)
    if let image = context.makeImage() {
        writePNG(image, to: root.appendingPathComponent(".build/icon/menubar-preview.png"))
    }
}

print("Wrote Resources/AppIcon.icns and Resources/MenuBarIcon.pdf (plate found at \(plate))")
