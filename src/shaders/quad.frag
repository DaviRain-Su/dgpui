#version 450

layout(location = 0) in vec2 v_px;
layout(location = 1) flat in vec4 v_content;
layout(location = 2) flat in vec4 v_params;
layout(location = 3) flat in vec4 v_fill;
layout(location = 4) flat in vec4 v_border;
layout(location = 5) flat in vec4 v_shadow;

layout(location = 0) out vec4 out_color;

float sdRoundedBox(vec2 p, vec2 half_size, float radius) {
    float r = clamp(radius, 0.0, min(half_size.x, half_size.y));
    vec2 q = abs(p) - half_size + vec2(r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    vec2 half_size = max(v_content.zw * 0.5, vec2(0.0));
    vec2 center = v_content.xy + half_size;
    float radius = v_params.x;
    float border = max(v_params.y, 0.0);
    float blur = max(v_params.z, 0.0);
    float d = sdRoundedBox(v_px - center, half_size, radius);

    float fill_a = (1.0 - smoothstep(-0.75, 0.75, d + border)) * v_fill.a;
    float shape_a = (1.0 - smoothstep(-0.75, 0.75, d));
    float border_a = max(shape_a - (1.0 - smoothstep(-0.75, 0.75, d + border)), 0.0) * v_border.a;
    float shadow_a = (1.0 - shape_a) * (1.0 - smoothstep(0.0, max(blur, 0.001), d)) * v_shadow.a;

    float cover = clamp(fill_a + border_a, 0.0, 1.0);
    vec3 rgb = v_shadow.rgb * shadow_a * (1.0 - cover) + v_fill.rgb * fill_a + v_border.rgb * border_a;
    float a = shadow_a * (1.0 - cover) + cover;
    if (a <= 0.001) discard;
    out_color = vec4(rgb, a);
}
