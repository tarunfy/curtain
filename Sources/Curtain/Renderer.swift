// Renderer.swift - everything Metal: shaders, pipelines, texture, buffers,
// drawing. CurtainView calls render(mesh:in:) once per frame.

import MetalKit
import CurtainCore

final class Renderer {

    // Must match Uniforms in Shaders.metal field for field, padding included.
    struct Uniforms {
        var viewportSize: SIMD2<Float>
        var depthRange: Float
        var ambient: Float
        var lightDirection: SIMD3<Float>
        var diffuse: Float
        var sheenStrength: Float
        var sheenPower: Float
        var unused: Float = 0
        var sheenColor: SIMD3<Float>
    }

    // Must match ShadowVertex in Shaders.metal.
    struct ShadowVertex {
        var position: SIMD2<Float>
        var alpha: Float
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let fabricPipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let noDepthState: MTLDepthStencilState
    private var fabricTexture: MTLTexture
    private let fabricSampler: MTLSamplerState

    /// The fabric on the rail. Changing it regenerates the texture (~75 ms).
    var look: FabricLook {
        didSet { fabricTexture = FabricTexture.make(look: look, device: device, queue: commandQueue) }
    }

    // The GPU may still be reading last frame's vertices while the CPU writes
    // this frame's, so we rotate through three buffers and a semaphore stops
    // the CPU running more than three frames ahead. Standard Metal practice.
    private static let framesInFlight = 3
    private let inFlight = DispatchSemaphore(value: Renderer.framesInFlight)
    private var frameIndex = 0
    private var vertexBuffers: [MTLBuffer] = []
    private var shadowBuffers: [MTLBuffer] = []
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var shadowVertexCount = 0

    /// Set to receive the next frame's finished image (see Diagnostics.swift).
    var snapshotHandler: ((MTLTexture) -> Void)?

    init(device: MTLDevice, look: FabricLook) {
        self.device = device
        self.look = look
        commandQueue = device.makeCommandQueue()!

        // Shaders are compiled at launch from Shaders.metal inside the .app,
        // the way WebGL compiles GLSL at runtime. It takes a few milliseconds
        // and means building needs no Metal compiler on the machine.
        guard let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Shaders.metal is missing from the app bundle. Build and launch with `make run`.")
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            fatalError("Shader compile error:\n\(error)")
        }

        let fabric = MTLRenderPipelineDescriptor()
        fabric.vertexFunction = library.makeFunction(name: "curtain_vertex")
        fabric.fragmentFunction = library.makeFunction(name: "curtain_fragment")
        fabric.colorAttachments[0].pixelFormat = .bgra8Unorm
        fabric.depthAttachmentPixelFormat = .depth32Float
        fabricPipeline = try! device.makeRenderPipelineState(descriptor: fabric)

        // The shadow blends over whatever is there ("source over", premultiplied).
        let shadow = MTLRenderPipelineDescriptor()
        shadow.vertexFunction = library.makeFunction(name: "shadow_vertex")
        shadow.fragmentFunction = library.makeFunction(name: "shadow_fragment")
        shadow.colorAttachments[0].pixelFormat = .bgra8Unorm
        shadow.colorAttachments[0].isBlendingEnabled = true
        shadow.colorAttachments[0].sourceRGBBlendFactor = .one
        shadow.colorAttachments[0].sourceAlphaBlendFactor = .one
        shadow.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        shadow.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        shadow.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline = try! device.makeRenderPipelineState(descriptor: shadow)

        // Depth test: a fragment only lands if nothing nearer is there already.
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDesc)!
        let noDepth = MTLDepthStencilDescriptor()
        noDepth.depthCompareFunction = .always
        noDepth.isDepthWriteEnabled = false
        noDepthState = device.makeDepthStencilState(descriptor: noDepth)!

        fabricTexture = FabricTexture.make(look: look, device: device, queue: commandQueue)
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.mipFilter = .linear
        samplerDesc.sAddressMode = .repeat
        samplerDesc.tAddressMode = .repeat
        samplerDesc.maxAnisotropy = 4
        fabricSampler = device.makeSamplerState(descriptor: samplerDesc)!
    }

    /// Draw the shadow strip, then the mesh as lit, textured triangles (or
    /// lines, see Diagnostics).
    func render(mesh: ClothMesh, in view: MTKView) {
        prepareBuffers(for: mesh)

        inFlight.wait()
        frameIndex = (frameIndex + 1) % Renderer.framesInFlight
        let vertices = vertexBuffers[frameIndex]
        mesh.vertices.withUnsafeBytes { bytes in
            vertices.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        let shadowVertices = shadowBuffers[frameIndex]
        fillShadow(shadowVertices, from: mesh)

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass),
              let indexBuffer = indexBuffer else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }

        var uniforms = Uniforms(
            viewportSize: SIMD2(Float(view.bounds.width), Float(view.bounds.height)),
            depthRange: Tuning.depthRange,
            ambient: look.ambient,
            lightDirection: Tuning.lightDirection,
            diffuse: look.diffuse,
            sheenStrength: look.sheenStrength,
            sheenPower: look.sheenPower,
            sheenColor: look.sheenColor)

        encoder.setRenderPipelineState(shadowPipeline)
        encoder.setDepthStencilState(noDepthState)
        encoder.setVertexBuffer(shadowVertices, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: shadowVertexCount)

        encoder.setRenderPipelineState(fabricPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setTriangleFillMode(wireframeEnabled ? .lines : .fill)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(fabricTexture, index: 0)
        encoder.setFragmentSamplerState(fabricSampler, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint32, indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if let handler = snapshotHandler {
            snapshotHandler = nil
            commandBuffer.waitUntilCompleted()
            handler(drawable.texture)
        }
    }

    /// A strip two vertices per row wide, hugging the leading edge: dark at
    /// the fabric, transparent Tuning.shadowWidth points further out.
    private func fillShadow(_ buffer: MTLBuffer, from mesh: ClothMesh) {
        let out = buffer.contents().assumingMemoryBound(to: ShadowVertex.self)
        let offset = Tuning.shadowOffset
        for r in 0..<mesh.rows {
            let edge = mesh.vertices[r * mesh.columns + mesh.columns - 1].position
            let start = SIMD2(edge.x, edge.y) + offset
            out[r * 2] = ShadowVertex(position: start, alpha: Tuning.shadowStrength)
            out[r * 2 + 1] = ShadowVertex(position: start + SIMD2(Tuning.shadowWidth, 0), alpha: 0)
        }
    }

    /// (Re)create the GPU buffers when the mesh changes size.
    private func prepareBuffers(for mesh: ClothMesh) {
        guard mesh.indices.count != indexCount else { return }
        let byteCount = mesh.vertices.count * MemoryLayout<ClothVertex>.stride
        vertexBuffers = (0..<Renderer.framesInFlight).map { _ in
            device.makeBuffer(length: byteCount, options: .storageModeShared)!
        }
        shadowVertexCount = mesh.rows * 2
        shadowBuffers = (0..<Renderer.framesInFlight).map { _ in
            device.makeBuffer(length: shadowVertexCount * MemoryLayout<ShadowVertex>.stride,
                              options: .storageModeShared)!
        }
        indexBuffer = device.makeBuffer(bytes: mesh.indices,
                                        length: mesh.indices.count * MemoryLayout<UInt32>.stride)!
        indexCount = mesh.indices.count
    }
}
