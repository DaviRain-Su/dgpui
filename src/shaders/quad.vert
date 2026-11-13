#version 450

layout(location = 0) in vec2 a_unit;
layout(location = 1) in vec4 i_expanded;
layout(location = 2) in vec4 i_content;
layout(location = 3) in vec4 i_params;
layout(location = 4) in vec4 i_fill;
layout(location = 5) in vec4 i_border;
layout(location = 6) in vec4 i_shadow;

layout(set = 1, binding = 0) uniform Screen {
    vec2 viewport;
    vec2 _pad;
} screen;

layout(location = 0) out vec2 v_px;
layout(location = 1) flat out vec4 v_content;
layout(location = 2) flat out vec4 v_params;
layout(location = 3) flat out vec4 v_fill;
layout(location = 4) flat out vec4 v_border;
layout(location = 5) flat out vec4 v_shadow;

void main() {
    vec2 px = i_expanded.xy + a_unit * i_expanded.zw;
    v_px = px;
    v_content = i_content;
    v_params = i_params;
    v_fill = i_fill;
    v_border = i_border;
    v_shadow = i_shadow;

    vec2 vp = max(screen.viewport, vec2(1.0));
    vec2 ndc = vec2(px.x / vp.x * 2.0 - 1.0, 1.0 - px.y / vp.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
}
