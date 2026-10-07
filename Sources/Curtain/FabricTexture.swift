// FabricTexture.swift - a velvet texture generated in code at launch.
// Three layers: a fine thread weave, large soft patches where the pile lies
// in different directions (the "crushed" look), and per-texel grain. All of
// them repeat exactly at the texture edge, so tiling it shows no seams.

import Foundation
import Metal
import simd
import CurtainCore

enum FabricTexture {

    static func make(look: FabricLook, device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture {
        let started = CFAbsoluteTimeGetCurrent()
        defer { debugLog("fabric texture generated in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms") }
        let size = Tuning.textureSize
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        let twoPi = Float.pi * 2

        // Pile patches are the sum of smooth noise at four scales. Each layer
        // has its own, non-square lattice and offset so that no two layers'
        // dips line up; otherwise a grid shows through the fabric.
        let pileLayers: [(cellsX: Int, cellsY: Int, offset: Float, weight: Float)] = [
            (5, 7, 0.37, 0.5), (11, 9, 0.61, 0.25), (23, 19, 0.13, 0.125), (47, 43, 0.83, 0.0625),
        ]
        let pileTotal = pileLayers.reduce(0) { $0 + $1.weight }

        for y in 0..<size {
            for x in 0..<size {
                let u = Float(x) / Float(size), v = Float(y) / Float(size)   // 0...1 across the tile
                // Warp and weft threads crossing over and under each other.
                let weave = 0.5 + 0.5 * sin(u * Float(Tuning.threadsPerTile) * twoPi)
                                      * sin(v * Float(Tuning.threadsPerTile) * twoPi)
                // Soft patches where the pile lies in different directions.
                var pile: Float = 0
                for layer in pileLayers {
                    pile += layer.weight * valueNoise(u + layer.offset, v + layer.offset,
                                                      cellsX: layer.cellsX, cellsY: layer.cellsY)
                }
                pile /= pileTotal
                // Faint vertical streaks: noise stretched tall and thin, at two scales.
                let nap = 0.65 * valueNoise(u, v, cellsX: 61, cellsY: 5)
                        + 0.35 * valueNoise(u + 0.5, v + 0.25, cellsX: 127, cellsY: 3)
                // Grain.
                let fibre = hash(x, y, periodX: size, periodY: size)

                let brightness = 1
                    + look.weaveContrast * (weave - 0.5)
                    + look.pileContrast * (pile - 0.5)
                    + look.napContrast * (nap - 0.5)
                    + look.fibreContrast * (fibre - 0.5)
                let rgb = clamp(look.color * brightness, min: 0, max: 1)

                let i = (y * size + x) * 4
                pixels[i] = UInt8(rgb.x * 255)
                pixels[i + 1] = UInt8(rgb.y * 255)
                pixels[i + 2] = UInt8(rgb.z * 255)
            }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: true)
        desc.usage = .shaderRead
        let texture = device.makeTexture(descriptor: desc)!
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: size * 4)

        // Mipmaps: smaller copies for when the fabric is far away or compressed,
        // which stops the weave shimmering.
        let commands = queue.makeCommandBuffer()!
        let blit = commands.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        return texture
    }

    // MARK: Noise

    /// Deterministic 0...1 value for a lattice point. Wrapping the coordinates
    /// at the periods is what makes every layer tile seamlessly.
    private static func hash(_ x: Int, _ y: Int, periodX: Int, periodY: Int) -> Float {
        let px = UInt32(((x % periodX) + periodX) % periodX)
        let py = UInt32(((y % periodY) + periodY) % periodY)
        var h = px &* 374_761_393 &+ py &* 668_265_263
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }

    /// Smooth noise over the 0...1 tile: random values on a cellsX by cellsY
    /// lattice, blended between with a smoothstep.
    private static func valueNoise(_ u: Float, _ v: Float, cellsX: Int, cellsY: Int) -> Float {
        let x = u * Float(cellsX), y = v * Float(cellsY)
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = smoothstep(x - Float(x0)), fy = smoothstep(y - Float(y0))
        let a = hash(x0, y0, periodX: cellsX, periodY: cellsY)
        let b = hash(x0 + 1, y0, periodX: cellsX, periodY: cellsY)
        let c = hash(x0, y0 + 1, periodX: cellsX, periodY: cellsY)
        let d = hash(x0 + 1, y0 + 1, periodX: cellsX, periodY: cellsY)
        return mix(mix(a, b, fx), mix(c, d, fx), fy)
    }

    private static func smoothstep(_ t: Float) -> Float { t * t * (3 - 2 * t) }
    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
}
