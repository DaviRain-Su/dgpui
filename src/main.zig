const std = @import("std");
const dgpui = @import("dgpui");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const sdl = try dgpui.backend.sdl.SdlBackend.init(gpa, "dgpui — Todo Demo (Scroll + Focus)", 900, 680);
    defer sdl.deinitSelf();

    var state = dgpui.demo.DemoState{};
    try state.setup(gpa);
    defer state.deinit();

    var loop = dgpui.app.AppLoop.init(gpa, sdl.platformBackend(), sdl.rendererBackend());
    defer loop.deinit();
    loop.clear_color = dgpui.math.Color.fromHex(0x181926);
    loop.callbacks = .{
        .ctx = &state,
        .onEvent = dgpui.demo.DemoState.onEvent,
        .onRender = dgpui.demo.DemoState.onRender,
        .atlasFrame = dgpui.demo.DemoState.atlasFrame,
        .atlasClearDirty = dgpui.demo.DemoState.atlasClearDirty,
    };

    try loop.run();
}
