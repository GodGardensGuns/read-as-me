import AppKit
import Foundation

struct IconOutput {
    let fileName: String
    let pixels: Int
}

let outputs = [
    IconOutput(fileName: "icon_16x16.png", pixels: 16),
    IconOutput(fileName: "icon_16x16@2x.png", pixels: 32),
    IconOutput(fileName: "icon_32x32.png", pixels: 32),
    IconOutput(fileName: "icon_32x32@2x.png", pixels: 64),
    IconOutput(fileName: "icon_128x128.png", pixels: 128),
    IconOutput(fileName: "icon_128x128@2x.png", pixels: 256),
    IconOutput(fileName: "icon_256x256.png", pixels: 256),
    IconOutput(fileName: "icon_256x256@2x.png", pixels: 512),
    IconOutput(fileName: "icon_512x512.png", pixels: 512),
    IconOutput(fileName: "icon_512x512@2x.png", pixels: 1024),
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsFile = resources.appendingPathComponent("AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rect(_ side: CGFloat, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
    NSRect(x: side * x, y: side * y, width: side * width, height: side * height)
}

func drawRoundedBar(side: CGFloat, x: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat, color: NSColor) {
    let barRect = NSRect(
        x: side * x,
        y: side * centerY - side * height / 2,
        width: side * width,
        height: side * height
    )
    let bar = NSBezierPath(roundedRect: barRect, xRadius: side * width / 2, yRadius: side * width / 2)
    color.setFill()
    bar.fill()
}

func makeIcon(pixels: Int) throws -> Data {
    let side = CGFloat(pixels)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap"])
    }

    bitmap.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current = context
    context?.imageInterpolation = .high

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.shadowBlurRadius = side * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.014)
    shadow.set()

    let basePath = NSBezierPath(
        roundedRect: rect(side, x: 0.065, y: 0.065, width: 0.87, height: 0.87),
        xRadius: side * 0.205,
        yRadius: side * 0.205
    )
    let baseGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.06, green: 0.48, blue: 0.96, alpha: 1.0),
        NSColor(calibratedRed: 0.31, green: 0.27, blue: 0.88, alpha: 1.0),
        NSColor(calibratedRed: 0.58, green: 0.29, blue: 0.86, alpha: 1.0),
    ])
    baseGradient?.draw(in: basePath, angle: 315)

    shadow.shadowColor = .clear
    shadow.set()

    let gloss = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.28),
        NSColor.white.withAlphaComponent(0.02),
    ])
    gloss?.draw(in: basePath, angle: 90)

    let bookBottom = side * 0.225
    let bookTop = side * 0.565
    let bookLeft = side * 0.225
    let bookRight = side * 0.775
    let bookCenter = side * 0.5

    let leftPage = NSBezierPath()
    leftPage.move(to: NSPoint(x: bookCenter, y: bookBottom + side * 0.035))
    leftPage.line(to: NSPoint(x: bookLeft, y: bookBottom + side * 0.085))
    leftPage.line(to: NSPoint(x: bookLeft, y: bookTop))
    leftPage.line(to: NSPoint(x: bookCenter, y: bookTop - side * 0.055))
    leftPage.close()

    let rightPage = NSBezierPath()
    rightPage.move(to: NSPoint(x: bookCenter, y: bookBottom + side * 0.035))
    rightPage.line(to: NSPoint(x: bookRight, y: bookBottom + side * 0.085))
    rightPage.line(to: NSPoint(x: bookRight, y: bookTop))
    rightPage.line(to: NSPoint(x: bookCenter, y: bookTop - side * 0.055))
    rightPage.close()

    NSColor.white.withAlphaComponent(0.96).setFill()
    leftPage.fill()
    rightPage.fill()

    let pageStroke = NSColor(calibratedRed: 0.10, green: 0.33, blue: 0.84, alpha: 0.32)
    pageStroke.setStroke()

    for offset in [0.09, 0.16] {
        let leftLine = NSBezierPath()
        leftLine.move(to: NSPoint(x: bookLeft + side * 0.055, y: bookTop - side * offset))
        leftLine.line(to: NSPoint(x: bookCenter - side * 0.055, y: bookTop - side * (offset + 0.045)))
        leftLine.lineWidth = max(1.0, side * 0.012)
        leftLine.stroke()

        let rightLine = NSBezierPath()
        rightLine.move(to: NSPoint(x: bookCenter + side * 0.055, y: bookTop - side * (offset + 0.045)))
        rightLine.line(to: NSPoint(x: bookRight - side * 0.055, y: bookTop - side * offset))
        rightLine.lineWidth = max(1.0, side * 0.012)
        rightLine.stroke()
    }

    let centerLine = NSBezierPath()
    centerLine.move(to: NSPoint(x: bookCenter, y: bookBottom + side * 0.045))
    centerLine.line(to: NSPoint(x: bookCenter, y: bookTop - side * 0.06))
    centerLine.lineWidth = max(1.0, side * 0.018)
    NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.62, alpha: 0.28).setStroke()
    centerLine.stroke()

    let waveColor = NSColor.white.withAlphaComponent(0.96)
    drawRoundedBar(side: side, x: 0.285, centerY: 0.675, width: 0.048, height: 0.16, color: waveColor)
    drawRoundedBar(side: side, x: 0.385, centerY: 0.675, width: 0.052, height: 0.28, color: waveColor)
    drawRoundedBar(side: side, x: 0.492, centerY: 0.675, width: 0.056, height: 0.37, color: waveColor)
    drawRoundedBar(side: side, x: 0.605, centerY: 0.675, width: 0.052, height: 0.28, color: waveColor)
    drawRoundedBar(side: side, x: 0.713, centerY: 0.675, width: 0.048, height: 0.16, color: waveColor)

    let playPath = NSBezierPath()
    playPath.move(to: NSPoint(x: side * 0.455, y: side * 0.325))
    playPath.line(to: NSPoint(x: side * 0.455, y: side * 0.445))
    playPath.line(to: NSPoint(x: side * 0.56, y: side * 0.385))
    playPath.close()
    NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.88, alpha: 0.9).setFill()
    playPath.fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }

    return png
}

func appendOSType(_ value: String, to data: inout Data) {
    data.append(value.data(using: .ascii)!)
}

func appendBigEndianUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
        data.append(contentsOf: bytes)
    }
}

func makeICNS(from pngsBySize: [Int: Data]) throws -> Data {
    let chunks: [(type: String, png: Data)] = [
        ("icp4", pngsBySize[16]!),
        ("icp5", pngsBySize[32]!),
        ("icp6", pngsBySize[64]!),
        ("ic07", pngsBySize[128]!),
        ("ic08", pngsBySize[256]!),
        ("ic09", pngsBySize[512]!),
        ("ic10", pngsBySize[1024]!),
        ("ic11", pngsBySize[32]!),
        ("ic12", pngsBySize[64]!),
        ("ic13", pngsBySize[256]!),
        ("ic14", pngsBySize[512]!),
    ]

    let totalLength = 8 + chunks.reduce(0) { partial, chunk in
        partial + 8 + chunk.png.count
    }

    guard totalLength <= Int(UInt32.max) else {
        throw NSError(domain: "Icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "ICNS file is too large"])
    }

    var icns = Data()
    appendOSType("icns", to: &icns)
    appendBigEndianUInt32(UInt32(totalLength), to: &icns)

    for chunk in chunks {
        appendOSType(chunk.type, to: &icns)
        appendBigEndianUInt32(UInt32(8 + chunk.png.count), to: &icns)
        icns.append(chunk.png)
    }

    return icns
}

var pngsBySize: [Int: Data] = [:]

for output in outputs {
    let png = try makeIcon(pixels: output.pixels)
    pngsBySize[output.pixels] = png
    try png.write(to: iconset.appendingPathComponent(output.fileName))
}

let icns = try makeICNS(from: pngsBySize)
try icns.write(to: icnsFile)

print(icnsFile.path)
