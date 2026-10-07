// Diagnostics.swift - switches for poking at the app, read from environment
// variables so the shipped behaviour never changes. Launch the binary
// directly to use them, e.g.
//   CURTAIN_DEBUG=1 CURTAIN_WIREFRAME=1 build/Curtain.app/Contents/MacOS/Curtain

import AppKit
import Metal
import CurtainCore

private let environment = ProcessInfo.processInfo.environment

/// CURTAIN_DEBUG=1: print mouse and sleep/wake decisions to stdout.
let debugEnabled = environment["CURTAIN_DEBUG"] != nil
func debugLog(_ message: @autoclosure () -> String) {
    if debugEnabled { print(message()); fflush(stdout) }
}

/// CURTAIN_WIREFRAME=1: draw the mesh as lines instead of lit fabric.
let wireframeEnabled = environment["CURTAIN_WIREFRAME"] != nil

/// CURTAIN_SNAPSHOT=/path/file.png: save one frame as a PNG the first time the
/// cloth settles. Lets the rendering be checked without a screen recording.
let snapshotPath = environment["CURTAIN_SNAPSHOT"]
/// CURTAIN_SNAPSHOT_AFTER=seconds: take the snapshot after this long even if
/// the cloth has not settled.
let snapshotDeadline: Double? = environment["CURTAIN_SNAPSHOT_AFTER"].flatMap(Double.init)

/// CURTAIN_START=closed: begin with the curtain drawn across the screen.
let startClosed = environment["CURTAIN_START"] == "closed"

/// CURTAIN_LOOK=black|beige|red: try a fabric without editing Tuning.look.
/// Otherwise the last choice from the Fabric menu wins, then Tuning.look.
func initialLook() -> FabricLook {
    switch environment["CURTAIN_LOOK"] {
    case "black": return Tuning.matteBlack
    case "beige": return Tuning.beige
    case "red": return Tuning.velvetRed
    default:
        let saved = UserDefaults.standard.string(forKey: "look")
        return Tuning.looks.first { $0.name == saved } ?? Tuning.look
    }
}

enum Snapshot {
    /// Copy a BGRA8 drawable texture into a PNG file.
    static func save(texture: MTLTexture, to path: String) {
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
              let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            debugLog("snapshot failed")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            debugLog("snapshot written to \(path)")
        } catch {
            debugLog("snapshot failed: \(error)")
        }
    }
}
