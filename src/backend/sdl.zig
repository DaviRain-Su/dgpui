//! SDL3 + SDL_GPU 桌面端后端（macOS 自动走 Metal）
//!
//! 关键职责：
//! 1. 创建支持高分屏（Retina）和缩放的原生窗口
//! 2. 用 SDL_WaitEvent 实现“无事件时 0% CPU 休眠”
//! 3. 将 SDL 事件翻译为框架统一的 platform.Event（逻辑坐标）
//! 4. 初始化 SDL_GPU 设备并绑定窗口交换链（Swapchain），完成清屏提交

const std = @import("std");
const c = @import("c");
const math = @import("../math.zig");
const platform = @import("platform.zig");
const renderer = @import("renderer.zig");

pub const SdlError = error{
    InitFailed,
    WindowCreateFailed,
    GpuDeviceCreateFailed,
    ClaimWindowFailed,
    TextInputStartFailed,
    CommandBufferFailed,
};

pub const SdlBackend = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    gpu_device: *c.SDL_GPUDevice,
    redraw_event_type: u32,
    cursor_arrow: ?*c.SDL_Cursor,
    cursor_pointer: ?*c.SDL_Cursor,
    cursor_text: ?*c.SDL_Cursor,

    pub fn init(allocator: std.mem.Allocator, title: [*:0]const u8, width: i32, height: i32) !*SdlBackend {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
            return SdlError.InitFailed;
        }
        errdefer c.SDL_Quit();

        const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        const window = c.SDL_CreateWindow(title, width, height, flags) orelse {
            std.log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
            return SdlError.WindowCreateFailed;
        };
        errdefer c.SDL_DestroyWindow(window);

        // 在 macOS 下，SDL_GPU 会优先选择 Metal；也同时声明 SPIR-V/MSL 以便跨平台
        const gpu_device = c.SDL_CreateGPUDevice(
            c.SDL_GPU_SHADERFORMAT_MSL | c.SDL_GPU_SHADERFORMAT_SPIRV,
            true,
            null,
        ) orelse {
            std.log.err("SDL_CreateGPUDevice failed: {s}", .{c.SDL_GetError()});
            return SdlError.GpuDeviceCreateFailed;
        };
        errdefer c.SDL_DestroyGPUDevice(gpu_device);

        if (!c.SDL_ClaimWindowForGPUDevice(gpu_device, window)) {
            std.log.err("SDL_ClaimWindowForGPUDevice failed: {s}", .{c.SDL_GetError()});
            return SdlError.ClaimWindowFailed;
        }

        _ = c.SDL_StartTextInput(window);

        const redraw_event_type = c.SDL_RegisterEvents(1);

        const self = try allocator.create(SdlBackend);
        self.* = .{
            .allocator = allocator,
            .window = window,
            .gpu_device = gpu_device,
            .redraw_event_type = redraw_event_type,
            .cursor_arrow = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT),
            .cursor_pointer = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER),
            .cursor_text = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_TEXT),
        };
        return self;
    }

    pub fn deinitSelf(self: *SdlBackend) void {
        if (self.cursor_arrow) |cur| c.SDL_DestroyCursor(cur);
        if (self.cursor_pointer) |cur| c.SDL_DestroyCursor(cur);
        if (self.cursor_text) |cur| c.SDL_DestroyCursor(cur);
        c.SDL_ReleaseWindowFromGPUDevice(self.gpu_device, self.window);
        c.SDL_DestroyGPUDevice(self.gpu_device);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        self.allocator.destroy(self);
    }

    pub fn platformBackend(self: *SdlBackend) platform.PlatformBackend {
        return .{
            .ptr = self,
            .vtable = &platform_vtable,
        };
    }

    pub fn rendererBackend(self: *SdlBackend) renderer.RendererBackend {
        return .{
            .ptr = self,
            .vtable = &renderer_vtable,
        };
    }

    fn queryMetrics(self: *const SdlBackend) platform.WindowMetrics {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(self.window, &w, &h);
        var scale = c.SDL_GetWindowDisplayScale(self.window);
        if (scale <= 0) scale = 1.0;
        return .{
            .logical_width = @floatFromInt(@max(1, w)),
            .logical_height = @floatFromInt(@max(1, h)),
            .scale_factor = scale,
        };
    }

    fn translateSdlEvent(self: *SdlBackend, raw: *const c.SDL_Event) ?platform.Event {
        if (raw.type == self.redraw_event_type) {
            return .redraw_requested;
        }
        return switch (raw.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => .quit,
            c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => .{
                .resized = self.queryMetrics(),
            },
            c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED => .{
                .scale_changed = self.queryMetrics(),
            },
            c.SDL_EVENT_WINDOW_EXPOSED => .redraw_requested,
            c.SDL_EVENT_MOUSE_MOTION => .{
                .mouse_move = .{ .x = raw.motion.x, .y = raw.motion.y },
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => .{
                .mouse_down = .{
                    .pos = .{ .x = raw.button.x, .y = raw.button.y },
                    .button = translateButton(raw.button.button),
                    .clicks = raw.button.clicks,
                },
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => .{
                .mouse_up = .{
                    .pos = .{ .x = raw.button.x, .y = raw.button.y },
                    .button = translateButton(raw.button.button),
                },
            },
            c.SDL_EVENT_MOUSE_WHEEL => .{
                .scroll = .{
                    .pos = .{ .x = raw.wheel.mouse_x, .y = raw.wheel.mouse_y },
                    .dx = raw.wheel.x,
                    .dy = raw.wheel.y,
                },
            },
            c.SDL_EVENT_KEY_DOWN => .{
                .key_down = .{
                    .key = translateKey(raw.key.key),
                    .repeat = raw.key.repeat,
                },
            },
            c.SDL_EVENT_TEXT_INPUT => blk: {
                const cstr: [*:0]const u8 = raw.text.text orelse break :blk null;
                const slice = std.mem.span(cstr);
                var ev_text: @FieldType(platform.Event, "text_input") = .{
                    .utf8 = @splat(0),
                    .len = 0,
                };
                const copy_len = @min(slice.len, ev_text.utf8.len);
                @memcpy(ev_text.utf8[0..copy_len], slice[0..copy_len]);
                ev_text.len = @intCast(copy_len);
                break :blk .{ .text_input = ev_text };
            },
            else => null,
        };
    }

    fn translateButton(btn: u8) platform.MouseButton {
        return switch (btn) {
            c.SDL_BUTTON_LEFT => .left,
            c.SDL_BUTTON_MIDDLE => .middle,
            c.SDL_BUTTON_RIGHT => .right,
            else => .other,
        };
    }

    fn translateKey(key: c.SDL_Keycode) platform.KeyCode {
        return switch (key) {
            c.SDLK_RETURN, c.SDLK_KP_ENTER => .enter,
            c.SDLK_BACKSPACE => .backspace,
            c.SDLK_TAB => .tab,
            c.SDLK_ESCAPE => .escape,
            c.SDLK_SPACE => .space,
            c.SDLK_UP => .up,
            c.SDLK_DOWN => .down,
            c.SDLK_LEFT => .left,
            c.SDLK_RIGHT => .right,
            else => .character,
        };
    }

    const platform_vtable: platform.PlatformBackend.VTable = .{
        .waitEvent = struct {
            fn call(ptr: *anyopaque) ?platform.Event {
                const self: *SdlBackend = @ptrCast(@alignCast(ptr));
                var raw: c.SDL_Event = undefined;
                while (c.SDL_WaitEvent(&raw)) {
                    if (self.translateSdlEvent(&raw)) |ev| return ev;
                }
                return null;
            }
        }.call,
        .pollEvent = struct {
            fn call(ptr: *anyopaque) ?platform.Event {
                const self: *SdlBackend = @ptrCast(@alignCast(ptr));
                var raw: c.SDL_Event = undefined;
                while (c.SDL_PollEvent(&raw)) {
                    if (self.translateSdlEvent(&raw)) |ev| return ev;
                }
                return null;
            }
        }.call,
        .metrics = struct {
            fn call(ptr: *anyopaque) platform.WindowMetrics {
                const self: *SdlBackend = @ptrCast(@alignCast(ptr));
                return self.queryMetrics();
            }
        }.call,
        .requestRedraw = struct {
            fn call(ptr: *anyopaque) void {
                const self: *SdlBackend = @ptrCast(@alignCast(ptr));
                if (self.redraw_event_type != 0) {
                    var ev = std.mem.zeroes(c.SDL_Event);
                    ev.type = self.redraw_event_type;
                    _ = c.SDL_PushEvent(&ev);
                }
            }
        }.call,
        .setCursor = struct {
            fn call(ptr: *anyopaque, shape: platform.CursorShape) void {
                const self: *SdlBackend = @ptrCast(@alignCast(ptr));
                const cur = switch (shape) {
                    .arrow => self.cursor_arrow,
                    .pointer => self.cursor_pointer,
                    .text => self.cursor_text,
                };
                if (cur) |cursor| {
                    _ = c.SDL_SetCursor(cursor);
                }
            }
        }.call,
        .deinit = struct {
            fn call(ptr: *anyopaque) void {
                const self: *SdlBackend = @ptrCast(@alignCast(ptr));
                self.deinitSelf();
            }
        }.call,
    };

    const renderer_vtable: renderer.RendererBackend.VTable = .{
        .renderFrame = struct {
            fn call(ptr: *anyopaque, params: renderer.FrameParams) anyerror!void {
                const self: *SdlBackend = @ptrCast(@alignCast(ptr));
                const cmd_buf = c.SDL_AcquireGPUCommandBuffer(self.gpu_device) orelse {
                    return SdlError.CommandBufferFailed;
                };

                var swapchain_tex: ?*c.SDL_GPUTexture = null;
                var w: u32 = 0;
                var h: u32 = 0;
                if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(
                    cmd_buf,
                    self.window,
                    &swapchain_tex,
                    &w,
                    &h,
                )) {
                    _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
                    return;
                }

                if (swapchain_tex) |tex| {
                    var color_target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
                    color_target.texture = tex;
                    color_target.clear_color = .{
                        .r = params.clear_color.r,
                        .g = params.clear_color.g,
                        .b = params.clear_color.b,
                        .a = params.clear_color.a,
                    };
                    color_target.load_op = c.SDL_GPU_LOADOP_CLEAR;
                    color_target.store_op = c.SDL_GPU_STOREOP_STORE;

                    const pass = c.SDL_BeginGPURenderPass(cmd_buf, &color_target, 1, null);
                    if (pass) |p| {
                        c.SDL_EndGPURenderPass(p);
                    }
                }

                _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
            }
        }.call,
        .resize = struct {
            fn call(_: *anyopaque, _: u32, _: u32) void {
                // SDL_GPU 会在 WaitAndAcquireGPUSwapchainTexture 时自动适配窗口像素大小
            }
        }.call,
        .deinit = struct {
            fn call(_: *anyopaque) void {}
        }.call,
    };
};
