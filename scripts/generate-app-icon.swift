#!/usr/bin/env swift

import AppKit
import SwiftUI

// MARK: - Canonical geometry

/// 12 × 12 pixel grid. Mirrored in NemoNotch/Notch/MenuBar/MenuBarLabel.swift
/// (the menubar surface) — keep them in sync if either changes.
private let gridSize: CGFloat = 12

private struct GridBar {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
}

private let bars: [GridBar] = [
    GridBar(x: 0, y: 4, width: 12), // display top edge
    GridBar(x: 2, y: 5, width: 8), // notch body
    GridBar(x: 3, y: 6, width: 6), // chamfer
]

// MARK: - Colors

private let backgroundTop = Color(red: 245.0 / 255, green: 242.0 / 255, blue: 236.0 / 255)
private let backgroundBottom = Color(red: 232.0 / 255, green: 227.0 / 255, blue: 216.0 / 255)
private let foreground = Color(red: 26.0 / 255, green: 26.0 / 255, blue: 26.0 / 255)

// MARK: - View

private struct AppIconView: View {
    let side: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [backgroundTop, backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, canvasSize in
                let cell = canvasSize.width / gridSize
                for bar in bars {
                    let rect = CGRect(
                        x: bar.x * cell,
                        y: bar.y * cell,
                        width: bar.width * cell,
                        height: cell
                    )
                    context.fill(Path(rect), with: .color(foreground))
                }
            }
        }
        .frame(width: side, height: side)
    }
}

// MARK: - Render targets

private let targets: [(filename: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// MARK: - Output path

// #filePath resolves to this script's source file at compile time, even when
// invoked via shebang from anywhere.
let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outputDir = repoRoot
    .appendingPathComponent("NemoNotch")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: outputDir.path) else {
    FileHandle.standardError.write(
        Data("error: output dir not found: \(outputDir.path)\n".utf8)
    )
    exit(1)
}

// MARK: - Render & write

for (filename, pixels) in targets {
    let renderer = ImageRenderer(content: AppIconView(side: pixels))
    renderer.scale = 1 // view side already equals output pixel count

    guard
        let nsImage = renderer.nsImage,
        let tiff = nsImage.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(
            Data("error: render failed for \(filename)\n".utf8)
        )
        exit(1)
    }

    let outURL = outputDir.appendingPathComponent(filename)
    do {
        try png.write(to: outURL)
    } catch {
        FileHandle.standardError.write(
            Data("error: write failed for \(filename): \(error)\n".utf8)
        )
        exit(1)
    }
}

print("Wrote \(targets.count) PNGs to NemoNotch/Assets.xcassets/AppIcon.appiconset/")
