//! 把 DisplayList 里的 quad 用一个 SDF 着色器画出来。
//! 同一裁剪矩形的 quad 放进一个实例缓冲，一次 `SDL_DrawGPUPrimitives`。
//! 不同裁剪不能合成一次绘制：剪刀矩形只有一个，模板缓冲这次没做。
//! `glyph` 不画，等 PR 3 的字形图集。着色器是 SPIR-V；Metal 的 MSL 还没生成。

const std = @import("std");
const c = @import("c");
const math = @import("../math.zig");
const damage = @import("../damage.zig");
const display_list = @import("../display_list.zig");
const renderer = @import("renderer.zig");

const vert_spv = @embedFile("../shaders/quad.vert.spv");
const frag_spv = @embedFile("../shaders/quad.frag.spv");

const max_instances: usize = 128;

const Instance = extern struct {
    expanded: [4]f32,
    content: [4]f32,
    params: [4]f32,
    fill: [4]f32,
    border: [4]f32,
    shadow: [4]f32,
};

const ScreenUniform = extern struct {
    viewport: [2]f32,
    pad: [2]f32 = .{ 0, 0 },
};

const unit_quad = [_]f32{
    0, 0, 1, 0, 1, 1,
    0, 0, 1, 1, 0, 1,
};

pub const QuadRenderer = struct {
    device: *c.SDL_GPUDevice,
    pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    pipeline_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_INVALID,
    vert_shader: ?*c.SDL_GPUShader = null,
    frag_shader: ?*c.SDL_GPUShader = null,
    unit_buffer: ?*c.SDL_GPUBuffer = null,
    instance_buffer: ?*c.SDL_GPUBuffer = null,
    unit_transfer: ?*c.SDL_GPUTransferBuffer = null,
    instance_transfer: ?*c.SDL_GPUTransferBuffer = null,
    scene: ?*c.SDL_GPUTexture = null,
    scene_w: u32 = 0,
    scene_h: u32 = 0,
    scene_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_INVALID,
    scene_needs_clear: bool = true,
    unit_uploaded: bool = false,
    failed: bool = false,

    pub fn deinit(self: *QuadRenderer) void {
        if (self.pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(self.device, p);
        if (self.vert_shader) |s| c.SDL_ReleaseGPUShader(self.device, s);
        if (self.frag_shader) |s| c.SDL_ReleaseGPUShader(self.device, s);
        if (self.unit_buffer) |b| c.SDL_ReleaseGPUBuffer(self.device, b);
        if (self.instance_buffer) |b| c.SDL_ReleaseGPUBuffer(self.device, b);
        if (self.unit_transfer) |t| c.SDL_ReleaseGPUTransferBuffer(self.device, t);
        if (self.instance_transfer) |t| c.SDL_ReleaseGPUTransferBuffer(self.device, t);
        if (self.scene) |tex| c.SDL_ReleaseGPUTexture(self.device, tex);
        self.pipeline = null;
        self.vert_shader = null;
        self.frag_shader = null;
        self.unit_buffer = null;
        self.instance_buffer = null;
        self.unit_transfer = null;
        self.instance_transfer = null;
        self.scene = null;
        self.scene_w = 0;
        self.scene_h = 0;
        self.scene_needs_clear = true;
        self.unit_uploaded = false;
    }

    pub fn paint(
        self: *QuadRenderer,
        cmd: *c.SDL_GPUCommandBuffer,
        window: *c.SDL_Window,
        tex: *c.SDL_GPUTexture,
        pixel_w: u32,
        pixel_h: u32,
        params: renderer.FrameParams,
    ) void {
        const plan = damage.presentPlan(
            params.damage_rect,
            params.logical_size.width,
            params.logical_size.height,
            params.scale_factor,
        );
        var draw: ?display_list.DrawPlan = null;
        if (params.display_list) |list| {
            draw = list.buildDraw() catch |err| blk: {
                std.log.err("display list build failed: {s}", .{@errorName(err)});
                break :blk null;
            };
        }
        const format = c.SDL_GetGPUSwapchainTextureFormat(self.device, window);
        if (!self.failed and (self.pipeline == null or self.pipeline_format != format)) {
            self.ensurePipeline(format);
        }
        if (draw != null and self.pipeline != null) {
            self.upload(cmd, draw.?, params.scale_factor) catch |err| {
                std.log.err("quad upload failed: {s}", .{@errorName(err)});
                draw = null;
            };
        }

        const use_scene = self.ensureScene(format, pixel_w, pixel_h);
        // 交换链纹理是只写的，不能 LOAD 上一帧。局部更新画在我们自己的纹理上，再整张贴到交换链。
        const gpu_plan = if (use_scene) plan else damage.presentPlan(null, params.logical_size.width, params.logical_size.height, params.scale_factor);
        const clear_full = gpu_plan.clear_full or self.scene_needs_clear or !use_scene;
        if (use_scene) self.scene_needs_clear = false;

        var color_target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        color_target.texture = if (use_scene) self.scene.? else tex;
        color_target.clear_color = .{
            .r = params.clear_color.r,
            .g = params.clear_color.g,
            .b = params.clear_color.b,
            .a = params.clear_color.a,
        };
        color_target.load_op = if (clear_full) c.SDL_GPU_LOADOP_CLEAR else c.SDL_GPU_LOADOP_LOAD;
        color_target.store_op = c.SDL_GPU_STOREOP_STORE;
        color_target.cycle = false;

        const pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null) orelse return;
        self.drawQuads(cmd, pass, pixel_w, pixel_h, params.scale_factor, gpu_plan, draw);
        c.SDL_EndGPURenderPass(pass);

        if (use_scene) self.blitScene(cmd, tex, pixel_w, pixel_h);
    }

    fn drawQuads(
        self: *QuadRenderer,
        cmd: *c.SDL_GPUCommandBuffer,
        pass: *c.SDL_GPURenderPass,
        pixel_w: u32,
        pixel_h: u32,
        scale: f32,
        plan: damage.PresentPlan,
        draw: ?display_list.DrawPlan,
    ) void {
        const drawable = draw orelse return;
        const pipeline = self.pipeline orelse return;
        const unit = self.unit_buffer orelse return;
        const instances = self.instance_buffer orelse return;
        if (drawable.quads.len == 0 or plan.scissor.width <= 0 or plan.scissor.height <= 0) return;

        c.SDL_BindGPUGraphicsPipeline(pass, pipeline);
        const screen = ScreenUniform{ .viewport = .{ @floatFromInt(pixel_w), @floatFromInt(pixel_h) } };
        c.SDL_PushGPUVertexUniformData(cmd, 0, &screen, @sizeOf(ScreenUniform));
        var viewport = std.mem.zeroes(c.SDL_GPUViewport);
        viewport.w = @floatFromInt(pixel_w);
        viewport.h = @floatFromInt(pixel_h);
        viewport.max_depth = 1;
        c.SDL_SetGPUViewport(pass, &viewport);

        const bindings = [_]c.SDL_GPUBufferBinding{
            .{ .buffer = unit, .offset = 0 },
            .{ .buffer = instances, .offset = 0 },
        };
        c.SDL_BindGPUVertexBuffers(pass, 0, &bindings, 2);

        const limit = @min(drawable.quads.len, max_instances);
        if (drawable.quads.len > max_instances) {
            std.log.err("quad batch truncated to {d}", .{max_instances});
        }
        for (drawable.batches) |batch| {
            if (batch.count == 0 or batch.first >= limit) continue;
            const count = @min(batch.count, limit - batch.first);
            const scissor = batchScissor(plan.scissor, batch.clip, scale);
            if (scissor.width <= 0 or scissor.height <= 0) continue;
            var rect = std.mem.zeroes(c.SDL_Rect);
            rect.x = @intFromFloat(@floor(scissor.x));
            rect.y = @intFromFloat(@floor(scissor.y));
            rect.w = @intFromFloat(@max(0, @ceil(scissor.width)));
            rect.h = @intFromFloat(@max(0, @ceil(scissor.height)));
            if (rect.w <= 0 or rect.h <= 0) continue;
            c.SDL_SetGPUScissor(pass, &rect);
            c.SDL_DrawGPUPrimitives(pass, 6, @intCast(count), 0, @intCast(batch.first));
        }
    }

    fn ensureScene(self: *QuadRenderer, format: c.SDL_GPUTextureFormat, width: u32, height: u32) bool {
        if (width == 0 or height == 0) return false;
        if (self.scene) |tex| {
            if (self.scene_w == width and self.scene_h == height and self.scene_format == format) return true;
            c.SDL_ReleaseGPUTexture(self.device, tex);
            self.scene = null;
        }
        var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        info.type = c.SDL_GPU_TEXTURETYPE_2D;
        info.format = format;
        info.usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        info.width = width;
        info.height = height;
        info.layer_count_or_depth = 1;
        info.num_levels = 1;
        info.sample_count = c.SDL_GPU_SAMPLECOUNT_1;
        self.scene = c.SDL_CreateGPUTexture(self.device, &info);
        if (self.scene == null) {
            std.log.err("SDL_CreateGPUTexture for scene failed: {s}", .{c.SDL_GetError()});
            return false;
        }
        self.scene_w = width;
        self.scene_h = height;
        self.scene_format = format;
        self.scene_needs_clear = true;
        return true;
    }

    fn blitScene(self: *QuadRenderer, cmd: *c.SDL_GPUCommandBuffer, swapchain: *c.SDL_GPUTexture, width: u32, height: u32) void {
        const src = self.scene orelse return;
        var info = std.mem.zeroes(c.SDL_GPUBlitInfo);
        info.source.texture = src;
        info.source.w = width;
        info.source.h = height;
        info.destination.texture = swapchain;
        info.destination.w = width;
        info.destination.h = height;
        info.load_op = c.SDL_GPU_LOADOP_DONT_CARE;
        info.filter = c.SDL_GPU_FILTER_NEAREST;
        info.flip_mode = c.SDL_FLIP_NONE;
        info.cycle = false;
        c.SDL_BlitGPUTexture(cmd, &info);
    }

    fn ensurePipeline(self: *QuadRenderer, format: c.SDL_GPUTextureFormat) void {
        const device = self.device;
        self.deinit();
        self.device = device;
        self.failed = false;
        const formats = c.SDL_GetGPUShaderFormats(self.device);
        if (formats & c.SDL_GPU_SHADERFORMAT_SPIRV == 0) {
            std.log.err("SDL_GPU device has no SPIR-V shader format; quads stay unshaded", .{});
            self.failed = true;
            return;
        }
        self.vert_shader = createShader(self.device, vert_spv, c.SDL_GPU_SHADERSTAGE_VERTEX, 1);
        self.frag_shader = createShader(self.device, frag_spv, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 0);
        if (self.vert_shader == null or self.frag_shader == null) {
            self.failed = true;
            return;
        }
        self.unit_buffer = makeBuffer(self.device, @sizeOf(@TypeOf(unit_quad)));
        self.instance_buffer = makeBuffer(self.device, max_instances * @sizeOf(Instance));
        self.unit_transfer = makeTransfer(self.device, @sizeOf(@TypeOf(unit_quad)));
        self.instance_transfer = makeTransfer(self.device, max_instances * @sizeOf(Instance));
        if (self.unit_buffer == null or self.instance_buffer == null or self.unit_transfer == null or self.instance_transfer == null) {
            self.failed = true;
            return;
        }

        var blend = std.mem.zeroes(c.SDL_GPUColorTargetBlendState);
        blend.enable_blend = true;
        blend.src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE;
        blend.dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        blend.color_blend_op = c.SDL_GPU_BLENDOP_ADD;
        blend.src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE;
        blend.dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        blend.alpha_blend_op = c.SDL_GPU_BLENDOP_ADD;

        var color_desc = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
        color_desc.format = format;
        color_desc.blend_state = blend;

        var buffers = [_]c.SDL_GPUVertexBufferDescription{
            .{ .slot = 0, .pitch = 8, .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
            .{ .slot = 1, .pitch = @sizeOf(Instance), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_INSTANCE, .instance_step_rate = 0 },
        };
        var attrs = [_]c.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 },
            .{ .location = 1, .buffer_slot = 1, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = 0 },
            .{ .location = 2, .buffer_slot = 1, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = 16 },
            .{ .location = 3, .buffer_slot = 1, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = 32 },
            .{ .location = 4, .buffer_slot = 1, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = 48 },
            .{ .location = 5, .buffer_slot = 1, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = 64 },
            .{ .location = 6, .buffer_slot = 1, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = 80 },
        };
        var info = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
        info.vertex_shader = self.vert_shader;
        info.fragment_shader = self.frag_shader;
        info.vertex_input_state.vertex_buffer_descriptions = &buffers;
        info.vertex_input_state.num_vertex_buffers = 2;
        info.vertex_input_state.vertex_attributes = &attrs;
        info.vertex_input_state.num_vertex_attributes = attrs.len;
        info.primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        info.rasterizer_state.fill_mode = c.SDL_GPU_FILLMODE_FILL;
        info.rasterizer_state.cull_mode = c.SDL_GPU_CULLMODE_NONE;
        info.target_info.color_target_descriptions = &color_desc;
        info.target_info.num_color_targets = 1;
        info.multisample_state.sample_count = c.SDL_GPU_SAMPLECOUNT_1;
        self.pipeline = c.SDL_CreateGPUGraphicsPipeline(self.device, &info);
        if (self.pipeline == null) {
            std.log.err("SDL_CreateGPUGraphicsPipeline failed: {s}", .{c.SDL_GetError()});
            self.failed = true;
            return;
        }
        self.pipeline_format = format;
        std.log.info("SDF quad pipeline ready", .{});
    }

    fn upload(self: *QuadRenderer, cmd: *c.SDL_GPUCommandBuffer, plan: display_list.DrawPlan, scale: f32) !void {
        if (!self.unit_uploaded) {
            const quad_bytes = std.mem.sliceAsBytes(&unit_quad);
            if (!uploadBytes(cmd, self.device, self.unit_transfer.?, self.unit_buffer.?, quad_bytes.ptr, @intCast(quad_bytes.len))) {
                return error.UploadFailed;
            }
            self.unit_uploaded = true;
        }
        const n = @min(plan.quads.len, max_instances);
        var instances: [max_instances]Instance = undefined;
        for (plan.quads[0..n], 0..) |quad, i| {
            instances[i] = instanceFromQuad(quad, scale);
        }
        const bytes = std.mem.sliceAsBytes(instances[0..n]);
        if (!uploadBytes(cmd, self.device, self.instance_transfer.?, self.instance_buffer.?, bytes.ptr, @intCast(bytes.len))) {
            return error.UploadFailed;
        }
    }
};

fn instanceFromQuad(quad: display_list.Quad, scale: f32) Instance {
    const safe: f32 = if (scale > 0) scale else 1;
    const pad = @max(quad.shadow_blur, 1);
    const expanded = quad.rect.inflate(pad).toPhysical(safe);
    const content = quad.rect.toPhysical(safe);
    return .{
        .expanded = .{ expanded.x, expanded.y, expanded.width, expanded.height },
        .content = .{ content.x, content.y, content.width, content.height },
        .params = .{ quad.radius * safe, quad.border_width * safe, quad.shadow_blur * safe, 0 },
        .fill = color4(quad.fill),
        .border = color4(quad.border_color),
        .shadow = color4(quad.shadow_color),
    };
}

fn color4(color: math.Color) [4]f32 {
    return .{ color.r, color.g, color.b, color.a };
}

fn batchScissor(base: math.Rect, clip: ?math.Rect, scale: f32) math.Rect {
    const safe: f32 = if (scale > 0) scale else 1;
    const extra = clip orelse return base;
    return base.intersect(snapOut(extra.toPhysical(safe)));
}

fn snapOut(rect: math.Rect) math.Rect {
    const x0 = @floor(rect.x);
    const y0 = @floor(rect.y);
    const x1 = @ceil(rect.right());
    const y1 = @ceil(rect.bottom());
    return .{ .x = x0, .y = y0, .width = @max(0, x1 - x0), .height = @max(0, y1 - y0) };
}

fn createShader(device: *c.SDL_GPUDevice, code: []const u8, stage: c.SDL_GPUShaderStage, uniforms: u32) ?*c.SDL_GPUShader {
    var info = std.mem.zeroes(c.SDL_GPUShaderCreateInfo);
    info.code_size = code.len;
    info.code = code.ptr;
    info.entrypoint = "main";
    info.format = c.SDL_GPU_SHADERFORMAT_SPIRV;
    info.stage = stage;
    info.num_uniform_buffers = uniforms;
    const shader = c.SDL_CreateGPUShader(device, &info);
    if (shader == null) std.log.err("SDL_CreateGPUShader failed: {s}", .{c.SDL_GetError()});
    return shader;
}

fn makeBuffer(device: *c.SDL_GPUDevice, size: usize) ?*c.SDL_GPUBuffer {
    var info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
    info.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX;
    info.size = @intCast(size);
    return c.SDL_CreateGPUBuffer(device, &info);
}

fn makeTransfer(device: *c.SDL_GPUDevice, size: usize) ?*c.SDL_GPUTransferBuffer {
    var info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    info.size = @intCast(size);
    return c.SDL_CreateGPUTransferBuffer(device, &info);
}

fn uploadBytes(cmd: *c.SDL_GPUCommandBuffer, device: *c.SDL_GPUDevice, transfer: *c.SDL_GPUTransferBuffer, buffer: *c.SDL_GPUBuffer, bytes: [*]const u8, len: u32) bool {
    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, true) orelse return false;
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..len], bytes[0..len]);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);
    const copy = c.SDL_BeginGPUCopyPass(cmd) orelse return false;
    var source = std.mem.zeroes(c.SDL_GPUTransferBufferLocation);
    source.transfer_buffer = transfer;
    var dest = std.mem.zeroes(c.SDL_GPUBufferRegion);
    dest.buffer = buffer;
    dest.size = len;
    c.SDL_UploadToGPUBuffer(copy, &source, &dest, true);
    c.SDL_EndGPUCopyPass(copy);
    return true;
}
