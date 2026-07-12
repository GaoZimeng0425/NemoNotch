import AppKit
@testable import NemoNotch
import SwiftUI
import Testing

struct ArtworkColorTests {
    /// PNG bytes of a solid-color square, matching what MediaRemote hands us.
    private func imageData(fill: NSColor, size: Int = 64) -> Data {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        fill.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }

    private func hsb(_ color: Color) -> (hue: CGFloat, sat: CGFloat, bri: CGFloat) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB)!
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }

    @Test func solidColorPreservesHue() {
        let data = imageData(fill: NSColor(hue: 0.6, saturation: 0.8, brightness: 0.7, alpha: 1))
        let accent = ArtworkColor.accent(from: data)
        #expect(accent != nil)
        if let accent {
            #expect(abs(hsb(accent).hue - 0.6) < 0.05)
        }
    }

    @Test func grayscaleYieldsNil() {
        let data = imageData(fill: NSColor(white: 0.5, alpha: 1))
        #expect(ArtworkColor.accent(from: data) == nil)
    }

    @Test func nearBlackYieldsNil() {
        let data = imageData(fill: NSColor(hue: 0.3, saturation: 0.9, brightness: 0.05, alpha: 1))
        #expect(ArtworkColor.accent(from: data) == nil)
    }

    @Test func garbageDataYieldsNil() {
        #expect(ArtworkColor.accent(from: Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test func dimColorIsBoostedTowardLegibility() throws {
        // Saturated but dim green: the perceived-brightness floor must lift it
        // well above its original luma so it reads on the dark notch.
        let data = imageData(fill: NSColor(hue: 0.33, saturation: 0.9, brightness: 0.3, alpha: 1))
        let accent = ArtworkColor.accent(from: data)
        #expect(accent != nil)
        if let accent {
            let ns = try #require(NSColor(accent).usingColorSpace(.deviceRGB))
            let perceived = 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
            #expect(perceived >= 0.5)
        }
    }
}
