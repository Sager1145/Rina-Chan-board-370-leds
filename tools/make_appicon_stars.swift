#!/usr/bin/env swift
// Composites the app backdrop's star assets into the 1024x1024 app icon,
// behind Rina: stars are drawn only where the base icon still shows its flat
// background colour, so a star never covers her hair or the notepad.
//
// Usage: swift tools/make_appicon_stars.swift [--preview <dir>]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Inputs

let repoRoot: URL = {
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    if url.lastPathComponent == "tools" { url = url.deletingLastPathComponent() }
    return url.standardizedFileURL
}()

let assetsDir = repoRoot.appendingPathComponent("ios/RinaBoard/Resources/Assets.xcassets")
let iconDir = assetsDir.appendingPathComponent("AppIcon.appiconset")
let baseDir = repoRoot.appendingPathComponent("tools/appicon")

var previewDir: URL?
var args = Array(CommandLine.arguments.dropFirst())
while let flag = args.first {
    args.removeFirst()
    switch flag {
    case "--preview":
        guard let path = args.first else { fatalError("--preview needs a directory") }
        args.removeFirst()
        previewDir = URL(fileURLWithPath: path)
    default:
        fatalError("unknown argument \(flag)")
    }
}

// MARK: - Bitmap helpers

struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]   // RGBA8, premultiplied

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    init(cgImage: CGImage) {
        width = cgImage.width
        height = cgImage.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress,
                                    width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func makeImage() -> CGImage {
        var copy = pixels
        return copy.withUnsafeMutableBytes { raw -> CGImage in
            let context = CGContext(data: raw.baseAddress,
                                    width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return context.makeImage()!
        }
    }
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("cannot read \(url.path)")
    }
    return image
}

/// App icons must ship without an alpha channel, so the composed bitmap is
/// redrawn into an opaque context before it is encoded.
func flattenOpaque(_ image: CGImage) -> CGImage {
    let context = CGContext(data: nil,
                            width: image.width,
                            height: image.height,
                            bitsPerComponent: 8,
                            bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot finalize \(url.path)") }
}

// MARK: - Background mask

/// 1 where the base icon still shows its flat background colour (connected to
/// the border), 0 on Rina herself, with a soft edge so a star that reaches her
/// silhouette fades out instead of ending on a hard line.
func backgroundMask(of bitmap: Bitmap, tolerance: Double, erode: Int, blurRadius: Int) -> [Float] {
    let width = bitmap.width
    let height = bitmap.height

    func rgb(_ index: Int) -> (Double, Double, Double) {
        let base = index * 4
        return (Double(bitmap.pixels[base]), Double(bitmap.pixels[base + 1]), Double(bitmap.pixels[base + 2]))
    }

    // Background colour: the per-channel median of the border ring. Rina
    // reaches the bottom edge, so a mean (or a bottom corner) would be pulled
    // towards her sleeve; most of the ring is still flat background.
    var border: [(Double, Double, Double)] = []
    for x in 0..<width { border.append(rgb(x)); border.append(rgb((height - 1) * width + x)) }
    for y in 0..<height { border.append(rgb(y * width)); border.append(rgb(y * width + width - 1)) }
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
    let background = (median(border.map(\.0)), median(border.map(\.1)), median(border.map(\.2)))
    FileHandle.standardError.write("background rgb \(background)\n".data(using: .utf8)!)

    // Flood fill inward from the border.
    var isBackground = [Bool](repeating: false, count: width * height)
    var stack: [Int] = []
    func push(_ x: Int, _ y: Int) {
        let index = y * width + x
        guard !isBackground[index] else { return }
        let (r, g, b) = rgb(index)
        let distance = ((r - background.0) * (r - background.0)
                        + (g - background.1) * (g - background.1)
                        + (b - background.2) * (b - background.2)).squareRoot()
        guard distance <= tolerance else { return }
        isBackground[index] = true
        stack.append(index)
    }
    for x in 0..<width { push(x, 0); push(x, height - 1) }
    for y in 0..<height { push(0, y); push(width - 1, y) }
    while let index = stack.popLast() {
        let x = index % width
        let y = index / width
        if x > 0 { push(x - 1, y) }
        if x < width - 1 { push(x + 1, y) }
        if y > 0 { push(x, y - 1) }
        if y < height - 1 { push(x, y + 1) }
    }

    // Erode, so the anti-aliased rim around Rina counts as hers, then blur for
    // a soft falloff.
    var mask = [Float](repeating: 0, count: width * height)
    for i in 0..<mask.count { mask[i] = isBackground[i] ? 1 : 0 }
    for _ in 0..<erode {
        var eroded = mask
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard mask[index] > 0 else { continue }
                let left = x > 0 ? mask[index - 1] : 1
                let right = x < width - 1 ? mask[index + 1] : 1
                let up = y > 0 ? mask[index - width] : 1
                let down = y < height - 1 ? mask[index + width] : 1
                if left == 0 || right == 0 || up == 0 || down == 0 { eroded[index] = 0 }
            }
        }
        mask = eroded
    }
    if blurRadius > 0 {
        mask = boxBlur(mask, width: width, height: height, radius: blurRadius)
        mask = boxBlur(mask, width: width, height: height, radius: blurRadius)
    }
    return mask
}

func boxBlur(_ source: [Float], width: Int, height: Int, radius: Int) -> [Float] {
    var horizontal = [Float](repeating: 0, count: source.count)
    let window = Float(radius * 2 + 1)
    for y in 0..<height {
        for x in 0..<width {
            var total: Float = 0
            for dx in -radius...radius {
                let sx = min(max(x + dx, 0), width - 1)
                total += source[y * width + sx]
            }
            horizontal[y * width + x] = total / window
        }
    }
    var blurred = [Float](repeating: 0, count: source.count)
    for y in 0..<height {
        for x in 0..<width {
            var total: Float = 0
            for dy in -radius...radius {
                let sy = min(max(y + dy, 0), height - 1)
                total += horizontal[sy * width + x]
            }
            blurred[y * width + x] = total / window
        }
    }
    return blurred
}

// MARK: - Layout

/// SplitMix64 — the generator `RinaStarfieldSourceSpec` uses for its fixed
/// screenshot layout, so this tool's layout is reproducible too.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The five `l-bg_item--N` boxes from the source page, as a fraction of a
/// 390pt viewport width, so the icon's stars keep the backdrop's proportions
/// (`31/390`, `20/390`, ...) and its 1:1-ish aspect ratios.
let starBoxes: [(width: Double, height: Double)] = [
    (31, 31), (31, 31), (26, 27), (20, 20), (20, 20)
]
let sourceViewportWidth = 390.0

struct Star {
    let index: Int      // 0-based into starBoxes / the asset names
    let center: CGPoint
    let size: CGSize
    let rotation: CGFloat
    let opacity: CGFloat
}

let iconSize = 1024.0
/// Slightly larger than backdrop parity (`scale = 1`): at icon size the stars
/// are read in one glance rather than scrolled past.
let starScale = Double(ProcessInfo.processInfo.environment["RINA_ICON_STAR_SCALE"] ?? "1.35")!
let opacityLow = Double(ProcessInfo.processInfo.environment["RINA_ICON_STAR_OPACITY_LOW"] ?? "0.32")!
let opacityHigh = Double(ProcessInfo.processInfo.environment["RINA_ICON_STAR_OPACITY_HIGH"] ?? "0.5")!
let starCount = Int(ProcessInfo.processInfo.environment["RINA_ICON_STAR_COUNT"] ?? "9")!
/// "RINAICON" in ASCII hex.
let layoutSeed = UInt64(0x5249_4E41_4943_4F4E)

func layoutStars(mask: [Float], width: Int, height: Int) -> [Star] {
    var generator = SplitMix64(state: layoutSeed)
    func random(_ lower: Double, _ upper: Double) -> Double {
        lower + (Double(generator.next() >> 11) * 0x1p-53) * (upper - lower)
    }

    // iOS masks the icon with a ~22.4% continuous corner radius; keep every
    // star inside the safe circle so none is clipped or crowds the rim.
    let inset = iconSize * 0.075
    let safe = CGRect(x: inset, y: inset, width: iconSize - 2 * inset, height: iconSize - 2 * inset)

    func maskCoverage(center: CGPoint, radius: Double) -> Double {
        var inside = 0.0
        var total = 0.0
        let step = max(2.0, radius / 6)
        var dy = -radius
        while dy <= radius {
            var dx = -radius
            while dx <= radius {
                if dx * dx + dy * dy <= radius * radius {
                    total += 1
                    let x = Int((center.x + dx).rounded())
                    let y = Int((center.y + dy).rounded())
                    if x >= 0, x < width, y >= 0, y < height {
                        inside += Double(mask[y * width + x])
                    }
                }
                dx += step
            }
            dy += step
        }
        return total > 0 ? inside / total : 0
    }

    var stars: [Star] = []
    var attempts = 0
    while stars.count < starCount, attempts < 20000 {
        attempts += 1
        let index = Int(random(0, 5))
        let box = starBoxes[min(index, 4)]
        let scale = iconSize / sourceViewportWidth * starScale * random(0.85, 1.15)
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let radius = max(size.width, size.height) / 2
        let center = CGPoint(x: random(safe.minX + radius, safe.maxX - radius),
                             y: random(safe.minY + radius, safe.maxY - radius))
        // Fully on the flat background, and not stacked on another star.
        guard maskCoverage(center: center, radius: radius * 1.12) >= 0.995 else { continue }
        let spaced = stars.allSatisfy { other in
            let dx = other.center.x - center.x
            let dy = other.center.y - center.y
            return (dx * dx + dy * dy).squareRoot() > (radius + max(other.size.width, other.size.height) / 2) * 1.35
        }
        guard spaced else { continue }
        stars.append(Star(index: min(index, 4),
                          center: center,
                          size: size,
                          rotation: CGFloat(random(-.pi, .pi)),
                          opacity: CGFloat(random(opacityLow, opacityHigh))))
    }
    FileHandle.standardError.write("placed \(stars.count) stars in \(attempts) attempts\n".data(using: .utf8)!)
    // A base icon that leaves too little flat background would otherwise ship
    // a quietly emptier sky than the one that was reviewed.
    precondition(stars.count == starCount, "only \(stars.count) of \(starCount) stars fit on the background")
    return stars
}

// MARK: - Composite

let starImages: [CGImage] = (1...5).map {
    loadImage(assetsDir.appendingPathComponent("RinaBackgroundStar\($0).imageset/RinaBackgroundStar\($0).png"))
}

func render(base baseURL: URL, to outputURL: URL, previewName: String) {
    let baseImage = loadImage(baseURL)
    let bitmap = Bitmap(cgImage: baseImage)
    let width = bitmap.width
    let height = bitmap.height
    precondition(width == Int(iconSize) && height == Int(iconSize), "expected a 1024x1024 base icon")

    let mask = backgroundMask(of: bitmap, tolerance: 26, erode: 2, blurRadius: 2)
    let stars = layoutStars(mask: mask, width: width, height: height)

    // Stars go on their own layer so the background mask can be multiplied
    // into them before they reach the icon.
    var layer = Bitmap(width: width, height: height)
    layer.pixels.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress,
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        for star in stars {
            context.saveGState()
            // Bitmap y grows downward; the layout works in that space too.
            context.translateBy(x: star.center.x, y: CGFloat(height) - star.center.y)
            context.rotate(by: star.rotation)
            context.setAlpha(star.opacity)
            let image = starImages[star.index]
            // `background-size: contain` inside the element's box.
            let natural = CGSize(width: image.width, height: image.height)
            let fit = min(star.size.width / natural.width, star.size.height / natural.height)
            let drawSize = CGSize(width: natural.width * fit, height: natural.height * fit)
            context.draw(image, in: CGRect(x: -drawSize.width / 2, y: -drawSize.height / 2,
                                           width: drawSize.width, height: drawSize.height))
            context.restoreGState()
        }
    }

    for y in 0..<height {
        for x in 0..<width {
            let index = y * width + x
            let factor = min(max(mask[index], 0), 1)
            guard factor < 1 else { continue }
            for channel in 0..<4 {
                layer.pixels[index * 4 + channel] = UInt8(Float(layer.pixels[index * 4 + channel]) * factor)
            }
        }
    }

    var output = bitmap
    output.pixels.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress,
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(layer.makeImage(), in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    }

    // `--preview` is a dry run: it leaves the shipped asset untouched.
    let destination = previewDir.map { $0.appendingPathComponent("\(previewName).png") } ?? outputURL
    writePNG(flattenOpaque(output.makeImage()), to: destination)
    print("wrote \(destination.path)")
}

render(base: baseDir.appendingPathComponent("AppIcon-1024-base.png"),
       to: iconDir.appendingPathComponent("AppIcon-1024.png"),
       previewName: "AppIcon-1024")
render(base: baseDir.appendingPathComponent("AppIcon-1024-Dark-base.png"),
       to: iconDir.appendingPathComponent("AppIcon-1024-Dark.png"),
       previewName: "AppIcon-1024-Dark")
