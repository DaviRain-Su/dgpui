#include <metal_stdlib>
using namespace metal;

struct GlyphInstance {
    float4 bounds; // x, y, w, h (logical px)
    float4 uv;     // u, v, w, h (normalized)
    float4 color;  // r, g, b, a
};

struct FrameUniforms {
    float viewport_w;
    float viewport_h;
    float scale_factor;
    uint base_instance;
};

struct VsOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex VsOut glyph_vs(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant FrameUniforms &u [[buffer(0)]],
    const device GlyphInstance *glyphs [[buffer(1)]])
{
    const GlyphInstance g = glyphs[u.base_instance + iid];

    // 两个三角形：0,1,2, 0,2,3
    float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(1, 1),
        float2(0, 0), float2(1, 1), float2(0, 1)
    };
    float2 corner = corners[vid];

    float2 pos = g.bounds.xy + corner * g.bounds.zw;
    float2 uv = g.uv.xy + corner * g.uv.zw;

    // 逻辑像素 -> Metal NDC（Y 向上）
    float2 ndc;
    ndc.x = (pos.x / u.viewport_w) * 2.0 - 1.0;
    ndc.y = 1.0 - (pos.y / u.viewport_h) * 2.0;

    VsOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = uv;
    out.color = g.color;
    return out;
}

fragment float4 glyph_fs(
    VsOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlas_sampler [[sampler(0)]])
{
    float alpha = atlas.sample(atlas_sampler, in.uv).r;
    return float4(in.color.rgb, in.color.a * alpha);
}
