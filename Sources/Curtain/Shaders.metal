// Shaders.metal - the GPU side. Compiled at launch by Renderer.swift.
// Metal Shading Language is C++ with a few attributes; think GLSL with structs.

#include <metal_stdlib>
using namespace metal;

// Must match ClothVertex in ClothMesh.swift field for field.
struct Vertex {
    float3 position;      // screen points, origin top-left, y down, z towards you
    float3 normal;
    float2 uv;
    float occlusion;      // 1 = open fabric, lower = inside a fold
};

// Must match Renderer.Uniforms in Swift field for field. Order matters: float3
// is 16 bytes and 16-byte aligned on both sides.
struct Uniforms {
    float2 viewportSize;  // points
    float depthRange;
    float ambient;
    float3 lightDirection;
    float diffuse;
    float sheenStrength;
    float sheenPower;
    float unused;
    float3 sheenColor;
};

struct RasterData {
    float4 clipPosition [[position]];
    float3 normal;
    float2 uv;
    float occlusion;
};

// Maps points (0..width, 0..height, y down) to clip space (-1..1, y up).
static float4 toClip(float2 p, float depth, float2 viewportSize) {
    return float4(p.x / viewportSize.x * 2.0 - 1.0,
                  1.0 - p.y / viewportSize.y * 2.0,
                  depth, 1.0);
}

// The projection is orthographic: z only feeds the depth test, so nearer
// fabric covers fabric behind it when folds overlap.
vertex RasterData curtain_vertex(uint vid [[vertex_id]],
                                 const device Vertex *vertices [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]]) {
    Vertex v = vertices[vid];
    RasterData out;
    out.clipPosition = toClip(v.position.xy, 0.5 - v.position.z / u.depthRange, u.viewportSize);
    out.normal = v.normal;
    out.uv = v.uv;
    out.occlusion = v.occlusion;
    return out;
}

// Velvet: diffuse light from the normal, plus a sheen that brightens where the
// surface turns away from the viewer (the sides of folds), all darkened inside
// bunched-up folds.
fragment float4 curtain_fragment(RasterData in [[stage_in]],
                                 constant Uniforms &u [[buffer(1)]],
                                 texture2d<float> fabric [[texture(0)]],
                                 sampler fabricSampler [[sampler(0)]]) {
    float3 n = normalize(in.normal);
    if (n.z < 0.0) n = -n;   // the cloth is two-sided; always light the face you see

    float3 albedo = fabric.sample(fabricSampler, in.uv).rgb;
    float facing = max(dot(n, normalize(u.lightDirection)), 0.0);
    float rim = pow(1.0 - max(n.z, 0.0), u.sheenPower);   // the viewer looks along +z

    float3 color = albedo * (u.ambient + u.diffuse * facing)
                 + u.sheenColor * (u.sheenStrength * rim);
    return float4(color * in.occlusion, 1.0);
}

// The soft shadow the curtain casts on the desktop beside its edge: a strip of
// black that fades out, drawn before the fabric with alpha blending.
// Must match Renderer.ShadowVertex in Swift.
struct ShadowVertex {
    float2 position;
    float alpha;
};

struct ShadowRaster {
    float4 clipPosition [[position]];
    float alpha;
};

vertex ShadowRaster shadow_vertex(uint vid [[vertex_id]],
                                  const device ShadowVertex *vertices [[buffer(0)]],
                                  constant Uniforms &u [[buffer(1)]]) {
    ShadowRaster out;
    out.clipPosition = toClip(vertices[vid].position, 0.99, u.viewportSize);
    out.alpha = vertices[vid].alpha;
    return out;
}

fragment float4 shadow_fragment(ShadowRaster in [[stage_in]]) {
    float a = in.alpha * in.alpha;          // squared: darkest right at the edge, feathering out
    return float4(0.0, 0.0, 0.0, a);        // premultiplied black
}
