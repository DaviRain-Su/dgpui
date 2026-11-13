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

pub const available = true;

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
    /// 最近一次已知的交换链像素尺寸。来源是 `SDL_GetWindowSizeInPixels`，
    /// 绘制时如果 acquire 带回了非 0 的纹理尺寸，会再用那个值覆盖。
    pixel_width: u32,
    pixel_height: u32,
    /// 最近一次 resize / 像素尺寸 / 缩放 / 换屏事件刷新的指标。
    /// 鼠标坐标和 `metrics()` 都读它，避免每个事件再打一轮 SDL 查询，
    /// 也避免还没处理 `scale_changed` 时鼠标已经用了新缩放。
    cached_metrics: platform.WindowMetrics,
    cached_window_w: i32,
    cached_window_h: i32,
    /// TODO(PR2): 只记录，不参与裁剪。本帧仍然整屏 LOADOP_CLEAR。
    last_damage_rect: ?math.Rect,
    /// 超长 TEXT_INPUT 拆分后的待派发事件队列
    pending_events: std.ArrayList(platform.Event) = .empty,
    pending_head: usize = 0,

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
        // `width`/`height` 是期望的逻辑尺寸。Windows/X11 的窗口坐标是像素，
        // 200% 下直接 CreateWindow(800, 600) 归一化后只有 400×300。
        // 这里按「窗口坐标 / 当前逻辑尺寸」把窗口放大，让逻辑尺寸回到请求值。
        adjustWindowToRequestedLogical(window, width, height);

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
        errdefer c.SDL_ReleaseWindowFromGPUDevice(gpu_device, window);

        if (!c.SDL_StartTextInput(window)) {
            std.log.err("SDL_StartTextInput failed: {s}", .{c.SDL_GetError()});
            return SdlError.TextInputStartFailed;
        }

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
            .pixel_width = 1,
            .pixel_height = 1,
            .cached_metrics = .{
                .logical_width = 1,
                .logical_height = 1,
                .scale_factor = 1,
            },
            .cached_window_w = 1,
            .cached_window_h = 1,
            .last_damage_rect = null,
        };
        _ = self.refreshMetrics();
        return self;
    }

    pub fn deinitSelf(self: *SdlBackend) void {
        self.pending_events.deinit(self.allocator);
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

    fn adjustWindowToRequestedLogical(window: *c.SDL_Window, requested_w: i32, requested_h: i32) void {
        if (!c.SDL_SyncWindow(window)) {
            std.log.warn("SDL_SyncWindow before measuring failed: {s}", .{c.SDL_GetError()});
        }
        var win_w: c_int = 0;
        var win_h: c_int = 0;
        if (!c.SDL_GetWindowSize(window, &win_w, &win_h) or win_w <= 0 or win_h <= 0) return;
        var pixel_w: c_int = 0;
        var pixel_h: c_int = 0;
        const pixels_ok = c.SDL_GetWindowSizeInPixels(window, &pixel_w, &pixel_h);
        const metrics = platform.metricsFromPlatformSizes(.{
            .logical_width = win_w,
            .logical_height = win_h,
            .pixel_width = if (pixels_ok) pixel_w else null,
            .pixel_height = if (pixels_ok) pixel_h else null,
            .pixel_density = c.SDL_GetWindowPixelDensity(window),
            .content_scale = c.SDL_GetWindowDisplayScale(window),
        });
        const next = platform.windowSizeForRequestedLogical(
            requested_w,
            requested_h,
            win_w,
            win_h,
            metrics.logical_width,
            metrics.logical_height,
        );
        if (next.w == win_w and next.h == win_h) return;
        std.log.info("requested logical {d}x{d}, window coords {d}x{d} normalized to {d:.0}x{d:.0}; resizing to {d}x{d}", .{
            requested_w,
            requested_h,
            win_w,
            win_h,
            metrics.logical_width,
            metrics.logical_height,
            next.w,
            next.h,
        });
        if (!c.SDL_SetWindowSize(window, next.w, next.h)) {
            std.log.err("SDL_SetWindowSize failed: {s}", .{c.SDL_GetError()});
            return;
        }
        if (!c.SDL_SyncWindow(window)) {
            std.log.warn("SDL_SyncWindow after resize failed: {s}", .{c.SDL_GetError()});
        }
    }

    fn refreshMetrics(self: *SdlBackend) platform.WindowMetrics {
        var win_w: c_int = 0;
        var win_h: c_int = 0;
        if (!c.SDL_GetWindowSize(self.window, &win_w, &win_h) or win_w <= 0 or win_h <= 0) {
            win_w = 1;
            win_h = 1;
        }
        var pixel_w: c_int = 0;
        var pixel_h: c_int = 0;
        const pixels_ok = c.SDL_GetWindowSizeInPixels(self.window, &pixel_w, &pixel_h);
        // 物理像素用 SizeInPixels。
        // 两者都在时，logical = pixel / content_scale，scale_factor 就是 content_scale。
        // pixel_density 另存在 metrics.pixel_density，不再塞进 scale_factor。
        const metrics = platform.metricsFromPlatformSizes(.{
            .logical_width = win_w,
            .logical_height = win_h,
            .pixel_width = if (pixels_ok) pixel_w else null,
            .pixel_height = if (pixels_ok) pixel_h else null,
            .pixel_density = c.SDL_GetWindowPixelDensity(self.window),
            .content_scale = c.SDL_GetWindowDisplayScale(self.window),
        });
        self.cached_window_w = win_w;
        self.cached_window_h = win_h;
        self.cached_metrics = metrics;
        self.pixel_width = metrics.physicalWidth();
        self.pixel_height = metrics.physicalHeight();
        return metrics;
    }

    fn windowToLogical(self: *const SdlBackend, wx: f32, wy: f32) math.Point {
        return platform.windowPointToLogical(
            self.cached_window_w,
            self.cached_window_h,
            self.cached_metrics,
            .{ .x = wx, .y = wy },
        );
    }

    fn popPending(self: *SdlBackend) ?platform.Event {
        if (self.pending_head >= self.pending_events.items.len) {
            return null;
        }
        const ev = self.pending_events.items[self.pending_head];
        self.pending_head += 1;
        if (self.pending_head >= self.pending_events.items.len) {
            self.pending_events.clearRetainingCapacity();
            self.pending_head = 0;
        }
        return ev;
    }

    fn translateSdlEvent(self: *SdlBackend, raw: *const c.SDL_Event) ?platform.Event {
        if (raw.type == self.redraw_event_type) {
            return .redraw_requested;
        }
        return switch (raw.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => .quit,
            // RESIZED 是窗口坐标变化。PIXEL_SIZE_CHANGED 是可绘制像素变化
            // （跨屏、分数倍缩放时两者可以不同时发生）。两种都重新读 SizeInPixels。
            // SDL_GPU 的 Vulkan 后端也是盯着 PIXEL_SIZE_CHANGED 重建交换链。
            c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => .{
                .resized = self.refreshMetrics(),
            },
            c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED, c.SDL_EVENT_WINDOW_DISPLAY_CHANGED => .{
                .scale_changed = self.refreshMetrics(),
            },
            c.SDL_EVENT_WINDOW_EXPOSED => .redraw_requested,
            c.SDL_EVENT_MOUSE_MOTION => .{
                .mouse_move = self.windowToLogical(raw.motion.x, raw.motion.y),
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => .{
                .mouse_down = .{
                    .pos = self.windowToLogical(raw.button.x, raw.button.y),
                    .button = translateButton(raw.button.button),
                    .clicks = raw.button.clicks,
                },
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => .{
                .mouse_up = .{
                    .pos = self.windowToLogical(raw.button.x, raw.button.y),
                    .button = translateButton(raw.button.button),
                },
            },
            c.SDL_EVENT_MOUSE_WHEEL => .{
                .scroll = .{
                    .pos = self.windowToLogical(raw.wheel.mouse_x, raw.wheel.mouse_y),
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
                const text = eventText(raw.text.text);
                if (text.len == 0) break :blk null;
                // 回滚在 appendTextInputChunks 的 errdefer 里做完。这里不再 shrink 一次。
                switch (platform.queueTextInputChunks(self.allocator, &self.pending_events, text)) {
                    .queued => break :blk self.popPending(),
                    .oom_prefix => |ev| {
                        std.log.err("text input OOM; kept {d} bytes and dropped the rest", .{ev.text_input.len});
                        break :blk if (ev.text_input.len == 0) null else ev;
                    },
                }
            },
            // 候选词列表（TEXT_EDITING_CANDIDATES）还没翻译，UI 也还不会画。
            c.SDL_EVENT_TEXT_EDITING => platform.textEditingFromUtf8(
                eventText(raw.edit.text),
                raw.edit.start,
                raw.edit.length,
            ),
            else => null,
        };
    }

    fn eventText(ptr: [*c]const u8) []const u8 {
        const cstr = ptr orelse return "";
        return std.mem.span(cstr);
    }

    fn translateButton(btn: u8) platform.MouseButton {
        return platform.mouseButtonFromCode(btn);
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
                if (self.popPending()) |ev| return ev;
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
                if (self.popPending()) |ev| return ev;
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
                return self.cached_metrics;
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
                // TODO(PR2): 局部重绘。这里把脏区记下来，下面的 load op 仍然是整屏 CLEAR。
                self.last_damage_rect = params.damage_rect;
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

                if (w != 0) self.pixel_width = w;
                if (h != 0) self.pixel_height = h;

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
            fn call(ptr: *anyopaque, physical_width: u32, physical_height: u32) void {
                const self: *SdlBackend = @ptrCast(@alignCast(ptr));
                // 不在这里重建交换链。SDL_GPU 没有按宽高重建的公开 API：
                // `SDL_SetGPUSwapchainParameters` 只改 composition / present mode。
                // Vulkan 后端在事件进入队列时看到 PIXEL_SIZE_CHANGED，把
                // needsSwapchainRecreate 设上，下一次 WaitAndAcquire 才真正重建，
                // 尺寸来自那个事件里的像素（也就是 SizeInPixels）。
                // Metal 后端则在 acquire 时读 layer.drawableSize。
                // 我们要做的是把 AppLoop 算好的像素尺寸留在后端状态里，
                // acquire 回来的纹理尺寸会再覆盖一次（见 renderFrame）。
                self.pixel_width = @max(physical_width, 1);
                self.pixel_height = @max(physical_height, 1);
                self.cached_metrics.pixel_width = self.pixel_width;
                self.cached_metrics.pixel_height = self.pixel_height;
            }
        }.call,
        .deinit = struct {
            fn call(_: *anyopaque) void {}
        }.call,
    };
};
