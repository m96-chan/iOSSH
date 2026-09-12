#include <metal_stdlib>
using namespace metal;

struct Instance {
    float4 rect;
    float4 uv;
    float4 color;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex VertexOut terminalVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                               const device Instance *instances [[buffer(0)]],
                               constant float2 &viewport [[buffer(1)]]) {
    const float2 corners[6] = {float2(0, 0), float2(1, 0), float2(0, 1),
                              float2(0, 1), float2(1, 0), float2(1, 1)};
    Instance item = instances[instanceID];
    float2 corner = corners[vertexID];
    float2 pixel = item.rect.xy + corner * item.rect.zw;
    VertexOut out;
    out.position = float4(pixel.x / viewport.x * 2 - 1, 1 - pixel.y / viewport.y * 2, 0, 1);
    out.uv = item.uv.xy + corner * item.uv.zw;
    out.color = item.color;
    return out;
}

fragment float4 terminalSolid(VertexOut in [[stage_in]]) { return in.color; }

fragment float4 terminalGlyph(VertexOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler sampleFilter(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);
    float4 texel = atlas.sample(sampleFilter, in.uv);
    // The atlas stores straight RGBA. White glyphs are tinted by the cell color;
    // color emoji retain their rasterized color when the instance alpha is negative.
    if (in.color.a < 0) return float4(texel.rgb * texel.a, texel.a);
    return float4(in.color.rgb * texel.a, in.color.a * texel.a);
}

fragment float4 terminalImage(VertexOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
    constexpr sampler sampleFilter(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 texel = image.sample(sampleFilter, in.uv);
    return float4(texel.rgb * texel.a, texel.a);
}
