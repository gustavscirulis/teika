#include <metal_stdlib>
using namespace metal;

struct GPUParticle {
    float2 position;
    float size;
    float brightness;
};

struct Uniforms {
    float4 params;
    float4 color;
};

struct VertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float brightness;
};

vertex VertexOut particle_vertex(uint vid [[vertex_id]],
                                 const device GPUParticle *particles [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]]) {
    float level = u.params.x;
    float expand = u.params.y;
    float aspect = u.params.z;

    GPUParticle p = particles[vid];
    VertexOut out;
    float2 pos = p.position;
    if (aspect < 1.0) {
        pos.y *= aspect;
    } else {
        pos.x /= max(aspect, 0.0001);
    }
    out.position = float4(pos, 0.0, 1.0);
    out.pointSize = clamp(p.size * (1.0 + level * expand), 1.0, 64.0);
    out.brightness = p.brightness;
    return out;
}

fragment float4 particle_fragment(VertexOut in [[stage_in]],
                                  float2 pc [[point_coord]],
                                  constant Uniforms &u [[buffer(0)]]) {
    float2 uv = pc * 2.0 - 1.0;
    float r2 = dot(uv, uv);
    if (r2 > 1.0) {
        discard_fragment();
    }
    float falloff = exp(-r2 * u.params.w);
    float a = falloff * in.brightness;
    return float4(u.color.rgb * a, a);
}

struct GlowUniforms {
    float4 params;
    float4 params2;
    float4 color;
};

struct GlowVertexOut {
    float4 position [[position]];
    float2 design;
};

vertex GlowVertexOut glow_vertex(uint vid [[vertex_id]],
                                 constant GlowUniforms &u [[buffer(2)]]) {
    float2 ndc = float2(float(vid & 1u), float((vid >> 1) & 1u)) * 2.0 - 1.0;
    float aspect = max(u.params2.z, 0.0001);
    float2 design = aspect < 1.0 ? float2(ndc.x, ndc.y / aspect)
                                 : float2(ndc.x * aspect, ndc.y);
    GlowVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.design = design;
    return out;
}

inline float glow_dither(float2 p) {
    uint2 q = uint2(p);
    uint h = (q.x * 73856093u) ^ (q.y * 19349663u);
    h ^= h >> 13;
    h *= 0x5BD1E995u;
    h ^= h >> 15;
    return float(h & 0xFFFFu) / 65535.0 - 0.5;
}

fragment float4 glow_fragment(GlowVertexOut in [[stage_in]],
                              constant GlowUniforms &u [[buffer(2)]]) {
    float radius = max(u.params.y, 0.001);
    float2 d = in.design - u.params2.xy;
    float rn2 = dot(d, d) / (radius * radius);
    float core = exp(-rn2 * u.params.z);
    float halo = exp(-rn2 * u.params.z * 0.16);
    float a = u.params.x * mix(core, halo, u.params.w);
    a = max(a + glow_dither(in.position.xy) * u.params2.w, 0.0);
    return float4(u.color.rgb * a, a);
}
