#include <metal_stdlib>
using namespace metal;

// 必须与 src/scene.zig 的 QuadInstance 内存布局 100% 一致（6 个 float4 = 96 字节）
struct QuadInstance {
    float4 bounds;        // (x, y, width, height) 逻辑像素
    float4 background;    // (r, g, b, a)
    float4 border_color;  // (r, g, b, a)
    float4 shadow_color;  // (r, g, b, a)
    float4 style;         // (corner_radius, border_width, shadow_blur, _pad)
    float4 shadow_offset; // (ox, oy, 0, 0)
};

// SDL_GPU MSL 绑定规则：Uniform Buffer 在 [[buffer(0)]]，Storage Buffer 紧随其后在 [[buffer(1)]]
struct FrameUniforms {
    float2 viewport_logical;
    float scale_factor;
    uint base_instance;
};

struct VertexOut {
    float4 position [[position]];
    float2 local_pos;    // 相对于矩形中心的逻辑坐标
    float2 half_size;    // 矩形半宽高
    float4 background;
    float4 border_color;
    float4 shadow_color;
    float corner_radius;
    float border_width;
    float shadow_blur;
    float2 shadow_offset;
};

// Inigo Quilez 圆角矩形有向距离场（SDF）：
// 返回值 < 0 表示像素在圆角矩形内部，= 0 在边界上，> 0 在外部
static float sdfRoundedBox(float2 p, float2 half_size, float radius) {
    float r = clamp(radius, 0.0f, min(half_size.x, half_size.y));
    float2 q = abs(p) - half_size + float2(r);
    return length(max(q, float2(0.0f))) + min(max(q.x, q.y), 0.0f) - r;
}

vertex VertexOut quad_vs(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant FrameUniforms& u [[buffer(0)]],
    device const QuadInstance* quads [[buffer(1)]]
) {
    // 用 6 个顶点拼成 2 个三角形的单位矩形（0..1）
    constexpr float2 corners[6] = {
        float2(0.0f, 0.0f),
        float2(1.0f, 0.0f),
        float2(0.0f, 1.0f),
        float2(1.0f, 0.0f),
        float2(1.0f, 1.0f),
        float2(0.0f, 1.0f)
    };

    QuadInstance inst = quads[u.base_instance + instance_id];
    float2 unit = corners[vertex_id];

    float2 box_pos = inst.bounds.xy;
    float2 box_size = inst.bounds.zw;
    float2 half_size = box_size * 0.5f;
    float2 center = box_pos + half_size;

    float shadow_blur = inst.style.z;
    float2 shadow_off = inst.shadow_offset.xy;
    float pad = (inst.shadow_color.a > 0.0f && shadow_blur > 0.0f)
        ? (shadow_blur * 2.0f + max(abs(shadow_off.x), abs(shadow_off.y)))
        : 1.0f;

    float2 expanded_pos = box_pos - float2(pad);
    float2 expanded_size = box_size + float2(pad * 2.0f);
    float2 world_pos = expanded_pos + unit * expanded_size;

    // 逻辑坐标转 Metal NDC（左上角 (-1, +1) -> 右下角 (+1, -1)）
    float2 ndc = float2(
        (world_pos.x / u.viewport_logical.x) * 2.0f - 1.0f,
        1.0f - (world_pos.y / u.viewport_logical.y) * 2.0f
    );

    VertexOut out;
    out.position = float4(ndc, 0.0f, 1.0f);
    out.local_pos = world_pos - center;
    out.half_size = half_size;
    out.background = inst.background;
    out.border_color = inst.border_color;
    out.shadow_color = inst.shadow_color;
    out.corner_radius = inst.style.x;
    out.border_width = inst.style.y;
    out.shadow_blur = shadow_blur;
    out.shadow_offset = shadow_off;
    return out;
}

fragment float4 quad_fs(VertexOut in [[stage_in]]) {
    // 1 个物理像素对应的逻辑抗锯齿宽度
    float aa = max(fwidth(in.local_pos.x), 0.5f);

    float d = sdfRoundedBox(in.local_pos, in.half_size, in.corner_radius);

    // 外轮廓遮罩（带 1px 抗锯齿平滑）
    float box_alpha = 1.0f - smoothstep(-aa, aa, d);

    // 填充色与边框色混合：距离边界小于 border_width 时显现边框
    float4 box_col = in.background;
    if (in.border_width > 0.0f && in.border_color.a > 0.0f) {
        float border_t = smoothstep(-in.border_width - aa, -in.border_width + aa, d);
        box_col = mix(in.background, in.border_color, border_t);
    }
    float4 fg = float4(box_col.rgb, box_col.a * box_alpha);

    // 矩形外部的柔和投影
    float4 bg_shadow = float4(0.0f);
    if (in.shadow_color.a > 0.0f && in.shadow_blur > 0.0f) {
        float sd = sdfRoundedBox(in.local_pos - in.shadow_offset, in.half_size, in.corner_radius);
        float shadow_t = 1.0f - smoothstep(-in.shadow_blur * 0.25f, in.shadow_blur * 1.5f, sd);
        // 指数衰减让阴影边缘更自然
        shadow_t = shadow_t * shadow_t;
        bg_shadow = float4(in.shadow_color.rgb, in.shadow_color.a * shadow_t);
    }

    // Porter-Duff Source-Over：把矩形本体叠在阴影上面
    float out_a = fg.a + bg_shadow.a * (1.0f - fg.a);
    if (out_a <= 0.0001f) {
        return float4(0.0f);
    }
    float3 out_rgb = (fg.rgb * fg.a + bg_shadow.rgb * bg_shadow.a * (1.0f - fg.a)) / out_a;
    return float4(out_rgb, out_a);
}
