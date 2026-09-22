#!/usr/bin/env swift
//
//  Draws Recall's icon.
//
//  The mark is ⌘C — the copy shortcut itself — on a sheet of paper. The looped square
//  is doing double duty: it is the Command key, and it reads as a mind vector, four
//  strands crossing and looping back, which is what a clipboard history is.
//
//  Everything is constructed geometrically rather than set in a font: no licensing
//  question over shipping a glyph in an app icon, and the C can be drawn to exactly the
//  stroke weight of the ⌘ so the pair looks designed instead of typeset.
//
//  Run with:  swift Scripts/make-icon.swift
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

enum Palette {
    /// Warm paper, lit slightly from the top left.
    static let paperTop = CGColor(red: 0.996, green: 0.988, blue: 0.972, alpha: 1)
    static let paperBottom = CGColor(red: 0.941, green: 0.918, blue: 0.867, alpha: 1)
    /// The fold, and the shadow it casts.
    static let foldFace = CGColor(red: 0.886, green: 0.855, blue: 0.788, alpha: 1)
    static let foldShadow = CGColor(red: 0.702, green: 0.663, blue: 0.588, alpha: 0.55)
    /// Ink: a deep indigo rather than black, so it sits warm against the paper.
    static let ink = CGColor(red: 0.137, green: 0.169, blue: 0.325, alpha: 1)
    static let inkSoft = CGColor(red: 0.259, green: 0.310, blue: 0.494, alpha: 1)
}

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

/// A monoline C, drawn as an arc so it carries the same weight and cap as the ⌘.
///
/// The aperture is 80°, which is open enough to read as a C rather than an O at menu bar
/// sizes, and closed enough not to look like a bracket.
func letterCPath(center: CGPoint, width: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let aperture = CGFloat.pi * (40.0 / 180.0)
    path.addArc(
        center: center,
        radius: width / 2,
        startAngle: aperture,
        endAngle: -aperture,
        clockwise: false
    )
    return path
}

/// Apple's icon grid: the art sits in a rounded square inset from the canvas.
func squirclePath(in rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil)
}

// MARK: - Drawing

func drawIcon(in context: CGContext, size: CGFloat) {
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    context.clear(canvas)

    // Apple's macOS icons leave a margin; 824/1024 is the standard content box.
    let inset = size * 0.0977
    let plate = canvas.insetBy(dx: inset, dy: inset)
    let shape = squirclePath(in: plate)

    // A soft drop shadow so the paper sits on the desktop rather than in it. Kept weak
    // and wide: a tight dark shadow reads as a border, not as depth.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.016),
        blur: size * 0.055,
        color: CGColor(red: 0.18, green: 0.16, blue: 0.13, alpha: 0.22)
    )
    context.addPath(shape)
    context.setFillColor(Palette.paperTop)
    context.fillPath()
    context.restoreGState()

    // Paper, lit from the top.
    context.saveGState()
    context.addPath(shape)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [Palette.paperTop, Palette.paperBottom] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.maxY),
            end: CGPoint(x: plate.maxX, y: plate.minY),
            options: []
        )
    }

    drawFold(in: context, plate: plate, size: size)
    context.restoreGState()

    // The mark. Stroke weight is set as a fraction of the ⌘ itself so the loops stay
    // open — too heavy and the four holes close up into a blob.
    let markWidth = size * 0.315
    let strokeWidth = markWidth * 0.155
    context.setLineWidth(strokeWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(Palette.ink)

    // The C is matched to the ⌘'s height, not its width, so the two read as one size.
    let letterWidth = markWidth * 0.80
    let gap = markWidth * 0.20
    let totalWidth = markWidth + gap + letterWidth
    let originX = plate.midX - totalWidth / 2
    let markCenterY = plate.midY

    let command = commandPath(
        center: CGPoint(x: originX + markWidth / 2, y: markCenterY),
        width: markWidth
    )
    context.addPath(command)
    context.strokePath()

    let letter = letterCPath(
        center: CGPoint(x: originX + markWidth + gap + letterWidth / 2, y: markCenterY),
        width: letterWidth
    )
    context.addPath(letter)
    context.strokePath()
}

/// A turned-up corner, which is what makes a rectangle read as paper at 32 pixels.
///
/// Drawn as the underside of the sheet — lighter than the fold's shadow, darker than the
/// page — with the shadow it casts falling up and to the left.
func drawFold(in context: CGContext, plate: CGRect, size: CGFloat) {
    let fold = plate.width * 0.30
    let corner = CGPoint(x: plate.maxX, y: plate.minY)

    // The shadow the lifted corner casts on the sheet.
    let shadowTriangle = CGMutablePath()
    shadowTriangle.move(to: CGPoint(x: corner.x - fold, y: corner.y))
    shadowTriangle.addLine(to: CGPoint(x: corner.x, y: corner.y + fold))
    shadowTriangle.addLine(to: corner)
    shadowTriangle.closeSubpath()

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: -size * 0.012, height: size * 0.012),
        blur: size * 0.03,
        color: Palette.foldShadow
    )
    context.addPath(shadowTriangle)
    context.setFillColor(Palette.foldFace)
    context.fillPath()
    context.restoreGState()

    // A highlight along the crease, so the fold has an edge rather than just a tone.
    context.saveGState()
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.7))
    context.setLineWidth(size * 0.004)
    context.move(to: CGPoint(x: corner.x - fold, y: corner.y))
    context.addLine(to: CGPoint(x: corner.x, y: corner.y + fold))
    context.strokePath()
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
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes `iconutil` expects.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let context = makeContext(size: variant.pixels) else { continue }
    drawIcon(in: context, size: CGFloat(variant.pixels))
    guard let image = context.makeImage() else { continue }
    writePNG(image, to: iconset.appendingPathComponent("\(variant.name).png"))
}

// A large preview, for looking at the thing.
if let context = makeContext(size: 1024) {
    drawIcon(in: context, size: 1024)
    if let image = context.makeImage() {
        writePNG(image, to: root.appendingPathComponent(".build/icon/preview.png"))
    }
}

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

print("Wrote \(iconset.path) and Resources/MenuBarIcon.pdf")
