// ClothMesh.swift - turns the particle grid into something a renderer can
// light: a normal per particle, texture coordinates, and a "fold shadow"
// factor that darkens where the grid bunches up. Pure maths, no Metal.

import simd

/// One vertex of the mesh. Layout must match `Vertex` in Shaders.metal field
/// for field; Metal reads the raw bytes.
public struct ClothVertex {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var uv: SIMD2<Float>
    public var occlusion: Float
}

public final class ClothMesh {
    public let columns: Int
    public let rows: Int
    public private(set) var vertices: [ClothVertex]
    /// Two triangles per grid cell, as indices into `vertices`.
    public let indices: [UInt32]
    private let restSpacingX: Float

    public init(cloth: Cloth) {
        let columns = cloth.columns, rows = cloth.rows
        self.columns = columns
        self.rows = rows
        restSpacingX = cloth.spacingX

        // Texture coordinates come from the unstretched layout, so the weave
        // stays glued to the fabric however it moves, repeating every
        // Tuning.textureTile points.
        vertices = (0..<columns * rows).map { i in
            let c = i % columns, r = i / columns
            return ClothVertex(
                position: cloth.positions[i],
                normal: SIMD3(0, 0, 1),
                uv: SIMD2(Float(c) * cloth.spacingX, Float(r) * cloth.spacingY) / Tuning.textureTile,
                occlusion: 1)
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((columns - 1) * (rows - 1) * 6)
        for r in 0..<(rows - 1) {
            for c in 0..<(columns - 1) {
                let i = UInt32(r * columns + c)
                let below = i + UInt32(columns)
                indices += [i, below, i + 1, i + 1, below, below + 1]
            }
        }
        self.indices = indices
    }

    /// Refresh positions, normals and fold shadow from the cloth's current state.
    public func update(from cloth: Cloth) {
        let columns = self.columns, rows = self.rows
        let shadow = Tuning.foldShadowStrength
        let restX = restSpacingX

        cloth.positions.withUnsafeBufferPointer { p in
            vertices.withUnsafeMutableBufferPointer { v in
                for r in 0..<rows {
                    for c in 0..<columns {
                        let i = r * columns + c
                        // Normal = cross product of the across and down tangents,
                        // using the neighbours on each side (one side at the edges).
                        let left = p[i - (c > 0 ? 1 : 0)]
                        let right = p[i + (c + 1 < columns ? 1 : 0)]
                        let up = p[i - (r > 0 ? columns : 0)]
                        let down = p[i + (r + 1 < rows ? columns : 0)]
                        var n = cross(right - left, down - up)
                        let len = length(n)
                        n = len > 1e-6 ? n / len : SIMD3(0, 0, 1)

                        // Fold shadow, two parts. Bunching: how much closer, as
                        // the crow flies, the particles two to each side are than
                        // they would be flat (1 = flat). Valley: how far this
                        // point sits behind its neighbours, i.e. inside a fold.
                        let l = min(c, 2), rr = min(columns - 1 - c, 2)
                        let straight = length(p[i + rr] - p[i - l])
                        let bunching = 1 - min(straight / (Float(max(l + rr, 1)) * restX), 1)
                        let valley = min(max(((left.z + right.z) * 0.5 - p[i].z) / restX, 0), 1)

                        v[i].position = p[i]
                        v[i].normal = n
                        v[i].occlusion = 1 - shadow * bunching * (0.35 + 0.65 * valley)
                    }
                }
            }
        }
    }
}
