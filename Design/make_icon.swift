// Draws Copista's app icon: copies of a sheet of music, fanned out, on orange.
//
// Everything is drawn from code so the icon can be regenerated and every size is rendered for its
// size rather than scaled. No SF Symbols: Apple's license doesn't allow them in app icons.
//
// Run from the repository root, then rebuild the app:
//     swift Design/make_icon.swift
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appIconSet = root.appendingPathComponent("Copista/Assets.xcassets/AppIcon.appiconset")
let layeredIcon = root.appendingPathComponent("Copista/AppIcon.icon")
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let backgroundTop = color(1.00, 0.64, 0.22)
let backgroundBottom = color(0.93, 0.38, 0.06)
// One family of colour: white paper, the copies behind it tinted by the orange, and notes in a
// deeper shade of the same orange.
let paper = color(1.00, 1.00, 1.00)
let paperMiddle = color(1.00, 0.92, 0.82)
let paperBack = color(1.00, 0.84, 0.66)
let notation = color(0.80, 0.29, 0.02)
let staffLine = color(0.80, 0.29, 0.02, 0.28)

// MARK: - Artwork, in a 1024-point square

let sheetSize = CGSize(width: 470, height: 640)

func sheetRect() -> CGRect {
    CGRect(x: 512 - sheetSize.width / 2, y: 512 - sheetSize.height / 2 - 6, width: sheetSize.width, height: sheetSize.height)
}

/// Turns about a point below the page, so the sheets fan like copies held in one hand.
func fan(_ ctx: CGContext, degrees: CGFloat) {
    ctx.translateBy(x: 512, y: 150)
    ctx.rotate(by: degrees * .pi / 180)
    ctx.translateBy(x: -512, y: -150)
}

func drawBlankSheet(_ ctx: CGContext, fill: CGColor) {
    ctx.addPath(CGPath(roundedRect: sheetRect(), cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(fill)
    ctx.fillPath()
}

func drawBackSheets(_ ctx: CGContext) {
    ctx.saveGState()
    fan(ctx, degrees: 15)
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: color(0, 0, 0, 0.3))
    drawBlankSheet(ctx, fill: paperBack)
    ctx.restoreGState()

    ctx.saveGState()
    fan(ctx, degrees: 7)
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: color(0, 0, 0, 0.3))
    drawBlankSheet(ctx, fill: paperMiddle)
    ctx.restoreGState()
}

/// The staves are left out when small: at that size they only turn the page grey.
func drawFrontSheet(_ ctx: CGContext, withStaves: Bool) {
    ctx.saveGState()
    fan(ctx, degrees: -3)
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: color(0, 0, 0, 0.35))
    drawBlankSheet(ctx, fill: paper)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    if withStaves {
        let rect = sheetRect()
        ctx.setStrokeColor(staffLine)
        ctx.setLineWidth(6)
        ctx.setLineCap(.round)
        for staffTop in [rect.maxY - 66, rect.minY + 150] {
            for line in 0..<5 {
                let y = staffTop - CGFloat(line) * 22
                ctx.move(to: CGPoint(x: rect.minX + 46, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX - 46, y: y))
            }
        }
        ctx.strokePath()
    }
    ctx.restoreGState()
}

/// Two beamed eighth notes. Copista's own glyph; the app draws the same shape (`CopistaNotes`).
func drawNotes(_ ctx: CGContext, weight: CGFloat) {
    ctx.saveGState()
    fan(ctx, degrees: -3)
    ctx.setFillColor(notation)

    let heads = [CGPoint(x: 404, y: 408), CGPoint(x: 612, y: 448)]
    let stemTops: [CGFloat] = [668, 708]
    let stemWidth = 16 * weight

    for (head, top) in zip(heads, stemTops) {
        ctx.saveGState()
        ctx.translateBy(x: head.x, y: head.y)
        ctx.rotate(by: 22 * .pi / 180)
        ctx.addEllipse(in: CGRect(x: -58, y: -40, width: 116, height: 80))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.fill(CGRect(x: head.x + 53 - stemWidth, y: head.y + 8, width: stemWidth, height: top - head.y - 8))
    }

    let beamHeight = 46 * weight
    let left = heads[0].x + 53 - stemWidth, right = heads[1].x + 53
    ctx.move(to: CGPoint(x: left, y: stemTops[0]))
    ctx.addLine(to: CGPoint(x: right, y: stemTops[1]))
    ctx.addLine(to: CGPoint(x: right, y: stemTops[1] - beamHeight))
    ctx.addLine(to: CGPoint(x: left, y: stemTops[0] - beamHeight))
    ctx.closePath()
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - Rendering

func render(pixels: Int, draw: (CGContext) -> Void) -> Data {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

/// The icon for macOS before Liquid Glass: artwork on Apple's icon grid, an 824-point body with a
/// margin for the drop shadow, which the system doesn't add itself on those versions.
func drawClassicIcon(_ ctx: CGContext, pixels: Int) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(backgroundBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [backgroundTop, backgroundBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Scaled in slightly, since the sheets were sized for the full-bleed layered icon.
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 0.86, y: 0.86)
    ctx.translateBy(x: -512, y: -512)
    drawBackSheets(ctx)
    drawFrontSheet(ctx, withStaves: pixels >= 64)
    // Heavier when small, so the notes hold up at Finder-list sizes.
    drawNotes(ctx, weight: pixels >= 64 ? 1 : 1.5)
    ctx.restoreGState()
}

// MARK: - Classic asset catalog icon

try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try render(pixels: pixels) { drawClassicIcon($0, pixels: pixels) }.write(to: appIconSet.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: appIconSet.appendingPathComponent("Contents.json"))

// MARK: - Layered icon for Liquid Glass (macOS 26 and later), as Icon Composer would save it

let assets = layeredIcon.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try render(pixels: 1024) { drawBackSheets($0) }.write(to: assets.appendingPathComponent("sheets-back.png"))
try render(pixels: 1024) { drawFrontSheet($0, withStaves: true) }.write(to: assets.appendingPathComponent("sheet-front.png"))
try render(pixels: 1024) { drawNotes($0, weight: 1) }.write(to: assets.appendingPathComponent("notes.png"))

let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "display-p3:1.00000,0.64000,0.22000,1.00000",
      "display-p3:0.93000,0.38000,0.06000,1.00000"
    ],
    "orientation" : {
      "start" : { "x" : 0.5, "y" : 0 },
      "stop" : { "x" : 0.5, "y" : 1 }
    }
  },
  "groups" : [
    {
      "layers" : [ { "image-name" : "notes.png", "name" : "notes" } ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.3 },
      "translucency" : { "enabled" : false, "value" : 0 }
    },
    {
      "layers" : [ { "image-name" : "sheet-front.png", "name" : "sheet-front" } ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0 }
    },
    {
      "layers" : [ { "image-name" : "sheets-back.png", "name" : "sheets-back" } ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0 }
    }
  ],
  "supported-platforms" : {
    "squares" : [ "macOS" ]
  }
}

"""
try iconJSON.write(to: layeredIcon.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)

print("Wrote \(appIconSet.lastPathComponent) and \(layeredIcon.lastPathComponent)")
