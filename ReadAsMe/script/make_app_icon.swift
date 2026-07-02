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

func drawWaveArc(side: CGFloat, centerX: CGFloat, centerY: CGFloat, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, color: NSColor, lineWidth: CGFloat) {
    let path = NSBezierPath()
    path.appendArc(
        withCenter: NSPoint(x: side * centerX, y: side * centerY),
        radius: side * radius,
        startAngle: startAngle,
        endAngle: endAngle,
        clockwise: false
    )
    path.lineWidth = max(1.0, side * lineWidth)
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
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
        NSColor(calibratedRed: 0.02, green: 0.39, blue: 0.92, alpha: 1.0),
        NSColor(calibratedRed: 0.04, green: 0.67, blue: 0.75, alpha: 1.0),
        NSColor(calibratedRed: 0.12, green: 0.82, blue: 0.62, alpha: 1.0),
    ])
    baseGradient?.draw(in: basePath, angle: 315)

    shadow.shadowColor = .clear
    shadow.set()

    let gloss = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.30),
        NSColor.white.withAlphaComponent(0.03),
    ])
    gloss?.draw(in: basePath, angle: 90)

    let bookBottom = side * 0.205
    let bookTop = side * 0.455
    let bookLeft = side * 0.215
    let bookRight = side * 0.785
    let bookCenter = side * 0.5

    let cover = NSBezierPath(roundedRect: rect(side, x: 0.19, y: 0.17, width: 0.62, height: 0.31), xRadius: side * 0.045, yRadius: side * 0.045)
    NSColor(calibratedRed: 0.02, green: 0.22, blue: 0.58, alpha: 0.34).setFill()
    cover.fill()

    let leftPage = NSBezierPath()
    leftPage.move(to: NSPoint(x: bookCenter, y: bookBottom + side * 0.035))
    leftPage.line(to: NSPoint(x: bookLeft, y: bookBottom + side * 0.08))
    leftPage.line(to: NSPoint(x: bookLeft, y: bookTop))
    leftPage.curve(
        to: NSPoint(x: bookCenter, y: bookTop - side * 0.045),
        controlPoint1: NSPoint(x: bookLeft + side * 0.095, y: bookTop + side * 0.02),
        controlPoint2: NSPoint(x: bookCenter - side * 0.07, y: bookTop - side * 0.02)
    )
    leftPage.close()

    let rightPage = NSBezierPath()
    rightPage.move(to: NSPoint(x: bookCenter, y: bookBottom + side * 0.035))
    rightPage.line(to: NSPoint(x: bookRight, y: bookBottom + side * 0.08))
    rightPage.line(to: NSPoint(x: bookRight, y: bookTop))
    rightPage.curve(
        to: NSPoint(x: bookCenter, y: bookTop - side * 0.045),
        controlPoint1: NSPoint(x: bookRight - side * 0.095, y: bookTop + side * 0.02),
        controlPoint2: NSPoint(x: bookCenter + side * 0.07, y: bookTop - side * 0.02)
    )
    rightPage.close()

    NSColor.white.withAlphaComponent(0.97).setFill()
    leftPage.fill()
    rightPage.fill()

    let pageStroke = NSColor(calibratedRed: 0.05, green: 0.36, blue: 0.72, alpha: 0.30)
    pageStroke.setStroke()
    for offset in [0.065, 0.125] {
        let leftLine = NSBezierPath()
        leftLine.move(to: NSPoint(x: bookLeft + side * 0.055, y: bookTop - side * offset))
        leftLine.curve(
            to: NSPoint(x: bookCenter - side * 0.055, y: bookTop - side * (offset + 0.035)),
            controlPoint1: NSPoint(x: bookLeft + side * 0.12, y: bookTop - side * (offset - 0.015)),
            controlPoint2: NSPoint(x: bookCenter - side * 0.11, y: bookTop - side * (offset + 0.02))
        )
        leftLine.lineWidth = max(1.0, side * 0.011)
        leftLine.lineCapStyle = .round
        leftLine.stroke()

        let rightLine = NSBezierPath()
        rightLine.move(to: NSPoint(x: bookCenter + side * 0.055, y: bookTop - side * (offset + 0.035)))
        rightLine.curve(
            to: NSPoint(x: bookRight - side * 0.055, y: bookTop - side * offset),
            controlPoint1: NSPoint(x: bookCenter + side * 0.11, y: bookTop - side * (offset + 0.02)),
            controlPoint2: NSPoint(x: bookRight - side * 0.12, y: bookTop - side * (offset - 0.015))
        )
        rightLine.lineWidth = max(1.0, side * 0.011)
        rightLine.lineCapStyle = .round
        rightLine.stroke()
    }

    let centerLine = NSBezierPath()
    centerLine.move(to: NSPoint(x: bookCenter, y: bookBottom + side * 0.04))
    centerLine.line(to: NSPoint(x: bookCenter, y: bookTop - side * 0.045))
    centerLine.lineWidth = max(1.0, side * 0.017)
    centerLine.lineCapStyle = .round
    NSColor(calibratedRed: 0.04, green: 0.24, blue: 0.62, alpha: 0.24).setStroke()
    centerLine.stroke()

    let body = NSBezierPath(roundedRect: rect(side, x: 0.392, y: 0.47, width: 0.216, height: 0.125), xRadius: side * 0.075, yRadius: side * 0.075)
    NSColor.white.withAlphaComponent(0.94).setFill()
    body.fill()

    let head = NSBezierPath(ovalIn: rect(side, x: 0.39, y: 0.555, width: 0.22, height: 0.22))
    NSColor.white.withAlphaComponent(0.97).setFill()
    head.fill()

    let profileCut = NSBezierPath()
    profileCut.move(to: NSPoint(x: side * 0.505, y: side * 0.64))
    profileCut.curve(
        to: NSPoint(x: side * 0.595, y: side * 0.615),
        controlPoint1: NSPoint(x: side * 0.555, y: side * 0.668),
        controlPoint2: NSPoint(x: side * 0.602, y: side * 0.655)
    )
    profileCut.curve(
        to: NSPoint(x: side * 0.535, y: side * 0.57),
        controlPoint1: NSPoint(x: side * 0.588, y: side * 0.588),
        controlPoint2: NSPoint(x: side * 0.563, y: side * 0.574)
    )
    profileCut.lineWidth = max(1.0, side * 0.025)
    profileCut.lineCapStyle = .round
    NSColor(calibratedRed: 0.02, green: 0.48, blue: 0.78, alpha: 0.42).setStroke()
    profileCut.stroke()

    let waveColor = NSColor.white.withAlphaComponent(0.92)
    let accentWaveColor = NSColor(calibratedRed: 0.78, green: 1.0, blue: 0.98, alpha: 0.95)
    drawWaveArc(side: side, centerX: 0.50, centerY: 0.62, radius: 0.205, startAngle: 130, endAngle: 230, color: waveColor, lineWidth: 0.026)
    drawWaveArc(side: side, centerX: 0.50, centerY: 0.62, radius: 0.285, startAngle: 134, endAngle: 226, color: accentWaveColor, lineWidth: 0.021)
    drawWaveArc(side: side, centerX: 0.50, centerY: 0.62, radius: 0.205, startAngle: -50, endAngle: 50, color: waveColor, lineWidth: 0.026)
    drawWaveArc(side: side, centerX: 0.50, centerY: 0.62, radius: 0.285, startAngle: -46, endAngle: 46, color: accentWaveColor, lineWidth: 0.021)

    drawRoundedBar(side: side, x: 0.488, centerY: 0.50, width: 0.024, height: 0.055, color: NSColor.white.withAlphaComponent(0.86))

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
