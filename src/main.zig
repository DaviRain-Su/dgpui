const std = @import("std");
const dgpui = @import("dgpui");

const TodoList = struct {
    items: [32][64]u8 = undefined,
    lengths: [32]usize = @splat(0),
    count: usize = 0,
    draft: [64]u8 = undefined,
    draft_len: usize = 0,
    scroll: dgpui.ui.ScrollState = .{},

    fn draftSlice(self: *const TodoList) []const u8 {
        return self.draft[0..self.draft_len];
    }

    fn itemSlice(self: *const TodoList, i: usize) []const u8 {
        return self.items[i][0..self.lengths[i]];
    }

    fn appendDraftChar(self: *TodoList, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (self.draft_len + bytes.len > self.draft.len) return;
        @memcpy(self.draft[self.draft_len..][0..bytes.len], bytes);
        self.draft_len += bytes.len;
    }

    fn backspace(self: *TodoList) void {
        if (self.draft_len == 0) return;
        // 简单按字节删；教育 demo 不处理组合字符边界
        self.draft_len -= 1;
    }

    fn commitDraft(self: *TodoList) bool {
        if (self.draft_len == 0 or self.count >= self.items.len) return false;
        const i = self.count;
        const n = @min(self.draft_len, self.items[i].len);
        @memcpy(self.items[i][0..n], self.draft[0..n]);
        self.lengths[i] = n;
        self.count += 1;
        self.draft_len = 0;
        return true;
    }
};

const DemoState = struct {
    entities: dgpui.entity.EntityStore = undefined,
    todos: TodoList = .{},
    todos_id: dgpui.entity.EntityId = .{ .index = 0, .generation = 0 },
    focus: dgpui.input.FocusManager = .{},
    text_system: dgpui.text.TextSystem = undefined,
    text_ready: bool = false,
    scale: f32 = 1,
    view_key: u64 = 1,

    fn setup(self: *DemoState, gpa: std.mem.Allocator) !void {
        self.entities = dgpui.entity.EntityStore.init(gpa);
        self.todos_id = try self.entities.insert(&self.todos);
        try self.entities.observe(self.todos_id, self.view_key);

        // 预置几条，方便演示滚动
        const seeds = [_][]const u8{
            "读完 EntityStore 笔记",
            "对比 GPUI / Slint / egui",
            "复习 Damage Region",
            "手写一遍 Flex shrink",
            "准备 Monday 面试口述",
            "看 Metal SDF 着色器",
            "整理 Hitbox 冒泡例子",
            "写 Todo 输入框交互",
        };
        for (seeds) |s| {
            @memcpy(self.todos.draft[0..s.len], s);
            self.todos.draft_len = s.len;
            _ = self.todos.commitDraft();
        }

        const path = dgpui.text.font.defaultFontPath() orelse return error.FontNotFound;
        try self.text_system.init(gpa, path.ptr, 1024, 1024);
        self.text_ready = true;
    }

    fn deinit(self: *DemoState) void {
        if (self.text_ready) self.text_system.deinit();
        self.entities.deinit();
    }

    fn notifyTodos(self: *DemoState) void {
        self.entities.notify(self.todos_id) catch {};
    }

    fn onFocusInput(ctx: ?*anyopaque, _: dgpui.math.Point) bool {
        const self: *DemoState = @ptrCast(@alignCast(ctx.?));
        self.focus.focus(.{
            .id = self.todos_id,
            .handler = DemoState.onFocusedEvent,
            .ctx = self,
        });
        self.notifyTodos();
        return true;
    }

    fn onFocusedEvent(ctx: ?*anyopaque, ev: dgpui.backend.platform.Event) bool {
        const self: *DemoState = @ptrCast(@alignCast(ctx.?));
        const list = if (self.entities.get(self.todos_id)) |ptr|
            @as(*TodoList, @ptrCast(@alignCast(ptr)))
        else
            return false;

        switch (ev) {
            .text_input => |tb| {
                list.appendDraftChar(tb.slice());
                self.notifyTodos();
                return true;
            },
            .key_down => |kd| {
                if (kd.key == .backspace) {
                    list.backspace();
                    self.notifyTodos();
                    return true;
                }
                if (kd.key == .enter) {
                    if (list.commitDraft()) self.notifyTodos();
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn onEvent(ctx: *anyopaque, ev: dgpui.backend.platform.Event, loop: *dgpui.app.AppLoop) void {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .scroll => |sc| {
                if (self.entities.get(self.todos_id)) |ptr| {
                    const list: *TodoList = @ptrCast(@alignCast(ptr));
                    list.scroll.applyDelta(sc.dy * 20);
                    self.notifyTodos();
                }
            },
            .key_down, .text_input, .text_editing => {
                _ = self.focus.dispatch(ev);
                if (ev == .key_down and ev.key_down.key == .escape) loop.quit();
            },
            else => {},
        }

        if (self.entities.anyDirty()) {
            self.entities.clearDirty();
            loop.requestRedraw();
        }
    }

    fn measureText(
        ctx: ?*anyopaque,
        bytes: []const u8,
        font_size: f32,
        max_width: dgpui.layout.AvailableSpace,
    ) dgpui.math.Size {
        const self: *DemoState = @ptrCast(@alignCast(ctx.?));
        if (!self.text_ready) {
            return .{ .width = @as(f32, @floatFromInt(bytes.len)) * font_size * 0.5, .height = font_size * 1.25 };
        }
        const mw: ?f32 = switch (max_width) {
            .definite => |v| v,
            .max_content => null,
        };
        return self.text_system.measureText(bytes, font_size, self.scale, mw) catch .{
            .width = @as(f32, @floatFromInt(bytes.len)) * font_size * 0.5,
            .height = font_size * 1.25,
        };
    }

    fn paintText(
        ctx: ?*anyopaque,
        dl: *dgpui.scene.DisplayList,
        text: dgpui.ui.element.TextContent,
        origin: dgpui.math.Point,
        max_width: f32,
    ) !void {
        const self: *DemoState = @ptrCast(@alignCast(ctx.?));
        if (!self.text_ready) return;
        var prepared = try self.text_system.prepareWrapped(
            text.bytes,
            origin,
            text.font_size,
            self.scale,
            max_width,
            text.color,
        );
        defer prepared.deinit(self.text_system.allocator);
        for (prepared.glyphs) |g| {
            try dl.pushGlyph(.{ .bounds = g.bounds, .uv = g.uv, .color = g.color });
        }
    }

    fn onRender(
        ctx: *anyopaque,
        dl: *dgpui.scene.DisplayList,
        frame_alloc: std.mem.Allocator,
        metrics: dgpui.backend.platform.WindowMetrics,
        hits: *dgpui.hitbox.HitList,
    ) !void {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        self.scale = metrics.scale_factor;

        const list = if (self.entities.get(self.todos_id)) |ptr|
            @as(*TodoList, @ptrCast(@alignCast(ptr)))
        else
            &self.todos;

        const title_color = dgpui.math.Color.fromHex(0xcad3f5);
        const body_color = dgpui.math.Color.fromHex(0xa5adce);
        const accent = dgpui.math.Color.fromHex(0x8aadf4);
        const focused = if (self.focus.focusedId()) |id| dgpui.entity.EntityId.eql(id, self.todos_id) else false;

        // 输入框
        var draft_buf: [80]u8 = undefined;
        const draft_show = if (list.draft_len == 0)
            if (focused) "|" else "click to type todo..."
        else blk: {
            const n = @min(list.draft_len, draft_buf.len - 1);
            @memcpy(draft_buf[0..n], list.draft[0..n]);
            if (focused and n < draft_buf.len) {
                draft_buf[n] = '|';
                break :blk draft_buf[0 .. n + 1];
            }
            break :blk draft_buf[0..n];
        };

        var input_box = (try dgpui.ui.div(frame_alloc))
            .flexRow()
            .items(.center)
            .px(12)
            .py(10)
            .w(420)
            .bg(dgpui.math.Color.fromHex(0x1e2030))
            .border(if (focused) accent else dgpui.math.Color.fromHex(0x494d64), if (focused) 2 else 1)
            .rounded(10)
            .onClick(DemoState.onFocusInput, self)
            .hitTag(2);
        input_box = try input_box.child(try dgpui.ui.textStyled(frame_alloc, draft_show, 16, if (list.draft_len == 0) body_color else title_color));

        // 列表内容（可能高于 viewport）
        var content = (try dgpui.ui.div(frame_alloc)).flexCol().gap(8).w(420);
        var i: usize = 0;
        while (i < list.count) : (i += 1) {
            // 每个 label 必须拷到 FrameArena：textStyled 只存 slice，不能共用栈缓冲。
            const label = try std.fmt.allocPrint(frame_alloc, "{d}. {s}", .{ i + 1, list.itemSlice(i) });
            var row = (try dgpui.ui.div(frame_alloc))
                .flexRow()
                .items(.center)
                .px(12)
                .py(8)
                .bg(dgpui.math.Color.fromHex(0x363a4f))
                .rounded(8);
            row = try row.child(try dgpui.ui.textStyled(frame_alloc, label, 15, title_color));
            content = try content.child(row);
        }
        // 再挂一张 comptime DSL 实例化的静态卡片，做对比
        const comptime_root = try dgpui.ui.comptime_dsl.instantiate(frame_alloc, dgpui.ui.comptime_dsl.describeCounterCard(), 0);
        content = try content.childElem(comptime_root);

        const content_elem = content.finish();
        // 先用一个较宽约束测内容高度
        try dgpui.ui.layoutTree(content_elem, .{ .width = 420, .height = 2000 }, frame_alloc, DemoState.measureText, self);
        list.scroll.content_height = content_elem.layout_node.height;
        list.scroll.viewport_height = 260;
        list.scroll.offset_y = std.math.clamp(list.scroll.offset_y, 0, list.scroll.maxOffset());

        var header = (try dgpui.ui.div(frame_alloc)).flexCol().gap(8).w(420);
        header = try header.child(try dgpui.ui.textStyled(frame_alloc, "dgpui · Scroll + Focus + comptime DSL", 20, title_color));
        header = try header.child(try dgpui.ui.textStyled(frame_alloc, "滚轮滚动列表；点输入框后打字/Enter 添加；Escape 退出", 13, body_color));
        header = try header.childElem(input_box.finish());

        const header_elem = header.finish();
        try dgpui.ui.layoutTree(header_elem, .{ .width = 420, .height = 200 }, frame_alloc, DemoState.measureText, self);

        // 外层卡片背景
        try dl.pushQuad(.{
            .bounds = dgpui.math.Rect.init((metrics.logical_width - 480) * 0.5, 40, 480, 560),
            .background = dgpui.math.Color.fromHex(0x24273a),
            .corner_radius = 16,
            .border_color = dgpui.math.Color.fromHex(0x494d64),
            .border_width = 1,
            .shadow_color = dgpui.math.Color.fromHexRgba(0x00000090),
            .shadow_blur = 18,
            .shadow_offset = .{ .x = 0, .y = 8 },
        });

        const origin_x = (metrics.logical_width - 420) * 0.5;
        try dgpui.ui.paintTreeHit(header_elem, dl, origin_x, 60, DemoState.paintText, self, hits, null, null);

        const viewport = dgpui.math.Rect.init(origin_x, 60 + header_elem.layout_node.height + 12, 420, list.scroll.viewport_height);
        // viewport 边框
        try dl.pushQuad(.{
            .bounds = viewport,
            .background = dgpui.math.Color.fromHex(0x1e2030),
            .corner_radius = 10,
            .border_color = dgpui.math.Color.fromHex(0x494d64),
            .border_width = 1,
        });
        try dgpui.ui.paintScroll(viewport, list.scroll.offset_y, content_elem, dl, DemoState.paintText, self, hits, null);
    }

    fn atlasFrame(ctx: *anyopaque) ?dgpui.app.AtlasFrame {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        if (!self.text_ready) return null;
        return .{
            .pixels = self.text_system.atlas.pixels,
            .width = self.text_system.atlas.width,
            .height = self.text_system.atlas.height,
            .dirty = self.text_system.atlas.dirty,
        };
    }

    fn atlasClearDirty(ctx: *anyopaque) void {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        if (self.text_ready) self.text_system.atlas.dirty = false;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const sdl = try dgpui.backend.sdl.SdlBackend.init(gpa, "dgpui — PR 6: Scroll + Focus + comptime", 900, 680);
    defer sdl.deinitSelf();

    var state = DemoState{};
    try state.setup(gpa);
    defer state.deinit();

    var loop = dgpui.app.AppLoop.init(gpa, sdl.platformBackend(), sdl.rendererBackend());
    defer loop.deinit();
    loop.clear_color = dgpui.math.Color.fromHex(0x181926);
    loop.callbacks = .{
        .ctx = &state,
        .onEvent = DemoState.onEvent,
        .onRender = DemoState.onRender,
        .atlasFrame = DemoState.atlasFrame,
        .atlasClearDirty = DemoState.atlasClearDirty,
    };

    try loop.run();
}
