import AppKit
import SwiftUI

/// Dominant-color extraction for album artwork.
///
/// HSB hue-bucket weighted voting (borrowed from Atoll's
/// `prominentOpposingColors`): dull pixels are skipped (too dark, too bright,
/// or undersaturated), the rest vote for their hue bucket with weight
/// saturation² × brightness, and the heaviest bucket's weighted-average color
/// wins. The winner is saturation/brightness-boosted and floored to a
/// perceived-brightness minimum so it stays vivid and legible on the dark
/// notch background. Effectively grayscale artwork yields `nil` (callers fall
/// back to the theme accent).
enum ArtworkColor {
    /// Pure and synchronous — scans a 40×40 downsample, so run it off the
    /// main actor (`Task.detached`) and publish the result back.
    static func accent(from data: Data) -> Color? {
        guard let image = NSImage(data: data),
              let dominant = dominantColor(of: image) else { return nil }
        return Color(nsColor: ensureMinimumBrightness(dominant, floor: 0.55))
    }

    private static let sampleSize = 40
    private static let hueBucketCount = 12
    private static let minBrightness: CGFloat = 0.10
    private static let maxBrightness: CGFloat = 0.95
    private static let minSaturation: CGFloat = 0.20

    private static func dominantColor(of image: NSImage) -> NSColor? {
        guard let pixels = downsampledRGBA(image) else { return nil }

        var weight = [CGFloat](repeating: 0, count: hueBucketCount)
        var hueSum = [CGFloat](repeating: 0, count: hueBucketCount)
        var satSum = [CGFloat](repeating: 0, count: hueBucketCount)
        var briSum = [CGFloat](repeating: 0, count: hueBucketCount)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255
            let g = CGFloat(pixels[i + 1]) / 255
            let b = CGFloat(pixels[i + 2]) / 255
            let (hue, sat, bri) = hsb(r: r, g: g, b: b)
            guard bri > minBrightness, bri < maxBrightness, sat > minSaturation else { continue }
            let w = sat * sat * bri
            let bucket = min(Int(hue * CGFloat(hueBucketCount)), hueBucketCount - 1)
            weight[bucket] += w
            hueSum[bucket] += hue * w
            satSum[bucket] += sat * w
            briSum[bucket] += bri * w
        }

        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] > 0 else { return nil }

        return NSColor(
            hue: hueSum[best] / weight[best],
            saturation: min(satSum[best] / weight[best] * 1.2, 1),
            brightness: min(briSum[best] / weight[best] * 1.1, 1),
            alpha: 1
        )
    }

    /// Scale RGB up until the perceived brightness (0.2126R + 0.7152G +
    /// 0.0722B) reaches `floor`, keeping the hue while guaranteeing
    /// legibility on the near-black notch background.
    private static func ensureMinimumBrightness(_ color: NSColor, floor: CGFloat) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        let perceived = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        guard perceived > 0, perceived < floor else { return rgb }
        let scale = floor / perceived
        return NSColor(
            red: min(rgb.redComponent * scale, 1),
            green: min(rgb.greenComponent * scale, 1),
            blue: min(rgb.blueComponent * scale, 1),
            alpha: 1
        )
    }

    private static func hsb(r: CGFloat, g: CGFloat, b: CGFloat) -> (hue: CGFloat, sat: CGFloat, bri: CGFloat) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let bri = maxC
        let sat = maxC == 0 ? 0 : delta / maxC
        var hue: CGFloat = 0
        if delta > 0 {
            if maxC == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 {
                hue += 1
            }
        }
        return (hue, sat, bri)
    }

    private static func downsampledRGBA(_ image: NSImage) -> [UInt8]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = sampleSize
        let height = sampleSize
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
}
