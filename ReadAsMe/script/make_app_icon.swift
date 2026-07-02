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
let sourceFile = resources.appendingPathComponent("AppIconSource.png")

guard let sourceImage = NSImage(contentsOf: sourceFile) else {
    throw NSError(domain: "Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not load \(sourceFile.path)"])
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgbaData(for image: NSImage, pixels: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerPixel = 4
    let bytesPerRow = pixels * bytesPerPixel
    var data = Data(repeating: 0, count: pixels * pixels * bytesPerPixel)

    try data.withUnsafeMutableBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            throw NSError(domain: "Icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not allocate bitmap"])
        }
        guard let context = CGContext(
            data: baseAddress,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "Icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap context"])
        }

        context.interpolationQuality = .high
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))

        let sourceSize = image.size
        let scale = max(CGFloat(pixels) / sourceSize.width, CGFloat(pixels) / sourceSize.height)
        let drawWidth = sourceSize.width * scale
        let drawHeight = sourceSize.height * scale
        let drawRect = CGRect(
            x: (CGFloat(pixels) - drawWidth) / 2,
            y: (CGFloat(pixels) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    return data
}

func makeEdgeWhiteTransparent(_ data: inout Data, pixels: Int) {
    let bytesPerPixel = 4
    let threshold: UInt8 = 242
    var visited = Array(repeating: false, count: pixels * pixels)
    var queue: [(Int, Int)] = []

    func index(_ x: Int, _ y: Int) -> Int {
        (y * pixels + x) * bytesPerPixel
    }

    func isEdgeWhite(_ x: Int, _ y: Int) -> Bool {
        let i = index(x, y)
        return data[i] >= threshold && data[i + 1] >= threshold && data[i + 2] >= threshold
    }

    func enqueue(_ x: Int, _ y: Int) {
        guard x >= 0, x < pixels, y >= 0, y < pixels else { return }
        let seenIndex = y * pixels + x
        guard !visited[seenIndex], isEdgeWhite(x, y) else { return }
        visited[seenIndex] = true
        queue.append((x, y))
    }

    for x in 0..<pixels {
        enqueue(x, 0)
        enqueue(x, pixels - 1)
    }
    for y in 0..<pixels {
        enqueue(0, y)
        enqueue(pixels - 1, y)
    }

    var cursor = 0
    while cursor < queue.count {
        let (x, y) = queue[cursor]
        cursor += 1
        let i = index(x, y)
        data[i + 3] = 0

        enqueue(x + 1, y)
        enqueue(x - 1, y)
        enqueue(x, y + 1)
        enqueue(x, y - 1)
    }
}

func pngData(from rgba: Data, pixels: Int) throws -> Data {
    let bytesPerPixel = 4
    let bytesPerRow = pixels * bytesPerPixel
    var mutable = rgba
    let byteCount = mutable.count
    return try mutable.withUnsafeMutableBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            throw NSError(domain: "Icon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not access bitmap"])
        }
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: baseAddress,
            size: byteCount,
            releaseData: { _, _, _ in }
        ) else {
            throw NSError(domain: "Icon", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not create data provider"])
        }
        guard let cgImage = CGImage(
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw NSError(domain: "Icon", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not create image"])
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Icon", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
        }
        return png
    }
}

func makeIcon(pixels: Int) throws -> Data {
    var rgba = try rgbaData(for: sourceImage, pixels: pixels)
    makeEdgeWhiteTransparent(&rgba, pixels: pixels)
    return try pngData(from: rgba, pixels: pixels)
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
        throw NSError(domain: "Icon", code: 8, userInfo: [NSLocalizedDescriptionKey: "ICNS file is too large"])
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
