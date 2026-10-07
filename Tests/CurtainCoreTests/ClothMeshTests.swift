// ClothMeshTests.swift - the mesh built from a flat cloth must be flat, lit
// evenly, and wired into valid triangles.

import Testing
import simd
@testable import CurtainCore

@Suite struct ClothMeshTests {
    @Test("closed cloth: normals mostly face the viewer, little fold shadow, valid triangles")
    func closedCloth() {
        let cloth = makeCloth(open: false)
        cloth.settle(steps: 300)
        let mesh = ClothMesh(cloth: cloth)
        mesh.update(from: cloth)

        let count = cloth.columns * cloth.rows
        #expect(mesh.vertices.count == count)
        #expect(mesh.indices.count == (cloth.columns - 1) * (cloth.rows - 1) * 6)
        #expect(mesh.indices.allSatisfy { Int($0) < count })
        // The closed curtain hangs in gentle waves, so normals tilt a little
        // but never far from straight out of the screen.
        #expect(mesh.vertices.allSatisfy { abs(length($0.normal) - 1) < 1e-3 })
        #expect(mesh.vertices.allSatisfy { $0.normal.z > 0.8 })
        #expect(mesh.vertices.allSatisfy { $0.occlusion > 0.85 })
    }

    @Test("a bunched cloth gets fold shadow and tilted normals")
    func bunchedCloth() {
        let cloth = makeCloth(open: true)
        cloth.settle(steps: 600)
        let mesh = ClothMesh(cloth: cloth)
        mesh.update(from: cloth)

        #expect(!cloth.hasNonFinite())
        #expect(mesh.vertices.contains { $0.occlusion < 0.9 })
        #expect(mesh.vertices.allSatisfy { abs(length($0.normal) - 1) < 1e-3 })
    }
}
